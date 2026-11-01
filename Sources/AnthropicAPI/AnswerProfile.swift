import Foundation

/// The three live-answer modes from docs/PLAN.md decision D4, encoded once so the
/// app, the spikes and the tests agree on model settings.
public enum AnswerMode: String, CaseIterable, Sendable {
    /// Claude Haiku 5.5: lowest latency and cost.
    case fast
    /// Claude Sonnet 5.5 with thinking off: the default for every detected question.
    case standard
    /// Claude Sonnet 5.5 with adaptive thinking at low effort. The API guide's preferred
    /// low-latency setting; M0 measures it against `standard` before choosing.
    case standardAdaptive = "standard-adaptive"
    /// Claude Opus 5.5 for hard, multi-document questions (hotkey or "deeper").
    case deep
}

public struct AnswerProfile: Sendable, Equatable {
    public var model: String
    public var thinking: ThinkingConfig?
    public var effort: Effort
    public var maxTokens: Int
    public var fallbacks: Fallbacks?

    public init(model: String, thinking: ThinkingConfig?, effort: Effort, maxTokens: Int, fallbacks: Fallbacks?) {
        self.model = model
        self.thinking = thinking
        self.effort = effort
        self.maxTokens = maxTokens
        self.fallbacks = fallbacks
    }

    public static func forMode(_ mode: AnswerMode) -> AnswerProfile {
        switch mode {
        case .fast:
            // Haiku 5.5 has no server-side fallback: sending `fallbacks` would 400 or be ignored.
            return AnswerProfile(model: "claude-haiku-5-5", thinking: .disabled, effort: .low, maxTokens: 300, fallbacks: nil)
        case .standard:
            return AnswerProfile(model: "claude-sonnet-5-5", thinking: .betweenTools, effort: .low, maxTokens: 300, fallbacks: .default)
        case .standardAdaptive:
            // Thinking tokens count toward max_tokens, so leave headroom.
            return AnswerProfile(model: "claude-sonnet-5-5", thinking: nil, effort: .low, maxTokens: 1024, fallbacks: .default)
        case .deep:
            // Thinking cannot be disabled on Opus 5.5; effort is the only control.
            return AnswerProfile(model: "claude-opus-5-5", thinking: nil, effort: .medium, maxTokens: 2048, fallbacks: .default)
        }
    }

    /// Beta headers this profile requires.
    public var betas: [String] { fallbacks == nil ? [] : [Fallbacks.betaHeader] }

    public func makeRequest(system: [SystemBlock], messages: [Message]) -> MessagesRequest {
        MessagesRequest(model: model, maxTokens: maxTokens, system: system, messages: messages, stream: true,
                        thinking: thinking, outputConfig: OutputConfig(effort: effort), fallbacks: fallbacks)
    }

    public struct ValidationError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Catches combinations the API rejects with a 400, before a request is sent.
    public func validate() throws {
        func fail(_ message: String) throws { throw ValidationError(description: message) }
        let isHaiku55 = model == "claude-haiku-5-5"
        let isSonnet55 = model == "claude-sonnet-5-5"
        let isOpus55 = model == "claude-opus-5-5"

        if thinking == .betweenTools {
            if !isSonnet55 { try fail("thinking.between_tools is only accepted by claude-sonnet-5-5") }
            if effort > .high { try fail("between_tools requires effort high or below") }
        }
        if thinking == .disabled {
            if isSonnet55 || isOpus55 { try fail("\(model) rejects thinking.disabled; use effort (or between_tools on Sonnet 5.5)") }
            if isHaiku55 && effort > .high { try fail("Haiku 5.5 accepts thinking.disabled only at effort high or below") }
        }
        if fallbacks != nil && isHaiku55 { try fail("claude-haiku-5-5 has no server-side fallback; omit fallbacks") }
        if maxTokens <= 0 { try fail("max_tokens must be positive") }
    }
}

/// Approximate first-party prices per million tokens (Anthropic API, 2026-10), for the
/// spend meter and spike reports. Not authoritative: check the pricing page.
public struct ModelPricing: Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double

    public static func forModel(_ model: String) -> ModelPricing? {
        switch model {
        case "claude-opus-5-5": return ModelPricing(input: 4, output: 20, cacheRead: 0.20, cacheWrite5m: 5)
        case "claude-sonnet-5-5": return ModelPricing(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.5)
        case "claude-haiku-5-5": return ModelPricing(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite5m: 0.125)
        default: return nil
        }
    }

    /// Cost in US dollars. `input_tokens` excludes cached tokens, which are billed separately.
    public func cost(of usage: Usage) -> Double {
        let perToken = 1.0 / 1_000_000
        return Double(usage.inputTokens ?? 0) * input * perToken
            + Double(usage.outputTokens ?? 0) * output * perToken
            + Double(usage.cacheReadInputTokens ?? 0) * cacheRead * perToken
            + Double(usage.cacheCreationInputTokens ?? 0) * cacheWrite5m * perToken
    }
}
