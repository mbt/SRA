import Foundation

/// Remote host profile. Stored as Codable JSON under Application Support —
/// no SwiftData, no accounts, plain files (see ssssh/Shellby precedent).
struct HostProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    /// "ed25519" | "ecdsa" | "password" — key reference lives in Keychain.
    var authKind: AuthKind = .ed25519
    var keyTag: String? // Keychain tag for the private key
    /// TOFU-pinned host key, OpenSSH "algorithm base64-blob" string.
    /// nil = never connected; pinned on first successful connect.
    var pinnedHostKey: String?
    var lastKnownArch: RemoteArch?

    enum AuthKind: String, Codable, Sendable {
        case ed25519, ecdsa, password
    }
}

enum RemoteArch: String, Codable, Sendable {
    case darwinArm64   // aarch64 macOS
    case darwinX64     // x86_64 macOS
    case linuxX64      // x86_64 Linux
    case linuxArm64    // aarch64 Linux
    case unknown

    /// Bundle resource name for the matching harness binary.
    var harnessResourceName: String {
        switch self {
        case .darwinArm64: return "harness-darwin-arm64"
        case .darwinX64: return "harness-darwin-x64"
        case .linuxX64: return "harness-linux-x64"
        case .linuxArm64: return "harness-linux-arm64"
        case .unknown: return "harness-linux-x64" // safest fallback
        }
    }

    /// Parse `uname -sm` output, e.g. "Darwin arm64", "Linux x86_64".
    static func parse(uname: String) -> RemoteArch {
        let s = uname.lowercased()
        let isDarwin = s.contains("darwin")
        let isLinux = s.contains("linux")
        let isArm = s.contains("arm64") || s.contains("aarch64")
        let isX64 = s.contains("x86_64") || s.contains("x64")
        if isDarwin && isArm { return .darwinArm64 }
        if isDarwin && isX64 { return .darwinX64 }
        if isLinux && isX64 { return .linuxX64 }
        if isLinux && isArm { return .linuxArm64 }
        return .unknown
    }
}

@Observable
@MainActor
final class HostStore {
    var hosts: [HostProfile] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = dir.appendingPathComponent("hosts.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HostProfile].self, from: data)
        else { return }
        hosts = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ host: HostProfile) { hosts.append(host); save() }
    func remove(_ host: HostProfile) { hosts.removeAll { $0.id == host.id }; save() }
    func update(_ host: HostProfile) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[i] = host; save()
    }
}
