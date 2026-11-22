# ACP notes (Agent Client Protocol v1, stdio transport)

Source: agentclientprotocol.com. ACP is JSON-RPC 2.0, UTF-8, one object per
line, no embedded newlines, no batches. Client launches agent as subprocess;
here the "subprocess" is the remote harness via SSH exec, stdio forwarded.

## Message flow (this repo)

1. `initialize` — client sends `protocolVersion: 1`, `clientCapabilities`
   (`fs.readTextFile/writeTextFile`, `terminal`), `clientInfo`. Harness
   replies with its version, `agentCapabilities`, `agentInfo`, `authMethods: []`.
2. `session/new` — params must be an object carrying `cwd` (string) and
   `mcpServers` (array): Hermes-strict clients reject missing keys, so
   `ACPClient` always sends `{"cwd":…,"mcpServers":[]}`. This harness
   accepts and ignores both fields. Returned: `sessionId`.
3. `session/prompt` — `{"sessionId","prompt":[{"type":"text","text":"…"}]}`.
   Harness execs via `/bin/sh -c`, emits one `session/update` notification
   (`agent_message_chunk` + text), then the prompt result with
   `stopReason: "end_turn"`.
4. `$/cancel_request` — client sends the notification with `requestId` of
   the in-flight prompt and ends the local stream immediately. The scaffold
   harness exec is single-shot (not preemptible), so this is best-effort.

## Rules we obey

- stdout carries **only** ACP JSON lines; all logging → stderr.
- EOF on stdin = clean shutdown (harness exits after finishing work).
- Receivers apply `session/update`s in order; transports preserve order.
- Unknown methods → `-32601` (requests only, silent for notifications).
- Top-level arrays rejected with `-32600` (no batches).

## Test vectors

See `harness/README.md` for the `printf … | harness` manual test.
iOS side: `ACPClient` ids increment from 0; prompt results correlate by id.
`session/update` notifications route by `params.sessionId` to that session's
stream, and only `agent_message_chunk` updates reach chat (thought/tool
chunks are dropped). Transport death fails every pending request with
`ACPError.disconnected` and finishes all streams — no waiter hangs.
`initialize` is validated fail-fast: the client speaks exactly
`protocolVersion` 1 and has no `authenticate` flow, so version mismatch or a
non-empty `authMethods` surfaces as `ACPError.protocolViolation`.

## Extending

- Advertise `loadSession`, `modes`, `models` in `initialize` when added.
- Chunk long outputs into multiple `session/update`s (ordering matters).
- Add `authenticate` gate by returning non-empty `authMethods`.
- v2 draft (ID-keyed upserts, renamed methods) is out of scope for now —
  gate it on version negotiation when stabilized.
