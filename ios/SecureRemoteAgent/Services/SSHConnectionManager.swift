import Foundation
import Citadel
import NIO

/// Thin wrapper around Citadel's SSHClient.
/// Primary transport: SSH exec channel running the harness with stdio
/// forwarded. Keeps all NIO details inside this type — the rest of the
/// app talks to `SSHConnectionManager` + `AsyncStream<String>` lines.
///
/// Why Citadel: pure Swift, compiles on iOS with no xcframework, natively
/// async/await (SwiftNIO SSH). libssh2 was evaluated as reference only.
actor SSHConnectionManager {
    /// Holds the live Citadel client. Citadel's SSHClient is not Sendable,
    /// so it cannot sit in actor state directly under complete concurrency:
    /// values loaded from this Sendable holder stay usable across awaits,
    /// and access is still serialized by the actor. Lifetimes are managed
    /// here (connect/disconnect).
    private let clientBox = ClientBox()
    private var hostProfile: HostProfile?

    /// Connect with public-key (Keychain) or password auth.
    /// Host-key verification: pinned fingerprint stored per host (TODO).
    func connect(host: HostProfile) async throws {
        self.hostProfile = host
        // NOTE: fill Keychain lookup + host-key pinning before TestFlight.
        // This scaffold connects with password or Keychain key via Citadel.
        // Citadel 0.9.2 has no SSHClientSettings (added upstream later);
        // connect parameters are passed directly.
        let client = try await SSHClient.connect(
            host: host.host,
            port: host.port,
            authenticationMethod: {
                // Placeholder: replace with Keychain-backed key material.
                // .ed25519/.rsa/.p256/.p384/.p521(username:privateKey:)
                // take the corresponding swift-crypto key type.
                SSHAuthenticationMethod.passwordBased(username: host.username, password: "")
            }(),
            hostKeyValidator: .acceptAnything(), // TODO: pin on first use
            reconnect: .never
        )
        self.clientBox.client = client
    }

    /// Run a one-shot command, capture combined output. Used for
    /// `uname -sm` detection, `chmod`, `mkdir -p`, mosh-server probe.
    func capture(_ command: String) async throws -> String {
        guard let client = clientBox.client else { throw SSHError.notConnected }
        // NOTE: two executeCommand overloads exist in Citadel 0.9.2
        // (ExecClient.swift and TTY.swift); the mergeStreams label picks
        // the TTY one and matches this method's "combined output" contract.
        let out = try await client.executeCommand(command, mergeStreams: true)
        return String(decoding: out.readableBytesView, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Upload a local harness binary to the remote path (SFTP).
    func upload(localURL: URL, remotePath: String) async throws {
        guard let client = clientBox.client else { throw SSHError.notConnected }
        // SFTP has no tilde expansion: a leading "~/" is rewritten to a
        // home-relative path (sftp-server resolves relative paths from the
        // login home). Shell-side users keep passing "~/" — shellEscape
        // expands it back via $HOME, so both spellings agree.
        let sftpPath: String
        if remotePath.hasPrefix("~/") {
            sftpPath = String(remotePath.dropFirst(2))
        } else {
            sftpPath = remotePath
        }
        let data = try Data(contentsOf: localURL)
        do {
            try await client.withSFTP { sftp in
                try await sftp.withFile(
                    filePath: sftpPath,
                    flags: [.write, .create, .truncate]
                ) { file in
                    // Built inside the closure: ByteBuffer is not Sendable,
                    // so it must not cross the @Sendable closure boundary.
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    try await file.write(buffer, at: 0)
                }
            }
        } catch {
            throw SSHError.uploadFailed("\(error)")
        }
    }

    /// Open a long-lived exec channel: `remotePath` with stdin/stdout
    /// piped as ACP transport. Returns async streams of lines.
    /// The ACPClient drives this; MoshManager may wrap it later.
    func openHarnessChannel(remotePath: String) async throws -> HarnessChannel {
        guard clientBox.client != nil else { throw SSHError.notConnected }
        // Citadel 0.9.2 exposes no public exec-with-stdin primitive (the
        // streaming exec core is internal; executeCommandStream is
        // stdout-only), so open a shell channel and `exec` the harness:
        // the shell replaces itself with the harness, leaving PTY-less
        // pipes straight to the harness stdio. Returns immediately; the
        // pump below owns the session until the remote side closes.
        let (stdoutStream, stdoutContinuation) = AsyncStream<String>.makeStream()
        let (stdinStream, stdinContinuation) = AsyncStream<String>.makeStream()
        Task {
            await self.runHarnessPump(
                box: self.clientBox,
                remotePath: remotePath,
                stdin: stdinStream,
                stdoutContinuation: stdoutContinuation
            )
        }
        return HarnessChannel(stdin: stdinContinuation, stdout: stdoutStream)
    }

    /// Background lifetime of one harness channel. Runs until the remote
    /// side closes the channel or an error occurs; then finishes stdout.
    ///
    /// nonisolated so the withTTY closure below is nonisolated too (Citadel
    /// takes it as a sending parameter). The box is Sendable, so loading
    /// the client inside keeps it disconnected from the actor's region.
    /// Verified against Citadel 0.9.2 under -strict-concurrency=complete.
    private nonisolated func runHarnessPump(
        box: ClientBox,
        remotePath: String,
        stdin: AsyncStream<String>,
        stdoutContinuation: AsyncStream<String>.Continuation
    ) async {
        guard let client = box.client else {
            stdoutContinuation.finish()
            return
        }
        do {
            try await client.withTTY { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "exec \(Self.shellEscape(remotePath))\n"))
                // stdin -> remote runs alongside the read loop below. The
                // writer crosses into the feeder task inside a Sendable box
                // (NIO writeAndFlush is thread-safe, and only the feeder
                // ever writes).
                let writer = WriterBox(outbound)
                let feeder = Task {
                    for await line in stdin {
                        do {
                            try await writer.writer.write(ByteBuffer(string: line + "\n"))
                        } catch {
                            break
                        }
                    }
                }
                var carry = ""
                do {
                    for try await chunk in inbound {
                        // ACP framing is stdout-only; the harness must keep
                        // logs on stderr. Anything else is a protocol error.
                        guard case .stdout(let bytes) = chunk else { continue }
                        carry += String(decoding: bytes.readableBytesView, as: UTF8.self)
                        while let range = carry.range(of: "\n") {
                            stdoutContinuation.yield(String(carry[..<range.lowerBound]))
                            carry = String(carry[range.upperBound...])
                        }
                    }
                } catch {
                    // Remote closed or errored; fall through to finish.
                }
                feeder.cancel()
                if !carry.isEmpty { stdoutContinuation.yield(carry) }
                stdoutContinuation.finish()
            }
        } catch {
            stdoutContinuation.finish()
        }
    }

    /// Quote a remote path for shell consumption. Expands a leading `~/`
    /// via $HOME (quoting would suppress tilde expansion).
    private static func shellEscape(_ path: String) -> String {
        let expanded: String
        if path.hasPrefix("~/") {
            expanded = "$HOME/" + path.dropFirst(2)
        } else {
            expanded = path
        }
        // Double quotes keep $HOME live; escape anything the shell would
        // otherwise interpret. Slugs we generate never contain these.
        let escaped = expanded
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    func disconnect() async {
        // Close the SSH channel, then drop the reference so in-flight
        // channel tasks fail their writes and finish.
        guard let client = clientBox.client else { return }
        clientBox.client = nil
        try? await client.close()
    }
}

/// Holds the live Citadel client. See SSHConnectionManager.clientBox.
private final class ClientBox: @unchecked Sendable {
    var client: SSHClient?
    init(client: SSHClient? = nil) { self.client = client }
}

/// Sendable holder for the harness stdin writer. NIO channels are
/// thread-safe for writeAndFlush, and only the feeder task ever writes.
private final class WriterBox: @unchecked Sendable {
    let writer: TTYStdinWriter
    init(_ writer: TTYStdinWriter) { self.writer = writer }
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
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .notImplemented(let what): return "Scaffold: \(what)"
        case .authFailed: return "SSH authentication failed"
        case .hostKeyMismatch: return "Host key mismatch"
        case .uploadFailed(let why): return "SFTP upload failed: \(why)"
        }
    }
}
