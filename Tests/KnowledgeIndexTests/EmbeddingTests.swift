import Foundation
import Testing
@testable import KnowledgeIndex

@Suite struct WordPieceTokenizerTests {
    let vocab = ["[UNK]": 0, "cache": 1, "##d": 2, "prompt": 3, "##s": 4, "max": 5, "_": 6, "tokens": 7,
                 "cafe": 8, "!": 9, ".": 10, "un": 11, "##related": 12, "$": 13, "5": 14]

    @Test func lowercasesStripsAccentsAndSplitsPunctuation() {
        let tokenizer = WordPieceTokenizer(vocabulary: vocab)
        #expect(tokenizer.ids("Cached PROMPTS!") == [1, 2, 3, 4, 9])
        #expect(tokenizer.ids("max_tokens") == [5, 6, 7])
        #expect(tokenizer.ids("Café.") == [8, 10])
        #expect(tokenizer.ids("$5") == [13, 14])
        #expect(tokenizer.ids("unrelated") == [11, 12])
    }

    @Test func dropsUnknownWordsUnlessAskedToKeepThem() {
        let tokenizer = WordPieceTokenizer(vocabulary: vocab, maxCharactersPerWord: 12)
        #expect(tokenizer.ids("cache zebra prompt") == [1, 3])
        #expect(tokenizer.ids("cache zebra prompt", keepingUnknown: true) == [1, -1, 3])
        // A word that matches a prefix but cannot be completed is unknown as a whole.
        #expect(tokenizer.ids("cachex", keepingUnknown: true) == [-1])
        #expect(tokenizer.ids("cachedcachedcached", keepingUnknown: true) == [-1])  // longer than 12 characters
    }

    @Test func cleansControlCharactersAndWhitespace() {
        let tokenizer = WordPieceTokenizer(vocabulary: vocab)
        #expect(tokenizer.ids("cache\u{7}d\tprompt\u{00A0}prompts") == [1, 2, 3, 3, 4])
    }

    @Test func readsHuggingFaceTokenizerJSON() throws {
        let json = ###"{"normalizer": {"type": "BertNormalizer", "lowercase": true, "strip_accents": null},"###
            + ###""model": {"type": "WordPiece", "unk_token": "[UNK]", "continuing_subword_prefix": "##","###
            + ###""max_input_chars_per_word": 100, "vocab": {"[UNK]": 0, "hello": 1, "##s": 2}}}"###
        let tokenizer = try WordPieceTokenizer(json: Data(json.utf8))
        #expect(tokenizer.ids("Héllos") == [1, 2])
        #expect(tokenizer.vocabularySize == 3)
        #expect(throws: EmbeddingError.self) { try WordPieceTokenizer(json: Data(#"{"model": {"type": "BPE"}}"#.utf8)) }
    }
}

@Suite struct StaticEmbedderTests {
    @Test func averagesTokenVectorsAndNormalizes() throws {
        let tokenizer = WordPieceTokenizer(vocabulary: ["[UNK]": 0, "a": 1, "b": 2])
        let table: [Float] = [0, 0, /* a */ 1, 0, /* b */ 0, 1]
        let embedder = try StaticEmbedder(identifier: "test", tokenizer: tokenizer, table: table, dimensions: 2)
        let both = embedder.embed("a b")
        #expect(abs(both[0] - 0.7071) < 0.001 && abs(both[1] - 0.7071) < 0.001)
        #expect(embedder.embed("a a a") == [1, 0])
        #expect(embedder.embed("zzz") == [0, 0])
    }

    @Test func unknownWordsCountTowardTheTokenLimit() throws {
        let tokenizer = WordPieceTokenizer(vocabulary: ["[UNK]": 0, "a": 1, "b": 2])
        var embedder = try StaticEmbedder(identifier: "test", tokenizer: tokenizer, table: [0, 0, 1, 0, 0, 1], dimensions: 2)
        embedder.maxTokens = 2
        // "zzz" uses the second slot, so "b" is past the limit.
        #expect(embedder.embed("a zzz b") == [1, 0])
    }

    @Test func rejectsTablesThatDoNotFitTheVocabulary() {
        let tokenizer = WordPieceTokenizer(vocabulary: ["[UNK]": 0, "a": 1, "b": 2])
        #expect(throws: EmbeddingError.self) { try StaticEmbedder(identifier: "x", tokenizer: tokenizer, table: [1, 2, 3], dimensions: 2) }
    }
}

@Suite struct SafeTensorsTests {
    func file(dtype: String, shape: [Int], payload: [UInt8]) -> Data {
        let header = #"{"embeddings": {"dtype": "\#(dtype)", "shape": [\#(shape.map(String.init).joined(separator: ","))], "data_offsets": [0, \#(payload.count)]}}"#
        var data = Data()
        var length = UInt64(header.utf8.count).littleEndian
        data.append(Data(bytes: &length, count: 8))
        data.append(Data(header.utf8))
        data.append(contentsOf: payload)
        return data
    }

    @Test func readsF32() throws {
        let values: [Float] = [1.5, -2, 0.25, 8]
        let payload = values.withUnsafeBytes { Array($0) }
        let tensor = try SafeTensors.read(file(dtype: "F32", shape: [2, 2], payload: payload), name: "embeddings")
        #expect(tensor.shape == [2, 2])
        #expect(tensor.values == values)
    }

