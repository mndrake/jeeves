import Foundation

public struct Chunk: Sendable, Equatable {
    public var id: Int64?
    /// File path or URL of the source document.
    public var source: String
    /// `Title > H2 > H3` path of the chunk within its document.
    public var breadcrumb: String
    public var text: String
    /// The knowledge source (folder or site) the chunk came from, so a source can be
    /// re-indexed or removed as a unit. Empty for chunks inserted without one.
    public var collection: String

    public init(id: Int64? = nil, source: String, breadcrumb: String, text: String, collection: String = "") {
        self.id = id
        self.source = source
        self.breadcrumb = breadcrumb
        self.text = text
        self.collection = collection
    }
}

public struct SearchHit: Sendable, Equatable {
    public var chunkID: Int64
    /// Lexical: BM25 (lower is better). Vector: cosine distance (lower is better).
    /// Hybrid: reciprocal-rank-fusion score (higher is better).
    public var score: Double
}

/// The local hybrid index from docs/prd/05: FTS5 (BM25) over chunk text and
/// breadcrumbs, plus a sqlite-vec `vec0` table of embeddings, in one SQLite file.
///
/// M0 scope: schema, insert, the three query paths and their latency. Enrichment
/// columns (context prefix, synthetic questions) arrive in M3.
public final class ChunkIndex {
    public let dimensions: Int
    public let connection: SQLiteConnection

    private let insertChunk: Statement
    private let insertVector: Statement
    private let lexicalQuery: Statement
    private let vectorQuery: Statement
    private let fetchChunk: Statement

    public init(path: String, dimensions: Int) throws {
        precondition(dimensions > 0)
        self.dimensions = dimensions
        connection = try SQLiteConnection(path: path)
        try connection.execute("""
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY,
            source TEXT NOT NULL,
            breadcrumb TEXT NOT NULL,
            text TEXT NOT NULL,
            collection TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS chunks_collection ON chunks(collection);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            text, breadcrumb, content='chunks', content_rowid='id', tokenize='porter unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(rowid, text, breadcrumb) VALUES (new.id, new.text, new.breadcrumb);
        END;
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, text, breadcrumb) VALUES ('delete', old.id, old.text, old.breadcrumb);
            DELETE FROM chunks_vec WHERE rowid = old.id;
        END;
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_vec USING vec0(
            embedding float[\(dimensions)] distance_metric=cosine
        );
        """)
        insertChunk = try connection.prepare("INSERT INTO chunks(source, breadcrumb, text, collection) VALUES (?, ?, ?, ?)")
        insertVector = try connection.prepare("INSERT INTO chunks_vec(rowid, embedding) VALUES (?, ?)")
        // Column weights: text 1.0, breadcrumb 2.0. The breadcrumb holds the page title
        // and section headings, which name the topic a spoken question is about.
        lexicalQuery = try connection.prepare("""
        SELECT rowid, bm25(chunks_fts, 1.0, 2.0) AS score FROM chunks_fts
        WHERE chunks_fts MATCH ? ORDER BY score LIMIT ?
        """)
        vectorQuery = try connection.prepare("""
        SELECT rowid, distance FROM chunks_vec WHERE embedding MATCH ? AND k = ? ORDER BY distance
        """)
        fetchChunk = try connection.prepare("SELECT id, source, breadcrumb, text, collection FROM chunks WHERE id = ?")
    }

    /// Inserts chunks with their embeddings in one transaction. Returns the new IDs.
    @discardableResult
    public func insert(_ items: [(chunk: Chunk, embedding: [Float])]) throws -> [Int64] {
        try connection.transaction {
            try items.map { item in
                guard item.embedding.count == dimensions else {
                    throw SQLiteError(code: -1, message: "embedding has \(item.embedding.count) dimensions, index expects \(dimensions)")
                }
                try insertChunk.bind(1, item.chunk.source)
                try insertChunk.bind(2, item.chunk.breadcrumb)
                try insertChunk.bind(3, item.chunk.text)
                try insertChunk.bind(4, item.chunk.collection)
                try insertChunk.run()
                let id = connection.lastInsertRowID
                try insertVector.bind(1, id)
                try insertVector.bind(2, vector: item.embedding)
                try insertVector.run()
                return id
            }
        }
    }

    /// Inserts chunks without embeddings (lexical search only), in one transaction.
    @discardableResult
    public func insert(chunks: [Chunk]) throws -> [Int64] {
        try connection.transaction {
            try chunks.map { chunk in
                try insertChunk.bind(1, chunk.source)
                try insertChunk.bind(2, chunk.breadcrumb)
                try insertChunk.bind(3, chunk.text)
                try insertChunk.bind(4, chunk.collection)
                try insertChunk.run()
                return connection.lastInsertRowID
            }
        }
    }

    /// Replaces a collection's chunks atomically: searches see either the old set or
    /// the new one, never a half-indexed source.
    public func replaceCollection(_ collection: String, with chunks: [Chunk]) throws {
        let delete = try connection.prepare("DELETE FROM chunks WHERE collection = ?")
        try connection.transaction {
            try delete.bind(1, collection)
            try delete.run()
            for chunk in chunks {
                try insertChunk.bind(1, chunk.source)
                try insertChunk.bind(2, chunk.breadcrumb)
                try insertChunk.bind(3, chunk.text)
                try insertChunk.bind(4, collection)
                try insertChunk.run()
            }
        }
    }

