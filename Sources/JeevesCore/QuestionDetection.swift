import Foundation

/// Decides whether an utterance is a question worth answering (docs/prd/03), using
/// fast heuristics on the provisional transcript at the end of speech.
///
/// Speech recognition punctuation is unreliable, so a missing "?" is not decisive:
/// interrogative openers ("how", "what", "can you", "is there") and request phrases
/// ("tell me about", "walk me through") count too. Call-logistics questions ("can you
/// hear me?") are ignored.
public struct QuestionDetector: Sendable {
    public struct Detection: Sendable, Equatable {
        /// The question text to answer: the question sentence, plus the sentence before
        /// it when the question alone is too short to search on.
        public var question: String
        public var reason: Reason
        /// The sentence that asks, and the utterance's text before and after it.
        public var sentence: String
        public var before: String
        public var after: String

        public init(question: String, reason: Reason, sentence: String? = nil, before: String = "", after: String = "") {
            self.question = question
            self.reason = reason
            self.sentence = sentence ?? question
            self.before = before
            self.after = after
        }
    }

    public enum Reason: String, Sendable, Equatable, Codable {
        case questionMark = "question mark"
        case interrogative = "interrogative opener"
        case request = "request phrase"
        /// A question mid-sentence after a filler: "...and it's like, what happens if...".
        case embedded = "embedded question"
    }

    public enum Rules: Sendable, Equatable {
        case current
        /// The v0.4 detector, for comparison in spike-qa: no tag-question, unfinished
        /// sentence or embedded-question rules, and the shorter request list.
        case v04
    }

    public var minimumWords: Int
    public var rules: Rules

    public init(minimumWords: Int = 3, rules: Rules = .current) {
        self.minimumWords = minimumWords
        self.rules = rules
    }

    static let interrogatives: Set<String> = [
        "what", "what's", "whats", "how", "how's", "why", "when", "where", "which", "who", "whose",
    ]
    static let auxiliaries: Set<String> = [
        "can", "could", "does", "do", "did", "is", "are", "was", "were", "should", "would", "will",
        "has", "have", "isn't", "doesn't", "don't", "aren't", "can't", "won't", "shall", "may", "might",
    ]
    /// Phrases that ask for an explanation without being grammatical questions.
    static let requestPhrases = [
        "tell me about", "tell me how", "tell me what", "tell me why", "walk me through", "explain how",
        "explain what", "explain why", "can you explain", "i'm curious", "im curious", "i'm wondering",
        "i was wondering", "i wonder", "do you know", "any idea", "any thoughts on", "help me understand",
        "remind me", "what about",
    ]
    static let addedRequestPhrases = [
        "help me unpack", "unpack that", "unpack this", "tell me more", "say more about",
        "give me more details", "give me a sense", "elaborate on", "expand on", "talk me through", "can you maybe",
        "could you maybe", "what do you mean by", "i'd love to hear", "i would love to hear", "i'd love to know",
        "curious how", "curious what", "curious why", "curious about", "how would you", "what would you",
    ]
    /// Tags that turn a statement into a check rather than a question ("It's fast, right?").
    static let tags = [
        "right", "you know", "yeah", "correct", "okay", "ok", "no", "huh", "isn't it", "aren't they", "you see", "eh", "yes",
        "true", "or what", "or something", "or whatever", "kind of", "sort of",
    ]
    /// Interrogatives that start a question in the middle of a sentence, after a filler or
    /// conjunction ("and can you maybe...", "it's like what happens if...").
    static let embeddedOpeners: Set<String> = [
        "can you", "could you", "would you", "do you", "did you", "have you", "are you", "is there", "are there",
        "what happens", "how do", "how does", "how did", "how would", "how can", "how should", "why do", "why does",
        "why is", "why would", "what do", "what does", "what is", "what's the", "which one", "does it", "can it",
        "can we", "should we", "should i", "is it",
    ]
    /// Words a finished sentence rarely ends on.
    static let danglers: Set<String> = [
        "and", "or", "but", "so", "like", "um", "uh", "the", "a", "an", "of", "to", "for", "with", "about", "in", "on",
        "at", "from", "into", "which", "because", "if", "maybe", "is", "are", "was", "were", "do", "does", "can",
        "could", "would", "should", "will", "your", "my", "our", "their", "what", "how", "why",
        "where", "when", "who", "kind", "sort", "just", "really", "basically",
    ]
    static let embeddedMarkers: Set<String> = ["like", "and", "so", "but", "um", "uh", "okay", "well", "then", "now", "also", "basically", "anyway"]
    /// Fillers that open a question without changing it ("so", "okay so", "and um").
    static let fillers: Set<String> = [
        "so", "okay", "ok", "and", "but", "um", "uh", "well", "right", "yeah", "hey", "alright", "also", "like", "now",
        "actually", "then", "oh", "hmm", "quick",
    ]
    /// Logistics and small talk, matched against the start of the normalized sentence.
    static let ignored = [
        "can you hear me", "can you see my screen", "can you see me", "can everyone hear", "is my audio",
        "are you there", "how are you", "how's it going", "how is it going", "how are things", "is that okay",
        "does that make sense", "make sense", "is that right", "you know what i mean", "right", "can i share",
        "should i share", "who just joined", "did i lose you", "am i on mute", "are you on mute", "how about you",
        "is everyone here", "shall we start", "should we get started", "what time is it",
    ]

