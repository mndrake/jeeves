#if os(macOS)
import CoreAudio
import Foundation
import JeevesCore

/// `AudioProcessInfo` (JeevesCore) filled in from Core Audio.
public typealias AudioProcess = AudioProcessInfo

extension AudioProcessInfo {
    /// Every process Core Audio currently tracks.
    public static func all() throws -> [AudioProcessInfo] {
        let objects = try AudioProperty.array(AudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList,
                                              element: AudioObjectID(kAudioObjectUnknown))
        return objects.compactMap { object in
            guard let pid = try? AudioProperty.scalar(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let bundleID = (try? AudioProperty.string(object, kAudioProcessPropertyBundleID)) ?? nil
            let running = (try? AudioProperty.scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcessInfo(objectID: object, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    /// This process's own Core Audio object, if it has one (used to exclude Jeeves from global taps).
    public static func current() -> AudioObjectID? {
        let object = try? AudioProperty.processObject(for: ProcessInfo.processInfo.processIdentifier)
        return object.flatMap { $0 == AudioObjectID(kAudioObjectUnknown) ? nil : $0 }
    }
}

extension Browser {
    /// The browser's processes that Core Audio currently knows about.
    public func audioProcesses() throws -> [AudioProcessInfo] {
        try AudioProcessInfo.all().filter { owns($0) }
    }
}
#endif
