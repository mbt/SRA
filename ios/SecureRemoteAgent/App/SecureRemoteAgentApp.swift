import SwiftUI

/// Entry point. Single window, tabbed root.
/// Phase 1 ships SSH + ACP chat. Mosh roaming upgrade is behind Settings toggle.
@main
struct SecureRemoteAgentApp: App {
    @State private var store = HostStore()
    @State private var sessionManager = SessionManager()
    @State private var moshManager = MoshManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(sessionManager)
                .environment(moshManager)
        }
    }
}
