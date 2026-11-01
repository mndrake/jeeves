import Foundation

public struct Usage: Decodable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var cacheReadInputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil,
                cacheCreationInputTokens: Int? = nil, cacheReadInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    /// Later values win; `message_delta` usage is cumulative.
    public func merged(with other: Usage?) -> Usage {
        guard let other else { return self }
        return Usage(inputTokens: other.inputTokens ?? inputTokens,
                     outputTokens: other.outputTokens ?? outputTokens,
                     cacheCreationInputTokens: other.cacheCreationInputTokens ?? cacheCreationInputTokens,
                     cacheReadInputTokens: other.cacheReadInputTokens ?? cacheReadInputTokens)
    }
}

public struct APIErrorBody: Decodable, Sendable, Equatable {
    public var type: String
    public var message: String
}

/// One decoded event from a streaming Messages response.
public enum StreamEvent: Sendable, Equatable {
    case messageStart(id: String, model: String, usage: Usage?)
    /// `block` is the raw `content_block`; `blockType` is its `type` (text, thinking, fallback, ...).
    case contentBlockStart(index: Int, blockType: String, block: JSONValue)
    case textDelta(index: Int, text: String)
    /// Thinking, signature, tool-input and other non-text deltas.
    case otherDelta(index: Int, deltaType: String)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, stopDetails: JSONValue?, usage: Usage?)
    case messageStop
    case ping
    case error(APIErrorBody)
    case unknown(type: String)

    public static func decode(_ data: Data) throws -> StreamEvent {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        switch envelope.type {
        case "message_start":
            let message = try JSONDecoder().decode(MessageStart.self, from: data).message
            return .messageStart(id: message.id, model: message.model, usage: message.usage)
        case "content_block_start":
            let start = try JSONDecoder().decode(BlockStart.self, from: data)
            return .contentBlockStart(index: start.index, blockType: start.contentBlock["type"]?.stringValue ?? "unknown",
                                      block: start.contentBlock)
        case "content_block_delta":
            let delta = try JSONDecoder().decode(BlockDelta.self, from: data)
            if delta.delta.type == "text_delta" {
                return .textDelta(index: delta.index, text: delta.delta.text ?? "")
            }
            return .otherDelta(index: delta.index, deltaType: delta.delta.type)
        case "content_block_stop":
            return .contentBlockStop(index: try JSONDecoder().decode(BlockStop.self, from: data).index)
        case "message_delta":
            let delta = try JSONDecoder().decode(MessageDelta.self, from: data)
            return .messageDelta(stopReason: delta.delta.stopReason, stopDetails: delta.delta.stopDetails, usage: delta.usage)
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            return .error(try JSONDecoder().decode(ErrorEvent.self, from: data).error)
        default:
            return .unknown(type: envelope.type)
        }
    }

    private struct Envelope: Decodable { let type: String }
    private struct MessageStart: Decodable {
        struct Inner: Decodable { let id: String; let model: String; let usage: Usage? }
        let message: Inner
    }
    private struct BlockStart: Decodable {
        let index: Int
        let contentBlock: JSONValue
        enum CodingKeys: String, CodingKey { case index, contentBlock = "content_block" }
    }
    private struct BlockDelta: Decodable {
        struct Inner: Decodable { let type: String; let text: String? }
        let index: Int
        let delta: Inner
    }
    private struct BlockStop: Decodable { let index: Int }
    private struct MessageDelta: Decodable {
        struct Inner: Decodable {
            let stopReason: String?
            let stopDetails: JSONValue?
            enum CodingKeys: String, CodingKey { case stopReason = "stop_reason", stopDetails = "stop_details" }
        }
        let delta: Inner
        let usage: Usage?
    }
    private struct ErrorEvent: Decodable { let error: APIErrorBody }
}

/// A stream event stamped with the monotonic time it was decoded.
public struct TimedStreamEvent: Sendable, Equatable {
    public var event: StreamEvent
    public var receivedAt: UInt64

    public init(event: StreamEvent, receivedAt: UInt64) {
        self.event = event
        self.receivedAt = receivedAt
    }
}
