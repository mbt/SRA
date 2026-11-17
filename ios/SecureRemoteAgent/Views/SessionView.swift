import SwiftUI

/// Chat-style UI over the ACP session: user prompts in, streamed
/// `session/update` text out. Full terminal (SwiftTerm) comes later
/// for interactive shells; ACP chat is the primary interface.
struct SessionView: View {
    let sessionId: UUID
    @Environment(SessionManager.self) private var manager
    @State private var draft = ""

    private var session: SessionManager.ActiveSession? {
        manager.sessions.first(where: { $0.id == sessionId })
    }

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session?.messages ?? []) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: session?.messages.count ?? 0) { _, _ in
                    if let last = session?.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            HStack {
                TextField("Ask the remote agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session?.state != .ready)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(session?.host.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await manager.sendPrompt(text, in: sessionId) }
    }
}

private struct MessageBubble: View {
    let message: AgentMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }
            Text(message.text)
                .padding(10)
                .background(message.role == .user ? Color.accentColor.opacity(0.85) : Color(.secondarySystemBackground))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .fontDesign(.monospaced)
                .overlay {
                    if message.isStreaming { ProgressView().scaleEffect(0.6).offset(x: 28) }
                }
            if message.role != .user { Spacer() }
        }
    }
}
