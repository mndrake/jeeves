import Foundation
import Testing
@testable import AnthropicAPI

@Suite struct StreamAccumulatorTests {
    /// Runs raw SSE text through parser, decoder and accumulator, as the client does.
    private func accumulate(_ sse: String) throws -> StreamAccumulator {
        var parser = SSEParser()
        var accumulator = StreamAccumulator()
        var clock: UInt64 = 1_000
        for event in parser.feed(Array(sse.utf8)) {
            clock += 10
            accumulator.apply(TimedStreamEvent(event: try StreamEvent.decode(Data(event.data.utf8)), receivedAt: clock))
        }
        return accumulator
    }

    @Test func plainTextStream() throws {
        let acc = try accumulate("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"usage":{"input_tokens":120,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type":"ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"- **Cache"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" reads** cost less [1]"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":14}}

        event: message_stop
        data: {"type":"message_stop"}


        """)
        #expect(acc.answerText == "- **Cache reads** cost less [1]")
        #expect(acc.stopReason == "end_turn")
        #expect(acc.servedModel == "claude-sonnet-5-5")
        #expect(acc.usage == Usage(inputTokens: 120, outputTokens: 14, cacheCreationInputTokens: 0, cacheReadInputTokens: 900))
        #expect(acc.firstEventAt == 1_010)
        #expect(acc.firstTextAt == 1_040)  // first non-empty text delta, not message_start
        #expect(acc.isComplete)
    }

    @Test func emptyThinkingBlockBeforeTextIsIgnored() throws {
        let acc = try accumulate("""
        data: {"type":"message_start","message":{"id":"m","model":"claude-sonnet-5-5","usage":{"input_tokens":5}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}

        data: {"type":"message_stop"}


        """)
        #expect(acc.answerText == "Answer")
    }

    @Test func refusalDiscardsPartialText() throws {
        let acc = try accumulate("""
        data: {"type":"message_start","message":{"id":"m","model":"claude-sonnet-5-5","usage":{}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partial"}}

        data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":3}}

        data: {"type":"message_stop"}


        """)
        #expect(acc.isRefusal)
        #expect(acc.answerText == nil)
        #expect(acc.rawText == "Partial")
        #expect(acc.stopDetails?["category"]?.stringValue == "cyber")
    }

    @Test func serverSideFallbackBlockIsRecordedAndTextContinues() throws {
        let acc = try accumulate("""
        data: {"type":"message_start","message":{"id":"m","model":"claude-sonnet-5","usage":{}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-sonnet-5"}}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Served by fallback"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}

        data: {"type":"message_stop"}


        """)
        #expect(acc.fallbackSwitches == [.init(from: "claude-sonnet-5-5", to: "claude-sonnet-5")])
        #expect(acc.answerText == "Served by fallback")
        #expect(acc.servedModel == "claude-sonnet-5")
    }

    @Test func midStreamErrorEventIsCaptured() throws {
        let acc = try accumulate("""
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


        """)
        #expect(acc.streamError == APIErrorBody(type: "overloaded_error", message: "Overloaded"))
        #expect(AnthropicError.stream(acc.streamError!).isRetryable)
    }

    @Test func unknownEventTypesDoNotThrow() throws {
        let event = try StreamEvent.decode(Data(#"{"type":"some_future_event","x":1}"#.utf8))
        #expect(event == .unknown(type: "some_future_event"))
    }

    @Test func pricingUsesSeparateCacheRates() throws {
        let sonnet = try #require(ModelPricing.forModel("claude-sonnet-5-5"))
        let cost = sonnet.cost(of: Usage(inputTokens: 1_000_000, outputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 1_000_000))
        #expect(abs(cost - 2.20) < 1e-9)
    }
}
