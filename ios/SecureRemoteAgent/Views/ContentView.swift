import SwiftUI

struct ContentView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        TabView {
            NavigationStack {
                HostListView()
            }
            .tabItem { Label("Hosts", systemImage: "server.rack") }

            NavigationStack {
                SessionsView()
            }
            .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

private struct SessionsView: View {
    @Environment(SessionManager.self) private var manager

    var body: some View {
        List(manager.sessions) { session in
            NavigationLink(session.host.name) {
                SessionView(sessionId: session.id)
            }
            .swipeActions {
                Button("Disconnect", role: .destructive) {
                    Task { await manager.disconnect(session.id) }
                }
            }
        }
        .navigationTitle("Sessions")
        .overlay {
            if manager.sessions.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right", description: Text("Connect from the Hosts tab."))
            }
        }
    }
}
