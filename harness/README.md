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
zig build -Doptimize=ReleaseSmall   # host binary -> zig-out/bin/
zig build test                      # unit tests
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

```sh
zig build -Doptimize=ReleaseSmall
printf '%s\n' \
 '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"test","version":"0"}}}' \
 '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}' \
  | ./zig-out/bin/secure-remote-harness
# copy sessionId, then:
printf '%s\n' \
 '{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"ses_...","prompt":[{"type":"text","text":"uname -sm"}]}}' \
  | ./zig-out/bin/secure-remote-harness
```

stdout must contain only JSON lines; logs go to stderr.
