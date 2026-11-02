import AnthropicAPI
import Foundation
import KnowledgeIndex
import Testing
@testable import Assistant

@Suite struct AnswerPipelineTests {
    func knowledge() async throws -> KnowledgeBase {
        let knowledge = try KnowledgeBase(path: ":memory:")
        _ = try await knowledge.index(documents: [
            SourceDocument(location: "notes/caching.md", title: "Prompt caching",
                           markdown: "## Lifetime\n\nCached prompts stay warm for five minutes by default; every read refreshes the timer."),
        ], sourceID: "notes")
        return knowledge
    }

    func collect(_ stream: AsyncStream<AnswerEvent>) async -> [AnswerEvent] {
        var events: [AnswerEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func showsPassagesAndExplainsMissingKey() async throws {
        let pipeline = AnswerPipeline(knowledge: try await knowledge(), client: nil, mode: .standard)
        let events = await collect(pipeline.answer(question: "how long does the cache stay warm", transcript: ""))
        guard case .passages(let result) = events.first else { Issue.record("no passages event"); return }
        #expect(result.passages.first?.breadcrumb == "Prompt caching > Lifetime")
        guard case .finished(let summary) = events.last else { Issue.record("no summary"); return }
        #expect(summary.note?.contains("API key") == true)
    }

    @Test func answersNotInNotesWithoutCallingClaude() async throws {
        // The client points at a closed port: calling it would fail the test.
        let client = AnthropicClient(configuration: AnthropicConfiguration(apiKey: "x", baseURL: URL(string: "http://127.0.0.1:9")!))
        let pipeline = AnswerPipeline(knowledge: try await knowledge(), client: client, mode: .standard)
        let events = await collect(pipeline.answer(question: "does it support zebras", transcript: ""))
        #expect(events.contains(.text(AnswerPipeline.noPassagesText)))
        guard case .finished(let summary) = events.last else { Issue.record("no summary"); return }
        #expect(summary.note == "no passages matched")
    }

    @Test func reportsTransportFailureAfterOneRetry() async throws {
        let client = AnthropicClient(configuration: AnthropicConfiguration(apiKey: "x", baseURL: URL(string: "http://127.0.0.1:9")!, timeout: 5))
        let pipeline = AnswerPipeline(knowledge: try await knowledge(), client: client, mode: .fast)
        let events = await collect(pipeline.answer(question: "how long does the cache stay warm", transcript: ""))
        #expect(events.contains { if case .retrying = $0 { true } else { false } })
        guard case .failed = events.last else { Issue.record("expected failure, got \(events)"); return }
    }
}
