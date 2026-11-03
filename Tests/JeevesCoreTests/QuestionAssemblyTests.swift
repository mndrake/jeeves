import Foundation
import Testing
@testable import JeevesCore

@Suite struct QuestionAssemblerTests {
    typealias U = QuestionAssembler.Utterance

    func run(_ assembler: inout QuestionAssembler, _ utterances: [U]) -> [QuestionAssembler.Event] {
        utterances.compactMap { assembler.utteranceEnded($0) }
    }

    @Test func joinsTheLeadInAcrossShortPauses() {
        var assembler = QuestionAssembler()
        let events = run(&assembler, [
            U(text: "We run a support bot on Sonnet.", start: 0, end: 2.0),
            U(text: "The system prompt is about twenty thousand tokens.", start: 2.8, end: 5.5),
            U(text: "How do we make that cheaper?", start: 6.3, end: 8.0),
        ])
        #expect(events.count == 1)
        let question = events[0].question
        #expect(question.leadIn == "We run a support bot on Sonnet. The system prompt is about twenty thousand tokens.")
        #expect(question.question == "How do we make that cheaper?")
        #expect(question.start == 0)
        #expect(question.text.hasPrefix("We run a support bot"))
    }

    @Test func stopsAtLongPausesAndTheLookbackLimit() {
        var assembler = QuestionAssembler(settings: .init(leadInGap: 1.5, leadInSeconds: 10))
        // The 2.5 s pause before "We use prompt caching" is longer than the gap.
        let events = run(&assembler, [
            U(text: "Unrelated chatter about the weather today.", start: 0, end: 3),
            U(text: "We use prompt caching already.", start: 5.5, end: 8),        // 2.5 s pause before: new turn
            U(text: "And we batch the nightly jobs.", start: 8.5, end: 10),
            U(text: "What else can we do about cost?", start: 10.6, end: 12.5),
        ])
        #expect(events.first?.question.leadIn == "We use prompt caching already. And we batch the nightly jobs.")

        var short = QuestionAssembler(settings: .init(leadInGap: 1.5, leadInSeconds: 5))
        let limited = run(&short, [
            U(text: "First sentence of a long setup.", start: 0, end: 4),
            U(text: "Second sentence of the setup.", start: 4.5, end: 8),
            U(text: "Which model should we pick?", start: 8.5, end: 10),
        ])
        #expect(limited.first?.question.leadIn == "Second sentence of the setup.")
    }

    @Test func neverReachesBackIntoAnEarlierQuestion() {
        var assembler = QuestionAssembler(settings: .init(followUpWindow: 0))
        let events = run(&assembler, [
            U(text: "How long does a cached prompt stay warm?", start: 0, end: 2),
            U(text: "Five minutes by default.", start: 2.5, end: 4),
            U(text: "And what does a cache write cost?", start: 4.5, end: 6),
        ])
        #expect(events.count == 2)
        #expect(events[1].question.leadIn == "Five minutes by default.")
    }

    @Test func keepsTheWholeAskingUtterance() {
        var assembler = QuestionAssembler()
        let event = assembler.utteranceEnded(U(text: "We moved to Opus last week. So how do we turn on extended thinking? Thanks.",
                                               start: 0, end: 5))
        #expect(event?.question.leadIn == "We moved to Opus last week.")
        #expect(event?.question.question == "So how do we turn on extended thinking? Thanks.")
    }

    @Test func capsTheLeadInToTheMostRecentWords() {
        var assembler = QuestionAssembler(settings: .init(leadInWords: 4))
        let event = run(&assembler, [
            U(text: "One two three four five six.", start: 0, end: 2),
            U(text: "How does streaming work?", start: 2.5, end: 4),
        ]).first
        #expect(event?.question.leadIn == "three four five six.")
    }

    @Test func detectsAQuestionSplitAcrossPauses() {
        var assembler = QuestionAssembler()
        let events = run(&assembler, [
            U(text: "It's a really neat extension.", start: 0, end: 2),
            U(text: "And can you maybe", start: 2.5, end: 3.5),
            U(text: "just for the uninitiated", start: 4.4, end: 5.6),
            U(text: "explain what DuckDB does", start: 6.0, end: 7.5),
        ])
        // "And can you maybe" alone is too short to ask; each later piece completes it.
        #expect(events.first.map { $0.question.question.hasPrefix("And can you maybe just for the uninitiated") } == true)
        #expect(events.first?.question.leadIn == "It's a really neat extension.")
    }

    @Test func theFinalTextCanCompleteAQuestion() {
        var assembler = QuestionAssembler()
        let cut = U(text: "What's the price of the", start: 0, end: 2)
        #expect(assembler.utteranceEnded(cut) == nil)
        let event = assembler.utteranceFinalized(U(text: "What's the price of the batch API?", start: 0, end: 2))
        #expect(event?.question.question == "What's the price of the batch API?")
        // Asked once: the same final again changes nothing.
        #expect(assembler.utteranceFinalized(U(text: "What's the price of the batch API?", start: 0, end: 2)) == nil)
    }

