// M0 spike: SQLite FTS5 + sqlite-vec latency on a synthetic corpus.
//
//   swift run -c release spike-vec [--chunks 8000] [--dim 384] [--queries 200] [--path /tmp/x.sqlite]
//
// The corpus is synthetic (random unit vectors; text drawn Zipf-style from a 20,000-term
// vocabulary, like natural language), so this measures storage and query cost, not
// retrieval quality. Quality is measured in
// M3 with a real embedding model. Budget from docs/PLAN.md section 5: embed + both
// searches + fusion under 100 ms warm, with searches themselves well under 40 ms.
import Foundation
import JeevesCore
import KnowledgeIndex

let flags = CommandLineFlags(switches: ["keep"])
let chunkCount = flags.int("chunks", default: 8_000)
let dimensions = flags.int("dim", default: 384)
let queryCount = flags.int("queries", default: 200)
let path = flags.string("path", default: NSTemporaryDirectory() + "jeeves-spike-vec-\(ProcessInfo.processInfo.processIdentifier).sqlite")

// Deterministic generator so runs are comparable across machines.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var rng = SplitMix64(state: 42)

@MainActor func randomUnitVector() -> [Float] {
    var v = (0..<dimensions).map { _ in Float.random(in: -1...1, using: &rng) }
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
    for i in v.indices { v[i] /= norm }
    return v
}

// Technical terms first so they get the high-frequency ranks, then filler terms.
let technicalTerms = """
prompt caching cache_control ephemeral ttl streaming server events message_start content_block_delta \
text_delta stop_reason refusal fallback max_tokens output_config effort thinking adaptive between_tools \
sonnet opus haiku model pricing tokens input output batch files api sdk python typescript swift \
retry backoff overloaded rate limit header anthropic version beta tool json schema structured \
context window compaction citations documents pdf vision embeddings retrieval chunk index search latency
""".split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
let vocabulary = technicalTerms + (0..<(20_000 - technicalTerms.count)).map { "term\($0)" }

// Zipf(s = 1) sampler over vocabulary ranks via the cumulative distribution.
let zipfCDF: [Double] = {
    var running = 0.0
    let weights = (1...vocabulary.count).map { 1.0 / Double($0) }
    let total = weights.reduce(0, +)
    return weights.map { running += $0 / total; return running }
}()

@MainActor func zipfWord() -> String {
    let u = Double.random(in: 0..<1, using: &rng)
    var lo = 0, hi = zipfCDF.count - 1
    while lo < hi {
        let mid = (lo + hi) / 2
        if zipfCDF[mid] < u { lo = mid + 1 } else { hi = mid }
    }
    return vocabulary[lo]
}

@MainActor func sentence(_ words: Int) -> String {
    (0..<words).map { _ in zipfWord() }.joined(separator: " ")
}

try? FileManager.default.removeItem(atPath: path)
log("SQLite \(SQLiteConnection.sqliteVersion), sqlite-vec \(SQLiteConnection.sqliteVecVersion)")
log("building \(chunkCount) chunks x \(dimensions) dims at \(path)")

let index = try ChunkIndex(path: path, dimensions: dimensions)
let batchSize = 500
var insertMs = 0.0
var inserted = 0
while inserted < chunkCount {
    let n = min(batchSize, chunkCount - inserted)
    let batch = (0..<n).map { i in
        (chunk: Chunk(source: "docs/page-\((inserted + i) / 8).md",
                      breadcrumb: "Doc \((inserted + i) / 8) > \(sentence(3))",
                      text: sentence(60)),
         embedding: randomUnitVector())
    }
    insertMs += try measureMilliseconds { try index.insert(batch) }.ms
    inserted += n
}
try index.connection.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('optimize'); PRAGMA wal_checkpoint(TRUNCATE);")
let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0

let queries = (0..<queryCount).map { _ in (text: sentence(8), embedding: randomUnitVector()) }
// Warm-up pass: page cache and statement caches.
for query in queries.prefix(10) { _ = try index.hybridSearch(query.text, embedding: query.embedding) }

var lexical: [Double] = [], vector: [Double] = [], hybrid: [Double] = [], fetch: [Double] = []
for query in queries {
    lexical.append(try measureMilliseconds { try index.lexicalSearch(query.text, limit: 20) }.ms)
    vector.append(try measureMilliseconds { try index.vectorSearch(query.embedding, limit: 20) }.ms)
    let (hits, ms) = try measureMilliseconds { try index.hybridSearch(query.text, embedding: query.embedding) }
    hybrid.append(ms)
    fetch.append(try measureMilliseconds { try hits.compactMap { try index.chunk(id: $0.chunkID) } }.ms)
}

print("""
spike-vec  chunks=\(chunkCount) dim=\(dimensions) queries=\(queryCount)
  insert       \(String(format: "%.0f", Double(chunkCount) / (insertMs / 1000))) chunks/s (\(String(format: "%.0f", insertMs)) ms total)
  file size    \(String(format: "%.1f", Double(fileBytes) / 1_048_576)) MB
  lexical k=20 \(LatencyStats(lexical)!.summary)
  vector k=20  \(LatencyStats(vector)!.summary)
  hybrid top6  \(LatencyStats(hybrid)!.summary)
  fetch 6      \(LatencyStats(fetch)!.summary)
""")
if !flags.has("keep") {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
}
