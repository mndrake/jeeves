// M0 spike: measures Claude live-answer latency per answer mode.
//
//   ANTHROPIC_API_KEY=sk-ant-... swift run -c release spike-claude [--modes standard,standard-adaptive,fast,deep] [--n 8] [--out results/claude.json]
//   swift run spike-claude --dry-run        # print the request bodies, no network
//   swift run spike-claude --base-url http://127.0.0.1:8765   # against scripts/mock-anthropic.py
//
// Reports, per mode: time to first byte (message_start), time to first answer token,
// total time, cache write/read tokens, served model, stop reason and estimated cost.
// The first request per model writes the prompt cache; later ones should read it.
import AnthropicAPI
import Foundation
import JeevesCore

let flags = CommandLineFlags(switches: ["dry-run", "help"])
if flags.has("help") {
    print("usage: spike-claude [--modes standard,standard-adaptive,fast,deep] [--n 8] [--out path.json] [--dry-run]")
    exit(0)
}
let modes = flags.string("modes", default: "standard,standard-adaptive,fast,deep")
    .split(separator: ",").compactMap { AnswerMode(rawValue: String($0)) }
let questionCount = max(1, flags.int("n", default: 8))

let passages = """
[1] Client SDKs > Languages
Official SDKs exist for Python, TypeScript, Java, Go, Ruby, C# and PHP. Other languages call the HTTP API directly.

[2] Prompt caching > Lifetime
Cache entries live for five minutes by default and every read refreshes the timer. A one-hour TTL is available with "ttl": "1h"; writes cost 2x base input price for the one-hour TTL and 1.25x for five minutes.

[3] Prompt caching > Minimums
Shorter prefixes silently do not cache. The minimum cacheable prefix is 512 tokens on Claude Opus 5.5, Claude Sonnet 5.5 and Claude Haiku 5.5. Check usage.cache_read_input_tokens to confirm hits.

[4] Streaming > Errors
An error event can arrive mid-stream, for example overloaded_error. Retry with backoff; partial output from a failed stream should be discarded.

[5] Models > Pricing
Claude Sonnet 5.5 costs $2 per million input tokens and $10 per million output tokens. Claude Haiku 5.5 costs $0.10 and $0.50 for prompts up to 100K tokens.

[6] Refusals > Fallbacks
A declined request returns HTTP 200 with stop_reason "refusal". Sending fallbacks: "default" with the server-side-fallback-2026-07-01 beta header retries some declines on another model.
"""

let transcript = """
...so we moved the system prompt to the front and we're seeing the bill drop, but I'm not sure \
it's actually caching. Quick question for you while we're on it...
"""

let questions = [
    "How long does a cached prompt stay warm?",
    "Why would our prompt not be caching at all?",
    "What does Sonnet five point five cost per million tokens?",
    "What happens if the model refuses mid-answer, can it fall back automatically?",
    "If the stream dies halfway with an overloaded error what should we do?",
    "Is there an official Swift SDK?",
    "How do we check whether the cache actually hit?",
    "What's the price difference between the five minute and one hour cache?",
    "Does Haiku cost the same as Sonnet?",
    "Can we use it from Rust?",
]

func userTurn(_ question: String) -> String {
    "Passages:\n\(passages)\n\nRecent transcript:\n\(transcript)\n\nQuestion: \(question)"
}

let system = [SystemBlock(text: LiveAnswerPrompt.system, cacheControl: .ephemeral)]

if flags.has("dry-run") {
    for mode in modes {
        let profile = AnswerProfile.forMode(mode)
        try profile.validate()
        let body = try profile.makeRequest(system: system, messages: [.user(userTurn(questions[0]))]).jsonData()
        print("== \(mode.rawValue)  anthropic-beta: \(profile.betas.joined(separator: ",").ifEmpty("(none)"))")
        print(String(decoding: body, as: UTF8.self).prefix(700) + " ...\n")
    }
    print("system prompt: \(LiveAnswerPrompt.system.count) characters (needs > 512 tokens to cache)")
    exit(0)
}

