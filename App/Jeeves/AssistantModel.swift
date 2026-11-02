import AnthropicAPI
import Assistant
import Foundation
import KnowledgeIndex
import Observation

/// One question and its answer, as the answer panel shows it.
struct Exchange: Identifiable, Equatable {
    enum Trigger: String { case detected = "Heard", manual = "Asked" }
    enum Status: Equatable { case searching, answering, done, failed(String) }

    let id = UUID()
    let question: String
    let trigger: Trigger
    let askedAt = Date()
    var status: Status = .searching
    var passages: [Passage] = []
    var answer = ""
    var passagesMs: Double?
    var summary: AnswerSummary?
    var retryNote: String?

    var isActive: Bool { status == .searching || status == .answering }
}

/// Runs questions through the answer pipeline and keeps the recent exchanges.
@MainActor
@Observable
final class AssistantModel {
    private(set) var current: Exchange?
    private(set) var history: [Exchange] = []
    private(set) var hasAPIKey: Bool

    var mode: AnswerMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "answerMode") }
    }
    /// Answer detected questions automatically. Off: only the Ask field and "Answer last".
    var autoAnswer: Bool {
        didSet { UserDefaults.standard.set(autoAnswer, forKey: "autoAnswer") }
    }

    let knowledge: KnowledgeModel
    private var apiKey: String?
    private var task: Task<Void, Never>?
    /// Supplies the recent call transcript for each request (set by ListeningModel).
    var recentTranscript: @MainActor () -> String = { "" }

    init(knowledge: KnowledgeModel) {
        self.knowledge = knowledge
        let stored = UserDefaults.standard.string(forKey: "answerMode").flatMap(AnswerMode.init(rawValue:))
        mode = stored == .standardAdaptive ? .standard : (stored ?? .standard)
        autoAnswer = UserDefaults.standard.object(forKey: "autoAnswer") as? Bool ?? true
        // Read once at launch so the Keychain is not queried per question.
        apiKey = KeychainStore.load() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        hasAPIKey = apiKey?.isEmpty == false
    }

    static let modes: [AnswerMode] = [.fast, .standard, .deep]

    static func label(for mode: AnswerMode) -> String {
        switch mode {
        case .fast: "Fast (Haiku 5.5)"
        case .standard, .standardAdaptive: "Standard (Sonnet 5.5)"
        case .deep: "Deep (Opus 5.5)"
        }
    }

    var maskedKey: String {
        guard let apiKey, apiKey.count > 12 else { return hasAPIKey ? "saved" : "not set" }
        return String(apiKey.prefix(10)) + "..." + String(apiKey.suffix(4))
    }

    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, KeychainStore.save(trimmed) else { return false }
        apiKey = trimmed
        hasAPIKey = true
        return true
    }

    func removeAPIKey() {
        KeychainStore.delete()
        apiKey = nil
        hasAPIKey = false
    }

    /// Answers a question, replacing any answer still streaming.
    func ask(_ rawQuestion: String, trigger: Exchange.Trigger) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let base = knowledge.base else { return }
        // The same question detected twice (partial, then a repeat) is answered once.
        if trigger == .detected, let current, current.question == question, current.isActive { return }

        task?.cancel()
        if let current { archive(current) }
        current = Exchange(question: question, trigger: trigger)

        let client = apiKey.map { AnthropicClient(configuration: AnthropicConfiguration(apiKey: $0)) }
        let pipeline = AnswerPipeline(knowledge: base, client: client, mode: mode)
        let transcript = recentTranscript()
        let id = current!.id
        task = Task {
            for await event in pipeline.answer(question: question, transcript: transcript) {
                guard !Task.isCancelled, self.current?.id == id else { return }
                apply(event)
            }
        }
    }

    func clear() {
        task?.cancel()
        current = nil
        history = []
    }

    private func apply(_ event: AnswerEvent) {
        guard var exchange = current else { return }
        switch event {
        case .passages(let result):
            exchange.passages = result.passages
            exchange.passagesMs = result.milliseconds
            exchange.status = .answering
        case .text(let delta):
            exchange.answer += delta
        case .retrying(let reason):
            exchange.retryNote = "Retrying: \(reason)"
        case .finished(let summary):
            exchange.summary = summary
            if summary.refused { exchange.answer = "" }
            exchange.status = .done
        case .failed(let message):
            exchange.status = .failed(message)
        }
        current = exchange
    }

    private func archive(_ exchange: Exchange) {
        var finished = exchange
        if finished.isActive { finished.status = .failed("Interrupted by a newer question") }
        history.insert(finished, at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
    }
}