    @Test func aFinalForAnOlderUtteranceOnlyFixesTheLeadIn() {
        var assembler = QuestionAssembler()
        _ = assembler.utteranceEnded(U(text: "We run a support pot", start: 0, end: 2))
        _ = assembler.utteranceEnded(U(text: "on Sonnet.", start: 2.5, end: 3.5))
        #expect(assembler.utteranceFinalized(U(text: "We run a support bot", start: 0, end: 2)) == nil)
        let event = assembler.utteranceEnded(U(text: "How do we make it cheaper?", start: 4, end: 6))
        #expect(event?.question.leadIn == "We run a support bot on Sonnet.")
    }

    @Test func lastTurnGivesTheUtteranceWithItsLeadIn() {
        var assembler = QuestionAssembler()
        #expect(assembler.lastTurn == nil)
        _ = assembler.utteranceEnded(U(text: "We cache the system prompt.", start: 0, end: 2))
        _ = assembler.utteranceEnded(U(text: "The hit rate is low", start: 2.5, end: 4))
        #expect(assembler.lastTurn?.leadIn == "We cache the system prompt.")
        #expect(assembler.lastTurn?.utterance == "The hit rate is low")
    }

    @Test func aReplyWithNoPauseEndsTheQuestion() {
        var assembler = QuestionAssembler()
        let event = assembler.utteranceEnded(U(
            text: "So what did you learn from the pilot? Yeah, I mean, it's a great question. We learned a lot about data.",
            start: 0, end: 6))
        #expect(event?.question.question == "So what did you learn from the pilot?")
    }

    @Test func followUpsStopWhereTheReplyStarts() {
        var assembler = QuestionAssembler(settings: .init(followUpWindow: 2))
        _ = assembler.utteranceEnded(U(text: "How do we train taste into the models?", start: 0, end: 2))
        let event = assembler.utteranceEnded(U(text: "Like with human feedback. Yeah, so it's funny. Early on we did exactly that.",
                                               start: 2.5, end: 7))
        guard case .revised(let revised) = event else { Issue.record("expected a revision"); return }
        #expect(revised.followUp == "Like with human feedback.")
        // The reply closed the question: more speech is not a follow-up.
        #expect(assembler.utteranceEnded(U(text: "And then we moved to verifiable rewards.", start: 7.5, end: 9)) == nil)
    }

    @Test func aFollowUpQuestionIsAskedOnItsOwnWithTheFirstAsLeadIn() {
        var assembler = QuestionAssembler()
        _ = assembler.utteranceEnded(U(text: "How fast is Sonnet on long prompts?", start: 0, end: 2))
        let event = assembler.utteranceEnded(U(text: "And what about Opus with thinking on?", start: 2.6, end: 4.5))
        guard case .asked(let second) = event else { Issue.record("expected a new question, got \(String(describing: event))"); return }
        #expect(second.question == "And what about Opus with thinking on?")
        #expect(second.leadIn == "How fast is Sonnet on long prompts?")
    }

    @Test func aFirstPersonAnswerToAYouQuestionEndsIt() {
        var assembler = QuestionAssembler()
        let event = assembler.utteranceEnded(U(text: "Do you have numbers for Opus five five? We don't yet, that's coming.",
                                               start: 0, end: 5))
        #expect(event?.question.question == "Do you have numbers for Opus five five?")
        // The answer has started: the next phrase is not a follow-up.
        #expect(assembler.utteranceEnded(U(text: "We expect them in a couple of weeks.", start: 5.5, end: 8)) == nil)
    }

