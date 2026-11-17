# ACP notes (Agent Client Protocol v1, stdio transport)

Source: agentclientprotocol.com. ACP is JSON-RPC 2.0, UTF-8, one object per
line, no embedded newlines, no batches. Client launches agent as subprocess;
here the "subprocess" is the remote harness via SSH exec, stdio forwarded.

## Message flow (this repo)

1. `initialize` — client sends `protocolVersion: 1`, `clientCapabilities`
   (`fs.readTextFile/writeTextFile`, `terminal`), `clientInfo`. Harness
   replies with its version, `agentCapabilities`, `agentInfo`, `authMethods: []`.
2. `session/new` — optional `cwd`/`mcpServers`. Harness returns `sessionId`.
3. `session/prompt` — `{"sessionId","prompt":[{"type":"text","text":"…"}]}`.
   Harness execs via `/bin/sh -c`, emits one `session/update` notification
   (`agent_message_chunk` + text), then the prompt result with
   `stopReason: "end_turn"`.
4. `session/cancel` / `$/cancel_request` — acked `{ok:true}` (exec is
   single-shot, not preemptible, in the scaffold).

## Rules we obey

- stdout carries **only** ACP JSON lines; all logging → stderr.
- EOF on stdin = clean shutdown (harness exits after finishing work).
- Receivers apply `session/update`s in order; transports preserve order.
- Unknown methods → `-32601` (requests only, silent for notifications).
- Top-level arrays rejected with `-32600` (no batches).

## Test vectors

See `harness/README.md` for the `printf … | harness` manual test.
iOS side: `ACPClient` ids increment from 0; correlate prompt results by id,
stream chunks via `session/update` fan-out until the result arrives.

## Extending

- Advertise `loadSession`, `modes`, `models` in `initialize` when added.
- Chunk long outputs into multiple `session/update`s (ordering matters).
- Add `authenticate` gate by returning non-empty `authMethods`.
- v2 draft (ID-keyed upserts, renamed methods) is out of scope for now —
  gate it on version negotiation when stabilized.
