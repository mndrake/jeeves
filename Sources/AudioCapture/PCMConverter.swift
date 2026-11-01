#if os(macOS)
@preconcurrency import AVFoundation

/// Streaming sample-rate and format conversion with AVAudioConverter.
///
/// Conversion state (resampler history) is kept across calls, so feed buffers in
/// order and never signal end-of-stream mid-session. Not thread-safe: use from one
/// queue (the tap's IO queue, or one task for files).
public final class PCMConverter {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CoreAudioError(status: -1, operation: "create converter \(inputFormat) -> \(outputFormat)")
        }
        // Speech: favour quality over CPU only slightly; the input is already band-limited call audio.
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Converts one buffer. Returns nil if the converter produced no frames yet.
    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let feed = OneShotInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if let buffer = feed.take() {
                inputStatus.pointee = .haveData
                return buffer
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        if status == .error { throw error ?? CoreAudioError(status: -1, operation: "convert") }
        return output.frameLength > 0 ? output : nil
    }
}

/// Hands the converter its input exactly once per convert call.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

extension AVAudioPCMBuffer {
    /// Root-mean-square level of channel 0 in dBFS (-160 for silence).
    public var rmsDecibels: Float {
        let frames = Int(frameLength)
        guard frames > 0 else { return -160 }
        var sum: Float = 0
        if let samples = floatChannelData?[0] {
            for i in 0..<frames { sum += samples[i] * samples[i] }
        } else if let samples = int16ChannelData?[0] {
            for i in 0..<frames { let s = Float(samples[i]) / 32768; sum += s * s }
        } else {
            return -160
        }
        let rms = (sum / Float(frames)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }
}
#endif
