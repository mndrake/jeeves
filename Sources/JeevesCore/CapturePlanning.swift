import Foundation

/// A process known to Core Audio. Lives in JeevesCore (plain integer IDs) so the
/// capture planning logic can be unit-tested on any platform; AudioCapture fills it in.
public struct AudioProcessInfo: Sendable, Hashable, CustomStringConvertible {
    /// Core Audio process object ID (`AudioObjectID`).
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String?
    public let isRunningOutput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }

    public var description: String {
        "pid \(pid)  object \(objectID)  \(isRunningOutput ? "PLAYING" : "idle   ")  \(bundleID ?? "(no bundle id)")"
    }
}

/// Browsers Jeeves supports for web calls. Browsers play call audio from helper
/// processes rather than the main app, so matching is by bundle-ID prefix.
/// Chrome confirmed in M0; the others are best guesses to confirm with `spike-tap --list`.
public enum Browser: String, CaseIterable, Sendable {
    case chrome, safari, edge, arc, firefox

    /// Main application bundle IDs, for `CATapDescription.bundleIDs` taps.
    public var appBundleIDs: [String] {
        switch self {
        case .chrome: ["com.google.Chrome"]
        case .safari: ["com.apple.Safari"]
        case .edge: ["com.microsoft.edgemac"]
        case .arc: ["company.thebrowser.Browser"]
        case .firefox: ["org.mozilla.firefox"]
        }
    }

    /// Prefixes of bundle IDs belonging to the browser, including helper processes.
    /// Safari's media plays from the shared WebKit GPU process, which other WebKit
    /// apps (Mail, embedded web views) also use.
    public var processBundlePrefixes: [String] {
        switch self {
        case .chrome: ["com.google.Chrome"]
        case .safari: ["com.apple.Safari", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]
        case .edge: ["com.microsoft.edgemac"]
        case .arc: ["company.thebrowser"]
        case .firefox: ["org.mozilla."]
        }
    }

    public func owns(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return processBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    public func owns(_ process: AudioProcessInfo) -> Bool { owns(bundleID: process.bundleID) }
}

/// What the capture supervisor should do with its tap after looking at Core Audio's
/// current process list.
public enum CaptureAction: Equatable, Sendable {
    case none
    /// No tap yet and the browser has no audio processes: keep watching.
    case waitForBrowser
    case start(Set<UInt32>)
    /// Change the running tap's process list in place (no audio interruption).
    case retarget(Set<UInt32>)
    /// Tear the tap down and build a new one (a short gap, filled with silence).
    case rebuild(Set<UInt32>, reason: String)
    /// The browser is gone: stop and go back to waiting.
    case stop(reason: String)
}

public enum CapturePlanner {
    /// The browser's processes Core Audio currently knows about.
    public static func targets(for browser: Browser, in processes: [AudioProcessInfo]) -> Set<UInt32> {
        Set(processes.filter(browser.owns).map(\.objectID))
    }

    /// Decides how to keep a per-process tap pointed at the browser.
    ///
    /// - Parameters:
    ///   - tapped: the processes the running tap covers, or nil if there is no tap.
    ///   - canRetarget: whether in-place retargeting works on this system (learned at
    ///     runtime; when it does not, a rebuild is only worth its audio gap if a process
    ///     the tap misses is actually playing).
    public static func decide(browser: Browser, processes: [AudioProcessInfo],
                              tapped: Set<UInt32>?, canRetarget: Bool) -> CaptureAction {
        let desired = targets(for: browser, in: processes)
        guard let tapped else {
            return desired.isEmpty ? .waitForBrowser : .start(desired)
        }
        if desired.isEmpty { return .stop(reason: "\(browser.rawValue) has no audio processes") }
        if desired == tapped { return .none }
        if tapped.isDisjoint(with: desired) {
            return .rebuild(desired, reason: "\(browser.rawValue) restarted")
        }
        if canRetarget { return .retarget(desired) }
        let missedAndPlaying = processes.contains { desired.contains($0.objectID) && !tapped.contains($0.objectID) && $0.isRunningOutput }
        return missedAndPlaying ? .rebuild(desired, reason: "new \(browser.rawValue) audio process is playing") : .none
    }
}

/// Retry delays for failed rebuilds: 0.25 s, 0.5 s, 1 s, 2 s, then capped.
public struct ExponentialBackoff: Sendable {
    public var initial: Double
    public var maximum: Double
    public var multiplier: Double
    public private(set) var attempts = 0

    public init(initial: Double = 0.25, maximum: Double = 4, multiplier: Double = 2) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
    }

    public mutating func nextDelay() -> Double {
        defer { attempts += 1 }
        return min(maximum, initial * pow(multiplier, Double(attempts)))
    }

    public mutating func reset() { attempts = 0 }
}

/// Keeps the audio timeline aligned with wall-clock time across tap rebuilds.
///
/// Speech engines number audio by samples received. If a rebuild drops 300 ms of audio
/// and nothing replaces it, every later timestamp is 300 ms early and latency figures
/// are wrong. After a restart, the aligner reports how much silence to insert so the
/// emitted audio catches up with real time. It never fills during normal capture,
/// where small differences are clock drift, not lost audio.
public struct TimelineAligner: Sendable {
    /// Longest gap filled with silence; anything longer is treated as a pause in capture.
    public var maximumFill: Double
    /// Gaps shorter than this are ignored.
    public var tolerance: Double
    public private(set) var emittedSeconds: Double = 0
    public private(set) var filledSeconds: Double = 0
    private var startedAt: UInt64?

    public init(maximumFill: Double = 5, tolerance: Double = 0.05) {
        self.maximumFill = maximumFill
        self.tolerance = tolerance
    }

    /// Call for every chunk before emitting it. `capturedAt` is when the chunk's last
    /// sample arrived. Returns the seconds of silence to emit before the chunk.
    public mutating func silenceBefore(chunkDuration: Double, capturedAt: UInt64, afterRestart: Bool) -> Double {
        guard let start = startedAt else {
            let durationNanos = UInt64(max(0, chunkDuration) * 1_000_000_000)
            startedAt = capturedAt >= durationNanos ? capturedAt - durationNanos : 0
            emittedSeconds += chunkDuration
            return 0
        }
        var fill = 0.0
        if afterRestart {
            let wallEnd = MonotonicClock.milliseconds(from: start, to: capturedAt) / 1000
            let deficit = wallEnd - (emittedSeconds + chunkDuration)
            if deficit > tolerance { fill = min(deficit, maximumFill) }
        }
        filledSeconds += fill
        emittedSeconds += fill + chunkDuration
        return fill
    }
}
