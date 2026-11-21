import CryptoKit
import Foundation
import Testing
@testable import SecureRemoteAgent

@Suite("SSHKeychain round-trip")
struct SSHKeychainTests {
    private func uniqueTag() -> String {
        "test-\(UUID().uuidString)"
    }

    @Test func ed25519GenerateThenLoadReturnsSameKey() throws {
        let tag = uniqueTag()
        defer { try? SSHKeychain.delete(tag: tag) }
        let first = try SSHKeychain.loadOrGenerateEd25519(tag: tag)
        let second = try #require(try SSHKeychain.loadEd25519(tag: tag))
        #expect(first.rawRepresentation == second.rawRepresentation)
    }

    @Test func ed25519TagsAreIsolated() throws {
        let tagA = uniqueTag(), tagB = uniqueTag()
        defer {
            try? SSHKeychain.delete(tag: tagA)
            try? SSHKeychain.delete(tag: tagB)
        }
        let keyA = try SSHKeychain.loadOrGenerateEd25519(tag: tagA)
        let keyB = try SSHKeychain.loadOrGenerateEd25519(tag: tagB)
        #expect(keyA.rawRepresentation != keyB.rawRepresentation)
    }

    @Test func p256GenerateThenLoadReturnsSameKey() throws {
        let tag = uniqueTag()
        defer { try? SSHKeychain.delete(tag: tag) }
        let first = try SSHKeychain.loadOrGenerateP256(tag: tag)
        let second = try #require(try SSHKeychain.loadP256(tag: tag))
        #expect(first.rawRepresentation == second.rawRepresentation)
    }

    @Test func deleteRemovesKey() throws {
        let tag = uniqueTag()
        _ = try SSHKeychain.loadOrGenerateEd25519(tag: tag)
        try SSHKeychain.delete(tag: tag)
        #expect(try SSHKeychain.loadEd25519(tag: tag) == nil)
    }
}

@Suite("HostKeyPinning")
struct HostKeyPinningTests {
    /// Build an `ssh-ed25519 AAAA…` line from a fresh key without NIO.
    private func openSSHLine() -> String {
        let pub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        var blob = Data()
        func putString(_ bytes: Data) {
            var len = UInt32(bytes.count).bigEndian
            blob.append(Data(bytes: &len, count: 4))
            blob.append(bytes)
        }
        putString(Data("ssh-ed25519".utf8))
        putString(pub)
        return "ssh-ed25519 " + blob.base64EncodedString()
    }

    @Test func firstUseMatchesAnything() {
        #expect(HostKeyPinning.matches(expected: nil, presented: "ssh-ed25519 AAAA"))
    }

    @Test func sameKeyMatches() {
        let key = openSSHLine()
        #expect(HostKeyPinning.matches(expected: key, presented: key))
    }

    @Test func differentKeyRejects() {
        #expect(!HostKeyPinning.matches(expected: openSSHLine(), presented: openSSHLine()))
    }

    @Test func fingerprintIsStableAndScoped() throws {
        let key = openSSHLine()
        let f1 = try HostKeyPinning.fingerprint(openSSHKey: key)
        let f2 = try HostKeyPinning.fingerprint(openSSHKey: key)
        #expect(f1 == f2)
        #expect(f1.hasPrefix("SHA256:"))
        #expect(!f1.contains("="))
        let other = try HostKeyPinning.fingerprint(openSSHKey: openSSHLine())
        #expect(other != f1)
    }
}
