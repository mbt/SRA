import CryptoKit
import Foundation

/// Uploads the correct prebuilt harness binary for the remote's OS/arch,
/// then returns the remote path to execute.
///
/// Flow:
///   1. `uname -sm` over SSH -> RemoteArch (skipped when `lastKnownArch`)
///   2. pick bundled resource `harness-<slug>` (built by scripts/build-harness.sh)
///   3. compare local sha256 against the remote file; SFTP + `chmod +x`
///      only on mismatch — repeat connects upload 0 bytes
///   4. prune older `harness-<slug>-<version>` files on success
///   5. cache arch on HostProfile so next connect skips detection
///
/// Binaries are tiny by design (Zig ReleaseSmall, static musl on Linux).
actor HarnessDeployer {
    static let remoteDir = "~/.secure-remote-agent"
    static let bundleVersion = "0.2.0" // bump with harness releases

    let connection: SSHConnectionManager

    init(connection: SSHConnectionManager) {
        self.connection = connection
    }

    func ensureHarness(host: HostProfile) async throws -> RemoteArch {
        let arch: RemoteArch
        if let known = host.lastKnownArch, known != .unknown {
            arch = known
        } else {
            arch = try await detectArch()
        }
        try await uploadIfNeeded(arch: arch)
        return arch
    }

    func detectArch() async throws -> RemoteArch {
        let out = try await connection.capture("uname -sm")
        return RemoteArch.parse(uname: out)
    }

    func remotePath(for arch: RemoteArch) -> String {
        "\(Self.remoteDir)/\(Self.fileName(for: arch))"
    }

    static func fileName(for arch: RemoteArch) -> String {
        "\(arch.harnessResourceName)-\(bundleVersion)"
    }

    private func uploadIfNeeded(arch: RemoteArch) async throws {
        guard let localURL = Bundle.main.url(
            forResource: arch.harnessResourceName,
            withExtension: nil,
            subdirectory: "Harnesses"
        ) else {
            throw DeployError.missingBundledBinary(arch.harnessResourceName)
        }
        let data = try Data(contentsOf: localURL)
        try await connection.capture("mkdir -p \(Self.remoteDir)")
        let path = remotePath(for: arch)
        if try await remoteSHA256(path: path) != Self.sha256Hex(of: data) {
            try await connection.upload(data: data, remotePath: path)
            try await connection.capture("chmod +x \(path)")
        }
        try await pruneOldVersions(arch: arch)
    }

    /// Hex sha256 of the remote file, or nil when missing/unreadable.
    /// `sha256sum` (Linux) with `shasum -a 256` (macOS) fallback — both
    /// print `<hash>  <path>`. Connection errors also surface as nil; the
    /// upload path then fails loudly on its own.
    private func remoteSHA256(path: String) async -> String? {
        let out = try? await connection.capture(
            "sha256sum \(path) 2>/dev/null || shasum -a 256 \(path) 2>/dev/null")
        let hash = out?.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init)
        return (hash?.isEmpty == false) ? hash : nil
    }

    /// Delete `harness-<slug>-*` files other than the current version.
    private func pruneOldVersions(arch: RemoteArch) async throws {
        let current = Self.fileName(for: arch)
        let listing = (try? await connection.capture("ls -1 \(Self.remoteDir)")) ?? ""
        for stale in Self.staleEntries(lsOutput: listing, arch: arch, current: current) {
            try await connection.capture("rm -f \(Self.remoteDir)/\(stale)")
        }
    }

    /// Filenames in an `ls -1` listing that belong to `arch` but are not the
    /// current version. Pure (unit-tested) — the only untrusted input is the
    /// remote listing, and entries are matched against our own slug prefix.
    static func staleEntries(lsOutput: String, arch: RemoteArch, current: String) -> [String] {
        let prefix = "\(arch.harnessResourceName)-"
        return lsOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix(prefix) && $0 != current && !$0.contains("/") }
    }

    /// Lowercase hex SHA-256. Pure (unit-tested against NIST vector).
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum DeployError: Error, LocalizedError {
    case missingBundledBinary(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledBinary(let n): return "Bundled harness missing: \(n) — run scripts/build-harness.sh"
        case .uploadFailed(let why): return "Harness upload failed: \(why)"
        }
    }
}
