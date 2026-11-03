import Foundation

/// Turns utterances (speech between pauses) into whole questions.
///
/// Speakers often set a question up over several sentences, with pauses in between:
/// "We run a support bot on Sonnet. The system prompt is about twenty thousand tokens.
/// How do we make that cheaper?" Each pause ends an utterance, so the utterance that
/// asks holds only the last sentence. The assembler keeps recent utterances and, when
/// one ends, looks for a question at the end of the turn so far: the earlier utterances
/// joined across pauses up to `leadInGap` long, starting at most `leadInSeconds`
/// earlier and never reaching back into an earlier question. What comes before the
/// question sentence is its lead-in. With `followUpWindow` set,
/// speech that continues within that window revises the question ("...I mean
/// specifically with the batch API").
///
/// Without speaker labels, a lead-in can include the end of someone else's answer, and
/// a follow-up can be the start of the reply; a sentence that opens like a reply
/// ("Yeah, great question...") marks where the question ended. The defaults come from
/// replaying recorded calls against hand-checked questions (`spike-qa sweep`,
/// docs/QUESTIONS.md).
public struct QuestionAssembler: Sendable {
    public struct Settings: Sendable, Equatable, Codable {
        /// Longest pause between two utterances that still joins them into one lead-in.
        public var leadInGap: Double
        /// How far before the asking utterance a lead-in may start.
        public var leadInSeconds: Double
        /// The lead-in keeps at most this many words (the most recent ones).
        public var leadInWords: Int
        /// Seconds after a question in which more speech revises it. 0 turns revisions off.
        public var followUpWindow: Double
        /// A revised question gains at most this many words of follow-up.
        public var followUpWords: Int

        /// Defaults from `spike-qa sweep` over three recorded interviews (45 minutes, 11
        /// hand-checked questions; docs/QUESTIONS.md).
        public init(leadInGap: Double = 1.2, leadInSeconds: Double = 20, leadInWords: Int = 80,
                    followUpWindow: Double = 2, followUpWords: Int = 60) {
            self.leadInGap = leadInGap
            self.leadInSeconds = leadInSeconds
            self.leadInWords = leadInWords
            self.followUpWindow = followUpWindow
            self.followUpWords = followUpWords
        }

        /// The v0.4 behaviour, for comparison: the detector's question text alone (the
        /// question sentence, plus the sentence before it when it is very short).
        public static let utteranceOnly = Settings(leadInGap: 0, leadInSeconds: 0, leadInWords: 0, followUpWindow: 0)
    }

