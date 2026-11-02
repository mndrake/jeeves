#if os(macOS)
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import JeevesCore
import Synchronization

/// What a capture session is doing, for logs and the menu bar.
public enum CaptureStatus: Sendable, Equatable, CustomStringConvertible {
    case starting
    case waitingForBrowser(Browser)
    case capturing(processes: Int, outputDevice: String)
    case reconnecting(reason: String)
    case stopped

    public var description: String {
        switch self {
        case .starting: "starting"
        case .waitingForBrowser(let browser): "waiting for \(browser.rawValue.capitalized) to play audio"
        case .capturing(let processes, let device):
            processes > 0 ? "capturing \(processes) processes, output: \(device)" : "capturing, output: \(device)"
        case .reconnecting(let reason): "reconnecting: \(reason)"
        case .stopped: "stopped"
        }
    }
}

public enum CaptureEvent: Sendable {
    case audio(AudioChunk)
    case status(CaptureStatus)
}

public struct CaptureStatistics: Sendable {
    /// Every tap restart, grouped into outages (see `RestartLog`).
    public var restartLog = RestartLog()
    public var restarts: [RestartLog.Entry] { restartLog.entries }
    /// From the first tap starting to its first audio (nil until audio arrives).
    public var startupMs: Double?
    public var retargets = 0
    public var retargetFailures = 0
    /// Whether in-place retargeting worked on this Mac (nil until first tried).
    public var retargetSupported: Bool?
    public var silenceFilledSeconds = 0.0
    public var outputSeconds = 0.0
    /// Totals across every tap the session has used.
    public var callbacks = 0
    public var emptyCallbacks = 0
    public var inputFrames = 0
    public var outputFrames = 0
    public var discontinuities = 0
    public var droppedFrames = 0
    public var audibleChunks = 0
    public var conversionErrors = 0
    public var inputSampleRate = 0.0
    public var inputChannels = 0

    mutating func add(_ tap: TapStatistics) {
        callbacks += tap.callbacks
        emptyCallbacks += tap.emptyCallbacks
        inputFrames += tap.inputFrames
        outputFrames += tap.outputFrames
        discontinuities += tap.discontinuities
        droppedFrames += tap.droppedFrames
        audibleChunks += tap.audibleChunks
        conversionErrors += tap.conversionErrors
        if tap.inputSampleRate > 0 {
            inputSampleRate = tap.inputSampleRate
            inputChannels = tap.inputChannels
        }
    }
}

/// Keeps a browser's audio flowing for the length of a call (docs/prd/01, milestone M1).
///
/// Wraps `ProcessTap` and repairs it when the world changes:
/// - The browser starts or ends audio processes (new tab, new call, restart): the tap is
///   retargeted in place, or rebuilt if retargeting is unsupported and a missed
///   process is playing. Watched through Core Audio's process list plus a 1 s poll.
/// - The default output device changes (AirPods connect or disconnect): the tap's
///   aggregate device is rebuilt on the new device.
/// - No first audio within `watchdog.startupTimeout`, or IO stops arriving for
///   `watchdog.stallTimeout` once it has flowed: rebuilt.
/// - The browser quits: capture pauses and resumes when it plays audio again.
/// Failed rebuilds retry with exponential backoff. Audio lost during a rebuild is
/// replaced with silence so the consumer's timeline stays aligned with real time.
///
/// All control logic runs on one serial queue. Call `stop()` when done.
public final class CaptureSession: @unchecked Sendable {
    public let browser: Browser
    public let strategy: TapStrategy
    public let outputFormat: AVAudioFormat
    public var watchdog = IOWatchdog()
    public var pollInterval: Double = 1.0

    private let control = DispatchQueue(label: "jeeves.capture.control", qos: .userInitiated)

    // Control-queue state.
    private var running = false
    private var tap: ProcessTap?
    private var tapped: Set<AudioObjectID>?
    private var tapStartedAt: UInt64 = 0
    private var outputDeviceName = ""
    private var canRetarget = true
    private var backoff = ExponentialBackoff()
    private var retryScheduled = false
    private var evaluatePending = false
    private var deviceChangePending = false
    private var timer: DispatchSourceTimer?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var status: CaptureStatus = .stopped
    /// Statistics of taps already torn down (restarts), added into the session totals.
    private var finishedTaps: [TapStatistics] = []