    /// Replies often open like this ("Yeah, it's a great question...").
    static let replyOpeners = [
        "yeah", "yes", "yep", "no", "nope", "sure", "right", "exactly", "absolutely", "totally", "definitely",
        "great question", "good question", "that's a great", "that's a good", "thats a great", "so i think", "i think",
        "well", "honestly", "oh", "mhm", "uh huh", "i mean yeah", "it depends", "short answer", "so basically",
    ]

    /// True when the text opens the way a reply does.
    public static func startsLikeReply(_ text: String) -> Bool {
        let normalized = words(text).joined(separator: " ")
        return replyOpeners.contains { normalized == $0 || normalized.hasPrefix($0 + " ") }
    }

    /// When a reply begins right after a question with no pause ("...what did you
    /// learn? Yeah, I mean, it's a great question..."), the text up to the reply.
    /// Needs the question mark, since "yeah" mid-turn is common.
    public func beforeReply(_ text: String) -> String? {
        let sentences = Self.sentences(text)
        guard sentences.count >= 2 else { return nil }
        for index in (1..<sentences.count).reversed()
        where sentences[index - 1].endsWithQuestionMark && Self.startsLikeReply(sentences[index].text) {
            return sentences[..<index].map(\.text).joined(separator: " ")
        }
        return nil
    }

    /// Splits text at its first sentence (after the first) that opens like a reply.
    public static func splitAtReply(_ text: String) -> (before: String, reply: String?) {
        let sentences = sentences(text)
        guard let index = sentences.indices.dropFirst().first(where: { startsLikeReply(sentences[$0].text) }) else {
            return (text, nil)
        }
        return (sentences[..<index].map(\.text).joined(separator: " "), sentences[index...].map(\.text).joined(separator: " "))
    }

    /// Returns the question in `utterance`, or nil if it does not ask one.
    public func detect(_ utterance: String) -> Detection? {
        let sentences = Self.sentences(utterance)
        guard !sentences.isEmpty else { return nil }
        // Look at the last two sentences: a question usually ends the turn, sometimes
        // followed by a short tail ("...for the batch API? Thanks.").
        for index in sentences.indices.reversed().prefix(2) {
            let sentence = sentences[index]
            // Only a short tail may follow the question ("Thanks."); a longer one means the
            // speaker went on, as when answering their own rhetorical question.
            if rules == .current, index != sentences.count - 1, Self.words(sentences[sentences.count - 1].text).count > 4 { break }
            guard let reason = reason(for: sentence) else { continue }
            var question = sentence.text
            if Self.words(sentence.text).count < 6, index > 0 {
                question = sentences[index - 1].text + " " + question
            }
            if Self.words(question).count < minimumWords { continue }
            return Detection(question: question, reason: reason, sentence: sentence.text,
                             before: sentences[..<index].map(\.text).joined(separator: " "),
                             after: sentences[(index + 1)...].map(\.text).joined(separator: " "))
        }
        return nil
    }

