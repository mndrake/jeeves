import Foundation

/// Text normalization for comparing transcripts: lowercase words, punctuation removed,
/// apostrophes, underscores and decimal points kept (so "max_tokens", "don't" and "5.5"
/// survive as one word each).
public enum TranscriptText {
    public static func words(_ text: String) -> [String] {
        var cleaned = ""
        let characters = Array(text.lowercased())
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber || character == "_" || character == "'" {
                cleaned.append(character)
            } else if character == ".", index > 0, index + 1 < characters.count,
                      characters[index - 1].isNumber, characters[index + 1].isNumber {
                cleaned.append(character)  // decimal point
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}

/// Word error rate: (substitutions + deletions + insertions) / reference words, from a
/// word-level edit distance.
public struct WordErrorRate: Sendable, Equatable {
    public let referenceWords: Int
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int

    public var errors: Int { substitutions + deletions + insertions }
    public var rate: Double { referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords) }

    public init(reference: String, hypothesis: String) {
        self.init(referenceWords: TranscriptText.words(reference), hypothesisWords: TranscriptText.words(hypothesis))
    }

    public init(referenceWords reference: [String], hypothesisWords hypothesis: [String]) {
        let n = reference.count, m = hypothesis.count
        // cost[i][j] = (total, substitutions, deletions, insertions) for reference[..<i], hypothesis[..<j]
        var previous = (0...m).map { (total: $0, sub: 0, del: 0, ins: $0) }
        for i in 1...max(n, 1) where n > 0 {
            var current = [(total: i, sub: 0, del: i, ins: 0)]
            for j in 1...max(m, 1) where m > 0 {
                let same = reference[i - 1] == hypothesis[j - 1]
                let diagonal = previous[j - 1]
                let up = previous[j]          // deletion of a reference word
                let left = current[j - 1]     // insertion of a hypothesis word
                let options = [
                    (total: diagonal.total + (same ? 0 : 1), sub: diagonal.sub + (same ? 0 : 1), del: diagonal.del, ins: diagonal.ins),
                    (total: up.total + 1, sub: up.sub, del: up.del + 1, ins: up.ins),
                    (total: left.total + 1, sub: left.sub, del: left.del, ins: left.ins + 1),
                ]
                current.append(options.min { $0.total < $1.total }!)
            }
            previous = current
        }
        let best = n == 0 ? (total: m, sub: 0, del: 0, ins: m) : previous[m]
        referenceWords = n
        substitutions = best.sub
        deletions = best.del
        insertions = best.ins
    }
}

/// How many domain-term occurrences in the reference also appear in the hypothesis.
/// Terms are matched as whole word sequences after normalization.
public struct TermRecall: Sendable, Equatable {
    public struct Miss: Sendable, Equatable {
        public let term: String
        public let expected: Int
        public let found: Int
    }

    public let expected: Int
    public let found: Int
    public let misses: [Miss]

    public var rate: Double { expected == 0 ? 1 : Double(found) / Double(expected) }

    public init(terms: [String], reference: String, hypothesis: String) {
        let referenceWords = TranscriptText.words(reference)
        let hypothesisWords = TranscriptText.words(hypothesis)
        var expected = 0, found = 0
        var misses: [Miss] = []
        for term in Set(terms) {
            let termWords = TranscriptText.words(term)
            guard !termWords.isEmpty else { continue }
            let inReference = Self.count(termWords, in: referenceWords)
            guard inReference > 0 else { continue }
            let inHypothesis = min(inReference, Self.count(termWords, in: hypothesisWords))
            expected += inReference
            found += inHypothesis
            if inHypothesis < inReference { misses.append(Miss(term: term, expected: inReference, found: inHypothesis)) }
        }
        self.expected = expected
        self.found = found
        self.misses = misses.sorted { $0.term < $1.term }
    }

    static func count(_ phrase: [String], in words: [String]) -> Int {
        guard phrase.count <= words.count else { return 0 }
        return (0...(words.count - phrase.count)).filter { Array(words[$0..<$0 + phrase.count]) == phrase }.count
    }
}

/// Rewrites known speech-recognition mishearings to the intended terms, e.g. "cloud code"
/// to "Claude Code" (heard every time in M0). Aliases are matched case-insensitively on
/// word boundaries, longest first, and only multi-word or unambiguous aliases should be
/// listed: "cloud" alone is a real word and must not become "Claude".
/// `@unchecked Sendable`: the compiled expressions are immutable after init.
public struct AliasTable: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let canonical: String
        public let aliases: [String]

