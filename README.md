# SecureRemoteAgent

iOS app (Swift) + tiny remote harnesses (Zig) that speak
[ACP](https://agentclientprotocol.com) (Agent Client Protocol) over **SSH**
— with **Mosh** roaming as a Phase-2 upgrade. Run the agent on your Mac or
cloud box; drive it from your phone.

> Idea: ship a harness binary per remote (`darwin-arm64`, `darwin-x64`,
> `linux-x64`, `linux-arm64`). The iOS app detects the remote with
> `uname -sm`, uploads the right binary, and speaks ACP v1 JSON-RPC over
> the SSH stdio channel. See [IDEA.md](IDEA.md).

## Repo layout

```
harness/   Zig harness (size-first: ReleaseSmall, stripped, static musl on Linux)
ios/       SwiftUI iOS app (Swift 6, Citadel SSH, xcodegen project.yml)
scripts/   build-harness.sh (4 targets -> dist/), size-report.sh (300 KiB gate)
docs/      ARCHITECTURE.md, ACP_NOTES.md
dist/      built harnesses (gitignored) -> bundled into iOS Resources/Harnesses
```

## Quick start

### 1. Build the harnesses

```sh
zig version                    # need 0.17+ (pinned: 0.14/0.15 toolchains
                               # cannot link on current macOS; harness uses
                               # the 0.17 Io/Threaded APIs)
scripts/build-harness.sh       # -> dist/harness-{darwin-arm64,darwin-x64,linux-x64,linux-arm64}
scripts/size-report.sh         # budget: each < 300 KiB
```

Manual smoke test (no iPhone needed):

```sh
printf '%s\n' \
 '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
 '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
 | ./dist/harness-$(uname -sm | awk '{print tolower($1)}')* 2>/dev/null || ./dist/harness-linux-x64
```

### 2. Generate + open the iOS project

```sh
brew install xcodegen
cd ios && xcodegen generate && open SecureRemoteAgent.xcodeproj
```

Copy the four `dist/harness-*` files into
`ios/SecureRemoteAgent/Resources/Harnesses/` before archiving (wired as a
resources build phase in `project.yml`).

### 3. Review the wired Citadel call sites

`SSHConnectionManager.capture/upload/openHarnessChannel` are wired against
Citadel 0.9.2 (shell-channel + `exec` shim for the harness stdio pipe; SFTP
upload with truncate). Remaining before TestFlight (search `TODO`):

- Host-key TOFU pinning + Keychain Ed25519 keygen (CryptoKit).
- Live test against a real host — framing verified only by typecheck so far.

Everything else (ACP framing, deploy flow, chat UI) is already connected.

## Size priority (harnesses)

`harness/build.zig` defaults to `-Doptimize=ReleaseSmall` with
`strip = true`, `single_threaded = true`, zero dependencies. Keep it that
way — `size-report.sh` fails the build over 300 KiB. See
[harness/README.md](harness/README.md) for the budget tips.

## SSH / Mosh

- **SSH**: Citadel (pure Swift over SwiftNIO, iOS-safe, no xcframework).
  Password + pubkey auth, SFTP upload, PTY-less exec for ACP.
- **Mosh**: stubbed `MoshManager` (off by default). Plan: race
  `which mosh-server` at connect, confirm UDP end-to-end, roam the same
  stdio framing; always fall back to SSH silently. Same pattern as Blink/ssssh.

## Status

Scaffold / pre-alpha. ACP `initialize → session/new → session/prompt`
works against the local harness binary; SSH channel bodies are implemented
against Citadel 0.9.2 and need a live-host test. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the roadmap.
