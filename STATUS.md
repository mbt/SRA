# STATUS — SecureRemoteAgent (resume here next session)

Date: 2026-11-21. Branch: `main` (clean, 15 commits — next session sees
this number +1, ending with the commit that touches this file; step-8
deliverables HEAD `27df55f`).
Scope terminus: **Phase-1 SSH path TestFlight-ready. Mosh UDP, SwiftTerm tab,
LLM bridge stay out of scope** (see §5).

## 1. Resume commands (run first)

```sh
git status --short --branch
git log --oneline -5
zig version                    # need 0.17.x
make test && make sizes        # harness unit tests + 300 KiB gate
cd ios && xcodegen generate
xcodebuild -project SecureRemoteAgent.xcodeproj -scheme SecureRemoteAgent \
  -destination 'platform=iOS Simulator,name=iPhone 17' test  # expect TEST SUCCEEDED (24 tests)
```

Hermes reference (installed `0.23.1` at `~/.local/bin/hermes`):
`hermes acp --check`, `hermes status`.

## 2. Where we are (verified 2026-11-21)

DONE this session (all committed, `git status` clean):

- **Step 0 hygiene** (`29a6d8c`): deleted stray `SecureRemoteAgent/`
  SolidJS template + `SRA_SecureRemoteAgent.json` session dump (gitignored via
  `SRA_*.json`, `.conda/`); README smoke test uses Hermes-strict
  `session/new` params `{"cwd":"/tmp","mcpServers":[]}`; committed the 5
  previously-dirty files (Hermes-compat ACP client, Citadel 0.9.2 wiring,
  `exactVersion` pins — 0.9.3/1.5.3 tags don't exist upstream).
- **Step 1 test target** (`59998b1`): `GENERATE_INFOPLIST_FILE: YES` on
  `SecureRemoteAgentTests`; `xcodebuild test` green (was pre-existing FAIL).
- **Step 2 P0 security** (`df771da`): TOFU host-key pinning + Keychain auth.
  - `connect(host:password:) -> HostProfile`: `.password` requires non-empty
    password (empty-password path gone); `.ed25519`/`.ecdsa` use Keychain
    (auto-generate on first use), returns profile with `pinnedHostKey`/`keyTag`.
  - `TOFUHostKeyValidator` (Citadel `.custom`): pins on first connect,
    mismatch → `SSHError.hostKeyMismatch` via rejection flag (Citadel's
    `InvalidHostKey` has no public init; handshake errors may wrap, so the
    flag — not catching — is the source of truth).
  - New: `Services/SSHKeychain.swift` (this-device-only, no sync),
    `Services/HostKeyPinning.swift` (`SHA256:` fingerprints for future UI).
  - `startSession(to:hostStore:password:)` persists the updated profile
    (pin + keyTag + arch) via `HostStore.update`.
  - 12/12 tests pass (RemoteArch, SSHKeychain, HostKeyPinning).
- **Step 3 sessions + arch** (`f44863f`): per-session connection/client
  keyed by session UUID (no more clobbering); `disconnect(_:)` + Sessions
  swipe; `AddHostView` authKind picker; password sheet for `.password`
  hosts (never stored); arch persists so relaunch skips `uname -sm`.
- **Step 4 settings** (`0bb96af`): `MoshManager` via environment from App;
  `Status.displayText`; working "Manage SSH keys" sheet
  (`SSHKeychain.allTags()` + delete).

Known green: app builds + tests clean for simulator (Citadel 0.9.2,
SwiftTerm 1.99.3). TOFU + Keychain verified by unit tests + typecheck only —
live-host proof deferred to step 7.

- **Step 5 ACPClient hardening** (`ad54836`): `initialize` validated
  fail-fast (version must be 1, auth-gated remotes rejected);
  `stop()` + listen-loop `defer` resume all waiters with `.disconnected`;
  `cancel(sessionId:)` sends `$/cancel_request` with request-id correlation
  (non-throwing); `start(channel:)` seam + 6 scripted-channel tests —
  18/18 green. `docs/ACP_NOTES.md` updated.

- **Step 6 HarnessDeployer** (`435f539`): sha256 remote check
  (`sha256sum`/`shasum` fallback) skips SFTP when hashes match; `upload`
  `Data` overload; `pruneOldVersions` with traversal-safe filter; 6 new
  helper tests — 24/24 green.
- **Size gate pre-check**: `make test` (Zig) passes; `size-report.sh` shows
  all four harness binaries 174–199 KB (< 300 KiB). Re-run before archive.
- **Step 7 live-host validation** (this commit): REAL SSH server — dropbear
  2026.94 in user-mode on 127.0.0.1:23456 with scratch host key +
  authorized_keys (no system sshd or `~/.ssh` changes) via
  `scripts/live-server-setup.sh`; driver `scripts/live-validation.py`
  replays the app's exact flows (exec-channel `capture`, sha/SFTP deploy +
  chmod + skip-on-match, `withTTY`-equivalent shell channel + `exec`
  bootstrap, NDJSON protocol, TOFU pin/tamper). **27/27 checks green**
  (exit 0), transcript `docs/LIVE_2026-11-21.md` + byte-level `.raw.txt`.
  Findings:
  1. `withTTY` sends `shell` WITHOUT a pty-req — the feared `\r\n`/ECHO
     PTY mangling cannot occur on the harness path. 0 `\r` bytes in the
     whole stream, 0 shell noise lines, 26 exact prompt round trips,
     64 KiB output intact as one session/update chunk. No Citadel ≥0.10
     migration needed (harness-side `\\r` trim stays as defense).
  2. SFTP paths live-verified: `SSHConnectionManager.upload` strips `~/`
     to home-RELATIVE (sftp-servers resolve from login home); driver now
     matches that byte-for-byte.
  3. Reconnect skip-upload live-verified: sha equal → 0 bytes transferred.
  4. Tampered hostkey pin → connection refused, fail-closed (strict).
     Kernel gotcha: unattended `ssh` here defaults to
     `UpdateHostKeys=accept-new`, so pin/mismatch tests must force
     `StrictHostKeyChecking=yes` + `UpdateHostKeys=no` (the app's TOFU via
     Citadel custom validator does the equivalent).
  Same-session pre-flight: `xcodebuild test` → TEST SUCCEEDED
  (24 tests, 5 suites); no app code was touched this step.

