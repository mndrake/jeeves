// Question assembly calibration: replay recorded calls (call traces) through end-of-
// speech detection and question assembly with any settings, and score the questions
// Jeeves would have asked against hand-checked labels. See docs/QUESTIONS.md.
//
//   spike-qa transcript call.jsonl                 # utterances with times, for labelling
//   spike-qa label call.jsonl                      # Claude drafts call.labels.tsv (ANTHROPIC_API_KEY)
//   spike-qa replay call.jsonl [settings] [--verbose]
//   spike-qa sweep a.jsonl b.jsonl [--silence-ms 300,400,600] [--gap 0,1,1.5,2] [--lookback 10,20] [--follow 0,2]
//
// Settings: --silence-ms 400 --speech-db -45 --gap 1.5 --lookback 20 --lead-words 80
// --follow 0 --follow-words 60 --noise-margin 12, or --utterance-only (v0.4 question
// assembly), --fixed-threshold (v0.4 end-of-speech detection), --v04 (v0.4 as shipped).
// Labels are read from <trace>.labels.tsv next to each trace when present.
import AnthropicAPI
import Foundation
import JeevesCore

let flags = CommandLineFlags(switches: ["verbose", "utterance-only", "force", "help", "fixed-threshold", "v04"])
/// --noise-margin 12 (default) or --fixed-threshold for the v0.4 endpointer.
let noiseMargin: Float? = flags.has("fixed-threshold") ? nil : Float(flags.double("noise-margin", default: 12))
let command = flags.positional.first ?? "help"
let traces = Array(flags.positional.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func clock(_ seconds: Double) -> String {
    let total = max(0, seconds)
    return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
}

func load(_ path: String) -> (trace: CallTrace, labels: [QuestionLabel]?) {
    let url = URL(fileURLWithPath: path)
    let trace: CallTrace
    do { trace = try CallTrace.read(url) } catch { fail("\(path): \(error)") }
    let labelsURL = labelsPath(for: url)
    guard let text = try? String(contentsOf: labelsURL, encoding: .utf8) else { return (trace, nil) }
    do { return (trace, try QuestionLabel.parse(text)) } catch { fail("\(labelsURL.path): \(error)") }
}

func labelsPath(for trace: URL) -> URL {
    let base = trace.pathExtension == "jsonl" ? trace.deletingPathExtension() : trace
    return base.appendingPathExtension("labels.tsv")
}

func options(silence: Double? = nil, gap: Double? = nil, lookback: Double? = nil, follow: Double? = nil) -> TraceReplay.Options {
    if flags.has("v04") { return .v04 }
    if flags.has("utterance-only") {
        return TraceReplay.Options(silenceDuration: silence ?? flags.double("silence-ms", default: 400) / 1000,
                                   speechThresholdDecibels: Float(flags.double("speech-db", default: -45)),
                                   noiseMarginDecibels: noiseMargin, assembler: .utteranceOnly)
    }
    let defaults = QuestionAssembler.Settings()
    let settings = QuestionAssembler.Settings(
        leadInGap: gap ?? flags.double("gap", default: defaults.leadInGap),
        leadInSeconds: lookback ?? flags.double("lookback", default: defaults.leadInSeconds),
        leadInWords: flags.int("lead-words", default: defaults.leadInWords),
        followUpWindow: follow ?? flags.double("follow", default: defaults.followUpWindow),
        followUpWords: flags.int("follow-words", default: defaults.followUpWords))
    return TraceReplay.Options(silenceDuration: silence ?? flags.double("silence-ms", default: 400) / 1000,
                               speechThresholdDecibels: Float(flags.double("speech-db", default: -45)),
                               noiseMarginDecibels: noiseMargin, assembler: settings)
}

func describe(_ o: TraceReplay.Options) -> String {
    if o == .v04 { return "v0.4 as shipped" }
    if o.assembler == .utteranceOnly { return String(format: "silence %3.0f ms, utterance only (v0.4)", o.silenceDuration * 1000) }
    return String(format: "silence %3.0f ms, gap %.1f s, lookback %2.0f s, follow %.1f s",
                  o.silenceDuration * 1000, o.assembler.leadInGap, o.assembler.leadInSeconds, o.assembler.followUpWindow)
}

func median(_ values: [Double]) -> Double? { LatencyStats(values.map { $0 * 1000 }).map { $0.p50 / 1000 } }

func summary(_ score: QuestionScore) -> String {
    String(format: "labels %d, asked %d (%.0f%%), complete %d (%.0f%%), coverage %.2f (first ask %.2f), extra %.2f, false %d, asked after %@ s, final after %@ s, score %.3f",
           score.labels, score.detected, pct(score.detected, score.labels), score.complete, pct(score.complete, score.labels),
           score.meanCoverage, score.meanFirstCoverage, score.meanExtra, score.falseTriggers.count,
           median(score.askDelays).map { String(format: "%.1f", $0) } ?? "-",
           median(score.revisionDelays).map { String(format: "%.1f", $0) } ?? "-", score.score)
}

func pct(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) * 100 / Double(b) }

