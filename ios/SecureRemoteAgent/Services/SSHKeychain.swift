import CryptoKit
import Foundation
import Security

/// Keychain-backed SSH client keys. Private key material lives only in the
/// Keychain (generic-password items, this-device-only, no iCloud sync) —
/// never in `hosts.json`, never in UserDefaults.
///
/// Ed25519 is the default. CryptoKit has no Secure Enclave Curve25519, so
/// this stores the 32-byte raw representation as the item secret; the access
/// control (`whenUnlockedThisDeviceOnly`) is the protection boundary.
enum SSHKeychain {
    static let service = "com.secureremote.agent.ssh-key"

    enum KeychainError: Error, LocalizedError {
        case storeFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
        case badKeyData

        var errorDescription: String? {
            switch self {
            case .storeFailed(let s): return "Keychain store failed (\(s))"
            case .loadFailed(let s): return "Keychain load failed (\(s))"
            case .deleteFailed(let s): return "Keychain delete failed (\(s))"
            case .badKeyData: return "Keychain held malformed key data"
            }
        }
    }

    // MARK: - Ed25519

    /// Load the Ed25519 key for `tag`, generating + storing one on first use.
    static func loadOrGenerateEd25519(tag: String) throws -> Curve25519.Signing.PrivateKey {
        if let existing = try loadEd25519(tag: tag) { return existing }
        let fresh = Curve25519.Signing.PrivateKey()
        try store(raw: fresh.rawRepresentation, tag: tag)
        return fresh
    }

    static func loadEd25519(tag: String) throws -> Curve25519.Signing.PrivateKey? {
        guard let data = try load(tag: tag) else { return nil }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw KeychainError.badKeyData
        }
        return key
    }

    // MARK: - ECDSA P-256

    /// Load the P-256 key for `tag`, generating + storing one on first use.
    static func loadOrGenerateP256(tag: String) throws -> P256.Signing.PrivateKey {
        if let existing = try loadP256(tag: tag) { return existing }
        let fresh = P256.Signing.PrivateKey()
        try store(raw: fresh.rawRepresentation, tag: tag)
        return fresh
    }

    static func loadP256(tag: String) throws -> P256.Signing.PrivateKey? {
        guard let data = try load(tag: tag) else { return nil }
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
            throw KeychainError.badKeyData
        }
        return key
    }

    /// All key tags stored under this service (for the Keys settings UI).
    static func allTags() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let list = items as? [[String: Any]] else {
            throw KeychainError.loadFailed(status)
        }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func delete(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Raw item access (shared)

    private static func store(raw: Data, tag: String) throws {
        // Delete-then-add keeps this idempotent across re-provisions.
        try? delete(tag: tag)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.storeFailed(status) }
    }

    private static func load(tag: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.loadFailed(status)
        }
        return data
    }
}