    public struct Utterance: Sendable, Equatable {
        public var text: String
        /// Session audio time, in seconds.
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public struct Question: Sendable, Equatable {
        /// Stable across revisions of the same question.
        public var id: Int
        /// What the speaker said before asking: earlier utterances of the turn and any
        /// sentences of the asking utterance before the question sentence.
        public var leadIn: String
        /// The question sentence and the rest of its utterance.
        public var question: String
        /// Speech that continued the question within the follow-up window.
        public var followUp: String
        public var reason: QuestionDetector.Reason
        /// Audio span the question covers, lead-in to follow-up.
        public var start: Double
        public var end: Double
        /// 0 when first asked, then 1, 2, ... for each follow-up.
        public var revision: Int

        /// The question as asked, follow-up included, without the lead-in.
        public var asked: String { [question, followUp].filter { !$0.isEmpty }.joined(separator: " ") }
        /// Everything: lead-in, question, follow-up.
        public var text: String { [leadIn, question, followUp].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    public enum Event: Sendable, Equatable {
        case asked(Question)
        case revised(Question)

        public var question: Question {
            switch self {
            case .asked(let question), .revised(let question): question
            }
        }
    }

    public var settings: Settings
    public var detector: QuestionDetector

    private var history: [Utterance] = []
    private var open: Question?
    /// Lead-ins never reach back before this time (the end of the last question).
    private var boundary = -Double.infinity
    private var nextID = 1

    public init(settings: Settings = Settings(), detector: QuestionDetector = QuestionDetector()) {
        self.settings = settings
        self.detector = detector
    }

    /// Feed each utterance as it ends, in order. Returns a new or revised question.
    public mutating func utteranceEnded(_ utterance: Utterance) -> Event? {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let current = Utterance(text: text, start: utterance.start, end: utterance.end)
        defer {
            history.append(current)
            let horizon = current.end - max(settings.leadInSeconds, 1) - 30
            history.removeAll { $0.end < horizon }
        }

        if var question = open, settings.followUpWindow > 0, current.start - question.end <= settings.followUpWindow {
            if QuestionDetector.startsLikeReply(text) {
                open = nil
                boundary = current.end
                return nil
            }
            // The speaker carries on, and a reply may start mid-utterance: keep what
            // comes before it, then close.
            let (more, reply) = QuestionDetector.splitAtReply(text)
            let words = QuestionDetector.words(more)
            // Backchannel ("thanks", "okay") neither revises nor closes.
            if words.count < 3 && reply == nil { return nil }
            let existing = QuestionDetector.words(question.followUp).count
            if words.count >= 3, existing + words.count <= settings.followUpWords {
                question.followUp = [question.followUp, more].filter { !$0.isEmpty }.joined(separator: " ")
                question.end = current.end
                question.revision += 1
                open = reply == nil ? question : nil
                boundary = current.end
                return .revised(question)
            }
            open = nil
            boundary = current.end
            if reply != nil { return nil }
        }
        open = nil

        // Detect over the whole turn so far, not just this utterance: a question often
        // runs across pauses ("can you maybe" / "just for the uninitiated" / "explain
        // what DuckDB does"), and no single piece of it reads as a question.
        let context = leadIn(before: current)
        let utteranceOnly = settings.leadInWords == 0
        var turn = utteranceOnly ? text : [context.text, text].filter { !$0.isEmpty }.joined(separator: " ")
        // A reply that began with no pause ends the question: look before it.
        if !utteranceOnly, let beforeReply = detector.beforeReply(turn) { turn = beforeReply }
        guard let detection = detector.detect(turn) else { return nil }
        let leadIn = utteranceOnly ? "" : Self.lastWords(detection.before, settings.leadInWords)
        // v0.4 (utterance only): the detector's own question text, nothing else.
        let asked = utteranceOnly ? detection.question
            : [detection.sentence, detection.after].filter { !$0.isEmpty }.joined(separator: " ")
        let question = Question(id: nextID, leadIn: leadIn, question: asked, followUp: "", reason: detection.reason,
                                start: context.start ?? current.start, end: current.end, revision: 0)
        nextID += 1
        open = question
        boundary = current.end
        return .asked(question)
    }

    /// The latest utterance and the turn before it, for answering on demand ("Answer
    /// last") when detection missed a question.
    public var lastTurn: (leadIn: String, utterance: String)? {
        guard let last = history.last else { return nil }
        var earlier = self
        earlier.history.removeLast()
        earlier.boundary = -.infinity
        let context = earlier.leadIn(before: last).text
        return (Self.lastWords(context, max(settings.leadInWords, 40)), last.text)
    }

    /// Feed the final transcript of an utterance when it arrives (after its end of
    /// speech). The provisional text at the pause can stop mid-sentence ("what's the
    /// price of the"); if the speaker then stays quiet, no later utterance re-checks
    /// it. If this is the latest utterance and nothing was asked from it, detection
    /// runs again on the final text.
    public mutating func utteranceFinalized(_ utterance: Utterance) -> Event? {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let index = history.lastIndex(where: { abs($0.start - utterance.start) < 0.01 && abs($0.end - utterance.end) < 0.01 }),
              history[index].text != text else { return nil }
        history[index].text = text
        guard index == history.count - 1, boundary < utterance.end else { return nil }
        let latest = history.removeLast()
        return utteranceEnded(latest)
    }

    /// Earlier utterances of the same turn, oldest first.
    private func leadIn(before current: Utterance) -> (text: String, start: Double?) {
        guard settings.leadInSeconds > 0, settings.leadInWords > 0 else { return ("", nil) }
        var picked: [Utterance] = []
        var next = current
        for utterance in history.reversed() {
            guard utterance.end > boundary,
                  next.start - utterance.end <= settings.leadInGap,
                  current.start - utterance.start <= settings.leadInSeconds else { break }
            picked.append(utterance)
            next = utterance
        }
        picked.reverse()
        return (picked.map(\.text).joined(separator: " "), picked.first?.start)
    }

    static func lastWords(_ text: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > limit else { return text }
        return words.suffix(limit).joined(separator: " ")
    }
}
