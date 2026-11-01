#if os(macOS)
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import JeevesCore
import Synchronization

/// Converted audio from the tap, ready for the speech engine.
public struct AudioChunk: @unchecked Sendable {
    /// In the tap's requested output format. Owned by the receiver.
    public let buffer: AVAudioPCMBuffer
    /// Host time of the first frame (mach absolute time units).
    public let hostTime: UInt64
    /// Monotonic time the IO callback ran.
    public let capturedAt: UInt64
    public let rmsDecibels: Float
}

public struct TapStatistics: Sendable, Equatable {
    public var callbacks = 0
    public var inputFrames = 0
    public var outputFrames = 0
    /// IO cycles whose sample time did not follow on from the previous one.
    public var discontinuities = 0
    public var droppedFrames = 0
    public var conversionErrors = 0
    public var inputSampleRate: Double = 0
    public var inputChannels: Int = 0
}

/// What to capture.
public enum TapTarget: Sendable, CustomStringConvertible {
    /// Specific Core Audio process objects (for a browser, its helper processes).
    case processes([AudioObjectID])
    /// Processes by bundle ID (macOS 26). With process restore on, a matching process
    /// that starts later is added automatically.
    case bundleIDs([String])
    /// Everything except the listed processes (fallback when per-app taps miss audio).
    case systemExcluding([AudioObjectID])

    public var description: String {
        switch self {
        case .processes(let ids): "processes \(ids)"
        case .bundleIDs(let ids): "bundle IDs \(ids)"
        case .systemExcluding(let ids): "system audio excluding \(ids)"
        }
    }
}

/// Captures another app's audio output with a Core Audio process tap, without a
/// virtual audio driver and without muting what the user hears.
///
/// Structure follows Apple's "Capturing system audio with Core Audio taps" sample:
/// a private, unmuted mono tap wrapped in a private aggregate device whose IO proc
/// receives the tapped audio. Requires `NSAudioCaptureUsageDescription`; macOS asks
/// for "system audio recording" permission the first time IO starts.
public final class ProcessTap: @unchecked Sendable {
    public let target: TapTarget
    public let outputFormat: AVAudioFormat

    private let ioQueue = DispatchQueue(label: "jeeves.tap.io", qos: .userInteractive)
    private let statistics = Mutex(TapStatistics())
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    // Touched only on ioQueue.
    private var converter: PCMConverter?
    private var expectedSampleTime: Double?

    /// - Parameter outputFormat: format delivered to the consumer, normally the speech
    ///   engine's preferred format. Defaults to 16 kHz mono Float32.
    public init(target: TapTarget, outputFormat: AVAudioFormat? = nil) {
        self.target = target
        self.outputFormat = outputFormat
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    deinit { stop() }

    public var stats: TapStatistics { statistics.withLock { $0 } }

    /// Creates the tap and aggregate device and starts IO. Chunks arrive on the
    /// returned stream until `stop()` is called.
    public func start() throws -> AsyncStream<AudioChunk> {
        precondition(ioProcID == nil, "tap already started")
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        do {
            try createTap()
            try createAggregateDevice()
            try startIO()
        } catch {
            stop()
            throw error
        }
        return stream
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
    }

    private var tapUUID = UUID()

    private func createTap() throws {
        let description: CATapDescription
        switch target {
        case .processes(let objects):
            description = CATapDescription(monoMixdownOfProcesses: objects)
        case .bundleIDs(let bundleIDs):
            description = CATapDescription()
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
            description.isMixdown = true
            description.isMono = true
            description.isExclusive = false
        case .systemExcluding(let objects):
            description = CATapDescription(monoGlobalTapButExcludeProcesses: objects)
        }
        description.name = "Jeeves call audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        tapUUID = description.uuid

        var newTap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTap), "AudioHardwareCreateProcessTap(\(target))")
        tapID = newTap
    }

    private func createAggregateDevice() throws {
        let outputUID = try AudioProperty.defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jeeves Tap",
            kAudioAggregateDeviceUIDKey: "jeeves-tap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var newDevice = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDevice), "AudioHardwareCreateAggregateDevice")
        aggregateID = newDevice
    }

    private func startIO() throws {
        var streamDescription = try AudioProperty.scalar(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError(status: -1, operation: "unsupported tap format \(streamDescription)")
        }
        let converter = try PCMConverter(from: tapFormat, to: outputFormat)
        statistics.withLock {
            $0.inputSampleRate = tapFormat.sampleRate
            $0.inputChannels = Int(tapFormat.channelCount)
        }
        ioQueue.sync { self.converter = converter }

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            self?.handleInput(inputData, time: inputTime.pointee, format: tapFormat)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    /// Runs on ioQueue for every IO cycle.
    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, time: AudioTimeStamp, format: AVAudioFormat) {
        let capturedAt = MonotonicClock.now()
        guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
              input.frameLength > 0 else { return }

        // Detect gaps: each cycle should start where the previous one ended.
        var gap = 0
        if time.mFlags.contains(.sampleTimeValid) {
            if let expected = expectedSampleTime, abs(time.mSampleTime - expected) > 1 {
                gap = max(0, Int(time.mSampleTime - expected))
            }
            expectedSampleTime = time.mSampleTime + Double(input.frameLength)
        }

        var output: AVAudioPCMBuffer?
        var failed = false
        do { output = try converter?.convert(input) } catch { failed = true }

        statistics.withLock {
            $0.callbacks += 1
            $0.inputFrames += Int(input.frameLength)
            $0.outputFrames += Int(output?.frameLength ?? 0)
            if gap > 0 { $0.discontinuities += 1; $0.droppedFrames += gap }
            if failed { $0.conversionErrors += 1 }
        }
        if let output {
            continuation?.yield(AudioChunk(buffer: output, hostTime: time.mHostTime, capturedAt: capturedAt,
                                           rmsDecibels: output.rmsDecibels))
        }
    }

    /// Picks a tap target for a browser using the given strategy.
    public static func target(for browser: Browser, strategy: TapStrategy) throws -> TapTarget {
        switch strategy {
        case .bundleIDs:
            return .bundleIDs(browser.appBundleIDs)
        case .processes:
            let objects = try browser.audioProcesses().map(\.objectID)
            guard !objects.isEmpty else {
                throw CoreAudioError(status: -1, operation: "no \(browser.rawValue) processes known to Core Audio; start the call first")
            }
            return .processes(objects)
        case .system:
            return .systemExcluding(AudioProcess.current().map { [$0] } ?? [])
        }
    }
}

public enum TapStrategy: String, CaseIterable, Sendable {
    /// `CATapDescription.bundleIDs` with process restore (macOS 26).
    case bundleIDs = "bundle"
    /// Every Core Audio process whose bundle ID matches the browser's prefixes.
    case processes = "pids"
    /// All system audio except Jeeves.
    case system
}
#endif
