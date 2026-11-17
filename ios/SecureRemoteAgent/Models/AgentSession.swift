import Foundation

/// One ACP session bound to a remote harness process over SSH.
/// UI observes this for chat-style streaming updates.
struct AgentMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    var role: Role
    var text: String
    var isStreaming: Bool

    enum Role: Sendable { case user, agent, system }
}

@Observable
@MainActor
final class SessionManager {
    struct ActiveSession: Identifiable {
        let id: UUID
        let host: HostProfile
        var acpSessionId: String?
        var messages: [AgentMessage]
        var state: State

        enum State { case connecting, deploying, ready, prompting, failed(String) }
    }

    var sessions: [ActiveSession] = []
    var connection: SSHConnectionManager?
    var acp: ACPClient?

    func startSession(to host: HostProfile) async {
        var s = ActiveSession(id: UUID(), host: host, acpSessionId: nil, messages: [], state: .connecting)
        sessions.append(s)
        guard let idx = sessions.firstIndex(where: { $0.id == s.id }) else { return }

        do {
            let conn = SSHConnectionManager()
            self.connection = conn
            try await conn.connect(host: host)
            sessions[idx].state = .deploying

            let deployer = HarnessDeployer(connection: conn)
            let arch = try await deployer.ensureHarness(host: host)
            var updated = host
            updated.lastKnownArch = arch
            _ = updated

            sessions[idx].state = .ready
            let client = ACPClient(connection: conn)
            self.acp = client
            try await client.start(remoteHarnessPath: deployer.remotePath(for: arch))
            let sid = try await client.newSession()
            sessions[idx].acpSessionId = sid
            sessions[idx].messages.append(AgentMessage(id: UUID(), role: .system, text: "Connected to \(host.name) (\(arch.rawValue)) · session \(sid)", isStreaming: false))
        } catch {
            sessions[idx].state = .failed(error.localizedDescription)
        }
        _ = s
    }

    func sendPrompt(_ text: String, in sessionId: UUID) async {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }),
              let sid = sessions[idx].acpSessionId,
              let acp
        else { return }
        sessions[idx].messages.append(AgentMessage(id: UUID(), role: .user, text: text, isStreaming: false))
        let streamId = UUID()
        sessions[idx].messages.append(AgentMessage(id: streamId, role: .agent, text: "", isStreaming: true))
        sessions[idx].state = .prompting
        do {
            let chunks = try await acp.prompt(sessionId: sid, text: text)
            for try await chunk in chunks {
                if let mIdx = sessions[idx].messages.firstIndex(where: { $0.id == streamId }) {
                    sessions[idx].messages[mIdx].text += chunk
                }
            }
            if let mIdx = sessions[idx].messages.firstIndex(where: { $0.id == streamId }) {
                sessions[idx].messages[mIdx].isStreaming = false
            }
            sessions[idx].state = .ready
        } catch {
            if let mIdx = sessions[idx].messages.firstIndex(where: { $0.id == streamId }) {
                sessions[idx].messages[mIdx].text += "\n[error] \(error.localizedDescription)"
                sessions[idx].messages[mIdx].isStreaming = false
            }
            sessions[idx].state = .ready
        }
    }
}