- **Step 8 docs + threat model** (this session, commit follows): full
  **Security & threat model** section in `README.md` — boundary of trust
  is the SSH account (prompt text is a shell command, `authMethods:[]`
  by design), mitigations (Keychain auth, TOFU fail-closed, deploy
  hygiene, pty-less channel), no-sandbox caveat, one-sentence RCE
  statement. `docs/ACP_NOTES.md`: Hermes-strict `session/new` params
  documented. `harness/README.md`: manual test fixed (was a **two-process
  test that silently fails** — sessions live in one process; now one
  invocation with `ses_1`), Zig-0.17 syntax fix (`zig build` plain —
  `-Doptimize=` no longer exists; ReleaseSmall is the default), stderr
  banner documented. Root README smoke test: one invocation, explicit
  `case "$uname -sm"` arch selection, live-verification section (dropbear
  + `live-validation.py`), status updated. Also fixed the stale
  zig-0.14/0.15 comment in `build.zig`. **Acceptance**: run by an
  independent agent that read only the docs, no code or conversation —
  ran the smoke test verbatim (exit 0, correct JSON sequence) and wrote
  an accurate RCE-boundary paragraph from the docs alone; only
  observation (readiness banner) checked as stderr, confirmed
  (`stdout`=JSON only, banner+logs=stderr). Both smoke tests re-run
  here exactly as documented: exit 0.

