// acp.zig — minimal Agent Client Protocol (agentclientprotocol.com) framing.
//
// Transport: JSON-RPC 2.0 over stdio, newline-delimited.
//   stdin  <- client requests/notifications (one JSON object per line)
//   stdout -> agent responses/notifications (one JSON object per line)
//   stderr -> free-form UTF-8 logs (never ACP messages)
//
// This file intentionally stays dependency-free and small:
// no async, no threads, fixed line buffer + page allocator for bodies.
// Keep it that way — binary size is the priority for this harness.

const std = @import("std");

/// Max single JSON-RPC line we accept. ACP forbids embedded newlines,
/// so a bounded line reader is both spec-correct and size-friendly.
pub const max_line: usize = 256 * 1024;

/// Write one JSON value as a single line to stdout.
/// Direct stringify into the writer: no intermediate buffer, no extra deps.
pub fn writeMessage(stdout: *std.Io.Writer, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, stdout);
    try stdout.writeAll("\n");
}

/// Write a raw pre-stringified JSON line (already validated, no newline).
pub fn writeRawLine(stdout: *std.Io.Writer, line: []const u8) !void {
    try stdout.writeAll(line);
    try stdout.writeAll("\n");
}

/// JSON-RPC id: number | string | null (no batches in ACP).
pub const Id = union(enum) {
    num: i64,
    str: []const u8,
    null_id,

    pub fn toValue(self: Id) std.json.Value {
        return switch (self) {
            .num => |n| .{ .integer = n },
            .str => |s| .{ .string = s },
            .null_id => .null,
        };
    }

    pub fn fromValue(v: ?std.json.Value) Id {
        const val = v orelse return .null_id;
        return switch (val) {
            .integer => |n| .{ .num = n },
            .string => |s| .{ .str = s },
            .null => .null_id,
            else => .null_id,
        };
    }
};

/// Empty JSON object. (0.17 ObjectMap is unmanaged: init needs explicit
/// empty key/value lists; put/deinit take the allocator each call.)
pub fn newObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return std.json.ObjectMap.init(allocator, &.{}, &.{});
}

pub fn objPut(
    m: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
) !void {
    try m.put(allocator, key, value);
}

/// Success envelope: {"jsonrpc":"2.0","id":…,"result":…}
pub fn success(allocator: std.mem.Allocator, id: Id, result: std.json.Value) !std.json.Value {
    var obj = try newObject(allocator);
    try objPut(&obj, allocator, "jsonrpc", .{ .string = "2.0" });
    try objPut(&obj, allocator, "id", id.toValue());
    try objPut(&obj, allocator, "result", result);
    return .{ .object = obj };
}

/// Error envelope: {"jsonrpc":"2.0","id":…,"error":{"code":…,"message":…}}
pub fn failure(allocator: std.mem.Allocator, id: Id, code: i64, message: []const u8) !std.json.Value {
    var err = try newObject(allocator);
    try objPut(&err, allocator, "code", .{ .integer = code });
    try objPut(&err, allocator, "message", .{ .string = message });
    var obj = try newObject(allocator);
    try objPut(&obj, allocator, "jsonrpc", .{ .string = "2.0" });
    try objPut(&obj, allocator, "id", id.toValue());
    try objPut(&obj, allocator, "error", .{ .object = err });
    return .{ .object = obj };
}

/// Notification envelope (no id): {"jsonrpc":"2.0","method":…,"params":…}
pub fn notification(allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) !std.json.Value {
    var obj = try newObject(allocator);
    try objPut(&obj, allocator, "jsonrpc", .{ .string = "2.0" });
    try objPut(&obj, allocator, "method", .{ .string = method });
    try objPut(&obj, allocator, "params", params);
    return .{ .object = obj };
}

// Standard JSON-RPC error codes (ACP uses these, no batches allowed).
pub const ERR_PARSE: i64 = -32700;
pub const ERR_INVALID_REQUEST: i64 = -32600;
pub const ERR_METHOD_NOT_FOUND: i64 = -32601;
pub const ERR_INVALID_PARAMS: i64 = -32602;
pub const ERR_INTERNAL: i64 = -32603;

test "id round-trip" {
    const t = std.testing;
    try t.expect((Id{ .num = 7 }).toValue().integer == 7);
    try t.expect(Id.fromValue(null) == .null_id);
}
