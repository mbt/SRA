# Architecture

```
┌─────────────┐   SSH exec (stdio)   ┌─────────────────────┐
│ iOS app     │ ───────────────────▶ │ remote macOS / Linux │
│ SwiftUI     │  upload-if-needed    │ harness binary (Zig) │
│ Citadel SSH │  ~/.secure-remote-…  │  ACP v1 over stdio   │
│ ACPClient   │ ◀─────────────────── │  /bin/sh -c exec     │
└─────────────┘  newline JSON-RPC    └─────────────────────┘
        │  Phase 2: Mosh roaming upgrade (UDP, same stdio framing)
```

## Components

- **ios/SecureRemoteAgent** — Swift 6, iOS 17+, SwiftUI. Four tabs' worth of
  views now: Hosts / Sessions / Settings. Services:
  - `SSHConnectionManager` (actor, Citadel-only choke point),
  - `HarnessDeployer` (`uname -sm` → slug → SFTP → `chmod +x`),
  - `ACPClient` (JSON-RPC ids, `session/update` fan-out),
  - `MoshManager` (stubbed probe, off by default).
- **harness/** — Zig, zero deps, `ReleaseSmall` + `strip` + `single_threaded`.
  Speaks ACP v1 minimal: `initialize`, `session/new`, `session/prompt`
  (shell exec + streamed chunk), `session/cancel`, `$/cancel_request`.
  Static musl builds for Linux so no glibc surprises.
- **scripts/** — `build-harness.sh` (4 targets → `dist/`), `size-report.sh`
  (300 KiB budget gate).

## Key decisions

1. **Zig for harnesses, not Rust/Go.** Priority is compiled size.
   Zig `ReleaseSmall` static binaries land ~80–200 KiB; Rust min-size is
   2–5× that, Go 10×+. Zig also cross-compiles all four targets from one
   macOS host with no Docker.
2. **Citadel (SwiftNIO SSH) for iOS SSH.** Pure Swift, no xcframework,
   async/await-native. Shout/libssh2 kept as reference pattern only.
3. **ACP over stdio tunneled in SSH exec.** Matches the official
   agent-client-protocol stdio transport (newline JSON-RPC, stdout pure).
   Mosh later reuses the same framing over a roaming pipe.
4. **Harness is a shim, not an LLM.** It proves deploy → exec → stream
   end-to-end. Swap `agent.zig runPrompt` for a subprocess LLM bridge
   (claude/codex) without touching framing or iOS code.
5. **Plain JSON persistence, Keychain keys.** No SwiftData/server/accounts
   (ssssh/Shellby precedent).

## Remote matrix

| Slug | Zig target | Notes |
|------|-----------|-------|
| darwin-arm64 | aarch64-macos | Apple Silicon |
| darwin-x64 | x86_64-macos | Intel Mac |
| linux-x64 | x86_64-linux-musl | static, most servers |
| linux-arm64 | aarch64-linux-musl | static, ARM servers |

Detect via `uname -sm`, cache on `HostProfile.lastKnownArch`.

## Next steps

1. Wire Citadel exec/SFTP bodies (marked TODO, one file each).
2. Host-key pinning (TOFU) + Keychain keygen (CryptoKit Ed25519).
3. `sha256sum` skip-upload check + versioned remote paths.
4. Real `session/update` chunking for long outputs (current: single chunk).
5. Mosh UDP path (Blink-derived build) behind the Settings toggle.
6. SwiftTerm full-terminal tab for interactive shells.