    @Test func readsF16() throws {
        // 1.0 = 0x3C00, -2.0 = 0xC000, 0.5 = 0x3800, 65504 = 0x7BFF (little-endian bytes).
        let payload: [UInt8] = [0x00, 0x3C, 0x00, 0xC0, 0x00, 0x38, 0xFF, 0x7B]
        let tensor = try SafeTensors.read(file(dtype: "F16", shape: [4, 1], payload: payload), name: "embeddings")
        #expect(tensor.values == [1, -2, 0.5, 65504])
    }

    @Test func halfPrecisionEdgeCases() {
        #expect(Float(halfBits: 0x0000) == 0)
        #expect(Float(halfBits: 0x0001) == Float(5.9604645e-08))  // smallest subnormal
        #expect(Float(halfBits: 0x7C00) == .infinity)
        #expect(Float(halfBits: 0x7E00).isNaN)
    }

    @Test func rejectsMissingTensorsAndBadHeaders() {
        #expect(throws: EmbeddingError.self) { try SafeTensors.read(Data([1, 2, 3]), name: "embeddings") }
        let data = file(dtype: "F32", shape: [1], payload: [0, 0, 0, 0])
        #expect(throws: EmbeddingError.self) { try SafeTensors.read(data, name: "other") }
        #expect(throws: EmbeddingError.self) { try SafeTensors.read(file(dtype: "I8", shape: [4], payload: [1, 2, 3, 4]), name: "embeddings") }
    }
}

/// A deterministic embedder for tests: each concept word lights up one dimension, and
/// synonyms share a dimension, so vector search finds what keyword search cannot.
struct ConceptEmbedder: Embedder {
    let identifier: String
    let dimensions = 4
    static let concepts: [String: Int] = [
        "cache": 0, "cached": 0, "caching": 0, "warm": 0, "ttl": 0,
        "price": 1, "cost": 1, "pricing": 1, "expensive": 1, "dollars": 1,
        "stream": 2, "streaming": 2, "sse": 2,
        "refusal": 3, "refuse": 3, "declines": 3,
    ]

    init(identifier: String = "concepts-v1") { self.identifier = identifier }

    func embed(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0.01, count: dimensions)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let index = Self.concepts[String(word)] { vector[index] += 1 }
        }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / norm }
    }
}

@Suite struct HybridSearchTests {
    let documents = [
        SourceDocument(location: "pricing.md", title: "Pricing", markdown: "## Models\n\nSonnet is two dollars per million input tokens."),
        SourceDocument(location: "caching.md", title: "Prompt caching", markdown: "## Lifetime\n\nA cached prefix stays warm for five minutes."),
        SourceDocument(location: "stream.md", title: "Streaming", markdown: "## Events\n\nServer-sent events deliver text deltas."),
    ]

    @Test func vectorSearchFindsSynonymsThatKeywordsMiss() async throws {
        let knowledge = try KnowledgeBase(path: ":memory:", embedder: ConceptEmbedder())
        _ = try await knowledge.index(documents: documents, sourceID: "docs")
        // No passage contains "expensive": keyword search finds nothing.
        let result = try await knowledge.search("how expensive is it")
        #expect(result.mode == .hybrid)
        #expect(result.passages.first?.source == "pricing.md")
    }

    @Test func keywordOnlyWithoutAnEmbedder() async throws {
        let knowledge = try KnowledgeBase(path: ":memory:")
        _ = try await knowledge.index(documents: documents, sourceID: "docs")
        let result = try await knowledge.search("how expensive is it")
        #expect(result.mode == .keyword)
        #expect(result.passages.isEmpty)
    }

    @Test func addingAnEmbedderLaterBackfillsVectorsFromStoredText() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("jeeves-hybrid-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }

        do {
            let knowledge = try KnowledgeBase(path: path)
            _ = try await knowledge.index(documents: documents, sourceID: "docs")
            #expect(try await knowledge.vectorCoverage().embedded == 0)
        }
        do {
            let knowledge = try KnowledgeBase(path: path)
            let embedded = try await knowledge.useEmbedder(ConceptEmbedder())
            #expect(embedded == 3)
            #expect(try await knowledge.vectorCoverage() == (embedded: 3, total: 3))
            #expect(try await knowledge.search("streaming refuse").mode == .hybrid)
        }
        // Reopening with the same model keeps the vectors.
        do {
            let knowledge = try KnowledgeBase(path: path)
            #expect(try await knowledge.useEmbedder(ConceptEmbedder()) == 0)
            #expect(try await knowledge.search("how expensive is it").passages.first?.source == "pricing.md")
        }
        // A different model rebuilds them.
        do {
            let knowledge = try KnowledgeBase(path: path)
            #expect(try await knowledge.useEmbedder(ConceptEmbedder(identifier: "concepts-v2")) == 3)
        }
    }

    @Test func reindexingReplacesVectorsWithTheChunks() async throws {
        let knowledge = try KnowledgeBase(path: ":memory:", embedder: ConceptEmbedder())
        _ = try await knowledge.index(documents: documents, sourceID: "docs")
        _ = try await knowledge.index(documents: Array(documents.prefix(1)), sourceID: "docs")
        #expect(try await knowledge.vectorCoverage() == (embedded: 1, total: 1))
        try await knowledge.remove(sourceID: "docs")
        #expect(try await knowledge.vectorCoverage() == (embedded: 0, total: 0))
    }

    @Test func llmsTxtSkipsNestedLanguageIndexes() {
        let links = LLMSTxt.links(in: """
        - [Hooks](https://code.claude.com/docs/en/hooks.md)
        - [French (228 pages)](https://code.claude.com/docs/_llms/fr.txt): Documentation for French.
        """)
        #expect(links.map(\.url.lastPathComponent) == ["hooks.md"])
    }
}
