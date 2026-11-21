import SwiftUI

struct HostListView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @State private var showingAdd = false

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
                        Task { await sessions.startSession(to: host, hostStore: store) }
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
    }
}

private struct AddHostView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var username = ""
    @State private var port = "22"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Hostname", text: $host).textInputAutocapitalization(.never)
                TextField("Username", text: $username).textInputAutocapitalization(.never)
                TextField("Port", text: $port).keyboardType(.numberPad)
            }
            .navigationTitle("Add Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.add(HostProfile(name: name.isEmpty ? host : name, host: host, port: Int(port) ?? 22, username: username))
                        dismiss()
                    }.disabled(host.isEmpty || username.isEmpty)
                }
            }
        }
    }
}
