import Foundation

/// Re-runs end-of-speech detection and question assembly over a recorded call, with
/// any settings, so they can be compared offline (`spike-qa`).
public struct TraceReplay: Sendable {
    public struct Options: Sendable, Equatable {
        public var silenceDuration: Double
        public var speechThresholdDecibels: Float
        /// Adaptive threshold margin above the noise floor; nil for the fixed threshold.
        public var noiseMarginDecibels: Float?
        public var assembler: QuestionAssembler.Settings
        public var detectorRules: QuestionDetector.Rules

        public init(silenceDuration: Double = 0.4, speechThresholdDecibels: Float = -45, noiseMarginDecibels: Float? = 12,
                    assembler: QuestionAssembler.Settings = QuestionAssembler.Settings(),
                    detectorRules: QuestionDetector.Rules = .current) {
            self.silenceDuration = silenceDuration
            self.speechThresholdDecibels = speechThresholdDecibels
            self.noiseMarginDecibels = noiseMarginDecibels
            self.assembler = assembler
            self.detectorRules = detectorRules
        }

        /// v0.4 as shipped: fixed -45 dBFS threshold, v0.4 detector, the asking
        /// utterance alone.
        public static let v04 = Options(noiseMarginDecibels: nil, assembler: .utteranceOnly, detectorRules: .v04)
    }

    /// One question as the live app would have handled it.
    public struct Asked: Sendable, Equatable {
        /// The question when first asked, and after its last follow-up.
        public var first: QuestionAssembler.Question
        public var last: QuestionAssembler.Question
        /// Session audio time the question was first asked and last revised (end of
        /// speech plus the silence wait).
        public var askedAt: Double
        public var revisedAt: Double
    }

    public struct Result: Sendable {
        public var utterances: [QuestionAssembler.Utterance]
        public var questions: [Asked]
    }

    public static func run(_ trace: CallTrace, options: Options = Options()) -> Result {
        var endpointer = SilenceEndpointer(speechThresholdDecibels: options.speechThresholdDecibels,
                                           silenceDuration: options.silenceDuration,
                                           noiseMarginDecibels: options.noiseMarginDecibels)
        var tracker = UtteranceTracker()
        var assembler = QuestionAssembler(settings: options.assembler, detector: QuestionDetector(rules: options.detectorRules))
        var utterances: [QuestionAssembler.Utterance] = []
        var questions: [Asked] = []
        var nextUpdate = 0
        let updates = trace.updates

        for (index, level) in trace.levels.enumerated() {
            let now = Double(index + 1) * trace.step
            func handle(_ event: QuestionAssembler.Event?) {
                switch event {
                case .asked(let question):
                    questions.append(Asked(first: question, last: question, askedAt: now, revisedAt: now))
                case .revised(let question):
                    if let i = questions.lastIndex(where: { $0.first.id == question.id }) {
                        questions[i].last = question
                        questions[i].revisedAt = now
                    }
                case nil:
                    break
                }
            }
            while nextUpdate < updates.count, updates[nextUpdate].at <= now {
                let u = updates[nextUpdate]
                let completed = tracker.update(TranscriptUpdate(text: u.text, isFinal: u.isFinal, audioStart: u.start, audioEnd: u.end, receivedAt: 0))
                for comparison in completed {
                    handle(assembler.utteranceFinalized(.init(text: comparison.final, start: comparison.speechStart, end: comparison.audioEnd)))
                }
                nextUpdate += 1
            }
            guard let end = endpointer.process(levelDecibels: level, duration: trace.step,
                                               capturedAt: UInt64(now * 1_000_000_000)) else { continue }
            let text = tracker.speechEnded(end)
            let utterance = QuestionAssembler.Utterance(text: text, start: end.speechStart, end: end.audioTime)
            if !text.isEmpty { utterances.append(utterance) }
            handle(assembler.utteranceEnded(utterance))
        }
        return Result(utterances: utterances, questions: questions)
    }
}

