import CryptoKit
import Foundation

/// Trust-on-first-use host-key pinning.
///
/// The pinned value is the full OpenSSH public-key string
/// (`"ssh-ed25519 AAAA…"`) stored on `HostProfile.pinnedHostKey`.
/// Comparison is exact string equality — no parsing, no canonicalization
/// risk. `fingerprint` renders the OpenSSH-style `SHA256:…` digest for UI
/// display (host detail / change warnings).
enum HostKeyPinning {
    /// True when there is no pin yet (first connect) or the presented key
    /// matches the pin. False = possible MITM / reinstalled host.
    static func matches(expected: String?, presented: String) -> Bool {
        guard let expected else { return true }
        return expected == presented
    }

    /// OpenSSH-style fingerprint: `SHA256:` + base64 (no padding) of the
    /// SHA-256 over the raw key blob (the base64 half of the OpenSSH string).
    static func fingerprint(openSSHKey: String) throws -> String {
        let parts = openSSHKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw PinError.malformedKey
        }
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:" + b64
    }

    enum PinError: Error, LocalizedError {
        case malformedKey
        var errorDescription: String? { "Malformed OpenSSH public key" }
    }
}
