import Testing
@testable import AnthropicAPI

@Suite struct SSEParserTests {
    @Test func parsesAnthropicStyleEvents() {
        var parser = SSEParser()
        let stream = """
        event: message_start
        data: {"type":"message_start"}

        event: ping
        data: {"type":"ping"}


        """
        let events = parser.feed(Array(stream.utf8))
        #expect(events == [
            SSEEvent(event: "message_start", data: #"{"type":"message_start"}"#),
            SSEEvent(event: "ping", data: #"{"type":"ping"}"#),
        ])
    }

    @Test func handlesChunksSplitAnywhereIncludingCRLF() {
        let stream = "event: a\r\ndata: one\r\n\r\nevent: b\r\ndata: two\r\n\r\n"
        let bytes = Array(stream.utf8)
        // Every possible split point, including between \r and \n.
        for split in 0...bytes.count {
            var parser = SSEParser()
            let events = parser.feed(bytes[..<split]) + parser.feed(bytes[split...])
            #expect(events.map(\.data) == ["one", "two"], "split at \(split)")
            #expect(events.map(\.event) == ["a", "b"])
        }
    }

    @Test func byteAtATimeMatchesWholeFeed() {
        let stream = "data: x\n\n: comment\ndata: y\ndata: z\n\nevent: e\rdata: w\r\r"
        var whole = SSEParser()
        let expected = whole.feed(Array(stream.utf8))
        var single = SSEParser()
        var events: [SSEEvent] = []
        for byte in stream.utf8 { events += single.feed([byte]) }
        #expect(events == expected)
        #expect(expected.map(\.data) == ["x", "y\nz", "w"])
    }

    @Test func ignoresCommentsAndUnknownFieldsAndStripsOneLeadingSpace() {
        var parser = SSEParser()
        let events = parser.feed(Array(": keepalive\nretry: 10\nfoo: bar\ndata:  two spaces\ndata:none\n\n".utf8))
        #expect(events == [SSEEvent(event: nil, data: " two spaces\nnone")])
    }

    @Test func blankLineWithoutDataDispatchesNothingAndResetsEventType() {
        var parser = SSEParser()
        let events = parser.feed(Array("event: orphan\n\ndata: x\n\n".utf8))
        #expect(events == [SSEEvent(event: nil, data: "x")])
    }

    @Test func incompleteTrailingEventIsNotDispatched() {
        var parser = SSEParser()
        #expect(parser.feed(Array("data: partial\n".utf8)).isEmpty)
        parser.finish()
        #expect(parser.feed(Array("\n".utf8)).isEmpty)
    }

    @Test func stripsByteOrderMarkOnlyAtStreamStart() {
        var parser = SSEParser()
        let events = parser.feed([0xEF, 0xBB, 0xBF] + Array("data: a\n\n".utf8))
        #expect(events.map(\.data) == ["a"])
    }

    @Test func decodesMultiByteUTF8SplitAcrossChunks() {
        let bytes = Array("data: café ☕\n\n".utf8)
        var parser = SSEParser()
        let events = parser.feed(bytes[..<10]) + parser.feed(bytes[10...])
        #expect(events.map(\.data) == ["café ☕"])
    }
}
