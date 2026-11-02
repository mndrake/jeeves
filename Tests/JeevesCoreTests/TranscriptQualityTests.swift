import Testing
@testable import JeevesCore

@Suite struct TranscriptTextTests {
    @Test func normalizesPunctuationButKeepsIdentifiersAndDecimals() {
        #expect(TranscriptText.words("Hello, Claude Code! What's max_tokens on Sonnet 5.5?")
                == ["hello", "claude", "code", "what's", "max_tokens", "on", "sonnet", "5.5"])
        #expect(TranscriptText.words("end of sentence. Next") == ["end", "of", "sentence", "next"])
    }
}

@Suite struct WordErrorRateTests {
    @Test func countsSubstitutionsDeletionsAndInsertions() {
        let wer = WordErrorRate(reference: "best practices for Claude Code", hypothesis: "best practices for cloud code today")
        #expect(wer.referenceWords == 5)
        #expect(wer.substitutions == 1 && wer.deletions == 0 && wer.insertions == 1)
        #expect(abs(wer.rate - 0.4) < 1e-9)
    }

    @Test func handlesEmptySides() {
        #expect(WordErrorRate(reference: "", hypothesis: "").rate == 0)
        #expect(WordErrorRate(reference: "a b", hypothesis: "").deletions == 2)
        #expect(WordErrorRate(reference: "", hypothesis: "a").insertions == 1)
        #expect(WordErrorRate(reference: "same words", hypothesis: "Same, words.").errors == 0)
    }
}

@Suite struct TermRecallTests {
    @Test func countsOccurrencesOfMultiWordTerms() {
        let recall = TermRecall(terms: ["Claude Code", "max_tokens", "MCP"],
                                reference: "Claude Code sets max_tokens. Claude Code again.",
                                hypothesis: "cloud code sets max_tokens. Claude Code again.")
        #expect(recall.expected == 3 && recall.found == 2)
        #expect(recall.misses == [.init(term: "Claude Code", expected: 2, found: 1)])
    }
}

@Suite struct AliasTableTests {
    @Test func rewritesObservedMishearings() {
        let text = AliasTable.anthropic.apply(to: "Okay, so best practices for cloud code. Set max tokens in automote.")
        #expect(text == "Okay, so best practices for Claude Code. Set max_tokens in auto mode.")
    }

    @Test func leavesRealUsesOfCommonWordsAlone() {
        let text = "We moved to the cloud. Code review is next."
        #expect(AliasTable.anthropic.apply(to: text) == text)  // "cloud. Code" crosses a sentence
        #expect(AliasTable.anthropic.apply(to: "cloud computing") == "cloud computing")
    }

    @Test func matchesCaseInsensitivelyOnWordBoundaries() {
        #expect(AliasTable.anthropic.apply(to: "CLOUD CODE and Cloud-Code") == "Claude Code and Claude Code")
        #expect(AliasTable.anthropic.apply(to: "cloudcode") == "cloudcode")
    }
}

@Suite struct UtteranceTrackerTests {
    func result(_ text: String, _ start: Double, _ end: Double, final: Bool) -> TranscriptUpdate {
        TranscriptUpdate(text: text, isFinal: final, audioStart: start, audioEnd: end, receivedAt: 0)
    }

    func end(_ start: Double, _ audioTime: Double) -> SilenceEndpointer.EndOfSpeech {
        .init(speechStart: start, audioTime: audioTime, wallTime: 0, detectedAt: 0)
    }

    @Test func comparesPartialAtEndpointWithTheFinal() {
        var tracker = UtteranceTracker()
        tracker.update(result("how long does a", 1.0, 2.0, final: false))
        tracker.update(result("how long does a cached prompt stay warm", 1.0, 3.4, final: false))
        let provisional = tracker.speechEnded(end(1.0, 3.5))
        #expect(provisional == "how long does a cached prompt stay warm")
        let done = tracker.update(result("How long does a cached prompt stay warm?", 1.0, 3.5, final: true))
        #expect(done.count == 1 && done[0].identical)
    }

    @Test func detectsWhenTheFinalDiffers() {
        var tracker = UtteranceTracker()
        tracker.update(result("what does cloud code cost", 5.0, 7.0, final: false))
        tracker.speechEnded(end(5.0, 7.1))
        let done = tracker.update(result("What does Claude Code cost?", 5.0, 7.1, final: true))
        #expect(done.first?.wordErrorRate.substitutions == 1)
        #expect(tracker.comparisons.count == 1)
    }

    @Test func includesFinalsAlreadyReceivedInsideALongUtterance() {
        var tracker = UtteranceTracker()
        tracker.update(result("First part of a long question,", 10.0, 13.0, final: true))
        tracker.update(result("and the rest", 13.0, 14.0, final: false))
        #expect(tracker.speechEnded(end(10.0, 14.2)) == "First part of a long question, and the rest")
        let done = tracker.update(result("and the rest of it?", 13.0, 14.2, final: true))
        #expect(done.first?.final == "First part of a long question, and the rest of it?")
        #expect(done.first?.wordErrorRate.deletions == 2)
    }
}
