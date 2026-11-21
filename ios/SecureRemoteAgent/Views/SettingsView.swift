import SwiftUI

struct SettingsView: View {
    @Environment(MoshManager.self) private var mosh
    @State private var showKeys = false

    var body: some View {
        @Bindable var mosh = mosh
        Form {
            Section("Roaming") {
                Toggle("Upgrade to Mosh when available", isOn: $mosh.isEnabled)
                LabeledContent("Status", value: mosh.status.displayText)
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
        .sheet(isPresented: $showKeys) { KeysView() }
    }
}

/// Lists Keychain SSH keys provisioned for hosts (one tag per host).
/// Deleting a key here forces fresh keygen on next connect — the remote's
/// `authorized_keys` will need the new public key.
private struct KeysView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if tags.isEmpty && errorMessage == nil {
                    Text("No keys yet — keys are generated on first connect.")
                        .foregroundStyle(.secondary)
                }
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.secondary)
                        Text(tag).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Delete", role: .destructive) { delete(tag) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("SSH Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        do {
            tags = try SSHKeychain.allTags()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ tag: String) {
        do {
            try SSHKeychain.delete(tag: tag)
            reload()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