    struct Sentence {
        var text: String
        var endsWithQuestionMark: Bool
    }

    func reason(for sentence: Sentence, allowUnfinished: Bool = false) -> Reason? {
        let words = Self.words(sentence.text)
        let content = Array(words.drop { Self.fillers.contains($0) })
        guard !content.isEmpty else { return nil }
        let normalized = content.joined(separator: " ")
        if Self.ignored.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") }) { return nil }
        let lowered = " " + words.joined(separator: " ") + " "
        if rules == .v04 {
            if sentence.endsWithQuestionMark { return words.count >= 2 ? .questionMark : nil }
            if Self.requestPhrases.contains(where: { lowered.contains(" " + $0 + " ") }) { return .request }
            return opener(content)
        }
        // The speaker paused mid-sentence ("and can you maybe", "what about the"): wait
        // for the rest rather than answer a fragment.
        if !sentence.endsWithQuestionMark, allowUnfinished == false, let last = words.last, Self.danglers.contains(last) { return nil }
        if (Self.requestPhrases + Self.addedRequestPhrases).contains(where: { lowered.contains(" " + $0 + " ") }) { return .request }
        if sentence.endsWithQuestionMark {
            guard words.count >= 2 else { return nil }
            // "It's great for local stuff, right?" checks a statement; it asks nothing
            // unless the rest of the sentence is a question too.
            if let tag = Self.tags.first(where: { normalized.hasSuffix(" " + $0) }) {
                let body = String(sentence.text.lowercased().dropLast()).trimmingCharacters(in: .whitespaces)
                let bodyWords = Self.words(body).dropLast(tag.split(separator: " ").count)
                let stripped = Sentence(text: bodyWords.joined(separator: " "), endsWithQuestionMark: false)
                return reason(for: stripped, allowUnfinished: true) == nil ? nil : .questionMark
            }
            return .questionMark
        }
        if let embedded = embeddedQuestion(in: words) { return embedded }
        return opener(content)
    }

    /// An interrogative or auxiliary opening ("how does...", "can you...").
    func opener(_ content: [String]) -> Reason? {
        if let first = content.first, Self.interrogatives.contains(first) || Self.auxiliaries.contains(first) {
            // "What we did was..." and "Do this first" are statements: require a few words
            // and, for auxiliaries, a subject-like second word.
            if Self.auxiliaries.contains(first) {
                let subjects: Set<String> = ["i", "you", "we", "they", "it", "he", "she", "this", "that", "there", "the", "a",
                                             "an", "claude", "my", "our", "your", "these", "those", "anyone", "one"]
                guard content.count >= 3, subjects.contains(content[1]) else { return nil }
            } else if content.count >= 2, ["we", "i", "they", "you"].contains(content[1]) && first == "what" {
                // "what we found is..." reads as a statement unless it ends with "?".
                return nil
            }
            return content.count >= minimumWords ? .interrogative : nil
        }
        return nil
    }

    /// "...and it's like what happens if you bring DuckDB into Postgres" asks, even with
    /// no question mark and no opener at the start.
    func embeddedQuestion(in words: [String]) -> Reason? {
        guard words.count >= 4 else { return nil }
        for index in 1..<(words.count - 1) where Self.embeddedMarkers.contains(words[index - 1]) {
            let pair = words[index] + " " + words[index + 1]
            guard Self.embeddedOpeners.contains(pair) else { continue }
            // At least a few words of question after the opener.
            if words.count - index >= minimumWords + 1 { return .embedded }
        }
        return nil
    }

    static func sentences(_ text: String) -> [Sentence] {
        var result: [Sentence] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "?" || character == "." || character == "!" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, words(trimmed).count > 0 {
                    result.append(Sentence(text: trimmed, endsWithQuestionMark: character == "?"))
                }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, words(tail).count > 0 { result.append(Sentence(text: tail, endsWithQuestionMark: false)) }
        return result
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }
}
