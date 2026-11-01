import Foundation

/// Request body for `POST /v1/messages`, limited to the fields Jeeves uses.
///
/// Deliberately absent: `temperature`, `top_p`, `top_k` (rejected on API version
/// 2026-10-21) and assistant prefill (rejected on current models).
public struct MessagesRequest: Encodable, Sendable, Equatable {
    public var model: String
    public var maxTokens: Int
    public var system: [SystemBlock]?
    public var messages: [Message]
    public var stream: Bool
    public var thinking: ThinkingConfig?
    public var outputConfig: OutputConfig?
    public var fallbacks: Fallbacks?

    public init(model: String, maxTokens: Int, system: [SystemBlock]? = nil, messages: [Message],
                stream: Bool = true, thinking: ThinkingConfig? = nil, outputConfig: OutputConfig? = nil,
                fallbacks: Fallbacks? = nil) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.stream = stream
        self.thinking = thinking
        self.outputConfig = outputConfig
        self.fallbacks = fallbacks
    }

    enum CodingKeys: String, CodingKey {
        case model, system, messages, stream, thinking, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }
}

public struct CacheControl: Encodable, Sendable, Equatable {
    public var ttl: String?
    public static let ephemeral = CacheControl(ttl: nil)
    public static let oneHour = CacheControl(ttl: "1h")

    enum CodingKeys: String, CodingKey { case type, ttl }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("ephemeral", forKey: .type)
        try container.encodeIfPresent(ttl, forKey: .ttl)
    }
}

public struct SystemBlock: Encodable, Sendable, Equatable {
    public var text: String
    public var cacheControl: CacheControl?

    public init(text: String, cacheControl: CacheControl? = nil) {
        self.text = text
        self.cacheControl = cacheControl
    }

    enum CodingKeys: String, CodingKey { case type, text, cacheControl = "cache_control" }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
    }
}

public enum Role: String, Encodable, Sendable { case user, assistant }

public struct Message: Encodable, Sendable, Equatable {
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> Message { Message(role: .user, content: [.text(text)]) }
}

public enum ContentBlock: Encodable, Sendable, Equatable {
    case text(String, cacheControl: CacheControl? = nil)
    /// A block returned by the API, echoed back verbatim (for example a thinking
    /// block, which must be passed back unchanged in later turns).
    case raw(JSONValue)

    enum CodingKeys: String, CodingKey { case type, text, cacheControl = "cache_control" }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text, let cacheControl):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case .raw(let value):
            try value.encode(to: encoder)
        }
    }
}

/// `thinking` request field.
public enum ThinkingConfig: Encodable, Sendable, Equatable {
    /// Adaptive thinking; `display` is "summarized", "omitted" or nil for the default.
    case adaptive(display: String? = nil)
    /// Accepted on Claude Haiku 5.5 at effort `high` or below. Rejected on Sonnet 5.5 and Opus 5.5.
    case disabled
    /// Claude Sonnet 5.5 only: no extended thinking. Effort `high` or below, no other fields.
    case betweenTools

    enum CodingKeys: String, CodingKey { case type, display }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .adaptive(let display):
            try container.encode("adaptive", forKey: .type)
            try container.encodeIfPresent(display, forKey: .display)
        case .disabled:
            try container.encode("disabled", forKey: .type)
        case .betweenTools:
            try container.encode("between_tools", forKey: .type)
        }
    }
}

public enum Effort: String, Encodable, Sendable, Comparable, CaseIterable {
    case low, medium, high, xhigh, max

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: Effort, rhs: Effort) -> Bool { lhs.rank < rhs.rank }
}

public struct OutputConfig: Encodable, Sendable, Equatable {
    public var effort: Effort?
    public init(effort: Effort?) { self.effort = effort }
}

/// Server-side refusal fallback. The `"default"` form routes by refusal category and
/// needs the `server-side-fallback-2026-07-01` beta header.
public enum Fallbacks: Encodable, Sendable, Equatable {
    case `default`

    public static let betaHeader = "server-side-fallback-2026-07-01"

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .default: try container.encode("default")
        }
    }
}

extension MessagesRequest {
    /// Encodes with sorted keys so the bytes are stable (prompt caching is a prefix match).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
