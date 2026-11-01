import Foundation
import Testing
@testable import KnowledgeIndex

@Suite struct ChunkIndexTests {
    func unit(_ values: [Float]) -> [Float] {
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return values.map { $0 / norm }
    }

    func makeIndex() throws -> ChunkIndex {
        let index = try ChunkIndex(path: ":memory:", dimensions: 4)
        try index.insert([
            (Chunk(source: "docs/caching.md", breadcrumb: "Prompt caching > Lifetime",
                   text: "Cache entries live for five minutes by default; reads refresh the timer."), unit([1, 0, 0, 0])),
            (Chunk(source: "docs/streaming.md", breadcrumb: "Streaming > Errors",
                   text: "An overloaded_error event can arrive mid-stream. Retry with backoff."), unit([0, 1, 0, 0])),
            (Chunk(source: "notes/pricing.md", breadcrumb: "Models > Pricing",
                   text: "Sonnet costs two dollars per million input tokens."), unit([0, 0, 1, 0])),
        ])
        return index
    }

    @Test func vendoredLibrariesLoad() {
        #expect(SQLiteConnection.sqliteVersion.hasPrefix("3."))
        #expect(SQLiteConnection.sqliteVecVersion == "v0.1.9")
    }

    @Test func lexicalSearchUsesBM25WithStemming() throws {
        let index = try makeIndex()
        let hits = try index.lexicalSearch("how long do cached entries live?")
        #expect(hits.first.flatMap { try? index.chunk(id: $0.chunkID) }?.breadcrumb == "Prompt caching > Lifetime")
        // Porter stemming: "retrying" matches "Retry".
        #expect(try index.lexicalSearch("retrying").map(\.chunkID) == [2])
    }

    @Test func vectorSearchOrdersByCosineDistance() throws {
        let index = try makeIndex()
        let hits = try index.vectorSearch(unit([0.1, 0.9, 0.2, 0]), limit: 3)
        #expect(hits.map(\.chunkID) == [2, 3, 1])
        #expect(hits[0].score < hits[1].score)
    }

    @Test func hybridSearchFusesBothSignals() throws {
        let index = try makeIndex()
        // Lexically about pricing, semantically closest to caching: both should surface.
        let hits = try index.hybridSearch("sonnet price per million", embedding: unit([1, 0, 0.2, 0]), limit: 2)
        #expect(Set(hits.map(\.chunkID)) == [1, 3])
    }

    @Test func untrustedTextCannotInjectFTSSyntax() throws {
        let index = try makeIndex()
        for hostile in ["\"unbalanced", "NEAR(a b", "text: OR AND NOT", "*", "chunks_fts MATCH 'x'", "", "?!"] {
            _ = try index.lexicalSearch(hostile)  // must not throw
        }
        #expect(ChunkIndex.ftsQuery(from: "max_tokens, top-p!") == "\"max_tokens\" OR \"top\"")
        #expect(ChunkIndex.ftsQuery(from: "a ? !") == nil)
    }

    @Test func deleteRemovesFromAllTables() throws {
        let index = try makeIndex()
        try index.delete(chunkID: 1)
        #expect(try index.count() == 2)
        #expect(try index.lexicalSearch("cache entries").isEmpty)
        #expect(!(try index.vectorSearch(unit([1, 0, 0, 0]), limit: 3).map(\.chunkID).contains(1)))
    }

    @Test func rejectsWrongDimensions() throws {
        let index = try makeIndex()
        #expect(throws: SQLiteError.self) {
            try index.insert([(Chunk(source: "x", breadcrumb: "x", text: "x"), [1, 0])])
        }
        #expect(try index.count() == 3)  // transaction rolled back
    }
}

@Suite struct RankFusionTests {
    @Test func rewardsAgreementAndKeepsStableTies() {
        let fused = reciprocalRankFusion([["a", "b", "c"], ["b", "a", "d"]])
        #expect(Array(fused.map(\.id).prefix(2)) == ["a", "b"])  // tie on score, a seen first
        #expect(fused.map(\.id).suffix(2) == ["c", "d"])
        #expect(abs(fused[0].score - (1.0 / 61 + 1.0 / 62)) < 1e-12)
    }

    @Test func duplicatesWithinOneListCountOnce() {
        let fused = reciprocalRankFusion([["a", "a", "b"]])
        #expect(fused.map(\.id) == ["a", "b"])
        #expect(abs(fused[1].score - 1.0 / 63) < 1e-12)
    }
}
