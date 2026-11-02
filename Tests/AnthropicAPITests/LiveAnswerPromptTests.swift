import Testing
@testable import AnthropicAPI

@Suite struct LiveAnswerPromptTests {
    @Test func hasNoRunsOfSpacesFromBrokenLineContinuations() {
        // A dropped `\` continuation joins source lines with their indentation.
        #expect(!LiveAnswerPrompt.system.contains("  "))
        #expect(!LiveAnswerPrompt.system.contains("\\"))
    }

    @Test func coversKnownMishearings() {
        #expect(LiveAnswerPrompt.system.contains(#""cloud code" means Claude Code"#))
        #expect(LiveAnswerPrompt.system.contains("Claude Haiku 5.5"))
    }

    @Test func isLongEnoughToCache() {
        // About 4 characters per token; the cacheable minimum is 512 tokens.
        #expect(LiveAnswerPrompt.system.count > 3_000)
    }
}
