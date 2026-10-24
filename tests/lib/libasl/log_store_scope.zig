// Test-side ASL reads: current-case tail for live observations, current boot
// for boot history. Never rerun an unbounded historical scan in a poll.
const std = @import("std");
// ATF callbacks have no process.Init; their file operations are synchronous.
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("asl.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("sys/time.h");
    @cInclude("sys/sysctl.h");
});
const a = std.heap.page_allocator;
var floor: usize = 0;
fn storePath() [*:0]const u8 {
    return if (c.getenv("RMX_ASL_TEST_STORE")) |p| p else "/var/log/asl";
}
fn z(s: []const u8) [:0]const u8 {
    return a.dupeZ(u8, s) catch unreachable;
}
pub fn begin() void {
    const store = c.asl_open_path(storePath(), 0) orelse @panic("open ASL scope");
    defer c.asl_release(store);
    var last: usize = 0;
    const result = c.asl_match(store, null, &last, std.math.maxInt(usize), 1, 100000, -1);
    defer c.asl_release(result);
    floor = last;
}
pub fn query(key: []const u8, value: []const u8, prefix: bool, boot: bool) []const u8 {
    const store = c.asl_open_path(storePath(), 0) orelse @panic("open scoped ASL reader");
    defer c.asl_release(store);
    const q = c.asl_new(c.ASL_TYPE_QUERY) orelse unreachable;
    defer c.asl_release(q);
    const list = c.asl_new(c.ASL_TYPE_LIST) orelse unreachable;
    defer c.asl_release(list);
    if (c.asl_set_query(q, z(key), z(value), @intCast(c.ASL_QUERY_OP_EQUAL | @as(c_int, if (prefix) c.ASL_QUERY_OP_PREFIX else 0))) != 0) @panic("ASL query key");
    if (boot) {
        var started: c.struct_timeval = undefined;
        var size: usize = @sizeOf(c.struct_timeval);
        if (c.sysctlbyname("kern.boottime", &started, &size, null, 0) != 0) @panic("boot time");
        var buf: [32]u8 = undefined;
        const stamp = std.fmt.bufPrintZ(&buf, "{d}", .{started.tv_sec}) catch unreachable;
        if (c.asl_set_query(q, "Time", stamp, c.ASL_QUERY_OP_NUMERIC | c.ASL_QUERY_OP_GREATER_EQUAL) != 0) unreachable;
    }
    c.asl_append(list, q);
    // A matching boundary record terminates an absent-tail search without
    // walking the older store. It is discarded, never treated as a match.
    if (!boot and floor != 0) {
        const boundary = c.asl_new(c.ASL_TYPE_QUERY) orelse unreachable;
        defer c.asl_release(boundary);
        var buf: [32]u8 = undefined;
        const id = std.fmt.bufPrintZ(&buf, "{d}", .{floor}) catch unreachable;
        if (c.asl_set_query(boundary, "ASLMessageID", id, c.ASL_QUERY_OP_NUMERIC | c.ASL_QUERY_OP_LESS_EQUAL) != 0) unreachable;
        c.asl_append(list, boundary);
    }
    var strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (strings.items) |s| a.free(s);
        strings.deinit(a);
    }
    var start: usize = std.math.maxInt(usize);
    while (true) {
        var last: usize = 0;
        const result = c.asl_match(store, list, &last, start, 1024, 100000, -1);
        defer c.asl_release(result);
        var stop = false;
        while (c.asl_next(result)) |message| {
            // List iteration returns borrowed messages, unlike store iteration.
            const id = c.asl_get(message, "ASLMessageID") orelse @panic("record ID");
            const number = std.fmt.parseInt(usize, std.mem.span(id), 10) catch unreachable;
            if (!boot and number <= floor) {
                stop = true;
                break;
            }
            const raw = c.asl_format(message, "raw", "sec", 0) orelse @panic("format ASL");
            defer c.free(raw);
            strings.append(a, a.dupe(u8, std.mem.span(raw)) catch unreachable) catch unreachable;
        }
        if (stop or last == 0 or last >= start or last == 1) break;
        start = last - 1;
    }
    var out: std.ArrayList(u8) = .empty;
    var i = strings.items.len;
    while (i > 0) {
        i -= 1;
        out.appendSlice(a, strings.items[i]) catch unreachable;
        out.append(a, '\n') catch unreachable;
    }
    return out.toOwnedSlice(a) catch unreachable;
}

extern fn asl_store_open_write([*:0]const u8, *?*anyopaque) u32;
extern fn asl_store_save(?*anyopaque, c.asl_object_t) u32;
extern fn asl_store_close(?*anyopaque) u32;
test "old boot records are excluded and current duplicates remain visible" {
    var path = "op942-scope-XXXXXX".* ++ [_]u8{0};
    try std.testing.expect(c.mkdtemp(@ptrCast(&path)) != null);
    defer std.Io.Dir.cwd().deleteTree(io, std.mem.sliceTo(&path, 0)) catch {};
    try std.testing.expectEqual(@as(c_int, 0), c.setenv("RMX_ASL_TEST_STORE", @ptrCast(&path), 1));
    defer _ = c.unsetenv("RMX_ASL_TEST_STORE");
    var writer: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), asl_store_open_write(@ptrCast(&path), &writer));
    const m = c.asl_new(c.ASL_TYPE_MSG);
    defer c.asl_release(m);
    try std.testing.expectEqual(@as(c_int, 0), c.asl_set(m, "Message", "banner"));
    try std.testing.expectEqual(@as(c_int, 0), c.asl_set(m, "Time", "1"));
    try std.testing.expectEqual(@as(u32, 0), asl_store_save(writer, m));
    try std.testing.expectEqual(@as(u32, 0), asl_store_close(writer));
    begin();
    const absent = query("Message", "banner", false, false);
    defer a.free(absent);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, absent, "[Message banner]"));
    try std.testing.expectEqual(@as(u32, 0), asl_store_open_write(@ptrCast(&path), &writer));
    try std.testing.expectEqual(@as(c_int, 0), c.asl_set(m, "Time", "2000000000"));
    for (0..2) |_| try std.testing.expectEqual(@as(u32, 0), asl_store_save(writer, m));
    try std.testing.expectEqual(@as(u32, 0), asl_store_close(writer));
    const boot_records = query("Message", "banner", false, true);
    defer a.free(boot_records);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, boot_records, "[Message banner]"));
    const tail = query("Message", "banner", false, false);
    defer a.free(tail);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, tail, "[Message banner]"));
}
