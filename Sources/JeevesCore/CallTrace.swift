import Foundation
import Synchronization

/// A recording of one listening session for offline replay (docs/QUESTIONS.md).
///
/// JSON Lines, one event per line:
/// - `header`: format version, where the trace came from, settings in force.
/// - `levels`: audio level in dBFS for consecutive `step`-second windows (the loudest
///   chunk in each window), one line per second of audio. Enough to re-run the
///   end-of-speech detector with other thresholds.
/// - `update`: every transcript result, with `at`, the session audio time when it
///   became available. Replays use it to know which text existed at each moment.
/// - `question`: what live detection asked, for comparison.
///
/// Times are seconds of session audio. No audio is stored.
public struct CallTrace: Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public var version: Int
        /// "live" (the app or spike-stt --live) or "file" (spike-stt on a recording).
        public var source: String
        public var name: String?
        public var engine: String?
        public var created: String?
        public var settings: [String: Double]?

        public init(version: Int = 1, source: String, name: String? = nil, engine: String? = nil,
                    created: String? = nil, settings: [String: Double]? = nil) {
            self.version = version
            self.source = source
            self.name = name
            self.engine = engine
            self.created = created
            self.settings = settings
        }
    }

    public struct Update: Sendable, Equatable {
        public var text: String
        public var isFinal: Bool
        public var start: Double
        public var end: Double
        /// Session audio time when the result was available.
        public var at: Double

        public init(text: String, isFinal: Bool, start: Double, end: Double, at: Double) {
            self.text = text
            self.isFinal = isFinal
            self.start = start
            self.end = end
            self.at = at
        }
    }

    public struct AskedQuestion: Sendable, Equatable {
        public var at: Double
        public var text: String
        public var reason: String
    }

    public var header: Header
    /// Window length of `levels`, in seconds.
    public var step: Double
    /// Level of each window from audio time 0, in dBFS.
    public var levels: [Float]
    public var updates: [Update]
    public var questions: [AskedQuestion]

    public var duration: Double { Double(levels.count) * step }

    public init(header: Header, step: Double, levels: [Float], updates: [Update], questions: [AskedQuestion] = []) {
        self.header = header
        self.step = step
        self.levels = levels
        self.updates = updates
        self.questions = questions
    }

    /// One line of the file. Fields depend on `type`.
    struct Line: Codable {
        var type: String
        var version: Int?
        var source: String?
        var name: String?
        var engine: String?
        var created: String?
        var settings: [String: Double]?
        var t: Double?
        var step: Double?
        var db: [Float]?
        var text: String?
        var final: Bool?
        var start: Double?
        var end: Double?
        var at: Double?
        var reason: String?
    }

    public struct FormatError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func read(_ url: URL) throws -> CallTrace {
        try parse(try Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> CallTrace {
        let decoder = JSONDecoder()
        var header: Header?
        var step = 0.05
        var levels: [Float] = []
        var updates: [Update] = []
        var questions: [AskedQuestion] = []
        var lineNumber = 0
        for raw in data.split(separator: UInt8(ascii: "\n")) where !raw.isEmpty {
            lineNumber += 1
            let line: Line
            do { line = try decoder.decode(Line.self, from: Data(raw)) } catch {
                // A trace cut off mid-write (the app quit) ends with a partial line.
                if lineNumber > 1 { continue }
                throw FormatError(description: "line \(lineNumber) is not a trace event: \(error)")
            }
            switch line.type {
            case "header":
                guard let version = line.version, version == 1 else {
                    throw FormatError(description: "unsupported trace version \(line.version.map(String.init) ?? "-")")
                }
                header = Header(version: version, source: line.source ?? "live", name: line.name, engine: line.engine,
                                created: line.created, settings: line.settings)
            case "levels":
                guard let t = line.t, let db = line.db else { continue }
                if let s = line.step, s > 0 { step = s }
                let index = Int((t / step).rounded())
                if index > levels.count {
                    levels += [Float](repeating: -160, count: index - levels.count)  // gap: treat as silence
                }
                if index < levels.count { levels.removeLast(levels.count - index) }
                levels += db
            case "update":
                guard let text = line.text, let start = line.start, let end = line.end else { continue }
                updates.append(Update(text: text, isFinal: line.final ?? false, start: start, end: end, at: line.at ?? end))
            case "question":
                guard let text = line.text else { continue }
                questions.append(AskedQuestion(at: line.at ?? 0, text: text, reason: line.reason ?? ""))
            default:
                continue
            }
        }
        guard let header else { throw FormatError(description: "no header line") }
        updates.sort { $0.at < $1.at }
        return CallTrace(header: header, step: step, levels: levels, updates: updates, questions: questions)
    }

    /// The trace as JSON Lines, in time order.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        func append(_ line: Line) throws {
            out.append(try encoder.encode(line))
            out.append(UInt8(ascii: "\n"))
        }
        try append(Line(type: "header", version: header.version, source: header.source, name: header.name,
                        engine: header.engine, created: header.created, settings: header.settings))
        let perLine = max(1, Int((1 / step).rounded()))
        var events: [(Double, Line)] = []
        for first in stride(from: 0, to: levels.count, by: perLine) {
            let slice = Array(levels[first..<min(levels.count, first + perLine)])
            events.append((Double(first) * step, Line(type: "levels", t: Double(first) * step, step: step, db: slice)))
        }
        for update in updates {
            events.append((update.at, Line(type: "update", text: update.text, final: update.isFinal,
                                           start: update.start, end: update.end, at: update.at)))
        }
        for question in questions {
            events.append((question.at, Line(type: "question", text: question.text, at: question.at, reason: question.reason)))
        }
        for (_, line) in events.sorted(by: { $0.0 < $1.0 }) { try append(line) }
        return out
    }
}

