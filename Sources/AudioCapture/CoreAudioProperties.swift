#if os(macOS)
import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        // Many Core Audio errors are four-character codes.
        let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
        let fourCC = bytes.allSatisfy { (0x20...0x7E).contains($0) } ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
        return "\(operation) failed with OSStatus \(status)\(fourCC)"
    }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

/// Typed reads of Core Audio object properties.
enum AudioProperty {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read property \(selector) of \(object)")
        return value
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, element: T) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size of property \(selector)")
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        var values = [T](repeating: element, count: count)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values), "read property \(selector)")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.size))
    }

    /// CFString properties are returned retained; the caller owns them.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read string property \(selector)")
        return value?.takeRetainedValue() as String?
    }

    /// The system's default output device and its UID (the aggregate device's clock source).
    static func defaultOutputDeviceUID() throws -> String {
        let device = try scalar(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioDeviceID(kAudioObjectUnknown))
        guard let uid = try string(device, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(status: -1, operation: "default output device has no UID")
        }
        return uid
    }

    /// Translates a PID to its Core Audio process object (kAudioObjectUnknown if none).
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "translate pid \(pid)")
        return object
    }
}
#endif
