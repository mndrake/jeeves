/// One transcription result, independent of the speech engine that produced it.
/// Lives in JeevesCore so question detection (M4) can be built and tested on any platform.
public struct TranscriptUpdate: Sendable, Equatable {
    public var text: String
    /// Volatile results are revised; a final result for a range never changes.
    public var isFinal: Bool
    /// Audio time range, in seconds from the start of the session's audio.
    public var audioStart: Double
    public var audioEnd: Double
    /// Monotonic time the result was received (see MonotonicClock).
    public var receivedAt: UInt64

    public init(text: String, isFinal: Bool, audioStart: Double, audioEnd: Double, receivedAt: UInt64) {
        self.text = text
        self.isFinal = isFinal
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.receivedAt = receivedAt
    }
}
