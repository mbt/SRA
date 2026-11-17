import SwiftUI

struct SettingsView: View {
    @State private var mosh = MoshManager()
    @State private var showKeys = false

    var body: some View {
        Form {
            Section("Roaming") {
                Toggle("Upgrade to Mosh when available", isOn: $mosh.isEnabled)
                LabeledContent("Status", value: String(describing: mosh.status))
                Text("Mosh survives network switches over UDP with predictive echo. Off by default; falls back to SSH silently.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keys") {
                Button("Manage SSH keys") { showKeys = true }
            }
            Section("About") {
                LabeledContent("Harness", value: HarnessDeployer.bundleVersion)
                LabeledContent("ACP", value: "v1 (stdio)")
            }
        }
        .navigationTitle("Settings")
    }
}