/// A hand-checked question in a trace: where it was asked and its full wording,
/// set-up included. Stored as TSV next to the trace (`name.labels.tsv`):
/// `start<TAB>end<TAB>text`, times in seconds or m:ss, `#` for comments.
public struct QuestionLabel: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public static func parse(_ tsv: String) throws -> [QuestionLabel] {
        var labels: [QuestionLabel] = []
        for (number, raw) in tsv.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3, let start = seconds(fields[0]), let end = seconds(fields[1]), end >= start else {
                throw CallTrace.FormatError(description: "labels line \(number + 1): expected start<TAB>end<TAB>text")
            }
            labels.append(QuestionLabel(start: start, end: end, text: fields[2]))
        }
        return labels
    }

    public static func format(_ labels: [QuestionLabel], comment: String? = nil) -> String {
        var lines = comment.map { $0.split(separator: "\n").map { "# " + $0 } } ?? []
        lines += labels.map { String(format: "%.2f\t%.2f\t%@", $0.start, $0.end, $0.text) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "754.2", "12:34" or "1:02:03.5".
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Scores replayed questions against labels.
///
/// - recall: labels some question was asked for.
/// - coverage: share of a label's content words the asked text contains (lead-in and
///   follow-up included); 0 for a missed label. "Complete" means at least 0.8.
/// - extra: share of the asked text's content words that are not in the label: words
///   dragged in from earlier talk or from the reply.
/// - false triggers: questions that match no label.
/// - delay: from the end of the labelled question to the moment it was asked, and to
///   its last revision.
public struct QuestionScore: Sendable {
    public struct Match: Sendable {
        public var label: QuestionLabel
        public var asked: TraceReplay.Asked?
        public var coverage: Double
        public var firstCoverage: Double
        public var extra: Double
    }

    public var matches: [Match]
    public var falseTriggers: [TraceReplay.Asked]

    public var labels: Int { matches.count }
    public var detected: Int { matches.filter { $0.asked != nil }.count }
    public var complete: Int { matches.filter { $0.coverage >= 0.8 }.count }
    public var meanCoverage: Double { mean(matches.map(\.coverage)) }
    public var meanFirstCoverage: Double { mean(matches.map(\.firstCoverage)) }
    public var meanExtra: Double { mean(matches.compactMap { $0.asked == nil ? nil : $0.extra }) }
    public var askDelays: [Double] { matches.compactMap { m in m.asked.map { $0.askedAt - m.label.end } } }
    public var revisionDelays: [Double] { matches.compactMap { m in m.asked.map { $0.revisedAt - m.label.end } } }

    /// One number for ranking settings: coverage, discounted for extra words and false
    /// triggers. Higher is better.
    public var score: Double {
        guard labels > 0 else { return 0 }
        let falseRate = Double(falseTriggers.count) / Double(labels)
        return meanCoverage * (1 - meanExtra) - 0.25 * falseRate
    }

    public init(matches: [Match], falseTriggers: [TraceReplay.Asked]) {
        self.matches = matches
        self.falseTriggers = falseTriggers
    }

    /// Several traces' scores as one.
    public init(merging scores: [QuestionScore]) {
        self.init(matches: scores.flatMap(\.matches), falseTriggers: scores.flatMap(\.falseTriggers))
    }

    /// A question asked from `matchBefore` seconds before a label starts to `matchAfter`
    /// seconds after it ends can match it; each question matches at most one label.
    public init(labels: [QuestionLabel], asked: [TraceReplay.Asked], matchBefore: Double = 2, matchAfter: Double = 8) {
        var candidates: [(label: Int, asked: Int, coverage: Double)] = []
        for (li, label) in labels.enumerated() {
            for (qi, question) in asked.enumerated()
            where question.askedAt >= label.start - matchBefore && question.askedAt <= label.end + matchAfter {
                let coverage = Self.overlap(label.text, question.last.text).coverage
                if coverage > 0 { candidates.append((li, qi, coverage)) }
            }
        }
        var labelTaken = Set<Int>(), askedTaken = Set<Int>()
        var chosen: [Int: Int] = [:]
        for candidate in candidates.sorted(by: { $0.coverage > $1.coverage })
        where !labelTaken.contains(candidate.label) && !askedTaken.contains(candidate.asked) {
            labelTaken.insert(candidate.label)
            askedTaken.insert(candidate.asked)
            chosen[candidate.label] = candidate.asked
        }
        matches = labels.enumerated().map { li, label in
            guard let qi = chosen[li] else {
                return Match(label: label, asked: nil, coverage: 0, firstCoverage: 0, extra: 0)
            }
            let question = asked[qi]
            let last = Self.overlap(label.text, question.last.text)
            return Match(label: label, asked: question, coverage: last.coverage,
                         firstCoverage: Self.overlap(label.text, question.first.text).coverage, extra: last.extra)
        }
        falseTriggers = asked.enumerated().filter { !askedTaken.contains($0.offset) }.map(\.element)
    }

    /// Content-word overlap between a label and asked text, counting repeats.
    static func overlap(_ label: String, _ asked: String) -> (coverage: Double, extra: Double) {
        let expected = contentWords(label), got = contentWords(asked)
        guard !expected.isEmpty else { return (0, 0) }
        var remaining = [String: Int]()
        for word in got { remaining[word, default: 0] += 1 }
        var shared = 0
        for word in expected where (remaining[word] ?? 0) > 0 {
            remaining[word]! -= 1
            shared += 1
        }
        let coverage = Double(shared) / Double(expected.count)
        let extra = got.isEmpty ? 0 : 1 - Double(shared) / Double(got.count)
        return (coverage, extra)
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "of", "to", "in", "on", "at", "for", "with", "from", "by", "as",
        "is", "are", "was", "were", "be", "been", "it", "its", "it's", "this", "that", "these", "those", "there",
        "i", "you", "we", "they", "he", "she", "me", "my", "your", "our", "their", "them", "us", "do", "does", "did",
        "have", "has", "had", "can", "could", "would", "will", "should", "just", "like", "um", "uh", "yeah", "okay",
        "know", "mean", "kind", "sort", "really", "very", "what", "how", "why", "when", "where", "which", "who", "if",
        "then", "than", "about", "not", "no", "yes", "oh", "right", "well", "also", "get", "got", "thing", "things",
        "i'm", "you're", "we're", "they're", "that's", "there's", "don't", "doesn't", "gonna", "wanna", "lot",
    ]

    static func contentWords(_ text: String) -> [String] {
        QuestionDetector.words(text).filter { !stopwords.contains($0) }
    }

    private func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
