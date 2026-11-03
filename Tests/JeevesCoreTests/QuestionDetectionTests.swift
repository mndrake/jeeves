import Testing
@testable import JeevesCore

@Suite struct QuestionDetectionTests {
    let detector = QuestionDetector()

    @Test(arguments: [
        "How long does a cached prompt stay warm?",
        "so how long does a cached prompt stay warm",            // no punctuation from STT
        "Okay so quick question for you. What does Sonnet five five cost?",
        "Can you explain how prompt caching works with batches",
        "walk me through setting up hooks in cloud code",
        "Is there a way to turn off thinking on Haiku",
        "I was wondering whether the batch API supports caching.",
        "Does Claude support PDFs natively",
        "We moved the system prompt. Why would it not be caching?",
        "It's a neat trick and it's like what happens if you bring DuckDB into Postgres",
        "Help me unpack that one. Why evil, give me more details on that",
        "Is it cached or no?",
    ])
    func detectsQuestions(_ text: String) {
        #expect(detector.detect(text) != nil, "\(text)")
    }

    @Test(arguments: [
        "We moved the system prompt to the front last week.",
        "Can you hear me?",
        "can you see my screen",
        "How are you doing today?",
        "Does that make sense?",
        "Okay. Right.",
        "What we found is that caching cut the bill in half.",
        "Do it.",
        "Yeah.",
        "",
        "It's great for local stuff, right?",
        "OLTP databases are row based stores, right?",
        "How do we convert geo types? So we have an extension that does that for us.",
        "That's what happens when you skip the cache.",
    ])
    func ignoresStatementsAndLogistics(_ text: String) {
        #expect(detector.detect(text) == nil, "\(text)")
    }

    @Test func shortQuestionTakesThePreviousSentenceAsContext() {
        let detection = detector.detect("We use Opus for the hard cases. Why is that slower?")
        #expect(detection?.question == "We use Opus for the hard cases. Why is that slower?")
        #expect(detection?.reason == .questionMark)
    }

    @Test func picksTheQuestionNotTheTrailingThanks() {
        let detection = detector.detect("What does the one hour cache cost to write? Thanks.")
        #expect(detection?.question == "What does the one hour cache cost to write?")
    }

    @Test func longQuestionStandsAlone() {
        let detection = detector.detect("Thanks for that. How much more does a one hour cache write cost than five minutes?")
        #expect(detection?.question == "How much more does a one hour cache write cost than five minutes?")
    }
}