        public init(_ canonical: String, aliases: [String]) {
            self.canonical = canonical
            self.aliases = aliases
        }
    }

    public let entries: [Entry]
    private let rules: [(pattern: NSRegularExpression, replacement: String)]

    public init(_ entries: [Entry]) {
        self.entries = entries
        let pairs = entries.flatMap { entry in entry.aliases.map { (alias: $0, canonical: entry.canonical) } }
            .sorted { $0.alias.count > $1.alias.count }
        rules = pairs.compactMap { pair in
            let words = pair.alias.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?<![\\w'])" + words.joined(separator: "[\\s,-]+") + "(?![\\w'])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: pair.canonical))
        }
    }

    public func apply(to text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.pattern.stringByReplacingMatches(in: result, range: range, withTemplate: rule.replacement)
        }
        return result
    }

    /// Mishearings observed on the MacBook Air in M0 (DECISIONS, 2026-11-02) and their
    /// obvious variants. Extend from M2 evaluation results.
    public static let anthropic = AliasTable([
        Entry("Claude Code", aliases: ["cloud code", "clawed code", "cloud coat", "claud code"]),
        Entry("Claude Desktop", aliases: ["cloud desktop", "clawed desktop"]),
        Entry("Claude API", aliases: ["cloud API", "clawed API"]),
        Entry("Claude Sonnet", aliases: ["cloud sonnet", "clawed sonnet"]),
        Entry("Claude Opus", aliases: ["cloud opus", "clawed opus"]),
        Entry("Claude Haiku", aliases: ["cloud haiku", "clawed haiku", "cloud high cue"]),
        Entry("Haiku", aliases: ["high cue", "hi coup"]),
        Entry("auto mode", aliases: ["automote", "auto mote"]),
        Entry("max_tokens", aliases: ["max tokens", "max token"]),
        Entry("MCP", aliases: ["M C P", "emcee P"]),
    ])
}

/// Compares the transcript Jeeves acts on at the end of speech (the latest partial, at
/// 400 ms of silence) with the engine's final transcript of the same speech, to measure
/// how often acting early means acting on different words (open question from M0).
public struct UtteranceTracker: Sendable {
    public struct Comparison: Sendable, Equatable {
        public let provisional: String
        public let final: String
        public let wordErrorRate: WordErrorRate
        public var identical: Bool { wordErrorRate.errors == 0 }
    }

    private struct Pending: Sendable {
        let end: SilenceEndpointer.EndOfSpeech
        let provisional: String
    }

    /// Finals whose audio ends this far after a detected end still belong to it.
    public var tolerance: Double
    private var finals: [TranscriptUpdate] = []
    private var latestPartial: TranscriptUpdate?
    private var pending: [Pending] = []
    public private(set) var comparisons: [Comparison] = []

    public init(tolerance: Double = 0.5) {
        self.tolerance = tolerance
    }

    /// Feed every engine result. Returns the comparisons this result completed.
    @discardableResult
    public mutating func update(_ result: TranscriptUpdate) -> [Comparison] {
        guard result.isFinal else {
            latestPartial = result
            return []
        }
        finals.append(result)
        if let partial = latestPartial, partial.audioEnd <= result.audioEnd + 0.01 { latestPartial = nil }
        let covered = pending.filter { result.audioEnd + tolerance >= $0.end.audioTime }
        pending.removeAll { result.audioEnd + tolerance >= $0.end.audioTime }
        let completed = covered.map { item -> Comparison in
            let finalText = text(from: item.end.speechStart, to: item.end.audioTime, includePartial: false)
            return Comparison(provisional: item.provisional, final: finalText,
                              wordErrorRate: WordErrorRate(reference: finalText, hypothesis: item.provisional))
        }
        comparisons += completed
        // Keep memory bounded: finals far behind every pending end are no longer needed.
        let horizon = (pending.map(\.end.speechStart).min() ?? result.audioEnd) - 30
        finals.removeAll { $0.audioEnd < horizon }
        return completed
    }

    /// Call at a detected end of speech. Returns the provisional text Jeeves would act on.
    @discardableResult
    public mutating func speechEnded(_ end: SilenceEndpointer.EndOfSpeech) -> String {
        let provisional = text(from: end.speechStart, to: end.audioTime, includePartial: true)
        pending.append(Pending(end: end, provisional: provisional))
        return provisional
    }

    private func text(from start: Double, to end: Double, includePartial: Bool) -> String {
        var pieces = finals.filter { $0.audioEnd > start - 0.2 && $0.audioStart < end + tolerance }.map(\.text)
        if includePartial, let partial = latestPartial, partial.audioEnd > start - 0.2 { pieces.append(partial.text) }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
