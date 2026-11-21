# STATUS — SecureRemoteAgent (resume here next session)

Date: 2026-11-21. Branch: `main` (clean, 4 commits, HEAD `df771da`).
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
  -destination 'platform=iOS Simulator,name=iPhone 17' test  # expect TEST SUCCEEDED (12 tests)
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

Known green: app builds + tests clean for simulator (Citadel 0.9.2,
SwiftTerm 1.99.3). TOFU + Keychain verified by unit tests + typecheck only —
live-host proof deferred to step 7.

## 3. Working list to conclusion (do in order)

### 3. SessionManager: N sessions + arch persistence (next up)
File: `ios/SecureRemoteAgent/Models/AgentSession.swift`.
- Today: single `connection`/`acp` shared across `ActiveSession`s (second
  connect clobbers first). Partially done in step 2: updated profile
  (pin/keyTag/arch) is now persisted via `hostStore` — the `_ = updated` and
  `_ = s` warts are gone.
- Implement: per-session connection+client (dictionary keyed by session UUID
  or move into `ActiveSession`); relaunch skips `uname -sm` when
  `lastKnownArch` known.
- New follow-up from step 2: `AddHostView` has no authKind picker and there
  is no password prompt UI — `.password` hosts fail cleanly (`.failed`) but
  can't connect from the UI. Add picker + prompt before TestFlight.
- Accept: two concurrent hosts each prompt independently; relaunch skips
  `uname -sm` when `lastKnownArch` known.

### 4. Settings: app-wide Mosh state
File: `ios/SecureRemoteAgent/Views/SettingsView.swift:4`.
- Today: `@State var mosh = MoshManager()` is view-local, toggle does nothing.
- Implement: inject single `MoshManager` via environment from
  `SecureRemoteAgentApp.swift` (same pattern as `HostStore`/`SessionManager`).
- Accept: toggle persists for session lifetime; status line reflects probe.

### 5. ACPClient hardening
File: `ios/SecureRemoteAgent/Services/ACPClient.swift`.
- Validate `initialize` result (`protocolVersion`, capabilities/auth) instead
  of `_ = result`; surface mismatch as `ACPError.protocolViolation`.
- Fail all `pending` continuations on disconnect/`listenLoop` end (today they
  hang if channel drops mid-request).
- Wire `cancel(sessionId:)` to `$/cancel_request` correlation if harness ever
  becomes preemptible (today scaffold ACKs `{ok:true}`).
- Update `docs/ACP_NOTES.md` (still describes old fan-out).
- Accept: bad-protocol remote fails fast with clear error; killing channel
  resumes every waiter with error, no hangs.

### 6. HarnessDeployer: skip-upload + version hygiene
File: `ios/SecureRemoteAgent/Services/HarnessDeployer.swift:45-58`.
- Add `sha256sum` remote check before SFTP; skip upload when hashes match.
- Keep versioned `remotePath` (`bundleVersion`), prune old versions on
  success.
- Accept: second connect uploads 0 bytes; `chmod +x` still applied after
  fresh upload.

### 7. Live-host validation (the one thing typecheck can't prove)
File: `SSHConnectionManager.swift` (`withTTY` + `exec` shim; Citadel
0.9.2 has no public exec-with-stdio primitive).
- Risk: PTY `\r\n` translation/echo breaks `\n`-framing in `carry` split.
- Test against a real host: `capture("uname -sm")` → `ensureHarness` →
  `start` → `newSession` → `prompt("echo ok")` returns exactly `ok` with no
  framing errors over ≥20 prompts and a 64 KiB output. Also confirms TOFU
  pin/mismatch against a real host key.
- If PTY mangles framing, migrate to Citadel ≥0.10 exec-with-stdio or strip
  `\r` + disable echo in the shim command.
- Accept: recorded transcript of the above in PR/commit message.

### 8. Docs + threat model (before TestFlight)
- `README.md`: add threat-model paragraph — harness is intentional RCE
  (`harness/src/agent.zig` `/bin/sh -c`), no auth gate
  (`authMethods:[]`); anyone with SSH access gets shell. State mitigations
  (TOFU + Keychain now implemented, no password default).
- `docs/ACP_NOTES.md`: document Hermes-strict `session/new` + chunk filter.
- `harness/README.md`: update manual test to Hermes-compatible params.
- Accept: a new agent reading only docs can run the smoke test and state the
  RCE boundary.

### 9. Size + matrix gate
```sh
scripts/build-harness.sh && scripts/size-report.sh  # all 4 < 300 KiB
```
- Copy `dist/harness-*` into
  `ios/SecureRemoteAgent/Resources/Harnesses/` before archive (build phase
  already wired in `project.yml`; today both copies exist and drift —
  make `dist/` the single source of truth).
- Accept: gate green, `ls -lh dist ios/.../Harnesses` agree.

### 10. TestFlight checklist
- Steps 0–9 green, `git status` clean, version bump (`bundleVersion` +
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
