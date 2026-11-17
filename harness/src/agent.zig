// agent.zig — tiny ACP v1 agent core.
//
// Implements the smallest useful ACP surface for the scaffold:
//   initialize -> session/new -> session/prompt -> session/cancel
//   $/cancel_request
//
// session/prompt executes the prompt text as `/bin/sh -c <text>` and
// streams captured output back as `session/update` notifications,
// then completes with `stopReason: "end_turn"`.
//
// This is deliberately a *harness*, not an LLM: it proves the
// iOS -> SSH -> stdio -> ACP loop end-to-end with minimal bytes.
// Swap `runPrompt` for a subprocess LLM bridge (claude/codex/etc.)
// without changing the framing in main.zig / acp.zig.

const std = @import("std");
const acp = @import("acp.zig");

pub const AGENT_NAME = "secure-remote-harness";
pub const AGENT_VERSION = "0.1.0";
pub const PROTOCOL_VERSION: i64 = 1;

pub const Agent = struct {
    allocator: std.mem.Allocator,
    // sessionId -> unit (we keep sessions lightweight; extend with cwd,
    // env, child handles as needed — watch binary size as you grow this).
    sessions: std.StringHashMap(void),
    next_session: u64,

    pub fn init(allocator: std.mem.Allocator) Agent {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(void).init(allocator),
            .next_session = 1,
        };
    }

    pub fn deinit(self: *Agent) void {
        var it = self.sessions.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.sessions.deinit();
    }

    fn newSessionId(self: *Agent) ![]u8 {
        // ses_<counter hex> — unique per harness process run, no deps.
        // (Add crypto randomness if sessions must survive restarts.)
        const id = try std.fmt.allocPrint(
            self.allocator,
            "ses_{x}",
            .{self.next_session},
        );
        self.next_session += 1;
        return id;
    }

    /// Handle `initialize`. Returns the `result` object (caller wraps it).
    /// `a` should be a short-lived arena: all maps are transient.
    pub fn handleInitialize(self: *Agent, a: std.mem.Allocator, params: ?std.json.Value) !std.json.Value {
        _ = self;
        _ = params;

        var agent_info = try acp.newObject(a);
        try acp.objPut(&agent_info, a, "name", .{ .string = AGENT_NAME });
        try acp.objPut(&agent_info, a, "title", .{ .string = "Secure Remote Harness" });
        try acp.objPut(&agent_info, a, "version", .{ .string = AGENT_VERSION });

        var prompt_caps = try acp.newObject(a);
        try acp.objPut(&prompt_caps, a, "image", .{ .bool = false });
        try acp.objPut(&prompt_caps, a, "audio", .{ .bool = false });
        try acp.objPut(&prompt_caps, a, "embeddedContext", .{ .bool = false });

        var session_caps = try acp.newObject(a);
        try acp.objPut(&session_caps, a, "loadSession", .{ .bool = false });

        var agent_caps = try acp.newObject(a);
        try acp.objPut(&agent_caps, a, "loadSession", .{ .bool = false });
        try acp.objPut(&agent_caps, a, "promptCapabilities", .{ .object = prompt_caps });
        try acp.objPut(&agent_caps, a, "sessionCapabilities", .{ .object = session_caps });

        var result = try acp.newObject(a);
        try acp.objPut(&result, a, "protocolVersion", .{ .integer = PROTOCOL_VERSION });
        try acp.objPut(&result, a, "agentCapabilities", .{ .object = agent_caps });
        try acp.objPut(&result, a, "agentInfo", .{ .object = agent_info });
        // Empty authMethods: no auth gate in the scaffold harness.
        // Add {"id": "...", ...} entries here to force client authenticate.
        try acp.objPut(&result, a, "authMethods", .{ .array = std.json.Array.init(a) });
        return .{ .object = result };
    }

    /// Handle `session/new`. Params may carry `cwd`, `mcpServers` (ignored here).
    /// `a` should be a short-lived arena; the session id string itself is
    /// allocated on the agent's long-lived allocator (stored in sessions).
    pub fn handleSessionNew(self: *Agent, a: std.mem.Allocator, params: ?std.json.Value) !std.json.Value {
        _ = params;
        const id = try self.newSessionId();
        errdefer self.allocator.free(id);
        try self.sessions.put(id, {});
        var result = try acp.newObject(a);
        try acp.objPut(&result, a, "sessionId", .{ .string = id });
        // modes / models omitted — advertise via capabilities when added.
        return .{ .object = result };
    }

    /// Extract sessionId + concatenated text prompt from session/prompt params.
    pub fn parsePrompt(params: ?std.json.Value) struct { session_id: []const u8, text: []const u8 } {
        const empty: []const u8 = "";
        const p = params orelse return .{ .session_id = empty, .text = empty };
        if (p != .object) return .{ .session_id = empty, .text = empty };
        const obj = p.object;
        const sid = if (obj.get("sessionId")) |v| (if (v == .string) v.string else empty) else empty;
        var text: []const u8 = empty;
        if (obj.get("prompt")) |pv| {
            if (pv == .array) {
                for (pv.array.items) |block| {
                    if (block != .object) continue;
                    if (block.object.get("text")) |t| {
                        if (t == .object) {
                            if (t.object.get("text")) |inner| {
                                if (inner == .string) {
                                    text = inner.string;
                                    break;
                                }
                            }
                        } else if (t == .string) {
                            text = t.string;
                            break;
                        }
                    }
                    // Also accept {"type":"text","text":"…"} shorthand.
                    if (block.object.get("type")) |ty| {
                        if (ty == .string and std.mem.eql(u8, ty.string, "text")) {
                            if (block.object.get("text")) |t2| {
                                if (t2 == .string) {
                                    text = t2.string;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
        return .{ .session_id = sid, .text = text };
    }

    /// Run `text` via /bin/sh -c and return combined output (caller frees).
    /// Cap at 64 KiB to bound memory on tiny remotes.
    pub fn runPrompt(self: *Agent, io: std.Io, text: []const u8) ![]u8 {
        const a = self.allocator;
        if (text.len == 0) return try a.dupe(u8, "(empty prompt)\n");

        // One-shot spawn + collect. Caller owns result slices.
        const result = std.process.run(a, io, .{
            .argv = &.{ "/bin/sh", "-c", text },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(16 * 1024),
        }) catch |err| {
            if (err == error.StreamTooLong) return try a.dupe(u8, "(output exceeded 64 KiB cap)\n");
            return err;
        };
        defer a.free(result.stdout);
        defer a.free(result.stderr);

        const out = result.stdout;
        const err_out = result.stderr;

        if (err_out.len > 0) {
            return try std.fmt.allocPrint(a, "{s}\n[stderr]\n{s}", .{ out, err_out });
        }
        if (out.len == 0) return try a.dupe(u8, "(ok, no output)\n");
        return try a.dupe(u8, out);
    }

    /// Build a `session/update` notification body for a text chunk.
    /// `a` should be a short-lived arena: all maps are transient.
    pub fn updateChunk(
        self: *Agent,
        a: std.mem.Allocator,
        session_id: []const u8,
        chunk: []const u8,
    ) !std.json.Value {
        _ = self;
        var content = try acp.newObject(a);
        try acp.objPut(&content, a, "type", .{ .string = "text" });
        try acp.objPut(&content, a, "text", .{ .string = chunk });

        var update = try acp.newObject(a);
        try acp.objPut(&update, a, "sessionUpdate", .{ .string = "agent_message_chunk" });
        try acp.objPut(&update, a, "content", .{ .object = content });

        var params = try acp.newObject(a);
        try acp.objPut(&params, a, "sessionId", .{ .string = session_id });
        try acp.objPut(&params, a, "update", .{ .object = update });
        return .{ .object = params };
    }
};

test "parsePrompt extracts text" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc =
        \\{"sessionId":"ses_1","prompt":[{"type":"text","text":"echo hi"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, doc, .{});
    defer parsed.deinit();
    const got = Agent.parsePrompt(parsed.value);
    try t.expectEqualStrings("ses_1", got.session_id);
    try t.expectEqualStrings("echo hi", got.text);
}
