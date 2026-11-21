import Foundation

/// Phase-2 roaming upgrade: SSH -> Mosh handoff.
///
/// Mosh (mobile shell, UDP + predictive echo) survives Wi-Fi drops and
/// network switches that would kill a plain SSH exec channel. The ACP
/// framing is transport-agnostic (newline JSON over stdio), so the same
/// harness binary and ACPClient work unchanged once the byte pipe roams.
///
/// Scaffold status: **stub**. Wiring a real mosh-client on iOS means
/// bundling Blink Shell's mosh build or a Swift UDP port — do that after
/// the SSH path is solid. Until then `isAvailable` gates the Settings
/// toggle and everything falls back to SSH with no added latency.
///
/// Planned flow (mirrors ssssh precedent):
///   1. after SSH auth, race `which mosh-server` against shell start so
///      the probe never delays connect;
///   2. `mosh-server new` over SSH, parse `MOSH CONNECT <port> <key>`;
///   3. confirm the UDP path end-to-end before switching the live
///      session over; fall back to SSH on any failure.
@Observable
@MainActor
final class MoshManager {
    var isEnabled = false // Settings toggle, off by default
    var status: Status = .disabled

    enum Status: Equatable {
        case disabled
        case probing
        case active(port: Int)
        case fallback(String)

        var displayText: String {
            switch self {
            case .disabled: return "Off — SSH only"
            case .probing: return "Probing…"
            case .active(let port): return "Active (UDP \(port))"
            case .fallback(let why): return "SSH fallback — \(why)"
            }
        }
    }

    /// Probe for `mosh-server` on the remote. Must be raced, never blocking.
    func probe(connection: SSHConnectionManager) async -> Bool {
        status = .probing
        // TODO: `which mosh-server` via connection.capture, raced with shell start.
        status = .fallback("mosh-server not probed yet (scaffold)")
        return false
    }
}