    // Shared with the IO handler.
    private struct Shared {
        var continuation: AsyncStream<CaptureEvent>.Continuation?
        var aligner = TimelineAligner()
        var afterRestart = false
        var firstTapStartedAt: UInt64?
        var stats = CaptureStatistics()
    }
    private let shared = Mutex(Shared())

    public init(browser: Browser, strategy: TapStrategy = .processes, outputFormat: AVAudioFormat? = nil) {
        self.browser = browser
        self.strategy = strategy
        self.outputFormat = outputFormat
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    /// Starts capturing. Audio and status changes arrive on the stream until `stop()`.
    public func start() -> AsyncStream<CaptureEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .bufferingNewest(1024))
        shared.withLock { $0.continuation = continuation }
        control.async { [weak self] in self?.begin() }
        return stream
    }

    /// Stops capture, removes listeners and ends the event stream. Do not call from the
    /// session's own event handlers' queue.
    public func stop() {
        control.sync { shutdown() }
    }

    /// A snapshot of totals across every tap this session has used.
    public var statistics: CaptureStatistics {
        let (finished, current) = control.sync { (finishedTaps, tap?.stats) }
        var stats = shared.withLock { $0.stats }
        for tapStats in finished { stats.add(tapStats) }
        if let current { stats.add(current) }
        return stats
    }

    // MARK: Control queue

    private func begin() {
        guard !running else { return }
        running = true
        publish(.starting)
        addListeners()
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        evaluate()
    }

    private func shutdown() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        removeListeners()
        stopTap()
        tapped = nil
        publish(.stopped)
        shared.withLock {
            $0.continuation?.finish()
            $0.continuation = nil
        }
    }

    private func tick() {
        guard running else { return }
        if let tap {
            let stats = tap.stats
            let verdict = watchdog.check(now: MonotonicClock.now(), tapStartedAt: tapStartedAt,
                                         firstCallbackAt: stats.firstCallbackAt == 0 ? nil : stats.firstCallbackAt,
                                         lastCallbackAt: stats.lastCallbackAt == 0 ? nil : stats.lastCallbackAt)
            switch verdict {
            case .healthy:
                break
            case .slowStart:
                restart(reason: "no audio within \(String(format: "%g", watchdog.startupTimeout)) s of starting the tap")
                return
            case .stalled:
                restart(reason: "audio IO stalled for \(String(format: "%g", watchdog.stallTimeout)) s")
                return
            }
        }
        evaluate()
    }

    private func evaluate() {
        guard running, !retryScheduled else { return }
        switch strategy {
        case .processes:
            evaluateProcesses()
        case .system, .bundleIDs:
            if tap == nil { startTap(restarting: false) }
        }
    }

    private func evaluateProcesses() {
        let processes: [AudioProcessInfo]
        do {
            processes = try AudioProcessInfo.all()
        } catch {
            publish(.reconnecting(reason: "cannot read Core Audio's process list: \(error)"))
            scheduleRetry()
            return
        }
        let action = CapturePlanner.decide(browser: browser, processes: processes, tapped: tapped, canRetarget: canRetarget)
        switch action {
        case .none:
            break
        case .waitForBrowser:
            if status != .waitingForBrowser(browser) { publish(.waitingForBrowser(browser)) }
        case .start(let set):
            tapped = set
            startTap(restarting: false)
        case .retarget(let set):
            if let tap, tap.retarget(processes: set.sorted()) {
                tapped = set
                shared.withLock {
                    $0.stats.retargets += 1
                    $0.stats.retargetSupported = true
                }
                publish(.capturing(processes: set.count, outputDevice: outputDeviceName))
            } else {
                canRetarget = false
                shared.withLock {
                    $0.stats.retargetFailures += 1
                    $0.stats.retargetSupported = false
                }
                evaluateProcesses()  // decide again without retargeting
            }
        case .rebuild(let set, let reason):
            tapped = set
            restart(reason: reason)
        case .stop(let reason):
            stopTap()
            tapped = nil
            publish(.reconnecting(reason: reason))
            publish(.waitingForBrowser(browser))
        }
    }

    private func currentTarget() throws -> TapTarget {
        switch strategy {
        case .processes:
            return .processes((tapped ?? []).sorted())
        case .system, .bundleIDs:
            return try ProcessTap.target(for: browser, strategy: strategy)
        }
    }

    private func startTap(restarting: Bool) {
        do {
            let target = try currentTarget()
            let tap = ProcessTap(target: target, outputFormat: outputFormat)
            try tap.start { [weak self] chunk in self?.handle(chunk) }
            self.tap = tap
            tapStartedAt = MonotonicClock.now()
            outputDeviceName = (try? AudioProperty.defaultOutputDevice().name) ?? "unknown device"
            backoff.reset()
            let startedAt = tapStartedAt
            shared.withLock {
                if $0.stats.restartLog.hasPending { $0.afterRestart = true }
                if $0.firstTapStartedAt == nil { $0.firstTapStartedAt = startedAt }
            }
            publish(.capturing(processes: tapped?.count ?? 0, outputDevice: outputDeviceName))
        } catch {
            publish(.reconnecting(reason: "\(error)"))
            scheduleRetry()
        }
    }

    private func stopTap() {
        guard let tap else { return }
        tap.stop()
        finishedTaps.append(tap.stats)
        self.tap = nil
    }

    private func restart(reason: String) {
        shared.withLock { $0.stats.restartLog.began(reason: reason, at: MonotonicClock.now()) }
        publish(.reconnecting(reason: reason))
        stopTap()
        startTap(restarting: true)
    }

    private func scheduleRetry() {
        guard running, !retryScheduled else { return }
        retryScheduled = true
        control.asyncAfter(deadline: .now() + backoff.nextDelay()) { [weak self] in
            guard let self, self.running else { return }
            self.retryScheduled = false
            if self.tap == nil, self.strategy == .processes { self.tapped = nil }  // re-plan from scratch
            self.evaluate()
        }
    }

    private func outputDeviceChanged() {
        guard running, !deviceChangePending else { return }
        deviceChangePending = true
        // Devices often change in a burst (AirPods connect: device added, then made default).
        control.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.running else { return }
            self.deviceChangePending = false
            guard let tap = self.tap, let current = try? AudioProperty.defaultOutputDevice(),
                  current.uid != tap.outputDeviceUID else { return }
            self.restart(reason: "output device changed to \(current.name)")
        }
    }

    private func processListChanged() {
        guard running, !evaluatePending else { return }
        evaluatePending = true
        control.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.evaluatePending = false
            self.evaluate()
        }
    }

    private func publish(_ newStatus: CaptureStatus) {
        status = newStatus
        _ = shared.withLock { $0.continuation?.yield(.status(newStatus)) }
    }

    // MARK: Core Audio listeners

    private func addListeners() {
        listen(AudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.processListChanged() }
        listen(AudioProperty.systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice) { [weak self] in self?.outputDeviceChanged() }
        listen(AudioProperty.systemObject, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputDeviceChanged() }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ action: @escaping @Sendable () -> Void) {
        var address = AudioProperty.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        if AudioObjectAddPropertyListenerBlock(object, &address, control, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func removeListeners() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, control, listener.block)
        }
        listeners.removeAll()
    }

    // MARK: IO queue

    private func handle(_ chunk: AudioChunk) {
        let duration = Double(chunk.buffer.frameLength) / outputFormat.sampleRate
        let (fill, continuation) = shared.withLock { (state: inout Shared) -> (Double, AsyncStream<CaptureEvent>.Continuation?) in
            let fill = state.aligner.silenceBefore(chunkDuration: duration, capturedAt: chunk.capturedAt,
                                                   afterRestart: state.afterRestart)
            state.afterRestart = false
            state.stats.restartLog.audioArrived(at: chunk.capturedAt)
            if state.stats.startupMs == nil, let started = state.firstTapStartedAt {
                state.stats.startupMs = MonotonicClock.milliseconds(from: started, to: chunk.capturedAt)
            }
            state.stats.silenceFilledSeconds += fill
            state.stats.outputSeconds += fill + duration
            return (fill, state.continuation)
        }
        if fill > 0, let silence = makeSilence(seconds: fill) {
            continuation?.yield(.audio(AudioChunk(buffer: silence, hostTime: chunk.hostTime,
                                                  capturedAt: chunk.capturedAt, rmsDecibels: -160)))
        }
        continuation?.yield(.audio(chunk))
    }

    private func makeSilence(seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount((seconds * outputFormat.sampleRate).rounded())
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
        }
        return buffer
    }
}
#endif
