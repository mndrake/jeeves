import Foundation
import Testing
@testable import AnthropicAPI

@Suite struct RequestEncodingTests {
    private func json(_ request: MessagesRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.jsonData()) as? [String: Any])
    }

    @Test func standardProfileMatchesThePlan() throws {
        let profile = AnswerProfile.forMode(.standard)
        let request = profile.makeRequest(
            system: [SystemBlock(text: "guide", cacheControl: .ephemeral)],
            messages: [.user("Question: what is prompt caching?")])
        let body = try json(request)

        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == 300)
        #expect(body["stream"] as? Bool == true)
        #expect((body["thinking"] as? [String: String]) == ["type": "between_tools"])
        #expect((body["output_config"] as? [String: String]) == ["effort": "low"])
        #expect(body["fallbacks"] as? String == "default")
        #expect(profile.betas == ["server-side-fallback-2026-07-01"])

        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.first?["type"] as? String == "text")
        #expect((system.first?["cache_control"] as? [String: String]) == ["type": "ephemeral"])

        // Fields the current API rejects must never be sent.
        for banned in ["temperature", "top_p", "top_k"] { #expect(body[banned] == nil) }
    }

    @Test func fastProfileUsesHaikuWithoutFallbacks() throws {
        let profile = AnswerProfile.forMode(.fast)
        let body = try json(profile.makeRequest(system: [], messages: [.user("q")]))
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect((body["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect(body["fallbacks"] == nil)
        #expect(profile.betas.isEmpty)
    }

    @Test func adaptiveAndDeepProfilesOmitThinking() throws {
        for mode in [AnswerMode.standardAdaptive, .deep] {
            let body = try json(AnswerProfile.forMode(mode).makeRequest(system: [], messages: [.user("q")]))
            #expect(body["thinking"] == nil, "\(mode)")
            #expect(body["fallbacks"] as? String == "default")
        }
    }

    @Test func everyShippedProfileValidates() throws {
        for mode in AnswerMode.allCases { try AnswerProfile.forMode(mode).validate() }
    }

    @Test func validationCatchesCombinationsTheAPIRejects() {
        var profile = AnswerProfile.forMode(.standard)
        profile.effort = .xhigh
        #expect(throws: AnswerProfile.ValidationError.self) { try profile.validate() }

        var haikuBetween = AnswerProfile.forMode(.fast)
        haikuBetween.thinking = .betweenTools
        #expect(throws: AnswerProfile.ValidationError.self) { try haikuBetween.validate() }

        var haikuFallback = AnswerProfile.forMode(.fast)
        haikuFallback.fallbacks = .default
        #expect(throws: AnswerProfile.ValidationError.self) { try haikuFallback.validate() }

        var opusDisabled = AnswerProfile.forMode(.deep)
        opusDisabled.thinking = .disabled
        #expect(throws: AnswerProfile.ValidationError.self) { try opusDisabled.validate() }
    }

    @Test func urlRequestCarriesVersionKeyAndDeduplicatedBetas() throws {
        let client = AnthropicClient(configuration: AnthropicConfiguration(apiKey: "sk-test"))
        let urlRequest = try client.makeURLRequest(
            AnswerProfile.forMode(.standard).makeRequest(system: [], messages: [.user("q")]),
            betas: ["server-side-fallback-2026-07-01", "server-side-fallback-2026-07-01"])
        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(urlRequest.httpMethod == "POST")
    }

    @Test func rawBlocksAreEchoedVerbatim() throws {
        let thinking: JSONValue = .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig")])
        let message = Message(role: .assistant, content: [.raw(thinking), .text("answer")])
        let data = try JSONEncoder().encode(message)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try #require(decoded["content"] as? [[String: Any]])
        #expect(content[0]["signature"] as? String == "sig")
        #expect(content[1]["text"] as? String == "answer")
    }
}