- **Step 9 size + matrix gate** (this session, commit follows):
  `scripts/build-harness.sh` now mirrors `dist/` →
  `ios/SecureRemoteAgent/Resources/Harnesses/` after every build and
  verifies byte-for-byte (`cmp`); dist is the single source of truth.
  Fixed a latent bug: `scripts/build-harness.sh` invoked
  `scripts/size-report.sh` via a path relative to the post-`cd` harness/
  dir (always "No such file") — now uses `$REPO_ROOT`. Gate green:
  darwin-arm64 199 KB, darwin-x64 174 KB, linux-arm64 184 KB,
  linux-x64 192 KB (all < 300 KiB). dist vs Resources/Harnesses
  sha256-identical for all four. `make test` green (Zig), `xcodebuild
  build` BUILD SUCCEEDED with the freshly mirrored resources.

## 3. Working list to conclusion (do in order)

### 10. TestFlight checklist (next up)
- All steps green, `git status` clean, version bump (`bundleVersion` +
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`).
- Archive on a real device target, install via TestFlight, connect to one
  macOS + one Linux host, one prompt each.
- Accept: two-host transcript attached to release notes.

## 4. Notes / gotchas for the next agent

- `import NIOSSH` in app code relies on transitive SPM module visibility
  (app depends only on Citadel). Works under Xcode; if it ever breaks, add
  an explicit `swift-nio-ssh` dep pinned to Citadel 0.9.2's range
  (`0.3.2..<0.4.0`, Joannis fork) and same for `swift-crypto` if needed.
- CryptoKit `Curve25519/P256.Signing.PrivateKey` passes directly to
  Citadel's swift-crypto-typed `.ed25519`/`.p256` — on Apple platforms
  swift-crypto typealiases CryptoKit. Verified by build.
- Keychain tests use unique tags + cleanup; Keychain persists on simulator
  across runs, so never use fixed tags in tests.
- `environment.yml` + `.conda/` are notebook-tooling artifacts, not project
  files (`environment.yml` is committed, `.conda/` ignored). Leave alone.
- Live validation fakery: `scripts/live-server-setup.sh` (dropbear
  user-mode; `brew install dropbear`) + `scripts/live-validation.py`
  (std-lib only, run from repo root). The driver's *second* run will take
  the sha-match skip path — delete
  `~/.secure-remote-agent/harness-<slug>` on the host first if you want
  the fresh-upload path in the transcript again.
- dropbear host keys are dropbear-format, not OpenSSH format — `ssh-keygen
  -lf` can't read them; take the host fingerprint from the pinned
  known_hosts after first connect (driver phase 4 does).
- 2026-11-21: the index picked up an unmerged state on `AgentSession.swift` /
  `HostListView.swift` with no `MERGE_HEAD` (external tooling). The `theirs`
  side was stale pre-step-3 code; resolved in favor of ours, verified
  marker-free, tests green. If it recurs, `git ls-files -u` to inspect and
  re-resolve the same way — no committed history was affected.

## 5. Explicitly out of scope (do NOT start)

Mosh UDP handoff (`MoshManager` probe/handshake), SwiftTerm full-terminal tab
(drop the unused dep until then), swapping `runPrompt` for a real LLM bridge,
ACP v2 draft.

## 6. File map for the next agent

- iOS transport/auth: `ios/SecureRemoteAgent/Services/SSHConnectionManager.swift`,
  `.../Services/SSHKeychain.swift`, `.../Services/HostKeyPinning.swift`
- ACP framing: `ios/.../Services/ACPClient.swift`, `harness/src/main.zig`,
  `harness/src/acp.zig`, `harness/src/agent.zig`
- Deploy: `ios/.../Services/HarnessDeployer.swift`
- State: `ios/.../Models/AgentSession.swift`, `.../Models/HostProfile.swift`
- UI: `ios/.../Views/{Content,HostList,Session,Settings}View.swift`
- Project: `ios/project.yml`, `Makefile`, `scripts/*`, `docs/*`
- Live validation: `scripts/live-server-setup.sh` (throwaway dropbear
  host), `scripts/live-validation.py` (driver),
  `docs/LIVE_<date>.md` + `.raw.txt` (transcripts)