var configuration: AnthropicConfiguration
if let baseURL = flags.values["base-url"].flatMap(URL.init(string:)) {
    // Local mock server: any key works.
    configuration = AnthropicConfiguration.fromEnvironment() ?? AnthropicConfiguration(apiKey: "mock")
    configuration.baseURL = baseURL
} else if let fromEnvironment = AnthropicConfiguration.fromEnvironment() {
    configuration = fromEnvironment
} else {
    log("Set ANTHROPIC_API_KEY to an Anthropic Console API key, or pass --dry-run or --base-url.")
    exit(2)
}
let client = AnthropicClient(configuration: configuration)

struct Record: Codable {
    var mode: String
    var question: String
    var servedModel: String?
    var ttfbMs: Double?
    var ttftMs: Double?
    var totalMs: Double
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheWriteTokens: Int?
    var cacheReadTokens: Int?
    var stopReason: String?
    var fallback: Bool
    var costUSD: Double?
    var error: String?
    var answer: String?
}

var records: [Record] = []

for mode in modes {
    let profile = AnswerProfile.forMode(mode)
    try profile.validate()
    log("\n== \(mode.rawValue): \(profile.model), thinking \(profile.thinking.map { "\($0)" } ?? "adaptive (default)"), effort \(profile.effort.rawValue)")
    for question in questions.prefix(questionCount) {
        let request = profile.makeRequest(system: system, messages: [.user(userTurn(question))])
        let start = MonotonicClock.now()
        var accumulator = StreamAccumulator()
        var errorText: String?
        do {
            for try await event in client.stream(request, betas: profile.betas) {
                accumulator.apply(event)
            }
        } catch {
            errorText = "\(error)"
        }
        let total = MonotonicClock.millisecondsSince(start)
        let usage = accumulator.usage
        let record = Record(
            mode: mode.rawValue, question: question, servedModel: accumulator.servedModel,
            ttfbMs: accumulator.firstEventAt.map { MonotonicClock.milliseconds(from: start, to: $0) },
            ttftMs: accumulator.firstTextAt.map { MonotonicClock.milliseconds(from: start, to: $0) },
            totalMs: total, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
            cacheWriteTokens: usage.cacheCreationInputTokens, cacheReadTokens: usage.cacheReadInputTokens,
            stopReason: accumulator.stopReason, fallback: !accumulator.fallbackSwitches.isEmpty,
            costUSD: ModelPricing.forModel(accumulator.servedModel ?? profile.model)?.cost(of: usage),
            error: errorText, answer: accumulator.answerText)
        records.append(record)
        let ttft = record.ttftMs.map { String(format: "%6.0f", $0) } ?? "     -"
        log("  ttft \(ttft) ms  total \(String(format: "%6.0f", total)) ms  cache w/r \(usage.cacheCreationInputTokens ?? 0)/\(usage.cacheReadInputTokens ?? 0)  out \(usage.outputTokens ?? 0)  \(accumulator.stopReason ?? "-")\(errorText.map { "  ERROR \($0)" } ?? "")")
    }
}

print("\nWarm requests only (the first request per model writes the cache).")
print("mode               | time to first answer token                         | total p50 | cache hits | cost")
for mode in modes {
    let rows = records.filter { $0.mode == mode.rawValue && $0.error == nil }
    // The first request per model writes the cache; report warm requests separately.
    let warm = rows.dropFirst()
    let ttft = LatencyStats(warm.compactMap(\.ttftMs))?.summary ?? "no data"
    let total = LatencyStats(warm.map(\.totalMs)).map { String(format: "%.0f ms", $0.p50) } ?? "-"
    let hits = warm.filter { ($0.cacheReadTokens ?? 0) > 0 }.count
    let cost = rows.compactMap(\.costUSD).reduce(0, +)
    print("\(mode.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) | \(ttft.padding(toLength: 50, withPad: " ", startingAt: 0)) | \(total.padding(toLength: 9, withPad: " ", startingAt: 0)) | \(hits)/\(warm.count) warm | $\(String(format: "%.4f", cost))")
}
let failures = records.filter { $0.error != nil }
if !failures.isEmpty { print("\n\(failures.count) request(s) failed; first error: \(failures[0].error!)") }

if let outPath = flags.values["out"] {
    let url = URL(fileURLWithPath: outPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(records).write(to: url)
    log("wrote \(records.count) records to \(outPath)")
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
