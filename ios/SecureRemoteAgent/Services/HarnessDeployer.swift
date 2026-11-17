import Foundation

/// Uploads the correct prebuilt harness binary for the remote's OS/arch,
/// then returns the remote path to execute.
///
/// Flow:
///   1. `uname -sm` over SSH -> RemoteArch
///   2. pick bundled resource `harness-<slug>` (built by scripts/build-harness.sh)
///   3. SFTP to `~/.secure-remote-agent/harness-<slug>`, `chmod +x`
///   4. cache arch on HostProfile so next connect skips detection
///
/// Binaries are tiny by design (Zig ReleaseSmall, static musl on Linux),
/// so re-upload on version mismatch is cheap — compare sha256 before
/// upload in the production pass.
actor HarnessDeployer {
    static let remoteDir = "~/.secure-remote-agent"
    static let bundleVersion = "0.1.0" // bump with harness releases

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
        "\(Self.remoteDir)/\(arch.harnessResourceName)-\(Self.bundleVersion)"
    }

    private func uploadIfNeeded(arch: RemoteArch) async throws {
        guard let localURL = Bundle.main.url(
            forResource: arch.harnessResourceName,
            withExtension: nil,
            subdirectory: "Harnesses"
        ) else {
            throw DeployError.missingBundledBinary(arch.harnessResourceName)
        }
        // TODO: picks: `sha256sum` remote check before upload to skip
        // re-upload when versions match. Cheap anyway (<300 KiB).
        try await connection.capture("mkdir -p \(Self.remoteDir)")
        try await connection.upload(localURL: localURL, remotePath: remotePath(for: arch))
        try await connection.capture("chmod +x \(remotePath(for: arch))")
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