/// Writes a call trace as the session runs. Safe to call from the audio feed and the
/// main actor at once. Lines are appended immediately, so a crash loses at most the
/// last second of levels.
public final class CallTraceWriter: Sendable {
    public let url: URL
    public let step: Double

    private struct State {
        var handle: FileHandle?
        var audioTime = 0.0
        /// Levels of the windows in the current second, and that second's first window.
        var windows: [Float] = []
        var firstWindow = 0
    }
    private let state: Mutex<State>

    public init(url: URL, header: CallTrace.Header, step: Double = 0.05) throws {
        self.url = url
        self.step = step
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CallTrace.FormatError(description: "cannot create \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        state = Mutex(State(handle: handle))
        write(CallTrace.Line(type: "header", version: header.version, source: header.source, name: header.name,
                             engine: header.engine, created: header.created, settings: header.settings))
    }

    /// Records one chunk of audio, in order: its level and its length in seconds.
    public func audio(levelDecibels: Float, duration: Double) {
        let lines: [CallTrace.Line] = state.withLock { state in
            let perLine = max(1, Int((1 / step).rounded()))
            let start = state.audioTime
            state.audioTime += duration
            // The chunk covers windows [first, last]; each keeps its loudest chunk.
            // The epsilon keeps accumulated rounding from touching a neighbouring window.
            let first = Int((start / step + 1e-6).rounded(.down))
            let last = max(first, Int((state.audioTime / step - 1e-6).rounded(.up)) - 1)
            var lines: [CallTrace.Line] = []
            for window in first...last {
                let offset = window - state.firstWindow
                if offset >= perLine {
                    lines.append(Self.levelsLine(state.windows, first: state.firstWindow, step: step))
                    state.windows = []
                    state.firstWindow += perLine * (offset / perLine)
                }
                let index = window - state.firstWindow
                while state.windows.count <= index { state.windows.append(-160) }
                state.windows[index] = max(state.windows[index], (levelDecibels * 10).rounded() / 10)
            }
            return lines
        }
        lines.forEach(write)
    }

    /// Records a transcript result that became available at session audio time `at`.
    public func update(_ update: TranscriptUpdate, at: Double) {
        write(CallTrace.Line(type: "update", text: update.text, final: update.isFinal,
                             start: Self.round(update.audioStart), end: Self.round(update.audioEnd), at: Self.round(at)))
    }

    /// Records a question the live session asked.
    public func question(_ text: String, reason: String, at: Double) {
        write(CallTrace.Line(type: "question", text: text, at: Self.round(at), reason: reason))
    }

    /// Writes the last levels and closes the file.
    public func close() {
        let line: CallTrace.Line? = state.withLock { state in
            defer { state.windows = [] }
            return state.windows.isEmpty ? nil : Self.levelsLine(state.windows, first: state.firstWindow, step: step)
        }
        if let line { write(line) }
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
        }
    }

    private static func levelsLine(_ windows: [Float], first: Int, step: Double) -> CallTrace.Line {
        CallTrace.Line(type: "levels", t: round(Double(first) * step), step: step, db: windows)
    }

    private static func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    private func write(_ line: CallTrace.Line) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(line) else { return }
        data.append(UInt8(ascii: "\n"))
        state.withLock { state in
            try? state.handle?.write(contentsOf: data)
        }
    }
}
