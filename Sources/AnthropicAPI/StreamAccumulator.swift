import Foundation

/// Folds stream events into the state the overlay and the spikes need: the answer
/// text so far, stop reason, usage, and first-token timing.
///
/// Rules that come from the API's behaviour:
/// - Blocks are read by `type`, never by position: an adaptive-thinking response can
///   start with an empty `thinking` block, and a server-side fallback inserts a
///   `fallback` block where one model handed over to another.
/// - A `refusal` stop reason means the partial text must be discarded, not shown as
///   an answer. `answerText` returns nil in that case.
public struct StreamAccumulator: Sendable {
    public struct FallbackSwitch: Sendable, Equatable {
        public var from: String?
        public var to: String?
    }

    public private(set) var messageID: String?
    /// The model named in `message_start`. With sticky fallback routing this can
    /// differ from the requested model.
    public private(set) var servedModel: String?
    public private(set) var stopReason: String?
    public private(set) var stopDetails: JSONValue?
    public private(set) var usage = Usage()
    public private(set) var fallbackSwitches: [FallbackSwitch] = []
    public private(set) var streamError: APIErrorBody?
    public private(set) var firstEventAt: UInt64?
    public private(set) var firstTextAt: UInt64?
    public private(set) var finishedAt: UInt64?

    private var blockTypes: [Int: String] = [:]
    private var blockText: [Int: String] = [:]

    public init() {}

    public var isComplete: Bool { finishedAt != nil }
    public var isRefusal: Bool { stopReason == "refusal" }

    /// Concatenated text blocks in index order, regardless of refusal.
    public var rawText: String {
        blockText.keys.sorted().compactMap { blockTypes[$0] == "text" ? blockText[$0] : nil }.joined()
    }

    /// The text to show as an answer, or nil if the request was refused.
    public var answerText: String? { isRefusal ? nil : rawText }

    /// Returns the text appended by this event, if any, for incremental rendering.
    @discardableResult
    public mutating func apply(_ timed: TimedStreamEvent) -> String? {
        if firstEventAt == nil { firstEventAt = timed.receivedAt }
        switch timed.event {
        case .messageStart(let id, let model, let startUsage):
            messageID = id
            servedModel = model
            usage = usage.merged(with: startUsage)
        case .contentBlockStart(let index, let type, let block):
            blockTypes[index] = type
            if type == "text" {
                blockText[index] = block["text"]?.stringValue ?? ""
            } else if type == "fallback" {
                fallbackSwitches.append(FallbackSwitch(from: block["from"]?["model"]?.stringValue,
                                                       to: block["to"]?["model"]?.stringValue))
            }
        case .textDelta(let index, let text):
            guard blockTypes[index] == "text" || blockTypes[index] == nil else { return nil }
            blockTypes[index] = "text"
            blockText[index, default: ""] += text
            if firstTextAt == nil, !text.isEmpty { firstTextAt = timed.receivedAt }
            return text
        case .messageDelta(let reason, let details, let deltaUsage):
            if let reason { stopReason = reason }
            if let details { stopDetails = details }
            usage = usage.merged(with: deltaUsage)
        case .messageStop:
            finishedAt = timed.receivedAt
        case .error(let body):
            streamError = body
            finishedAt = timed.receivedAt
        case .otherDelta, .contentBlockStop, .ping, .unknown:
            break
        }
        return nil
    }
}
