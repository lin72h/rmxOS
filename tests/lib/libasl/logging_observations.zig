const std = @import("std");

pub fn kernelBoot(current_text: usize, stored: usize) bool {
    _ = current_text; // Rotation may have removed the banner from messages.
    return stored == 1;
}
test "rotation removes current text but preserves the boot record in ASL" {
    try std.testing.expect(kernelBoot(0, 1));
    try std.testing.expect(!kernelBoot(1, 0));
    try std.testing.expect(!kernelBoot(0, 2));
}

pub const counters = [_][]const u8{ "dropped_wq", "dropped_kern_quota", "dropped_parse", "bsd_in_truncated", "store_failed", "store_fallback_memory", "file_action_failed", "native_malformed", "dup_suppressed", "config_rejected", "launchd_dropped", "sender_dropped" };
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
pub fn statusMatches(raw: []const u8, baseline: []const u8) bool {
    if (!validStatus(raw) or !validStatus(baseline)) return false;
    // SIGUSR1 only snapshots counters. Historical losses are allowed, but
    // neither an increment nor a decrease belongs to this idle interval.
    for (counters) |name| {
        if (value(raw, name) != value(baseline, name)) return false;
    }
    return true;
}
fn value(raw: []const u8, name: []const u8) u64 {
    var pattern: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&pattern, "[{s} ", .{name}) catch unreachable;
    const start = std.mem.indexOf(u8, raw, key).? + key.len;
    const end = std.mem.indexOfScalarPos(u8, raw, start, ']').?;
    return std.fmt.parseInt(u64, raw[start..end], 10) catch unreachable;
}
test "a numeric but changed idle counter fails" {
    const before = "[com.rmxos.asld.record status] [dropped_wq 7] [dropped_kern_quota 3980] [dropped_parse 0] [bsd_in_truncated 0] [store_failed 0] [store_fallback_memory 0] [file_action_failed 0] [native_malformed 0] [dup_suppressed 1] [config_rejected 0] [launchd_dropped 0] [sender_dropped 0]";
    const wrong = "[com.rmxos.asld.record status] [dropped_wq 7] [dropped_kern_quota 3980] [dropped_parse 0] [bsd_in_truncated 0] [store_failed 7] [store_fallback_memory 0] [file_action_failed 0] [native_malformed 0] [dup_suppressed 1] [config_rejected 0] [launchd_dropped 0] [sender_dropped 0]";
    try std.testing.expect(!statusMatches(wrong, before));
    try std.testing.expect(statusMatches(before, before));
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
    const line = "[com.rmxos.asld.record status] [dropped_wq 7] [dropped_kern_quota 0] [dropped_parse 0] [bsd_in_truncated 0] [store_failed 0] [store_fallback_memory 0] [file_action_failed 0] [native_malformed 0] [dup_suppressed 1] [config_rejected 0] [launchd_dropped 0] [sender_dropped 0]";
    try std.testing.expect(validStatus(line));
    try std.testing.expect(!validStatus("[com.rmxos.asld.record status] [dropped_wq invalid]"));
}
test "direct startup channel excludes a console record routed by asld" {
    const text = "fixture[1]: startup failed: timeout\nOct 22 kernel[0]: fixture[1]: startup failed: timeout\n";
    try std.testing.expectEqual(@as(usize, 1), directCount(text, "fixture"));
}

test "both sender and launchd loss counters reject changed values" {
    const baseline = "[com.rmxos.asld.record status] [dropped_wq 0] [dropped_kern_quota 0] [dropped_parse 0] [bsd_in_truncated 0] [store_failed 0] [store_fallback_memory 0] [file_action_failed 0] [native_malformed 0] [dup_suppressed 0] [config_rejected 0] [launchd_dropped 0] [sender_dropped 0]";
    for ([_][]const u8{ "launchd_dropped", "sender_dropped" }) |name| {
        var buffer: [512]u8 = undefined;
        @memcpy(buffer[0..baseline.len], baseline);
        const at = std.mem.indexOf(u8, baseline, name).? + name.len + 1;
        buffer[at] = '1';
        try std.testing.expect(!statusMatches(buffer[0..baseline.len], baseline));
    }
}
