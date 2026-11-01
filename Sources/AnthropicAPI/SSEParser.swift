/// One dispatched Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental Server-Sent Events parser (WHATWG event-stream format).
///
/// Feed it network chunks of any size; it returns each event once the blank line
/// that terminates it has arrived. Handles LF, CRLF and CR line endings, including
/// a CRLF split across two chunks, multi-line `data:` fields and `:` comments.
/// Kept free of Foundation so it is trivially testable.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastByteWasCR = false
    private var eventType: String?
    private var dataLines: [String] = []
    private var lastEventID: String?
    private var isFirstLine = true

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes {
            switch byte {
            case 0x0A:  // LF
                if lastByteWasCR { lastByteWasCR = false; continue }
                if let event = processLine() { events.append(event) }
            case 0x0D:  // CR
                lastByteWasCR = true
                if let event = processLine() { events.append(event) }
            default:
                lastByteWasCR = false
                line.append(byte)
            }
        }
        return events
    }

    /// Call at end of stream. Per the spec an event without its terminating blank
    /// line is discarded, so this only resets state.
    public mutating func finish() {
        line.removeAll()
        eventType = nil
        dataLines.removeAll()
    }

    private mutating func processLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if isFirstLine {
            // A UTF-8 byte order mark is allowed only at the very start of the stream.
            isFirstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }

        if line.isEmpty {
            defer { eventType = nil; dataLines.removeAll() }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(event: eventType, data: dataLines.joined(separator: "\n"), id: lastEventID)
        }
        if line.first == UInt8(ascii: ":") { return nil }  // comment

        let field: String
        var value: String
        if let colon = line.firstIndex(of: UInt8(ascii: ":")) {
            field = String(decoding: line[..<colon], as: UTF8.self)
            var valueStart = line.index(after: colon)
            if valueStart < line.endIndex, line[valueStart] == UInt8(ascii: " ") {
                valueStart = line.index(after: valueStart)
            }
            value = String(decoding: line[valueStart...], as: UTF8.self)
        } else {
            field = String(decoding: line, as: UTF8.self)
            value = ""
        }

        switch field {
        case "event": eventType = value
        case "data": dataLines.append(value)
        case "id": if !value.contains("\0") { lastEventID = value }
        default: value = ""  // "retry" and unknown fields are ignored
        }
        return nil
    }
}
