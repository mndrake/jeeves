import AnthropicAPI
import Foundation
import JeevesCore
import KnowledgeIndex

// spike-kb: build and query a Jeeves knowledge index from the command line (M3).
//
//   spike-kb --db kb.sqlite --add https://platform.claude.com/llms.txt --exclude /docs/en/api/
//   spike-kb --db kb.sqlite --add ~/Notes
//   spike-kb --db kb.sqlite --search "how long does a cached prompt stay warm"
//   spike-kb --db kb.sqlite --eval eval/retrieval/questions.tsv
//   spike-kb --db kb.sqlite --ask "what does sonnet five five cost"     (needs ANTHROPIC_API_KEY)
//
// --presets indexes both Anthropic doc sites. The app keeps its index in
// ~/Library/Application Support/Jeeves/index.sqlite; pass that path to inspect it.

let flags = CommandLineFlags(switches: ["presets", "verbose"])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("spike-kb: \(message)\n".utf8))
    exit(1)
}

let dbPath = flags.values["db"] ?? "kb.sqlite"
let knowledge: KnowledgeBase
do { knowledge = try KnowledgeBase(path: dbPath) } catch { fail("open \(dbPath): \(error)") }

var sources: [KnowledgeSource] = []
if flags.has("presets") { sources += [.claudePlatformDocs, .claudeCodeDocs] }
if let input = flags.values["add"] {
    guard var source = KnowledgeSource.guess(from: input) else { fail("cannot read source \(input)") }
    if let excludes = flags.values["exclude"] { source.excludes = excludes.split(separator: ",").map(String.init) }
    source.id = "cli-" + source.location
    sources.append(source)
}

for source in sources {
    print("== indexing \(source.name) (\(source.kind.rawValue))")
    do {
        let report = try await knowledge.index(source) { progress in
            if progress.total > 0 { print("   \(progress.phase) \(progress.completed)/\(progress.total)") }
        }
        print(String(format: "   %d documents, %d chunks in %.1f s", report.documents, report.chunks, report.seconds))
        for failure in report.failures.prefix(10) { print("   failed: \(failure)") }
        if report.failures.count > 10 { print("   ... and \(report.failures.count - 10) more failures") }
    } catch {
        print("   error: \(error)")
    }
}

let total = (try? await knowledge.chunkCount()) ?? 0
print("index: \(dbPath), \(total) chunks")

func show(_ result: SearchResult, verbose: Bool) {
    print(String(format: "query: %@  (%.1f ms)", result.query, result.milliseconds))
    for passage in result.passages {
        print("  [\(passage.number)] \(passage.breadcrumb)\n      \(passage.source)")
        if verbose { print("      " + passage.text.prefix(300).replacingOccurrences(of: "\n", with: "\n      ")) }
    }
}

if let query = flags.values["search"] {
    do { show(try await knowledge.search(query), verbose: flags.has("verbose")) } catch { fail("search: \(error)") }
}

// Retrieval eval: TSV of `question<TAB>expected URL substring`. Reports recall@1/3/6.
if let evalPath = flags.values["eval"] {
    guard let text = try? String(contentsOfFile: evalPath, encoding: .utf8) else { fail("cannot read \(evalPath)") }
    var hits = [1: 0, 3: 0, 6: 0]
    var n = 0
    var latencies: [Double] = []
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "\t").map(String.init)
        guard parts.count >= 2 else { continue }
        n += 1
        let result = try await knowledge.search(parts[0])
        latencies.append(result.milliseconds)
        let rank = result.passages.firstIndex { passage in
            parts[1].split(separator: "|").contains { passage.source.contains($0) }
        }.map { $0 + 1 }
        for k in hits.keys where (rank ?? 99) <= k { hits[k]! += 1 }
        print("\(rank.map { "hit@\($0)" } ?? "MISS ")  \(parts[0])")
        if rank == nil, flags.has("verbose") {
            for passage in result.passages.prefix(3) { print("        got \(passage.source)  (\(passage.breadcrumb))") }
        }
    }
    guard n > 0 else { fail("no questions in \(evalPath)") }
    for k in [1, 3, 6] { print(String(format: "recall@%d: %.2f (%d/%d)", k, Double(hits[k]!) / Double(n), hits[k]!, n)) }
    if let stats = LatencyStats(latencies) { print(String(format: "search p50 %.1f ms, p95 %.1f ms", stats.p50, stats.p95)) }
}

if let question = flags.values["ask"] {
    guard let configuration = AnthropicConfiguration.fromEnvironment() else { fail("set ANTHROPIC_API_KEY") }
    let result = try await knowledge.search(question)
    show(result, verbose: false)
    let mode = AnswerMode(rawValue: flags.values["mode"] ?? "standard") ?? .standard
    let profile = AnswerProfile.forMode(mode)
    let userTurn = LiveAnswerPrompt.userTurn(
        passages: result.passages.map { (label: $0.breadcrumb, text: $0.text) },
        transcript: "", question: question)
    let request = profile.makeRequest(system: [SystemBlock(text: LiveAnswerPrompt.system, cacheControl: .ephemeral)],
                                      messages: [.user(userTurn)])
    let client = AnthropicClient(configuration: configuration)
    var accumulator = StreamAccumulator()
    let started = MonotonicClock.now()
    print("\n\(profile.model):")
    for try await event in client.stream(request, betas: profile.betas) {
        if let text = accumulator.apply(event) {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }
    let ttft = accumulator.firstTextAt.map { MonotonicClock.milliseconds(from: started, to: $0) } ?? 0
    print(String(format: "\n\n(first token %.0f ms, stop %@, cache read %d)", ttft, accumulator.stopReason ?? "-",
                 accumulator.usage.cacheReadInputTokens ?? 0))
}
