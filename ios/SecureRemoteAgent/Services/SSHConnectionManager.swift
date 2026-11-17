import Foundation
import Citadel

/// Thin wrapper around Citadel's SSHClient.
/// Primary transport: SSH exec channel running the harness with stdio
/// forwarded. Keeps all NIO details inside this type — the rest of the
/// app talks to `SSHConnectionManager` + `AsyncStream<String>` lines.
///
/// Why Citadel: pure Swift, compiles on iOS with no xcframework, natively
/// async/await (SwiftNIO SSH). libssh2 was evaluated as reference only.
actor SSHConnectionManager {
    private var client: SSHClient?
    private var hostProfile: HostProfile?

    /// Connect with public-key (Keychain) or password auth.
    /// Host-key verification: pinned fingerprint stored per host (TODO).
    func connect(host: HostProfile) async throws {
        self.hostProfile = host
        // NOTE: fill Keychain lookup + host-key pinning before TestFlight.
        // This scaffold connects with password or agent key via Citadel.
        let settings = SSHClientSettings(
            host: host.host,
            port: host.port,
            authenticationMethod: {
                // Placeholder: replace with Keychain-backed key material.
                // .passwordBased(username:password:) or
                // .publicKeyBased(username:privateKey:…).
                .passwordBased(username: host.username, password: "")
            }(),
            hostKeyValidator: .acceptAnything() // TODO: pin on first use
        )
        let client = try await SSHClient.connect(to: settings)
        self.client = client
    }

    /// Run a one-shot command, capture combined output. Used for
    /// `uname -sm` detection, `chmod`, `mkdir -p`, mosh-server probe.
    func capture(_ command: String) async throws -> String {
        guard let client else { throw SSHError.notConnected }
        // Citadel exec API surface varies by version; isolate here so a
        // library bump touches one file. Replace body with:
        //   try await client.executeCommand(command)
        // returning (status, output).
        _ = client
        throw SSHError.notImplemented("capture(\(command)) — wire to Citadel exec in this one place")
    }

    /// Upload a local harness binary to the remote path (SFTP).
    func upload(localURL: URL, remotePath: String) async throws {
        guard client != nil else { throw SSHError.notConnected }
        // TODO: Citadel SFTP write via SFTPClient. Single choke point.
        throw SSHError.notImplemented("upload — wire to Citadel SFTP here")
    }

    /// Open a long-lived exec channel: `remotePath` with stdin/stdout
    /// piped as ACP transport. Returns async streams of lines.
    /// The ACPClient drives this; MoshManager may wrap it later.
    func openHarnessChannel(remotePath: String) async throws -> HarnessChannel {
        guard client != nil else { throw SSHError.notConnected }
        // TODO: Citadel channel with PTY-less exec, bidirectional pipe.
        throw SSHError.notImplemented("openHarnessChannel — wire to Citadel exec channel here")
    }

    func disconnect() async {
        // Citadel client cleanup.
        client = nil
    }
}

/// Bidirectional stdio to the remote harness process.
struct HarnessChannel: Sendable {
    let stdin: AsyncStream<String>.Continuation
    let stdout: AsyncStream<String>
}

enum SSHError: Error, LocalizedError {
    case notConnected
    case notImplemented(String)
    case authFailed
    case hostKeyMismatch

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .notImplemented(let what): return "Scaffold: \(what)"
        case .authFailed: return "SSH authentication failed"
        case .hostKeyMismatch: return "Host key mismatch"
        }
    }
}
