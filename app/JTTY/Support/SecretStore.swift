import Foundation
import Security

/// The API keys, in the keychain.
///
/// Not in `Preferences`: that is a plain JSON blob in `UserDefaults`, which
/// is the right home for a grid square and the wrong one for a key with
/// write access to a logbook.
enum Secret: String, CaseIterable, Sendable {
    /// QRZ logbook API key. Full read/write access to that logbook.
    case qrzLogbookKey

    var account: String { rawValue }
}

struct SecretStore: Sendable {
    var service = "com.w2asm.jtty.secrets"

    func load(_ secret: Secret) -> String? {
        var query = baseQuery(secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    func save(_ value: String, for secret: Secret) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear(secret) }

        SecItemDelete(baseQuery(secret) as CFDictionary)
        var query = baseQuery(secret)
        query[kSecValueData as String] = Data(trimmed.utf8)
        // Uploads happen while a contact completes, which can be with the
        // screen locked and the app running in the background on audio.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func clear(_ secret: Secret) -> Bool {
        let status = SecItemDelete(baseQuery(secret) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Synchronizable, so a key entered on one device is present on the next.
    /// iCloud Keychain is the only route that carries a secret between devices
    /// without it passing through anything of ours.
    private func baseQuery(_ secret: Secret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.account,
            kSecAttrSynchronizable as String: true,
        ]
    }
}
