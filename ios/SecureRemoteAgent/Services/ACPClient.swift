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
    private let connection: SSHConnectionManager
    private var nextId: Int = 0
    private var channel: HarnessChannel?
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var updateHandlers: [String: AsyncStream<String>.Continuation] = [:]
    private var listenTask: Task<Void, Never>?

    init(connection: SSHConnectionManager) {
        self.connection = connection
    }

    /// Launch remote harness and perform `initialize` handshake.
    func start(remoteHarnessPath: String) async throws {
        let ch = try await connection.openHarnessChannel(remotePath: remoteHarnessPath)
        self.channel = ch
        listenTask = Task { await self.listenLoop(stdout: ch.stdout) }
        let result = try await request(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": true],
            "clientInfo": ["name": "secure-remote-agent-ios", "title": "Secure Remote Agent", "version": "0.1.0"],
        ])
        // TODO: validate result.protocolVersion, negotiate capabilities/auth.
        _ = result
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
        if let cont = updateHandlers.removeValue(forKey: sessionId) {
            cont.finish()
        }
    }

    func cancel(sessionId: String) async throws {
        _ = try await request(method: "session/cancel", params: ["sessionId": sessionId])
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

enum ACPError: Error, LocalizedError {
    case notStarted
    case encoding
    case remote(String)
    case protocolViolation(String)

    var errorDescription: String? {
        switch self {
        case .notStarted: return "ACP channel not started"
        case .encoding: return "ACP message encoding failed"
        case .remote(let m): return "Remote error: \(m)"
        case .protocolViolation(let m): return "Protocol error: \(m)"
        }
    }
}
