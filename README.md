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

Manual smoke test (no iPhone needed). All three requests go into **one
invocation** — sessions live only inside a single harness process:

```sh
case "$(uname -sm)" in
  'Darwin arm64')  B=dist/harness-darwin-arm64 ;;
  'Darwin x86_64') B=dist/harness-darwin-x64 ;;
  'Linux x86_64')  B=dist/harness-linux-x64 ;;
  'Linux aarch64') B=dist/harness-linux-arm64 ;;
esac
printf '%s\n' \
 '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"smoke","version":"0.1.0"}}}' \
 '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
 '{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"ses_1","prompt":[{"type":"text","text":"echo ok"}]}}' \
 | $B
# expect on stdout: two JSON responses, one session/update containing
# "ok", then an end_turn result; EOF on stdin exits the harness cleanly
```

### 2. Generate + open the iOS project

```sh
brew install xcodegen
cd ios && xcodegen generate && open SecureRemoteAgent.xcodeproj
```

Copy the four `dist/harness-*` files into
`ios/SecureRemoteAgent/Resources/Harnesses/` before archiving (wired as a
resources build phase in `project.yml`).

### 3. Verify the full live path (2 min, no iPhone)

TOFU pinning, Keychain auth, arch probe, sha-keyed deploy and the NDJSON
harness session are all implemented and **verified against a real SSH
host**. Replay the app's exact SSH flows against a throwaway server:

```sh
brew install dropbear                    # once
scripts/live-server-setup.sh &           # user-mode sshd on 127.0.0.1:23456,
                                         # own host key + authorized_keys
python3 scripts/live-validation.py       # 27/27 checks, exit 0
```

Transcript lands in `docs/LIVE_<date>.md` (+ byte-level `.raw.txt`).
Nothing touches the system sshd or `~/.ssh`. Everything else (ACP
framing, deploy flow, chat UI) was already connected and unit-tested
(24 tests, 5 suites).

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

## Security & threat model

**The harness is remote code execution by design.** Every
`session/prompt` runs the prompt text as `/bin/sh -c <text>`
(`harness/src/agent.zig`, `runPrompt`; output capped at 64 KiB) and
returns combined stdout/stderr as an `agent_message_chunk`.
`initialize` answers with `authMethods: []` — there is **no ACP-level
auth gate**. This is intentional, not an oversight: ACP is a
trusted-pair protocol, and the security boundary is the SSH channel
that transports it.

**Boundary of trust = the SSH account.** Anyone who can authenticate to
the host's SSH as that user can already run an arbitrary shell there;
the harness adds nothing beyond that account's scope — commands run as
the same user with the same filesystem, network, and privileges. What
it *does not* grant: privilege escalation, persistence (only
`~/.secure-remote-agent/` is written), access to other users, or
anything the SSH login couldn't already do. The inverse also holds:
there is no sandbox — prompt text is a **shell command**, not an LLM
query, in this harness. Swap in an LLM bridge later; the framing stays.

**Mitigations implemented (app side):**
- Channel auth only: password or an Ed25519 key generated in Keychain
  (never stored in plaintext; no empty-password path accepted).
- Host-key TOFU pinning: the first connect pins the host fingerprint;
  a changed key fails closed with `SSHError.hostKeyMismatch`.
- Deploy hygiene: binaries live under `~/.secure-remote-agent/`,
  versioned `harness-<arch>-0.1.0`, sha256 compared (reconnects
  transfer 0 bytes), stale versions pruned; filename traversal filtered.
- Framing: ACP lines are the only thing on stdout; harness logs go to
  stderr. The channel used is a shell channel **without a pty**, so no
  `\r\n` translation or echo can corrupt the protocol stream.

**Not mitigated:** if you share the SSH account with others, the
harness faithfully executes whatever SSH allows. Use a dedicated,
lowest-privilege account when you want a fence between the app and
other users of that machine.

**RCE boundary in one sentence:** SecureRemoteAgent grants exactly the
capabilities of the SSH account it logs into — prompt text is executed
by `/bin/sh` as that account, with no additional auth, sandbox, or
privilege boundary at the ACP layer.

## Status

Pre-alpha but live-validated: ACP `initialize → session/new →
session/prompt` verified end-to-end against a real SSH host (dropbear;
27/27 checks — `docs/LIVE_2026-11-21.md`). TOFU pinning + Keychain auth
implemented and unit-tested (24 tests green). Remaining before
TestFlight: step 9 (size/matrix gate + single-source dist) and step 10
(device archive + two-host transcript). See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the roadmap.