    /// Deletes every chunk of one collection. Returns how many were removed.
    @discardableResult
    public func deleteCollection(_ collection: String) throws -> Int {
        try connection.transaction {
            let before = try count(collection: collection)
            let statement = try connection.prepare("DELETE FROM chunks WHERE collection = ?")
            try statement.bind(1, collection)
            try statement.run()
            return before
        }
    }

    public func count(collection: String) throws -> Int {
        let statement = try connection.prepare("SELECT count(*) FROM chunks WHERE collection = ?")
        try statement.bind(1, collection)
        _ = try statement.step()
        return Int(statement.int64(0))
    }

    /// Number of distinct source documents in a collection.
    public func documentCount(collection: String) throws -> Int {
        let statement = try connection.prepare("SELECT count(DISTINCT source) FROM chunks WHERE collection = ?")
        try statement.bind(1, collection)
        _ = try statement.step()
        return Int(statement.int64(0))
    }

    public func delete(chunkID: Int64) throws {
        let statement = try connection.prepare("DELETE FROM chunks WHERE id = ?")
        try statement.bind(1, chunkID)
        try statement.run()
    }

    public func count() throws -> Int {
        let statement = try connection.prepare("SELECT count(*) FROM chunks")
        _ = try statement.step()
        return Int(statement.int64(0))
    }

    /// BM25 search. Free text is turned into an OR of quoted terms, so user or
    /// transcript text can never be parsed as FTS5 query syntax.
    public func lexicalSearch(_ text: String, limit: Int = 20) throws -> [SearchHit] {
        guard let query = Self.ftsQuery(from: text) else { return [] }
        defer { lexicalQuery.reset() }
        try lexicalQuery.bind(1, query)
        try lexicalQuery.bind(2, Int64(limit))
        var hits: [SearchHit] = []
        while try lexicalQuery.step() {
            hits.append(SearchHit(chunkID: lexicalQuery.int64(0), score: lexicalQuery.double(1)))
        }
        return hits
    }

    /// Exact k-nearest-neighbour search by cosine distance.
    public func vectorSearch(_ embedding: [Float], limit: Int = 20) throws -> [SearchHit] {
        precondition(embedding.count == dimensions, "query has \(embedding.count) dimensions, index expects \(dimensions)")
        defer { vectorQuery.reset() }
        try vectorQuery.bind(1, vector: embedding)
        try vectorQuery.bind(2, Int64(limit))
        var hits: [SearchHit] = []
        while try vectorQuery.step() {
            hits.append(SearchHit(chunkID: vectorQuery.int64(0), score: vectorQuery.double(1)))
        }
        return hits
    }

    /// Lexical and vector search fused with reciprocal rank fusion.
    public func hybridSearch(_ text: String, embedding: [Float], candidates: Int = 20, limit: Int = 6) throws -> [SearchHit] {
        let lexical = try lexicalSearch(text, limit: candidates).map(\.chunkID)
        let vector = try vectorSearch(embedding, limit: candidates).map(\.chunkID)
        return reciprocalRankFusion([lexical, vector]).prefix(limit).map { SearchHit(chunkID: $0.id, score: $0.score) }
    }

    public func chunk(id: Int64) throws -> Chunk? {
        defer { fetchChunk.reset() }
        try fetchChunk.bind(1, id)
        guard try fetchChunk.step() else { return nil }
        return Chunk(id: fetchChunk.int64(0), source: fetchChunk.string(1) ?? "",
                     breadcrumb: fetchChunk.string(2) ?? "", text: fetchChunk.string(3) ?? "",
                     collection: fetchChunk.string(4) ?? "")
    }

    /// Splits on anything that is not a letter, digit or underscore, drops one-letter
    /// tokens and English stopwords, quotes each term, and ORs them. Returns nil if
    /// nothing searchable remains.
    ///
    /// Dropping stopwords matters for speed as well as precision: with OR semantics a
    /// term like "how" matches most chunks, and BM25 then has to score all of them.
    public static func ftsQuery(from text: String) -> String? {
        let terms = text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
        guard !terms.isEmpty else { return nil }
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    /// Function words that carry no retrieval signal in spoken questions.
    static let stopwords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be",
        "because", "been", "before", "being", "between", "both", "but", "by", "can", "could", "did", "do",
        "does", "doing", "down", "during", "each", "few", "for", "from", "further", "get", "got", "had",
        "has", "have", "having", "he", "her", "here", "hers", "him", "his", "how", "if", "in", "into", "is",
        "it", "its", "just", "kind", "know", "like", "me", "mean", "more", "most", "my", "no", "nor", "not",
        "now", "of", "off", "on", "once", "only", "or", "other", "our", "out", "over", "own", "quick",
        "question", "really", "same", "she", "should", "so", "some", "such", "than", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "those", "through", "to", "too", "um", "uh",
        "under", "until", "up", "very", "was", "we", "were", "what", "whats", "when", "where", "which",
        "while", "who", "whom", "why", "will", "with", "would", "yeah", "you", "your", "yours",
    ]
}
