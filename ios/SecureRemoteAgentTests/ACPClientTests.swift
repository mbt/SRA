import Foundation
import Testing
@testable import SecureRemoteAgent

/// ACPClient hardening, driven over scripted in-memory channels
/// (no SSH needed): the test plays the remote harness.
@Suite("ACPClient hardening")
struct ACPClientTests {
    private func encode(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private func parse(_ line: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(obj as? [String: Any])
    }

    private func requestId(_ line: String) throws -> Int {
        try #require(try parse(line)["id"] as? Int)
    }

    private func response(id: Int, result: Any) throws -> String {
        try encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func validInit() -> [String: Any] {
        ["protocolVersion": 1, "agentCapabilities": [:] as [String: Any],
         "agentInfo": ["name": "test"], "authMethods": [] as [Any]]
    }

    /// Start a client against scripted streams; answers `initialize` with
    /// `initResult`. Returns client, stdin iterator (reads what the client
    /// sends), and stdout continuation (feeds the client).
    private func startedClient(initResult: [String: Any]) async throws -> (
        client: ACPClient,
        stdin: AsyncStream<String>.AsyncIterator,
        stdout: AsyncStream<String>.Continuation
    ) {
        let (stdoutStream, stdoutCont) = AsyncStream<String>.makeStream()
        let (stdinStream, stdinCont) = AsyncStream<String>.makeStream()
        let client = ACPClient(connection: SSHConnectionManager())
        var stdin = stdinStream.makeAsyncIterator()
        let startTask = Task {
            try await client.start(channel: HarnessChannel(stdin: stdinCont, stdout: stdoutStream))
        }
        let initLine = try #require(await stdin.next())
        let initId = try requestId(initLine)
        stdoutCont.yield(try response(id: initId, result: initResult))
        try await startTask.value
        return (client, stdin, stdoutCont)
    }

    @Test func rejectsWrongProtocolVersion() async throws {
        var initResult = validInit()
        initResult["protocolVersion"] = 2
        do {
            _ = try await startedClient(initResult: initResult)
            Issue.record("expected protocolViolation for version 2")
        } catch let e as ACPError {
            guard case .protocolViolation(let m) = e else {
                Issue.record("wrong error: \(e)"); return
            }
            #expect(m.contains("protocolVersion 2"))
        }
    }

    @Test func rejectsMissingProtocolVersion() async throws {
        var initResult = validInit()
        initResult.removeValue(forKey: "protocolVersion")
        do {
            _ = try await startedClient(initResult: initResult)
            Issue.record("expected protocolViolation for missing version")
        } catch let e as ACPError {
            guard case .protocolViolation(let m) = e else {
                Issue.record("wrong error: \(e)"); return
            }
            #expect(m.contains("protocolVersion"))
        }
    }

    @Test func rejectsAuthGatedRemote() async throws {
        var initResult = validInit()
        initResult["authMethods"] = [["id": "oauth"]]
        do {
            _ = try await startedClient(initResult: initResult)
            Issue.record("expected protocolViolation for auth gate")
        } catch let e as ACPError {
            guard case .protocolViolation(let m) = e else {
                Issue.record("wrong error: \(e)"); return
            }
            #expect(m.contains("authentication"))
        }
    }

    @Test func pendingRequestsFailWhenChannelDies() async throws {
        let started = try await startedClient(initResult: validInit())
        let client = started.client
        var stdin = started.stdin
        let stdout = started.stdout
        let req = Task { try await client.newSession() }
        // The request line arriving proves the waiter registered first.
        _ = try #require(await stdin.next())
        // Remote dies with the request in flight.
        stdout.finish()
        do {
            _ = try await req.value
            Issue.record("expected disconnected")
        } catch let e as ACPError {
            #expect(e == .disconnected)
        }
        await client.stop()
    }

    @Test func promptStreamsChunksThenResult() async throws {
        let started = try await startedClient(initResult: validInit())
        let client = started.client
        var stdin = started.stdin
        let stdout = started.stdout
        let newTask = Task { try await client.newSession() }
        let newLine = try #require(await stdin.next())
        stdout.yield(try response(id: try requestId(newLine), result: ["sessionId": "ses_1"]))
        let sid = try await newTask.value
        #expect(sid == "ses_1")

        let chunksTask = Task { () -> [String] in
            var chunks: [String] = []
            let stream = try await client.prompt(sessionId: sid, text: "hi")
            for await chunk in stream { chunks.append(chunk) }
            return chunks
        }
        let promptLine = try #require(await stdin.next())
        let promptId = try requestId(promptLine)
        stdout.yield(try encode([
            "jsonrpc": "2.0", "method": "session/update",
            "params": ["sessionId": "ses_1",
                       "update": ["sessionUpdate": "agent_message_chunk",
                                  "content": ["text": "hello"]]],
        ]))
        stdout.yield(try response(id: promptId, result: ["stopReason": "end_turn"]))
        #expect(try await chunksTask.value == ["hello"])
        await client.stop()
        stdout.finish()
    }

    @Test func cancelSendsCancelRequest() async throws {
        let started = try await startedClient(initResult: validInit())
        let client = started.client
        var stdin = started.stdin
        let stdout = started.stdout
        let newTask = Task { try await client.newSession() }
        let newLine = try #require(await stdin.next())
        stdout.yield(try response(id: try requestId(newLine), result: ["sessionId": "ses_1"]))
        let sid = try await newTask.value

        let chunksTask = Task { () -> [String] in
            var chunks: [String] = []
            let stream = try await client.prompt(sessionId: sid, text: "hi")
            for await chunk in stream { chunks.append(chunk) }
            return chunks
        }
        let promptLine = try #require(await stdin.next())
        let promptId = try requestId(promptLine)

        await client.cancel(sessionId: sid)

        let cancelLine = try #require(await stdin.next())
        let cancelObj = try parse(cancelLine)
        #expect(cancelObj["method"] as? String == "$/cancel_request")
        let params = try #require(cancelObj["params"] as? [String: Any])
        #expect(params["requestId"] as? Int == promptId)
        // Local stream ended with no chunks; late result is harmless.
        #expect(try await chunksTask.value == [])
        stdout.yield(try response(id: promptId, result: ["stopReason": "cancelled"]))
        await client.stop()
        stdout.finish()
    }
}
