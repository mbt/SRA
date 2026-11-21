import Foundation

/// ACP v1 JSON-RPC client over the SSH harness channel.
///
/// Framing: one JSON object per line, UTF-8, no batches (matches
/// harness/src/*.zig). Requests carry incrementing numeric ids;
/// `session/update` notifications are demuxed into per-prompt streams.
///
/// Lifecycle: start() -> initialize -> newSession() -> prompt()*.
/// Transport-agnostic: works identically over plain SSH exec today
/// and over a Mosh-roamed channel once MoshManager lands.
actor ACPClient {
    /// The only ACP version this client speaks.
    static let supportedProtocolVersion = 1

    private let connection: SSHConnectionManager
    private var nextId: Int = 0
    private var channel: HarnessChannel?
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var updateHandlers: [String: AsyncStream<String>.Continuation] = [:]
    /// In-flight prompt request id per session, for `$/cancel_request`.
    private var promptRequestIds: [String: Int] = [:]
    private var listenTask: Task<Void, Never>?

    init(connection: SSHConnectionManager) {
        self.connection = connection
    }

    /// Launch remote harness and perform `initialize` handshake.
    func start(remoteHarnessPath: String) async throws {
        let ch = try await connection.openHarnessChannel(remotePath: remoteHarnessPath)
        try await start(channel: ch)
    }

    /// Drive the client over a pre-made channel (production path above, or
    /// scripted streams in tests). Validates the `initialize` result and
    /// fails fast on protocol mismatch.
    func start(channel: HarnessChannel) async throws {
        self.channel = channel
        listenTask = Task { await self.listenLoop(stdout: channel.stdout) }
        do {
            let result = try await request(method: "initialize", params: [
                "protocolVersion": Self.supportedProtocolVersion,
                "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": true],
                "clientInfo": ["name": "secure-remote-agent-ios", "title": "Secure Remote Agent", "version": "0.1.0"],
            ])
            try Self.validateInitialize(result)
        } catch {
            stop()
            throw error
        }
    }

    /// Fail-fast `initialize` validation: this client speaks exactly one
    /// protocol version and has no `authenticate` flow, so a remote that
    /// answers anything else is a protocol violation, not a session.
    private static func validateInitialize(_ result: Any) throws {
        guard let result = result as? [String: Any] else {
            throw ACPError.protocolViolation("initialize result is not an object")
        }
        guard let version = result["protocolVersion"] as? Int else {
            throw ACPError.protocolViolation("initialize result missing protocolVersion")
        }
        guard version == supportedProtocolVersion else {
            throw ACPError.protocolViolation(
                "unsupported protocolVersion \(version) (client speaks \(supportedProtocolVersion))")
        }
        if let authMethods = result["authMethods"] as? [Any], !authMethods.isEmpty {
            throw ACPError.protocolViolation(
                "remote requires authentication (\(authMethods.count) method(s)); client has no authenticate flow")
        }
    }

    /// Shut down: end the listen loop, resume every waiter with
    /// `.disconnected`, finish every stream. Idempotent.
    func stop() {
        listenTask?.cancel()
        listenTask = nil
        channel = nil
        failAllPending()
    }

    /// Resume all pending requests with `.disconnected` and finish all
    /// prompt streams. Runs on listen-loop end (channel killed) and on
    /// explicit `stop()` — no waiter ever hangs.
    private func failAllPending() {
        let waiters = pending
        pending.removeAll()
        for cont in waiters.values {
            cont.resume(throwing: ACPError.disconnected)
        }
        for (_, cont) in updateHandlers {
            cont.finish()
        }
        updateHandlers.removeAll()
    }

    func newSession(cwd: String? = nil) async throws -> String {
        // Hermes (and ACP agents generally) require both fields; the Zig
        // shim tolerates extras. Default cwd to /tmp when caller omits it.
        let params: [String: Any] = ["cwd": cwd ?? "/tmp", "mcpServers": []]
        let result = try await request(method: "session/new", params: params)
        guard let sid = (result as? [String: Any])?["sessionId"] as? String else {
            throw ACPError.protocolViolation("session/new missing sessionId")
        }
        return sid
    }

    /// Send `session/prompt`, return a stream of `session/update` text chunks.
    /// Caller iterates to completion; stream finishes on prompt result.
    /// Handlers are keyed by sessionId so concurrent prompts on different
    /// sessions route to the right stream (Hermes + Zig shim both send
    /// params.sessionId on every session/update notification).
    func prompt(sessionId: String, text: String) async throws -> AsyncStream<String> {
        let (stream, cont) = AsyncStream<String>.makeStream()
        // Single active prompt per session: finish a stale handler if the
        // caller re-prompts before the previous stream drained.
        if let existing = updateHandlers[sessionId] {
            existing.finish()
        }
        updateHandlers[sessionId] = cont
        let id = nextIdValue()
        promptRequestIds[sessionId] = id
        let params: [String: Any] = [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]],
        ]
        Task {
            do {
                _ = try await self.rawRequest(id: id, method: "session/prompt", params: params)
            } catch {
                // Response errors surface as stream end; success carries
                // stopReason in the prompt result itself.
            }
            await self.finishPrompt(sessionId: sessionId)
        }
        return stream
    }

    private func finishPrompt(sessionId: String) {
        promptRequestIds.removeValue(forKey: sessionId)
        if let cont = updateHandlers.removeValue(forKey: sessionId) {
            cont.finish()
        }
    }

    /// Best-effort cancel: tell the remote to drop the in-flight prompt and
    /// end the local stream. Correlated via `$/cancel_request {requestId}`
    /// (ACP v1); the scaffold harness single-shot exec just acks it.
    /// Never throws — cancelling a finished/unknown session is a no-op.
    func cancel(sessionId: String) {
        guard let channel else { return }
        if let id = promptRequestIds.removeValue(forKey: sessionId) {
            let notif: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "$/cancel_request",
                "params": ["requestId": id],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: notif),
               let line = String(data: data, encoding: .utf8)
            {
                channel.stdin.yield(line + "\n")
            }
        }
        if let cont = updateHandlers.removeValue(forKey: sessionId) {
            cont.finish()
        }
    }

    // MARK: - plumbing

    private func nextIdValue() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    private func request(method: String, params: [String: Any]) async throws -> Any {
        let id = nextIdValue()
        return try await rawRequest(id: id, method: method, params: params)
    }

    private func rawRequest(id: Int, method: String, params: [String: Any]) async throws -> Any {
        guard let channel else { throw ACPError.notStarted }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard var line = String(data: data, encoding: .utf8) else { throw ACPError.encoding }
        line += "\n"
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            channel.stdin.yield(line)
        }
    }

    private func listenLoop(stdout: AsyncStream<String>) async {
        // Channel death (remote kill, SSH drop) lands here: fail every
        // waiter so no request hangs past the transport.
        defer { failAllPending() }
        for await line in stdout {
            handle(line: line)
        }
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // Response?
        if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let err = obj["error"] {
                cont.resume(throwing: ACPError.remote("\(err)"))
            } else {
                cont.resume(returning: obj["result"] ?? [:])
            }
            return
        }
        // Notification: session/update -> route agent text to the matching
        // session's stream. Hermes emits thought/tool/plan updates on the
        // same method; only agent_message_chunk belongs in chat.
        if (obj["method"] as? String) == "session/update",
           let params = obj["params"] as? [String: Any],
           let sid = params["sessionId"] as? String,
           let update = params["update"] as? [String: Any],
           let kind = update["sessionUpdate"] as? String,
           kind == "agent_message_chunk",
           let content = update["content"] as? [String: Any],
           let text = content["text"] as? String,
           let cont = updateHandlers[sid]
        {
            cont.yield(text)
        }
    }
}

enum ACPError: Error, LocalizedError, Equatable {
    case notStarted
    case encoding
    case remote(String)
    case protocolViolation(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .notStarted: return "ACP channel not started"
        case .encoding: return "ACP message encoding failed"
        case .remote(let m): return "Remote error: \(m)"
        case .protocolViolation(let m): return "Protocol error: \(m)"
        case .disconnected: return "ACP connection lost"
        }
    }
}
