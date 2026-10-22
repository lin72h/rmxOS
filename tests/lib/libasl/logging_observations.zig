const std = @import("std");

pub const counters = [_][]const u8{ "dropped_wq", "dropped_kern_quota", "dropped_parse", "bsd_in_truncated", "store_failed", "store_fallback_memory", "file_action_failed", "native_malformed", "dup_suppressed", "config_rejected" };
pub fn validStatus(raw: []const u8) bool {
    if (std.mem.count(u8, raw, "[com.rmxos.asld.record status]") != 1) return false;
    for (counters) |name| {
        var pattern: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&pattern, "[{s} ", .{name}) catch return false;
        const start = (std.mem.indexOf(u8, raw, key) orelse return false) + key.len;
        if (std.mem.count(u8, raw, key) != 1) return false;
        const end = std.mem.indexOfScalarPos(u8, raw, start, ']') orelse return false;
        _ = std.fmt.parseInt(u64, raw[start..end], 10) catch return false;
    }
    return true;
}
pub fn newestStatus(raw: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "[com.rmxos.asld.record status]") != null) result = line;
    }
    return result;
}
pub fn directCount(raw: []const u8, token: []const u8) usize {
    var result: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, token) and line.len > token.len and line[token.len] == '[') result += 1;
    }
    return result;
}
test "fresh status accepts accumulated drops and ignores older status" {
    const line = "[com.rmxos.asld.record status] [dropped_wq 7] [dropped_kern_quota 0] [dropped_parse 0] [bsd_in_truncated 0] [store_failed 0] [store_fallback_memory 0] [file_action_failed 0] [native_malformed 0] [dup_suppressed 1] [config_rejected 0]";
    try std.testing.expect(validStatus(line));
    try std.testing.expect(!validStatus("[com.rmxos.asld.record status] [dropped_wq invalid]"));
}
test "direct startup channel excludes a console record routed by asld" {
    const text = "fixture[1]: startup failed: timeout\nOct 22 kernel[0]: fixture[1]: startup failed: timeout\n";
    try std.testing.expectEqual(@as(usize, 1), directCount(text, "fixture"));
}