    @Test func asksMidSpeechWhenAReplyStartsWithNoPause() {
        var assembler = QuestionAssembler()
        #expect(assembler.speechInProgress(U(text: "So what model is best", start: 0, end: 2)) == nil)
        let event = assembler.speechInProgress(U(text: "So what model is best for this? I think Sonnet five five, honestly",
                                                 start: 0, end: 5))
        #expect(event?.question.question == "So what model is best for this?")
        #expect(assembler.speechInProgress(U(text: "So what model is best for this? I think Sonnet five five, honestly. It's fast",
                                             start: 0, end: 6)) == nil)
        // The utterance's end does not ask it again; the next utterance starts fresh.
        #expect(assembler.utteranceEnded(U(text: "So what model is best for this? I think Sonnet five five, honestly. It's fast.",
                                           start: 0, end: 12)) == nil)
        #expect(assembler.utteranceEnded(U(text: "And how do you measure that?", start: 14, end: 16)) != nil)
    }

    @Test func tagQuestionsDoNotTrigger() {
        var assembler = QuestionAssembler()
        #expect(assembler.utteranceEnded(U(text: "It's great for local stuff, right?", start: 0, end: 2)) == nil)
        #expect(assembler.utteranceEnded(U(text: "So that's the plan, you know?", start: 3, end: 5)) == nil)
        #expect(assembler.utteranceEnded(U(text: "How does that scale, right?", start: 6, end: 8)) != nil)
    }

    @Test func followUpsReviseTheQuestionWhenEnabled() {
        var assembler = QuestionAssembler(settings: .init(followUpWindow: 2))
        let events = run(&assembler, [
            U(text: "How do we cut latency?", start: 0, end: 2),
            U(text: "thanks", start: 2.4, end: 2.8),                                   // backchannel: ignored
            U(text: "Specifically for the first token on long prompts.", start: 3.2, end: 6),
            U(text: "Yeah so the first thing is caching.", start: 6.5, end: 9),        // reply: closes
            U(text: "And streaming helps too.", start: 9.5, end: 11),
        ])
        #expect(events.count == 2)
        guard case .revised(let revised) = events[1] else { Issue.record("expected a revision"); return }
        #expect(revised.id == events[0].question.id)
        #expect(revised.revision == 1)
        #expect(revised.asked == "How do we cut latency? Specifically for the first token on long prompts.")
        #expect(revised.end == 6)
    }

    @Test func followUpsCanBeTurnedOff() {
        var assembler = QuestionAssembler(settings: .init(followUpWindow: 0))
        let events = run(&assembler, [
            U(text: "How do we cut latency?", start: 0, end: 2),
            U(text: "Specifically for the first token on long prompts.", start: 2.5, end: 5),
        ])
        #expect(events.count == 1)
    }

    @Test func utteranceOnlyReproducesTheDetectorText() {
        var assembler = QuestionAssembler(settings: .utteranceOnly)
        let events = run(&assembler, [
            U(text: "We run a support bot on Sonnet.", start: 0, end: 2),
            U(text: "Our prompts are long. How do we make that cheaper?", start: 2.5, end: 6),
        ])
        #expect(events.first?.question.text == QuestionDetector().detect("Our prompts are long. How do we make that cheaper?")?.question)
    }
}

/// Builds a trace from a script: loud audio while someone speaks, quiet otherwise, and
/// one final transcript result per utterance, available 0.3 s after it ends.
func syntheticTrace(_ script: [(text: String, start: Double, end: Double)], duration: Double? = nil) -> CallTrace {
    let step = 0.05
    let total = duration ?? ((script.map(\.end).max() ?? 0) + 3)
    var levels = [Float](repeating: -70, count: Int((total / step).rounded()))
    for line in script {
        for i in Int((line.start / step).rounded())..<min(levels.count, Int((line.end / step).rounded())) { levels[i] = -20 }
    }
    let updates = script.map { CallTrace.Update(text: $0.text, isFinal: true, start: $0.start, end: $0.end, at: $0.end + 0.3) }
    return CallTrace(header: .init(source: "file", name: "synthetic"), step: step, levels: levels, updates: updates)
}

@Suite struct CallTraceTests {
    @Test func roundTripsThroughJSONLines() throws {
        var trace = syntheticTrace([("How does caching work?", 1, 3)])
        trace.questions = [.init(at: 3.4, text: "How does caching work?", reason: "question mark")]
        let parsed = try CallTrace.parse(try trace.encoded())
        #expect(parsed == trace)
    }

    @Test func writerRecordsLevelsUpdatesAndQuestions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CallTraceWriter(url: url, header: .init(source: "live", name: "test"))
        // 2.5 s of 20 ms chunks: quiet, loud from 1.0 s to 2.0 s, quiet.
        for i in 0..<125 {
            let t = Double(i) * 0.02
            writer.audio(levelDecibels: (t >= 1 && t < 2) ? -20 : -70, duration: 0.02)
        }
        writer.update(TranscriptUpdate(text: "hello there", isFinal: true, audioStart: 1, audioEnd: 2, receivedAt: 0), at: 2.8)
        writer.question("hello there?", reason: "question mark", at: 2.4)
        writer.close()

