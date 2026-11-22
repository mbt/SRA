# secure-remote-harness

Tiny ACP (Agent Client Protocol) agent shim that runs on the **remote**
macOS / Linux box. The iOS app uploads the right binary over SSH, executes
it with stdio forwarded, and speaks ACP v1 JSON-RPC over that channel.

Priority: **compiled program size**. Zero dependencies, single-threaded,
`--release=small` + strip.

Requires Zig **0.17+** (the harness uses the new `std.Io`/`Threaded` APIs;
older toolchains also fail to link on current macOS, verified 0.14–0.16).

## Layout

- `src/main.zig` — stdio event loop (newline-delimited JSON-RPC)
- `src/acp.zig` — message envelopes (success / failure / notification)
- `src/agent.zig` — minimal agent: `initialize`, `session/new`,
  `session/prompt` (via `/bin/sh -c`), `session/cancel`

## Build

```sh
zig build                         # host binary -> zig-out/bin/ (ReleaseSmall
                                  # is the default; size gate: see below)
zig build test                    # unit tests
```

Cross-compile all shipped targets (see `../scripts/build-harness.sh`):

```sh
../scripts/build-harness.sh         # -> dist/harness-<slug>
../scripts/size-report.sh           # -> size table for README/badge
```

| Slug | Target | Remote |
|------|--------|--------|
| `darwin-arm64` | `aarch64-macos` | Apple Silicon Mac |
| `darwin-x64` | `x86_64-macos` | Intel Mac |
| `linux-x64` | `x86_64-linux-musl` | most servers |
| `linux-arm64` | `aarch64-linux-musl` | ARM servers / Pi |

musl targets produce **static** binaries — no glibc dependency on the remote.

## Size budget

Goal: each binary **< 300 KiB stripped** (typical today ~80–200 KiB).
`scripts/size-report.sh` is the gate — keep it green when adding features.

Tips if it grows:
- stay on `ReleaseSmall` + `strip = true` + `single_threaded = true`
- prefer `std.json.Value` + small `ArrayMap`s over big derived structs
- avoid `std.process.Child` alternatives that pull in threads
- no regex, no crypto, no HTTP in the harness — keep it a shim

## Manual test (no iOS needed)

All requests must go into **one process** — `session/new` and
`session/prompt` only see sessions created in the same invocation, and
the harness answers queued lines before exiting on EOF:

```sh
zig build
printf '%s\n' \
 '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}' \
 '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
 '{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"ses_1","prompt":[{"type":"text","text":"uname -sm"}]}}' \
  | ./zig-out/bin/secure-remote-harness
```

Notes:
- session ids are sequential per process: the first `session/new`
  always returns `ses_1` on a fresh run (used above).
- `session/new` params **must contain both `cwd` and `mcpServers`** for
  Hermes-strict clients — the harness ignores their values but Hermes
  rejects `{}` or a missing key. Always send
  `{"cwd":"/tmp","mcpServers":[]}`-shaped params.
- stdout must contain only JSON lines; logs (including the
  `secure-remote-harness … ready` banner) go to stderr. EOF on stdin
  exits the harness cleanly after answering everything in flight.
- To work against a *cross-compiled* binary, run the same pipeline
  against `../dist/harness-<slug>` instead of `zig-out/bin/…`.
