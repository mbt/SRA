# STATUS — SecureRemoteAgent (resume here next session)

Date: 2026-11-18. Branch: `main` (dirty, 1 commit `51f37dd`).
Scope terminus: **Phase-1 SSH path TestFlight-ready. Mosh UDP, SwiftTerm tab,
LLM bridge stay out of scope** (see §7).

## 1. Resume commands (run first)

```sh
git status --short --branch
git diff --stat
zig version                    # need 0.17.x
make test && make sizes        # harness unit tests + 300 KiB gate
cd ios && xcodegen generate
xcodebuild -project SecureRemoteAgent.xcodeproj -scheme SecureRemoteAgent \
  -destination 'generic/platform=iOS Simulator' build  # expect BUILD SUCCEEDED
```

Hermes reference (installed `0.23.1` at `~/.local/bin/hermes`):
`hermes acp --check`, `hermes status`.

## 2. Where we are (verified 2026-11-18)

DONE just now — Hermes-compat in `ios/SecureRemoteAgent/Services/ACPClient.swift`
(uncommitted, part of the 5 modified files):
- `newSession` sends `["cwd": cwd ?? "/tmp", "mcpServers": []]` (Hermes rejects
  `{}` / missing either key; Zig shim ignores extras — smoke-tested `ses_1` OK).
- `prompt` keys `updateHandlers` by `sessionId`, finishes stale handler on
  re-prompt, completes via actor-isolated `finishPrompt(sessionId:)`.
- `handle(line:)` requires `params.sessionId` + `update.sessionUpdate ==
  "agent_message_chunk"` and routes to that session only (thought/tool chunks
  no longer leak; concurrent sessions no longer cross-talk).
- Removed dead `sessionIdKey(_:)`. Shim compat confirmed:
  `harness/src/agent.zig:176-194` emits both `sessionId` and
  `agent_message_chunk`.

Still dirty (uncommitted): `README.md`, `AgentSession.swift`,
`ACPClient.swift`, `SSHConnectionManager.swift`, `project.yml`.
Untracked: `SRA_SecureRemoteAgent.json` (prior-session dump, 769 KiB — delete
or gitignore before commit), `SecureRemoteAgent/` (stray SolidJS template —
delete, unrelated to iOS/Zig).

Known green: app builds clean for simulator (Xcode 27.2, Citadel 0.9.2,
SwiftTerm 1.99.3). `xcodebuild test` FAILS pre-existing — see step 1.

## 3. Working list to conclusion (do in order)

### 0. Worktree hygiene (5 min)
- Decide: `rm -rf SecureRemoteAgent/` (stray template), `rm
  SRA_SecureRemoteAgent.json` or move out of repo (it is the prior session
  transcript, must not ship).
- `README.md` smoke test still shows `"params":{}` for `session/new` — update
  to `{"cwd":"/tmp","mcpServers":[]}` to match new client.
- Commit or stash the 5 modified files before further edits.
- Accept: `git status` shows only intended files.

### 1. Fix test target (10 min) — unblocks all verification
File: `ios/project.yml:67-73` (`SecureRemoteAgentTests` has no Info.plist).
- Add `GENERATE_INFOPLIST_FILE: YES` (or `info.path`) to the test target,
  `xcodegen generate`, then:
  `xcodebuild test -project SecureRemoteAgent.xcodeproj -scheme
  SecureRemoteAgent -destination 'platform=iOS Simulator,name=iPhone 17'`
- Accept: `RemoteArchTests` run green.

### 2. P0 security: TOFU + Keychain auth (largest item)
File: `ios/SecureRemoteAgent/Services/SSHConnectionManager.swift:22-40`.
- Today: `.acceptAnything()` + `passwordBased(..., password: "")`.
- Implement: host-key pinning (store fingerprint per host in
  `HostProfile`/Keychain, prompt on change = TOFU), Keychain Ed25519 keygen
  via CryptoKit, wire `authKind`/`keyTag` from `HostProfile.swift:11-14`.
- Accept: fresh host pins on first connect, mismatch errors
  (`SSHError.hostKeyMismatch`), no empty-password path, password auth only
  when `authKind == .password`.

### 3. SessionManager: N sessions + arch persistence
File: `ios/SecureRemoteAgent/Models/AgentSession.swift:28-58`.
- Today: single `connection`/`acp` shared across `ActiveSession`s (second
  connect clobbers first); `updated.lastKnownArch` computed then discarded
  (`_ = updated`, and stray `_ = s` at end).