switch command {
case "transcript":
    for path in traces {
        let (trace, _) = load(path)
        let result = TraceReplay.run(trace, options: options())
        print("# \(path): \(result.utterances.count) utterances, \(clock(trace.duration)) of audio (\(describe(options())))")
        for (index, utterance) in result.utterances.enumerated() {
            print(String(format: "%4d  %@  %@  %@", index, clock(utterance.start), clock(utterance.end), utterance.text))
        }
    }

case "replay":
    var scores: [QuestionScore] = []
    for path in traces {
        let (trace, labels) = load(path)
        let o = options()
        let result = TraceReplay.run(trace, options: o)
        print("== \(path) (\(describe(o)))")
        print("   \(result.utterances.count) utterances, \(result.questions.count) questions asked")
        guard let labels else {
            for asked in result.questions {
                print("  \(clock(asked.askedAt))  \(asked.last.revision > 0 ? "rev \(asked.last.revision) " : "")\(asked.last.text)")
            }
            print("   (no \(labelsPath(for: URL(fileURLWithPath: path)).lastPathComponent): run `spike-qa label` or write one to score)")
            continue
        }
        let score = QuestionScore(labels: labels, asked: result.questions)
        scores.append(score)
        print("   " + summary(score))
        if flags.has("verbose") {
            for match in score.matches {
                print("\n  label  \(clock(match.label.start))-\(clock(match.label.end))  \(match.label.text)")
                if let asked = match.asked {
                    print(String(format: "  asked  %@  coverage %.2f, extra %.2f%@", clock(asked.askedAt), match.coverage, match.extra,
                                 asked.last.revision > 0 ? ", \(asked.last.revision) follow-up(s)" : ""))
                    if !asked.last.leadIn.isEmpty { print("         lead-in:  \(asked.last.leadIn)") }
                    print("         question: \(asked.last.asked)")
                } else {
                    print("  MISSED")
                }
            }
            for asked in score.falseTriggers {
                print("\n  FALSE  \(clock(asked.askedAt))  \(asked.last.text)")
            }
        }
    }
    if scores.count > 1 { print("\n== all traces\n   " + summary(QuestionScore(merging: scores))) }

case "sweep":
    let loaded = traces.map(load)
    guard !loaded.isEmpty, loaded.allSatisfy({ $0.labels != nil }) else {
        fail("sweep needs traces with .labels.tsv files next to them")
    }
    func list(_ key: String, _ fallback: [Double]) -> [Double] {
        flags.values[key].map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } } ?? fallback
    }
    let silences = list("silence-ms", [300, 400, 600, 800]).map { $0 / 1000 }
    let gaps = list("gap", [0, 0.8, 1.2, 1.5, 2, 3])
    let lookbacks = list("lookback", [10, 20, 30])
    let follows = list("follow", [0, 1, 2, 3])
    var rows: [(options: TraceReplay.Options, score: QuestionScore)] = []
    func evaluate(_ o: TraceReplay.Options) -> QuestionScore {
        QuestionScore(merging: loaded.map { QuestionScore(labels: $0.labels!, asked: TraceReplay.run($0.trace, options: o).questions) })
    }
    for silence in silences {
        rows.append((TraceReplay.Options(silenceDuration: silence, noiseMarginDecibels: noiseMargin, assembler: .utteranceOnly),
                     QuestionScore(matches: [], falseTriggers: [])))
        rows[rows.count - 1].score = evaluate(rows[rows.count - 1].options)
        for gap in gaps {
            for lookback in (gap == 0 ? [lookbacks[0]] : lookbacks) {
                for follow in follows {
                    let o = TraceReplay.Options(silenceDuration: silence, noiseMarginDecibels: noiseMargin,
                                                assembler: .init(leadInGap: gap, leadInSeconds: lookback, followUpWindow: follow))
                    rows.append((o, evaluate(o)))
                }
            }
        }
    }
    let defaults = TraceReplay.Options()
    let labelCount = loaded.reduce(0) { $0 + $1.labels!.count }
    print("\(loaded.count) trace(s), \(labelCount) labelled questions, \(rows.count) settings")
    print("score = coverage x (1 - extra) - 0.25 x false triggers per label; coverage counts missed questions as 0\n")
    func row(_ r: (options: TraceReplay.Options, score: QuestionScore), _ tag: String = "") -> String {
        let s = r.score
        return String(format: "%-56@ cov %.2f  first %.2f  extra %.2f  complete %3.0f%%  asked %3.0f%%  false %2d  delay %@/%@ s  score %.3f %@",
                      describe(r.options), s.meanCoverage, s.meanFirstCoverage, s.meanExtra, pct(s.complete, s.labels),
                      pct(s.detected, s.labels), s.falseTriggers.count,
                      median(s.askDelays).map { String(format: "%.1f", $0) } ?? "-",
                      median(s.revisionDelays).map { String(format: "%.1f", $0) } ?? "-", s.score, tag)
    }
    let ranked = rows.sorted { $0.score.score > $1.score.score }
    print("Best \(min(flags.int("top", default: 15), ranked.count)):")
    for r in ranked.prefix(flags.int("top", default: 15)) { print(row(r)) }
    print("\nReference:")
    if let current = rows.first(where: { $0.options == defaults }) { print(row(current, "<- current default")) }
    else { print(row((defaults, evaluate(defaults)), "<- current default")) }
    if let utteranceOnly = rows.first(where: { $0.options.assembler == .utteranceOnly && $0.options.silenceDuration == 0.4 }) {
        print(row(utteranceOnly, "<- new detection, v0.4 assembly"))
    }
    print(row((.v04, evaluate(.v04)), "<- v0.4 as shipped"))

