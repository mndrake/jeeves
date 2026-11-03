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

@Suite struct LiveAnswerUserTurnTests {
    @Test func numbersPassagesInOrder() {
        let turn = LiveAnswerPrompt.userTurn(
            passages: [(label: "Prompt caching > Lifetime", text: "Five minutes."), (label: "Pricing", text: "$2.")],
            transcript: "  so we moved the prompt  ", question: "How long does it last?")
        #expect(turn == "Passages:\n[1] Prompt caching > Lifetime\nFive minutes.\n\n[2] Pricing\n$2.\n\nRecent transcript:\nso we moved the prompt\n\nQuestion: How long does it last?")
    }

    @Test func marksEmptyPassagesAndTranscript() {
        let turn = LiveAnswerPrompt.userTurn(passages: [], transcript: "", question: "Q?")
        #expect(turn.contains("(no passages matched)"))
        #expect(turn.contains("Recent transcript:\n(none)"))
    }
}

@Suite struct LiveAnswerLeadInTests {
    @Test func leadInSitsBetweenTranscriptAndQuestion() {
        let turn = LiveAnswerPrompt.userTurn(passages: [], transcript: "t", question: "How do we make that cheaper?",
                                             leadIn: " We run a support bot on Sonnet. ")
        #expect(turn.hasSuffix("Recent transcript:\nt\n\nLead-in: We run a support bot on Sonnet.\n\nQuestion: How do we make that cheaper?"))
        #expect(!LiveAnswerPrompt.userTurn(passages: [], transcript: "t", question: "Q?").contains("Lead-in"))
        #expect(LiveAnswerPrompt.system.contains("lead-in"))
    }
}
