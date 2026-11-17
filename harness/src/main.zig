// main.zig — stdio event loop for the ACP harness (Zig 0.17 APIs).
//
// Reads newline-delimited JSON-RPC from stdin, dispatches to agent.zig,
// writes newline-delimited responses to stdout, logs to stderr.
//
// Supported methods (ACP v1 minimal):
//   initialize, session/new, session/prompt, session/cancel,
//   $/cancel_request, plus `shutdown` notification to exit cleanly.
//
// Build (size-first):
//   zig build --release=small
// Cross (from macOS):
//   zig build --release=small -Dtarget=aarch64-macos
//   (see scripts/build-harness.sh for the 4 shipped targets)

const std = @import("std");
const acp = @import("acp.zig");
const agent_mod = @import("agent.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Threaded Io context (collapses to single-threaded when the binary is
    // built with single_threaded=true — see build.zig).
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    var out_buf: [8192]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &out_buf);
    var stdout = &stdout_fw.interface;

    var err_buf: [1024]u8 = undefined;
    var stderr_fw = std.Io.File.stderr().writer(io, &err_buf);
    var stderr = &stderr_fw.interface;

    // Log banner to stderr only — stdout must stay pure ACP.
    stderr.print("{s} {s} ready (ACP v{d}, stdio)\n", .{
        agent_mod.AGENT_NAME,
        agent_mod.AGENT_VERSION,
        agent_mod.PROTOCOL_VERSION,
    }) catch {};
    stderr.flush() catch {};

    var ag = agent_mod.Agent.init(allocator);
    defer ag.deinit();

    const line_buf = try allocator.alloc(u8, acp.max_line);
    defer allocator.free(line_buf);
    var stdin_fr = std.Io.File.stdin().reader(io, line_buf);
    var stdin_reader = &stdin_fr.interface;

    while (true) {
        const line = stdin_reader.takeDelimiter('\n') catch |err| {
            if (err == error.StreamTooLong) {
                // Oversize line: drain it, report Invalid Request, stay alive.
                drainLine(stdin_reader, line_buf.len);
                try respondParseError(allocator, stdout);
                continue;
            }
            return err;
        } orelse break; // null = clean EOF on stdin -> shutdown per ACP spec.

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "shutdown")) break;

        handleLine(allocator, io, &ag, trimmed, stdout, stderr) catch |err| {
            stderr.print("handle error: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
        };
        stdout.flush() catch {};
    }
    stdout.flush() catch {};
}

/// Discard the rest of an overlong line (and its newline) to resync framing.
fn drainLine(reader: *std.Io.Reader, cap: usize) void {
    var total: usize = 0;
    while (total < 16 * 1024 * 1024) {
        if (reader.takeDelimiter('\n')) |maybe| {
            _ = maybe;
            break; // delimiter consumed (or EOF) — resynced.
        } else |err| {
            if (err == error.StreamTooLong) {
                total += reader.discard(.limited(cap)) catch break;
                continue;
            }
            break;
        }
    }
}

fn respondParseError(allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const msg = try acp.failure(arena.allocator(), .null_id, acp.ERR_PARSE, "Parse error");
    try acp.writeMessage(stdout, msg);
    try stdout.flush();
}

fn handleLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    ag: *agent_mod.Agent,
    line: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // Per-message arena keeps steady-state memory flat.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch {
        const msg = try acp.failure(a, .null_id, acp.ERR_PARSE, "Parse error");
        try acp.writeMessage(stdout, msg);
        try stdout.flush();
        return;
    };

    const root = parsed.value;
    if (root != .object) {
        const msg = try acp.failure(a, .null_id, acp.ERR_INVALID_REQUEST, "Invalid Request: object expected");
        try acp.writeMessage(stdout, msg);
        try stdout.flush();
        return;
    }
    const obj = root.object;

    // ACP forbids batches: a top-level array would have failed the object
    // check above with Invalid Request.

    const id = acp.Id.fromValue(if (obj.get("id")) |v| v else null);
    const has_id = obj.get("id") != null;
    const method_val = obj.get("method");
    const method: ?[]const u8 = if (method_val) |m| (if (m == .string) m.string else null) else null;
    const params = obj.get("params");

    // Response to something we sent (has result/error, no method): ignore.
    if (method == null) return;

    const m = method.?;

    if (std.mem.eql(u8, m, "initialize")) {
        const result = try ag.handleInitialize(a, params);
        const msg = try acp.success(a, id, result);
        try acp.writeMessage(stdout, msg);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, m, "session/new")) {
        const result = try ag.handleSessionNew(a, params);
        const msg = try acp.success(a, id, result);
        try acp.writeMessage(stdout, msg);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, m, "session/prompt")) {
        const info = agent_mod.Agent.parsePrompt(params);
        if (info.session_id.len == 0) {
            const msg = try acp.failure(a, id, acp.ERR_INVALID_PARAMS, "Missing sessionId");
            try acp.writeMessage(stdout, msg);
            try stdout.flush();
            return;
        }
        if (ag.sessions.get(info.session_id) == null) {
            const msg = try acp.failure(a, id, acp.ERR_INVALID_PARAMS, "Unknown session");
            try acp.writeMessage(stdout, msg);
            try stdout.flush();
            return;
        }
        // Run + stream one chunk (scaffold: single-shot exec).
        const output = ag.runPrompt(io, info.text) catch |err| {
            stderr.print("exec failed: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
            const msg = try acp.failure(a, id, acp.ERR_INTERNAL, "exec failed");
            try acp.writeMessage(stdout, msg);
            try stdout.flush();
            return;
        };
        defer allocator.free(output);

        // 1) session/update notification
        const chunk_params = try ag.updateChunk(a, info.session_id, output);
        const notif = try acp.notification(a, "session/update", chunk_params);
        try acp.writeMessage(stdout, notif);

        // 2) prompt result
        var meta = try acp.newObject(a);
        // stopReason per ACP v1: end_turn | max_tokens | max_turn_requests | refused | cancelled
        try acp.objPut(&meta, a, "stopReason", .{ .string = "end_turn" });
        const msg = try acp.success(a, id, .{ .object = meta });
        try acp.writeMessage(stdout, msg);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, m, "session/cancel") or std.mem.eql(u8, m, "$/cancel_request")) {
        // Scaffold: single-shot exec is not preemptible; ack immediately.
        var ok = try acp.newObject(a);
        try acp.objPut(&ok, a, "ok", .{ .bool = true });
        if (has_id) {
            const msg = try acp.success(a, id, .{ .object = ok });
            try acp.writeMessage(stdout, msg);
        }
        try stdout.flush();
        return;
    }

    // Unknown method -> Method not found (only if it was a request).
    if (has_id) {
        const msg = try acp.failure(a, id, acp.ERR_METHOD_NOT_FOUND, "Method not found");
        try acp.writeMessage(stdout, msg);
        try stdout.flush();
    }
}

test {
    // Pull in acp + agent unit tests via `zig build test`.
    _ = @import("acp.zig");
    _ = @import("agent.zig");
}
