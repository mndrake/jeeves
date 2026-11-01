#if os(macOS)
import CoreAudio
import Foundation

/// A process known to Core Audio (any process that has opened audio I/O).
public struct AudioProcess: Sendable, Hashable, CustomStringConvertible {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool

    public var description: String {
        "pid \(pid)  object \(objectID)  \(isRunningOutput ? "PLAYING" : "idle   ")  \(bundleID ?? "(no bundle id)")"
    }

    /// Every process Core Audio currently tracks.
    public static func all() throws -> [AudioProcess] {
        let objects = try AudioProperty.array(AudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList,
                                              element: AudioObjectID(kAudioObjectUnknown))
        return objects.compactMap { object in
            guard let pid = try? AudioProperty.scalar(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let bundleID = try? AudioProperty.string(object, kAudioProcessPropertyBundleID)
            let running = (try? AudioProperty.scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: object, pid: pid, bundleID: bundleID ?? nil, isRunningOutput: running != 0)
        }
    }

    /// This process's own Core Audio object, if it has one (used to exclude Jeeves from global taps).
    public static func current() -> AudioObjectID? {
        let object = try? AudioProperty.processObject(for: ProcessInfo.processInfo.processIdentifier)
        return object.flatMap { $0 == AudioObjectID(kAudioObjectUnknown) ? nil : $0 }
    }
}

/// Browsers Jeeves supports for web calls. Browsers play call audio from helper
/// processes rather than the main app, so matching is by bundle-ID prefix.
/// The prefixes are best guesses to be confirmed with `spike-tap --list` (M0).
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

    public func owns(_ process: AudioProcess) -> Bool {
        guard let bundleID = process.bundleID else { return false }
        return processBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The browser's processes that Core Audio currently knows about.
    public func audioProcesses() throws -> [AudioProcess] {
        try AudioProcess.all().filter(owns)
    }
}
#endif
