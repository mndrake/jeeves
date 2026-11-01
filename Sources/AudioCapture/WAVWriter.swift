#if os(macOS)
@preconcurrency import AVFoundation

/// Writes captured chunks to a WAV file (16-bit PCM at the chunk's sample rate), to
/// build the M2 speech-to-text evaluation set from real calls.
public final class WAVWriter {
    private let file: AVAudioFile

    public init(url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws { try file.write(from: buffer) }
}
#endif
