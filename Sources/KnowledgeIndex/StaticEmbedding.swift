import Foundation

/// Turns text into a unit-length vector for semantic search.
public protocol Embedder: Sendable {
    /// Stored with the index; a different identifier means the vectors must be rebuilt.
    var identifier: String { get }
    var dimensions: Int { get }
    func embed(_ text: String) -> [Float]
}

public enum EmbeddingError: Error, CustomStringConvertible, Sendable {
    case invalidModel(String)

    public var description: String {
        switch self { case .invalidModel(let message): "embedding model: \(message)" }
    }
}

/// A Model2Vec static embedding model (docs/DECISIONS.md, M3 embedding shoot-out):
/// each WordPiece token has a fixed vector, and a text's embedding is the
/// L2-normalized mean of its tokens' vectors. No neural network runs at query time,
/// so a query embeds in microseconds on any CPU, and results are identical on macOS
/// and Linux.
///
/// Loads the two files Model2Vec publishes: `tokenizer.json` (Hugging Face
/// tokenizers format, WordPiece) and `model.safetensors` (one `embeddings` tensor,
/// vocabulary x dimensions, F32 or F16).
public struct StaticEmbedder: Embedder {
    public let identifier: String
    public let dimensions: Int
    public let tokenizer: WordPieceTokenizer
    /// Row-major vocabulary x dimensions.
    private let table: [Float]
    /// Tokens beyond this are ignored, as in Model2Vec's default `max_length`.
    public var maxTokens: Int

    public init(identifier: String, tokenizer: WordPieceTokenizer, table: [Float], dimensions: Int, maxTokens: Int = 512) throws {
        guard dimensions > 0, table.count % dimensions == 0, table.count / dimensions >= tokenizer.vocabularySize else {
            throw EmbeddingError.invalidModel("table of \(table.count) floats does not fit \(tokenizer.vocabularySize) tokens x \(dimensions)")
        }
        self.identifier = identifier
        self.tokenizer = tokenizer
        self.table = table
        self.dimensions = dimensions
        self.maxTokens = maxTokens
    }

    /// Loads `tokenizer.json` and `model.safetensors` from a directory.
    public init(directory: URL, identifier: String) throws {
        let tokenizer = try WordPieceTokenizer(json: Data(contentsOf: directory.appendingPathComponent("tokenizer.json")))
        let tensor = try SafeTensors.read(Data(contentsOf: directory.appendingPathComponent("model.safetensors")), name: "embeddings")
        guard tensor.shape.count == 2 else { throw EmbeddingError.invalidModel("embeddings tensor has shape \(tensor.shape)") }
        try self.init(identifier: identifier, tokenizer: tokenizer, table: tensor.values, dimensions: tensor.shape[1])
    }

    public func embed(_ text: String) -> [Float] {
        // Truncate first, then drop unknown words, as the reference does: an unknown
        // word still uses one of the `maxTokens` slots.
        let ids = tokenizer.ids(text, keepingUnknown: true).prefix(maxTokens).filter { $0 >= 0 }
        var sum = [Float](repeating: 0, count: dimensions)
        guard !ids.isEmpty else { return sum }
        table.withUnsafeBufferPointer { rows in
            sum.withUnsafeMutableBufferPointer { out in
                for id in ids {
                    let base = id * dimensions
                    for d in 0..<dimensions { out[d] += rows[base + d] }
                }
            }
        }
        var norm: Float = 0
        for value in sum { norm += value * value }
        norm = norm.squareRoot()
        guard norm > 0 else { return sum }
        return sum.map { $0 / norm }
    }
}

/// BERT-style WordPiece tokenization as Hugging Face `tokenizers` does it for
/// `BertNormalizer` + `BertPreTokenizer` + `WordPiece`: clean control characters,
/// space out CJK characters, lowercase and strip accents, split on whitespace and
/// punctuation, then greedy longest-match subwords with a `##` continuation prefix.
/// Unknown words are dropped (Model2Vec removes `[UNK]` before pooling).
public struct WordPieceTokenizer: Sendable {
    private let vocabulary: [String: Int]
    public let unknownID: Int?
    public let prefix: String
    public let maxCharactersPerWord: Int
    public let lowercase: Bool
    public let stripAccents: Bool

