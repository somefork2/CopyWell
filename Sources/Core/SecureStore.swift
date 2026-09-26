import CryptoKit
import Foundation
import Security

/// Encrypts the text of clips flagged as sensitive.
///
/// The symmetric key lives in the login keychain; the ciphertext lives in the
/// SwiftData store. A database copied off the machine is useless without it.
enum SecureStore {
    private static let account = "com.copywell.contentKey"
    private static let service = "CopyWell"

    /// Guarded by `lock`: the key is fetched once and reused for the process.
    nonisolated(unsafe) private static var cachedKey: SymmetricKey?
    private static let lock = NSLock()

    static func seal(_ plaintext: String) -> Data? {
        guard let key = key() else { return nil }
        return try? ChaChaPoly.seal(Data(plaintext.utf8), using: key).combined
    }

    static func open(_ ciphertext: Data) -> String? {
        guard let key = key(),
              let box = try? ChaChaPoly.SealedBox(combined: ciphertext),
              let data = try? ChaChaPoly.open(box, using: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func key() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        switch loadKey() {
        case .found(let existing):
            cachedKey = existing
            return existing
        case .failed:
            // The keychain answered with an error — locked, busy, access
            // denied — not "there is no key". Making a new key here used to
            // delete the old one on the way in, and every encrypted clip
            // became unreadable for good. Better to fail this once.
            return nil
        case .missing:
            break
        }
        let fresh = SymmetricKey(size: .bits256)
        guard storeKey(fresh) else { return nil }
        cachedKey = fresh
        return fresh
    }

    private enum Lookup {
        case found(SymmetricKey)
        case missing
        case failed
    }

    private static func loadKey() -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data else { return .failed }
        return .found(SymmetricKey(data: data))
    }

    private static func storeKey(_ key: SymmetricKey) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
