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
    }

    public enum Reason: String, Sendable, Equatable {
        case questionMark = "question mark"
        case interrogative = "interrogative opener"
        case request = "request phrase"
    }

    public var minimumWords: Int

    public init(minimumWords: Int = 3) {
        self.minimumWords = minimumWords
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

    /// Returns the question in `utterance`, or nil if it does not ask one.
    public func detect(_ utterance: String) -> Detection? {
        let sentences = Self.sentences(utterance)
        guard !sentences.isEmpty else { return nil }
        // Look at the last two sentences: a question usually ends the turn, sometimes
        // followed by a short tail ("...for the batch API? Thanks.").
        for index in sentences.indices.reversed().prefix(2) {
            let sentence = sentences[index]
            guard let reason = reason(for: sentence) else { continue }
            var question = sentence.text
            if Self.words(sentence.text).count < 6, index > 0 {
                question = sentences[index - 1].text + " " + question
            }
            if Self.words(question).count < minimumWords { continue }
            return Detection(question: question, reason: reason)
        }
        return nil
    }

    struct Sentence {
        var text: String
        var endsWithQuestionMark: Bool
    }

    func reason(for sentence: Sentence) -> Reason? {
        let words = Self.words(sentence.text)
        let content = Array(words.drop { Self.fillers.contains($0) })
        guard !content.isEmpty else { return nil }
        let normalized = content.joined(separator: " ")
        if Self.ignored.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") }) { return nil }
        if sentence.endsWithQuestionMark { return words.count >= 2 ? .questionMark : nil }
        let lowered = " " + words.joined(separator: " ") + " "
        if Self.requestPhrases.contains(where: { lowered.contains(" " + $0 + " ") }) { return .request }
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