    public var vocabularySize: Int { (vocabulary.values.max() ?? -1) + 1 }

    public init(vocabulary: [String: Int], unknownToken: String = "[UNK]", prefix: String = "##",
                maxCharactersPerWord: Int = 100, lowercase: Bool = true, stripAccents: Bool = true) {
        self.vocabulary = vocabulary
        self.unknownID = vocabulary[unknownToken]
        self.prefix = prefix
        self.maxCharactersPerWord = maxCharactersPerWord
        self.lowercase = lowercase
        self.stripAccents = stripAccents
    }

    /// Reads a Hugging Face `tokenizer.json` with a WordPiece model.
    public init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let model = root["model"] as? [String: Any],
              (model["type"] as? String) == "WordPiece",
              let vocab = model["vocab"] as? [String: Any] else {
            throw EmbeddingError.invalidModel("tokenizer.json is not a WordPiece tokenizer")
        }
        var vocabulary: [String: Int] = [:]
        vocabulary.reserveCapacity(vocab.count)
        for (token, id) in vocab {
            if let id = id as? Int { vocabulary[token] = id } else if let id = id as? NSNumber { vocabulary[token] = id.intValue }
        }
        let normalizer = root["normalizer"] as? [String: Any]
        let lowercase = normalizer?["lowercase"] as? Bool ?? true
        // BertNormalizer: strip_accents null means "follow lowercase".
        let strip = (normalizer?["strip_accents"] as? Bool) ?? lowercase
        self.init(vocabulary: vocabulary,
                  unknownToken: model["unk_token"] as? String ?? "[UNK]",
                  prefix: model["continuing_subword_prefix"] as? String ?? "##",
                  maxCharactersPerWord: model["max_input_chars_per_word"] as? Int ?? 100,
                  lowercase: lowercase, stripAccents: strip)
    }

    /// Token IDs without unknown words. With `keepingUnknown`, each unknown word is
    /// returned as -1 instead of dropped.
    public func ids(_ text: String, keepingUnknown: Bool = false) -> [Int] {
        var ids: [Int] = []
        for word in words(normalize(text)) {
            wordPiece(word, into: &ids, keepingUnknown: keepingUnknown)
        }
        return ids
    }

    // MARK: Normalization

    func normalize(_ text: String) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            // clean_text: drop NUL, U+FFFD and control characters; map whitespace to a space.
            if value == 0 || value == 0xFFFD { continue }
            if Self.isWhitespace(scalar) { scalars.append(" "); continue }
            if Self.isControl(scalar) { continue }
            // handle_chinese_chars: surround CJK ideographs with spaces.
            if Self.isCJK(value) {
                scalars.append(" "); scalars.append(scalar); scalars.append(" ")
                continue
            }
            scalars.append(scalar)
        }
        guard lowercase || stripAccents else { return scalars }
        var string = String(String.UnicodeScalarView(scalars))
        if stripAccents {
            // NFD, then drop combining marks (Unicode category Mn).
            string = string.decomposedStringWithCanonicalMapping
            string = String(String.UnicodeScalarView(string.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark }))
        }
        if lowercase { string = string.lowercased() }
        return Array(string.unicodeScalars)
    }

    /// Whitespace split, then every punctuation character becomes its own word.
    func words(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var words: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in scalars {
            if scalar == " " || Self.isWhitespace(scalar) {
                if !current.isEmpty { words.append(current); current = [] }
            } else if Self.isPunctuation(scalar) {
                if !current.isEmpty { words.append(current); current = [] }
                words.append([scalar])
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    func wordPiece(_ word: [Unicode.Scalar], into ids: inout [Int], keepingUnknown: Bool) {
        if word.count > maxCharactersPerWord {
            if keepingUnknown { ids.append(-1) }
            return
        }
        var pieces: [Int] = []
        var start = 0
        while start < word.count {
            var end = word.count
            var found: Int?
            while start < end {
                var piece = String(String.UnicodeScalarView(word[start..<end]))
                if start > 0 { piece = prefix + piece }
                if let id = vocabulary[piece] { found = id; break }
                end -= 1
            }
            guard let id = found else {  // the whole word is [UNK]
                if keepingUnknown { ids.append(-1) }
                return
            }
            pieces.append(id)
            start = end
        }
        for id in pieces {
            if id != unknownID { ids.append(id) } else if keepingUnknown { ids.append(-1) }
        }
    }

    // MARK: Character classes (as in Hugging Face tokenizers' BERT implementation)

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\t", "\n", "\r": return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\t", "\n", "\r": return false
        default:
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned: return true
            default: return false
            }
        }
    }

    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // ASCII non-alphanumerics count as punctuation even when Unicode calls them symbols ($, ^, `).
        if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    static func isCJK(_ value: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x20000...0x2A6DF).contains(value) ||
            (0x2A700...0x2B73F).contains(value) || (0x2B740...0x2B81F).contains(value) || (0x2B820...0x2CEAF).contains(value) ||
            (0xF900...0xFAFF).contains(value) || (0x2F800...0x2FA1F).contains(value)
    }
}

