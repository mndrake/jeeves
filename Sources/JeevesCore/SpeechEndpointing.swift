/// Level-based end-of-speech detection.
///
/// Speech engines finalize late: on the MacBook Air, SpeechAnalyzer's final results
/// trailed the audio by 828 ms p50 (DECISIONS, 2026-11-02). Jeeves therefore decides
/// for itself when a speaker has stopped: audio above a speech threshold, followed by
/// a run of quieter audio. That moment can trigger question detection on the latest
/// partial transcript, or force the engine to finalize early.
public struct SilenceEndpointer: Sendable {
    public struct EndOfSpeech: Sendable, Equatable {
        /// Session audio time (seconds) when speech started and ended.
        public var speechStart: Double
        public var audioTime: Double
        /// Monotonic time the last loud chunk was captured: when the speaker stopped.
        public var wallTime: UInt64
        /// Monotonic time the silence threshold was reached and this end was reported.
        public var detectedAt: UInt64
    }

    /// Audio above this level is speech, whatever the noise floor.
    public var speechThresholdDecibels: Float
    /// How long the audio must stay below the threshold to count as the end of speech.
    public var silenceDuration: Double
    /// Shorter bursts (a click, a cough) are ignored.
    public var minimumSpeechDuration: Double
    /// When set, speech must also be this far above the noise floor. Recordings with room
    /// tone, a music bed or a noisy line never fall below a fixed -45 dBFS between
    /// phrases, so a fixed threshold would see one endless utterance. nil: fixed only.
    public var noiseMarginDecibels: Float?

    public private(set) var audioTime: Double = 0
    /// Estimated noise floor: follows quiet audio down at once, rises slowly.
    public private(set) var noiseFloorDecibels: Float = -90
    private var speechStart: Double?
    private var lastLoudEnd: Double = 0
    private var lastLoudWall: UInt64 = 0

    /// How fast the noise floor may rise, in dB per second of audio.
    static let floorRisePerSecond: Float = 0.5

    public init(speechThresholdDecibels: Float = -45, silenceDuration: Double = 0.4, minimumSpeechDuration: Double = 0.15,
                noiseMarginDecibels: Float? = 12) {
        self.speechThresholdDecibels = speechThresholdDecibels
        self.silenceDuration = silenceDuration
        self.minimumSpeechDuration = minimumSpeechDuration
        self.noiseMarginDecibels = noiseMarginDecibels
    }

    public var isInSpeech: Bool { speechStart != nil }

    /// The level audio must exceed to count as speech right now.
    public var currentThresholdDecibels: Float {
        guard let margin = noiseMarginDecibels else { return speechThresholdDecibels }
        return max(speechThresholdDecibels, noiseFloorDecibels + margin)
    }

    /// Feeds one chunk of audio, in order. Returns an end of speech at most once per
    /// utterance, when the silence after it reaches `silenceDuration`.
    public mutating func process(levelDecibels: Float, duration: Double, capturedAt: UInt64) -> EndOfSpeech? {
        let chunkStart = audioTime
        audioTime += duration
        let threshold = currentThresholdDecibels
        if levelDecibels < noiseFloorDecibels {
            noiseFloorDecibels = max(levelDecibels, -90)
        } else {
            noiseFloorDecibels = min(levelDecibels, noiseFloorDecibels + Self.floorRisePerSecond * Float(duration))
        }
        if levelDecibels > threshold {
            if speechStart == nil { speechStart = chunkStart }
            lastLoudEnd = audioTime
            lastLoudWall = capturedAt
            return nil
        }
        guard let start = speechStart, audioTime - lastLoudEnd >= silenceDuration else { return nil }
        speechStart = nil
        guard lastLoudEnd - start >= minimumSpeechDuration else { return nil }
        return EndOfSpeech(speechStart: start, audioTime: lastLoudEnd, wallTime: lastLoudWall, detectedAt: capturedAt)
    }
}

/// Pairs detected ends of speech with the engine's final results to measure the time
/// from "speaker stopped" to "final text available".
public struct FinalLatencyMatcher: Sendable {
    /// A final whose audio ends this far after a detected end still counts for it
    /// (trailing quiet syllables, engine padding).
    public var lateTolerance: Double
    /// A final that runs further past the detected end than this covered more speech:
    /// the engine merged the pause into a longer utterance, so there is no latency to report.
    public var mergeThreshold: Double

    public private(set) var latenciesMs: [Double] = []
    public private(set) var detected = 0
    public private(set) var merged = 0
    private var pending: [SilenceEndpointer.EndOfSpeech] = []

    public init(lateTolerance: Double = 0.5, mergeThreshold: Double = 1.5) {
        self.lateTolerance = lateTolerance
        self.mergeThreshold = mergeThreshold
    }

    /// Ends of speech that no final result has covered yet.
    public var unmatched: Int { pending.count }

    public mutating func speechEnded(_ end: SilenceEndpointer.EndOfSpeech) {
        detected += 1
        pending.append(end)
    }

    /// Call for each final result. Returns the latency (ms) of the end it resolved, if any.
    ///
    /// Only the last end of speech a final covers gets a latency: earlier pauses inside
    /// the same final were swallowed by the engine, and timing them from the final would
    /// include the speech that followed them.
    @discardableResult
    public mutating func finalArrived(audioEnd: Double, at receivedAt: UInt64) -> [Double] {
        let covered = pending.filter { $0.audioTime <= audioEnd + lateTolerance }
        guard let last = covered.max(by: { $0.audioTime < $1.audioTime }) else { return [] }
        pending.removeAll { $0.audioTime <= audioEnd + lateTolerance }
        merged += covered.count - 1
        if audioEnd - last.audioTime > mergeThreshold {
            merged += 1
            return []
        }
        let latency = MonotonicClock.milliseconds(from: last.wallTime, to: receivedAt)
        latenciesMs.append(latency)
        return [latency]
    }
}
