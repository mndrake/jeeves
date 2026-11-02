import Foundation
import Security

enum AppPaths {
    /// ~/Library/Application Support/Jeeves, created on first use.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("Jeeves", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var index: URL { directory.appendingPathComponent("index.sqlite") }
    static var sources: URL { directory.appendingPathComponent("sources.json") }
}

/// The Anthropic API key, kept in the login Keychain (docs/prd/08).
///
/// Ad-hoc signed builds get a new code identity on every update, so after an update
/// macOS may ask once whether Jeeves may read the item; choose "Always Allow".
enum KeychainStore {
    static let service = "dev.jeeves.Jeeves"
    static let account = "anthropic-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) -> Bool {
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Jeeves Anthropic API key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