case "label":
    guard let path = traces.first else { fail("usage: spike-qa label call.jsonl") }
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        fail("set ANTHROPIC_API_KEY to draft labels with Claude, or write the .labels.tsv by hand")
    }
    let url = URL(fileURLWithPath: path)
    let target = labelsPath(for: url)
    if FileManager.default.fileExists(atPath: target.path) && !flags.has("force") {
        fail("\(target.path) exists; pass --force to replace it")
    }
    let (trace, _) = load(path)
    // Label from long utterances (1.5 s pauses) so each line is a readable stretch of speech.
    let utterances = TraceReplay.run(trace, options: TraceReplay.Options(silenceDuration: 1.5)).utterances
    let transcript = utterances.enumerated().map { String(format: "[%d] %@", $0.offset, $0.element.text) }.joined(separator: "\n")
    let instructions = """
    Below is a transcript of a recorded conversation (speech recognition, one numbered line per stretch of speech; \
    speakers are not labelled). Find every genuine question one person asks another that an expert would answer: \
    skip rhetorical questions, filler ("you know?", "right?") and call logistics ("can you hear me?").

    For each question, give the full question as the listener needs it: the asker's set-up before the question \
    (context, constraints, the situation they describe) and any clarification right after it, in the speaker's \
    own words copied exactly from the transcript. Do not include the other person's answer.

    Reply with only a JSON array, one object per question, in order:
    [{"first": <line number where the set-up starts>, "last": <line number where the question ends>, "text": "<exact words>"}]

    Transcript:
    \(transcript)
    """
    let client = AnthropicClient(configuration: AnthropicConfiguration(apiKey: key, timeout: 300))
    let model = flags.string("model", default: "claude-opus-5-5")
    let request = MessagesRequest(model: model, maxTokens: 16_000, messages: [.user(instructions)])
    var accumulator = StreamAccumulator()
    do {
        for try await event in client.stream(request) { _ = accumulator.apply(event) }
    } catch { fail("Claude request failed: \(error)") }
    guard let reply = accumulator.answerText, let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]") else {
        fail("no JSON array in the reply:\n\(accumulator.rawText)")
    }
    struct Drafted: Decodable { let first: Int; let last: Int; let text: String }
    let drafted: [Drafted]
    do { drafted = try JSONDecoder().decode([Drafted].self, from: Data(reply[start...end].utf8)) } catch {
        fail("could not read the reply: \(error)\n\(reply)")
    }
    let labels = drafted.compactMap { item -> QuestionLabel? in
        guard utterances.indices.contains(item.first), utterances.indices.contains(item.last), item.first <= item.last else { return nil }
        return QuestionLabel(start: utterances[item.first].start, end: utterances[item.last].end,
                             text: item.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))
    }
    let comment = """
    Drafted by \(model) from \(url.lastPathComponent). Check every line before calibrating:
    fix the wording to what was really asked, delete non-questions, add missed ones.
    start<TAB>end<TAB>full question (seconds or m:ss)
    """
    do { try QuestionLabel.format(labels, comment: comment).write(to: target, atomically: true, encoding: .utf8) } catch {
        fail("could not write \(target.path): \(error)")
    }
    print("wrote \(labels.count) labels to \(target.path)")

default:
    print("""
    usage:
      spike-qa transcript <trace.jsonl>...          utterances with times, for writing labels
      spike-qa label <trace.jsonl> [--model m]      draft <trace>.labels.tsv with Claude (ANTHROPIC_API_KEY)
      spike-qa replay <trace.jsonl>... [settings] [--verbose]
      spike-qa sweep <trace.jsonl>... [--silence-ms 300,400] [--gap 0,1.5] [--lookback 10,20] [--follow 0,2] [--top 15]
    settings: --silence-ms 400 --speech-db -45 --noise-margin 12 --gap 1.5 --lookback 20 --lead-words 80 --follow 0 --follow-words 60
              --utterance-only (v0.4 assembly)  --fixed-threshold (v0.4 end of speech)  --v04 (v0.4 as shipped)
    """)
}
