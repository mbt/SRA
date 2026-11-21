import SwiftUI

struct HostListView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @State private var showingAdd = false
    @State private var passwordHost: HostProfile?

    var body: some View {
        List {
            ForEach(store.hosts) { host in
                HStack {
                    VStack(alignment: .leading) {
                        Text(host.name).font(.headline)
                        Text("\(host.username)@\(host.host):\(host.port)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let arch = host.lastKnownArch {
                            Text(arch.rawValue).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Connect") {
                        if host.authKind == .password {
                            passwordHost = host
                        } else {
                            Task { await sessions.startSession(to: host, hostStore: store) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .swipeActions { Button("Delete", role: .destructive) { store.remove(host) } }
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            Button(action: { showingAdd = true }) { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showingAdd) { AddHostView() }
        .sheet(item: $passwordHost) { host in
            PasswordPromptView(hostName: host.name) { password in
                Task { await sessions.startSession(to: host, hostStore: store, password: password) }
            }
        }
    }
}

private struct AddHostView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var authKind: HostProfile.AuthKind = .ed25519

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Hostname", text: $host).textInputAutocapitalization(.never)
                TextField("Username", text: $username).textInputAutocapitalization(.never)
                TextField("Port", text: $port).keyboardType(.numberPad)
                Picker("Authentication", selection: $authKind) {
                    ForEach(HostProfile.AuthKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
            }
            .navigationTitle("Add Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.add(HostProfile(name: name.isEmpty ? host : name, host: host, port: Int(port) ?? 22, username: username, authKind: authKind))
                        dismiss()
                    }.disabled(host.isEmpty || username.isEmpty)
                }
            }
        }
    }
}

/// Password entry for `.password` hosts. The password is passed straight
/// to the SSH handshake and never stored — key-based hosts never see this.
private struct PasswordPromptView: View {
    let hostName: String
    let onConnect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .navigationTitle("Connect to \(hostName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        onConnect(password)
                        dismiss()
                    }.disabled(password.isEmpty)
                }
            }
        }
    }
}
