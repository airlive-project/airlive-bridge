// BridgeKeychain.swift — tiny Keychain wrapper for per-channel auth passwords.
//
// The receiver-auth password is a secret: it must live in the OS secret store,
// never in UserDefaults or a plist (swift/security.md, STREAM-AUTH-SPEC §4).
// One generic-password item per channel, keyed by the channel's UUID, so a
// password survives a rename and is scoped to exactly one source.

import Foundation
import Security

enum BridgeKeychain {
    /// Service tag groups all of the Bridge's auth items under one umbrella.
    private static let service = "studio.airlive.bridge.auth"

    /// Store (or replace) the password for a channel.  An empty string DELETES
    /// the item — "no password" is the absence of a secret, not a stored blank.
    static func setPassword(_ password: String, for channelID: UUID) {
        let account = channelID.uuidString
        deletePassword(for: channelID)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // This Mac only; never synced to iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Read the stored password for a channel, or nil if none is set.
    static func password(for channelID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: channelID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func deletePassword(for channelID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: channelID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
