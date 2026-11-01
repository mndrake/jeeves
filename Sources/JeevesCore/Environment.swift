import Foundation

/// Minimal command-line flag parsing shared by the spike executables.
public struct CommandLineFlags: Sendable {
    public let values: [String: String]
    public let switches: Set<String>
    public let positional: [String]

    /// Parses `--key value`, `--key=value` and bare `--switch` forms.
    /// Names in `switches` never take a value, so `--dry-run file.wav` keeps
    /// `file.wav` positional. Any other `--key` followed by another `--flag`
    /// (or nothing) is also treated as a switch.
    public init(_ arguments: [String] = Array(CommandLine.arguments.dropFirst()), switches knownSwitches: Set<String> = []) {
        var values: [String: String] = [:]
        var switches: Set<String> = []
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg.hasPrefix("--") {
                let body = String(arg.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    values[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if !knownSwitches.contains(body), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    values[body] = arguments[index + 1]
                    index += 1
                } else {
                    switches.insert(body)
                }
            } else {
                positional.append(arg)
            }
            index += 1
        }
        self.values = values
        self.switches = switches
        self.positional = positional
    }

    public func string(_ key: String, default value: String) -> String { values[key] ?? value }
    public func int(_ key: String, default value: Int) -> Int { values[key].flatMap(Int.init) ?? value }
    public func double(_ key: String, default value: Double) -> Double { values[key].flatMap(Double.init) ?? value }
    public func has(_ key: String) -> Bool { switches.contains(key) || values[key] != nil }
}

/// Writes to standard error so stdout can stay machine-readable.
public func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
