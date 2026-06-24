// BridgeKeychain.swift — tiny Keychain wrapper for the Bridge auth password.
//
// The receiver-auth password is a secret: it must live in the OS secret store,
// never in UserDefaults or a plist (swift/security.md, STREAM-AUTH-SPEC §4).
// One generic-password item per `account` string — the Bridge uses a single
// "global" account (one password for every channel).

import Foundation
import Security

enum BridgeKeychain {
    /// Service tag groups all of the Bridge's auth items under one umbrella.
    private static let service = "studio.airlive.bridge.auth"

    /// Store (or replace) the password for `account`.  An empty string DELETES
    /// the item — "no password" is the absence of a secret, not a stored blank.
    static func setPassword(_ password: String, account: String) {
        deletePassword(account: account)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // This Mac only; never synced to iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            // Loud, not silent: a failed write means the UI thinks a password is set
            // but the next launch finds none — surface it so it isn't chased as a
            // phantom "auth keeps resetting" bug.
            print("[BridgeKeychain] ⚠️ SecItemAdd failed for account '\(account)': OSStatus \(status)")
        }
    }

    /// Read the stored password for `account`, or nil if none is set.
    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
