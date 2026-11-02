import AnthropicAPI
import Foundation
import JeevesCore
import KnowledgeIndex

/// What the overlay shows while one question is answered, in order: passages
/// first (phase 1, local), then streamed answer text (phase 2, Claude), then a
/// summary. See docs/PLAN.md section 5 for the latency budget of each phase.
public enum AnswerEvent: Sendable, Equatable {
    case passages(SearchResult)
    case text(String)
    /// A retryable error happened before any text arrived; the request is being sent again.
    case retrying(String)
    case finished(AnswerSummary)
    case failed(String)
}

public struct AnswerSummary: Sendable, Equatable {
    public var model: String?
    public var stopReason: String?
    public var refused: Bool
    /// From the start of the request to the first answer token.
    public var firstTokenMs: Double?
    public var totalMs: Double
    public var usage: Usage
    public var costUSD: Double?
    /// Set when Claude was not called (no API key, no passages).
    public var note: String?
}

/// Runs one question through retrieval and generation. Stateless apart from its
/// dependencies, so the app makes one per settings change.
public struct AnswerPipeline: Sendable {
    public let knowledge: KnowledgeBase
    public let client: AnthropicClient?
    public let mode: AnswerMode
    public var passageLimit: Int

    public init(knowledge: KnowledgeBase, client: AnthropicClient?, mode: AnswerMode, passageLimit: Int = 6) {
        self.knowledge = knowledge
        self.client = client
        self.mode = mode
        self.passageLimit = passageLimit
    }

    /// The text shown when no passage matched; Claude is not called, since the prompt
    /// would only produce "Not in your notes." anyway.
    public static let noPassagesText = "Not in your notes."

    /// Streams the answer. Cancelling the consuming task cancels the HTTP request.
    public func answer(question: String, transcript: String) -> AsyncStream<AnswerEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(question: question, transcript: transcript) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func run(question: String, transcript: String, emit: @Sendable (AnswerEvent) -> Void) async {
        let started = MonotonicClock.now()
        let result: SearchResult
        do {
            result = try await knowledge.search(question, limit: passageLimit)
        } catch {
            emit(.failed("Search failed: \(error)"))
            return
        }
        emit(.passages(result))

        func summary(note: String) -> AnswerSummary {
            AnswerSummary(model: nil, stopReason: nil, refused: false, firstTokenMs: nil,
                          totalMs: MonotonicClock.milliseconds(from: started, to: MonotonicClock.now()),
                          usage: Usage(), costUSD: nil, note: note)
        }
        guard !result.passages.isEmpty else {
            emit(.text(Self.noPassagesText))
            emit(.finished(summary(note: "no passages matched")))
            return
        }
        guard let client else {
            emit(.finished(summary(note: "add an Anthropic API key in Settings to get answers")))
            return
        }

        let profile = AnswerProfile.forMode(mode)
        let userTurn = LiveAnswerPrompt.userTurn(
            passages: result.passages.map { (label: $0.breadcrumb, text: $0.text) },
            transcript: transcript, question: AliasTable.anthropic.apply(to: question))
        let request = profile.makeRequest(system: [SystemBlock(text: LiveAnswerPrompt.system, cacheControl: .ephemeral)],
                                          messages: [.user(userTurn)])

        // One quick retry on overload, 5xx or network errors, but only before any
        // text was shown: retrying after that would print the answer twice.
        for attempt in 1...2 {
            let requestStarted = MonotonicClock.now()
            var accumulator = StreamAccumulator()
            var sentText = false
            do {
                for try await event in client.stream(request, betas: profile.betas) {
                    if Task.isCancelled { return }
                    if let delta = accumulator.apply(event), !delta.isEmpty {
                        sentText = true
                        emit(.text(delta))
                    }
                }
                let usage = accumulator.usage
                emit(.finished(AnswerSummary(
                    model: accumulator.servedModel ?? profile.model,
                    stopReason: accumulator.stopReason,
                    refused: accumulator.isRefusal,
                    firstTokenMs: accumulator.firstTextAt.map { MonotonicClock.milliseconds(from: requestStarted, to: $0) },
                    totalMs: MonotonicClock.milliseconds(from: started, to: MonotonicClock.now()),
                    usage: usage,
                    costUSD: ModelPricing.forModel(accumulator.servedModel ?? profile.model)?.cost(of: usage),
                    note: accumulator.isRefusal ? "Claude declined to answer; the partial text was discarded" : nil)))
                return
            } catch {
                if Task.isCancelled { return }
                let retryable = (error as? AnthropicError)?.isRetryable ?? false
                if attempt == 1, retryable, !sentText {
                    emit(.retrying("\(error)"))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                emit(.failed("\(error)"))
                return
            }
        }
    }
}