        let trace = try CallTrace.read(url)
        #expect(trace.header.source == "live")
        #expect(trace.levels.count == 50)
        #expect(trace.levels[20] == -20 && trace.levels[39] == -20)
        #expect(trace.levels[19] == -70 && trace.levels[40] == -70)
        #expect(trace.updates == [.init(text: "hello there", isFinal: true, start: 1, end: 2, at: 2.8)])
        #expect(trace.questions.count == 1)
    }

    @Test func longChunksFillEveryWindowTheyCover() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CallTraceWriter(url: url, header: .init(source: "file"))
        writer.audio(levelDecibels: -30, duration: 0.256)   // a 4,096-frame chunk at 16 kHz
        writer.audio(levelDecibels: -60, duration: 1.0)
        writer.close()
        let trace = try CallTrace.read(url)
        #expect(trace.levels.count == 26)
        #expect(trace.levels.prefix(5).allSatisfy { $0 == -30 })
        #expect(trace.levels[5] == -30)                      // 0.25-0.30 holds both chunks: the louder wins
        #expect(trace.levels[6] == -60)
    }

    @Test func rejectsFilesWithoutAHeader() {
        #expect(throws: CallTrace.FormatError.self) { try CallTrace.parse(Data("{\"type\":\"levels\"}\n".utf8)) }
        #expect(throws: CallTrace.FormatError.self) { try CallTrace.parse(Data("not json\n".utf8)) }
    }
}

@Suite struct TraceReplayTests {
    let script: [(text: String, start: Double, end: Double)] = [
        ("We run a support bot on Sonnet.", 1.0, 3.0),
        ("The system prompt is about twenty thousand tokens.", 3.8, 6.5),
        ("How do we make that cheaper?", 7.3, 9.0),
        ("Prompt caching is the first thing to try.", 10.5, 13.0),
    ]

    @Test func replaysTheLiveSegmentationAndAssembly() {
        let result = TraceReplay.run(syntheticTrace(script))
        #expect(result.utterances.count == 4)
        #expect(result.questions.count == 1)
        let asked = result.questions[0]
        #expect(asked.first.text == "We run a support bot on Sonnet. The system prompt is about twenty thousand tokens. How do we make that cheaper?")
        // Asked at the end of speech plus the 400 ms silence wait.
        #expect(abs(asked.askedAt - 9.4) < 0.06)
    }

    @Test func longerSilenceMergesUtterances() {
        let merged = TraceReplay.run(syntheticTrace(script), options: .init(silenceDuration: 0.9))
        #expect(merged.utterances.count == 2)
        #expect(merged.questions.first?.first.leadIn == "We run a support bot on Sonnet. The system prompt is about twenty thousand tokens.")
    }

    @Test func utteranceOnlyLosesTheLeadIn() {
        let result = TraceReplay.run(syntheticTrace(script), options: .init(assembler: .utteranceOnly))
        #expect(result.questions.first?.first.text == "How do we make that cheaper?")
    }
}

@Suite struct QuestionScoreTests {
    let label = QuestionLabel(start: 1, end: 9, text: "We run a support bot on Sonnet. The system prompt is about twenty thousand tokens. How do we make that cheaper?")

    func asked(_ text: String, at time: Double) -> TraceReplay.Asked {
        let question = QuestionAssembler.Question(id: 1, leadIn: "", question: text, followUp: "", reason: .questionMark,
                                                  start: 0, end: time, revision: 0)
        return TraceReplay.Asked(first: question, last: question, askedAt: time, revisedAt: time)
    }

    @Test func fullQuestionScoresComplete() {
        let score = QuestionScore(labels: [label], asked: [asked(label.text, at: 9.4)])
        #expect(score.detected == 1 && score.complete == 1)
        #expect(score.meanCoverage == 1 && score.meanExtra == 0)
        #expect(score.falseTriggers.isEmpty)
        #expect(abs(score.askDelays[0] - 0.4) < 1e-9)
    }

    @Test func fragmentScoresPartialCoverage() {
        let score = QuestionScore(labels: [label], asked: [asked("How do we make that cheaper?", at: 9.4)])
        #expect(score.detected == 1 && score.complete == 0)
        // Content words: run support bot sonnet system prompt twenty thousand tokens make cheaper -> 2 of 11.
        #expect(abs(score.meanCoverage - 2.0 / 11.0) < 1e-9)
    }

    @Test func unmatchedQuestionsAreFalseTriggersAndMissedLabelsScoreZero() {
        let score = QuestionScore(labels: [label], asked: [asked("What's the weather like there?", at: 40)])
        #expect(score.detected == 0)
        #expect(score.meanCoverage == 0)
        #expect(score.falseTriggers.count == 1)
        #expect(score.score < 0)
    }

    @Test func parsesLabelFiles() throws {
        let labels = try QuestionLabel.parse("# comment\n12:30\t12:41.5\tHow do we cut cost?\n\n754.2\t760\tAnd latency?\n")
        #expect(labels == [QuestionLabel(start: 750, end: 761.5, text: "How do we cut cost?"),
                           QuestionLabel(start: 754.2, end: 760, text: "And latency?")])
        #expect(try QuestionLabel.parse(QuestionLabel.format(labels, comment: "x")) == labels)
        #expect(throws: CallTrace.FormatError.self) { try QuestionLabel.parse("12\tno end\n") }
    }
}