/// Minimal reader for the safetensors format: an 8-byte little-endian header length,
/// a JSON header naming each tensor's dtype, shape and byte range, then raw data.
public enum SafeTensors {
    public struct Tensor: Sendable {
        public var shape: [Int]
        public var values: [Float]
    }

    public static func read(_ data: Data, name: String) throws -> Tensor {
        guard data.count >= 8 else { throw EmbeddingError.invalidModel("safetensors file too short") }
        let headerLength = data.prefix(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
        let headerEnd = 8 + Int(headerLength)
        guard headerLength > 0, headerEnd <= data.count,
              let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<headerEnd)) as? [String: Any] else {
            throw EmbeddingError.invalidModel("bad safetensors header")
        }
        guard let entry = header[name] as? [String: Any],
              let dtype = entry["dtype"] as? String,
              let shape = (entry["shape"] as? [Any])?.compactMap({ ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }),
              let offsets = (entry["data_offsets"] as? [Any])?.compactMap({ ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }),
              offsets.count == 2 else {
            throw EmbeddingError.invalidModel("no tensor named \(name)")
        }
        let start = headerEnd + offsets[0], end = headerEnd + offsets[1]
        let count = shape.reduce(1, *)
        guard start <= end, end <= data.count else { throw EmbeddingError.invalidModel("tensor \(name) out of range") }
        let bytes = data.subdata(in: start..<end)
        var values = [Float](repeating: 0, count: count)
        switch dtype {
        case "F32":
            guard bytes.count == count * 4 else { throw EmbeddingError.invalidModel("F32 size mismatch") }
            _ = values.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        case "F16":
            guard bytes.count == count * 2 else { throw EmbeddingError.invalidModel("F16 size mismatch") }
            bytes.withUnsafeBytes { raw in
                for i in 0..<count {
                    let bits = UInt16(raw[2 * i]) | (UInt16(raw[2 * i + 1]) << 8)
                    values[i] = Float(halfBits: bits)
                }
            }
        default:
            throw EmbeddingError.invalidModel("unsupported dtype \(dtype)")
        }
        return Tensor(shape: shape, values: values)
    }
}

extension Float {
    /// IEEE 754 half precision to single, without relying on `Float16` (unavailable
    /// on some x86 Linux toolchains).
    init(halfBits bits: UInt16) {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits & 0x3FF)
        var result: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                result = sign
            } else {
                // Subnormal: normalize.
                var e: UInt32 = 0
                var m = mantissa
                while m & 0x400 == 0 { m <<= 1; e += 1 }
                result = sign | ((127 - 15 - e + 1) << 23) | ((m & 0x3FF) << 13)
            }
        } else if exponent == 0x1F {
            result = sign | 0x7F80_0000 | (mantissa << 13)
        } else {
            result = sign | ((exponent + 127 - 15) << 23) | (mantissa << 13)
        }
        self = Float(bitPattern: result)
    }
}