- Implement: per-session connection+client (dictionary keyed by session UUID
  or move into `ActiveSession`), persist arch via `HostStore.update(_:)`.
- Accept: two concurrent hosts each prompt independently; relaunch skips
  `uname -sm` when `lastKnownArch` known.

### 4. Settings: app-wide Mosh state
File: `ios/SecureRemoteAgent/Views/SettingsView.swift:4`.
- Today: `@State var mosh = MoshManager()` is view-local, toggle does nothing.
- Implement: inject single `MoshManager` via environment from
  `SecureRemoteAgentApp.swift` (same pattern as `HostStore`/`SessionManager`).
- Accept: toggle persists for session lifetime; status line reflects probe.

### 5. ACPClient hardening
File: `ios/SecureRemoteAgent/Services/ACPClient.swift:24-34,101-110`.
- Validate `initialize` result (`protocolVersion`, capabilities/auth) instead
  of `_ = result`; surface mismatch as `ACPError.protocolViolation`.
- Fail all `pending` continuations on disconnect/`listenLoop` end (today they
  hang if channel drops mid-request).
- Wire `cancel(sessionId:)` to `$/cancel_request` correlation if harness ever
  becomes preemptible (today scaffold ACKs `{ok:true}`).
- Update `docs/ACP_NOTES.md:31-32` (still describes old fan-out).
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
File: `SSHConnectionManager.swift:119-168` (`withTTY` + `exec` shim; Citadel
0.9.2 has no public exec-with-stdio primitive).
- Risk: PTY `\r\n` translation/echo breaks `\n`-framing in `carry` split.
- Test against a real host: `capture("uname -sm")` → `ensureHarness` →
  `start` → `newSession` → `prompt("echo ok")` returns exactly `ok` with no
  framing errors over ≥20 prompts and a 64 KiB output.
- If PTY mangles framing, migrate to Citadel ≥0.10 exec-with-stdio or strip
  `\r` + disable echo in the shim command.
- Accept: recorded transcript of the above in PR/commit message.

### 8. Docs + threat model (before TestFlight)
- `README.md`: add threat-model paragraph — harness is intentional RCE
  (`harness/src/agent.zig:148-153` `/bin/sh -c`), no auth gate
  (`authMethods:[]`); anyone with SSH access gets shell. State mitigations
  (TOFU, Keychain, no password default).
- `docs/ACP_NOTES.md`: document Hermes-strict `session/new` + chunk filter.
- `harness/README.md:54-66`: update manual test to Hermes-compatible params.
- Accept: a new agent reading only docs can run the smoke test and state the
  RCE boundary.

### 9. Size + matrix gate
```sh
scripts/build-harness.sh && scripts/size-report.sh  # all 4 < 300 KiB
```
- Copy `dist/harness-*` into
  `ios/SecureRemoteAgent/Resources/Harnesses/` before archive (build phase
  already wired in `project.yml:57-65`; today both copies exist and drift —
  make `dist/` the single source of truth).
- Accept: gate green, `ls -lh dist ios/.../Harnesses` agree.

### 10. TestFlight checklist
- Steps 0–9 green, `git status` clean, version bump (`bundleVersion` +
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml:43-50`).
- Archive on a real device target, install via TestFlight, connect to one
  macOS + one Linux host, one prompt each.
- Accept: two-host transcript attached to release notes.

## 4. Explicitly out of scope (do NOT start)
Mosh UDP handoff (`MoshManager` probe/handshake), SwiftTerm full-terminal tab
(drop the unused dep until then), swapping `runPrompt` for a real LLM bridge,
ACP v2 draft, Nitro/Cloudflare/Netlify deploy recipes under
`SecureRemoteAgent/` if that stray template survives deletion.

## 5. File map for the next agent
- iOS transport/auth: `ios/SecureRemoteAgent/Services/SSHConnectionManager.swift`
- ACP framing: `ios/.../Services/ACPClient.swift`, `harness/src/main.zig`,
  `harness/src/acp.zig`, `harness/src/agent.zig`
- Deploy: `ios/.../Services/HarnessDeployer.swift`
- State: `ios/.../Models/AgentSession.swift`, `.../Models/HostProfile.swift`
- UI: `ios/.../Views/{Content,HostList,Session,Settings}View.swift`
- Project: `ios/project.yml`, `Makefile`, `scripts/*`, `docs/*`
