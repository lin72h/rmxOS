const std = @import("std");
const checks = @import("checks.zig");
const c = @cImport({
    @cInclude("os/log.h");
    @cInclude("stdlib.h");
    @cInclude("pthread.h");
    @cInclude("dlfcn.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/ktrace.h");
    @cInclude("unistd.h");
});
pub export var __libc_syslog_mutex: c.pthread_mutex_t = null;
pub export fn __sys_task_self_trap() u32 {
    @panic("host test entered Mach transport");
}
pub export fn __sys_mach_reply_port() u32 {
    @panic("host test entered Mach transport");
}
pub export fn __sys__kernelrpc_mach_port_deallocate_trap(_: u32, _: u32) c_int {
    @panic("host test entered Mach transport");
}
pub export fn __sys__kernelrpc_mach_port_destroy_trap(_: u32, _: u32) c_int {
    @panic("host test entered Mach transport");
}
pub export fn __sys_mach_msg_trap(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32) c_int {
    @panic("host test entered Mach transport");
}
extern var _os_log_default: u8;
extern var _os_log_disabled: u8;
const default: c.os_log_t = @ptrCast(&_os_log_default);
const disabled: c.os_log_t = @ptrCast(&_os_log_disabled);
extern fn api_emit(c.os_log_t, c.os_log_type_t, [*:0]const u8, [*:0]const u8) void;
extern fn api_five(c.os_log_t) void;
extern fn api_wide(c.os_log_t) void;
extern fn api_once(c.os_log_t, *c_int) void;
var records: std.ArrayList([]u8) = .empty;
const allocator = std.heap.page_allocator;
pub export fn __libc_asl_send(record: [*:0]const u8) c_int {
    const copy = allocator.dupe(u8, std.mem.span(record)) catch return -1;
    records.append(allocator, copy) catch return -1;
    return 0;
}
fn clear() void {
    for (records.items) |r| allocator.free(r);
    records.clearRetainingCapacity();
}
fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}
fn field(record: []const u8, key: []const u8) ![]const u8 {
    const prefix = try std.fmt.allocPrint(allocator, "[{s} ", .{key});
    defer allocator.free(prefix);
    var p = (std.mem.indexOf(u8, record, prefix) orelse return error.FieldMissing) + prefix.len;
    var out: std.ArrayList(u8) = .empty;
    while (p < record.len and record[p] != ']') : (p += 1) {
        var ch = record[p];
        if (ch == '\\') {
            p += 1;
            if (p == record.len) return error.Escape;
            if (p + 2 < record.len and eq(record[p .. p + 3], "000")) {
                p += 2;
                continue;
            }
            ch = switch (record[p]) {
                'n' => '\n',
                'r' => '\r',
                else => record[p],
            };
        }
        try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
}
fn replay(format: [*:0]const u8, bytes: []const u8, kind: c_uint, op: u32) void {
    const is_default = std.mem.indexOf(u8, std.mem.span(format), "fields") != null and records.items.len >= 13 and records.items.len < 21;
    const log = if (is_default) default else c.os_log_create(if (op == 963) "org.rmxos.op963" else "org.rmxos.op970", "test");
    c._os_log_impl(null, log, @intCast(kind), format, bytes.ptr, @intCast(bytes.len));
}
test "public API byte-exact replay of all 74 oracle rows" {
    defer clear();
    checks.emit_hook = replay;
    defer checks.emit_hook = null;
    try checks.oracle();
    const Row = struct { eventMessage: []const u8, formatString: []const u8, messageType: []const u8, op: u32 };
    const parsed = try std.json.parseFromSlice([]Row, allocator, @embedFile("oracle.json"), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 74), records.items.len);
    for (records.items, parsed.value) |r, row| {
        try std.testing.expectEqualStrings(row.eventMessage, try field(r, "Message"));
        try std.testing.expectEqualStrings(row.formatString, try field(r, "org.rmxos.logd.formatString"));
        const kind = if (eq(row.messageType, "Info")) "1" else if (eq(row.messageType, "Error")) "16" else if (eq(row.messageType, "Fault")) "17" else "0";
        try std.testing.expectEqualStrings(kind, try field(r, "org.rmxos.logd.type"));
        const default_log = has(row.eventMessage, "log=OS_LOG_DEFAULT");
        try std.testing.expectEqualStrings(if (default_log) "" else if (row.op == 963) "org.rmxos.op963" else "org.rmxos.op970", try field(r, "org.rmxos.logd.subsystem"));
        try std.testing.expectEqualStrings(if (default_log) "" else "test", try field(r, "org.rmxos.logd.category"));
    }
}
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
test "objects enablement and five macros" {
    defer clear();
    const a = c.os_log_create("org.rmxos.api", "test");
    const b = c.os_log_create("org.rmxos.api", "test");
    try std.testing.expect(a != null and a == b);
    try std.testing.expect(c.os_retain(a) == @as(?*anyopaque, @ptrCast(a)));
    c.os_release(a);
    try std.testing.expect(c.os_retain(default) == @as(?*anyopaque, @ptrCast(default)));
    c.os_release(default);
    c.os_release(disabled);
    try std.testing.expect(a != c.os_log_create("org.rmxos.api", "other"));
    for ([_]u8{ 0, 1, 16, 17 }) |kind| {
        try std.testing.expect(c.os_log_type_enabled(a, kind));
        try std.testing.expect(c.os_log_type_enabled(default, kind));
        try std.testing.expect(!c.os_log_type_enabled(disabled, kind));
    }
    try std.testing.expect(!c.os_log_type_enabled(a, 2));
    api_five(a);
    try std.testing.expectEqual(@as(usize, 4), records.items.len);
    for (records.items, [_][]const u8{ "0", "1", "16", "17" }) |r, kind| {
        const expected = try std.fmt.allocPrint(allocator, "[org.rmxos.logd.type {s}]", .{kind});
        defer allocator.free(expected);
        try std.testing.expect(has(r, expected));
        try std.testing.expect(has(r, "[org.rmxos.logd.subsystem org.rmxos.api]"));
        try std.testing.expect(has(r, "[org.rmxos.logd.category test]"));
        for ([_][]const u8{ "threadID", "machTimestamp", "senderImagePath", "senderImageBuildID", "senderImagePC", "traceID", "formatString" }) |key| {
            const prefix = try std.fmt.allocPrint(allocator, "[org.rmxos.logd.{s} ", .{key});
            defer allocator.free(prefix);
            try std.testing.expect(has(r, prefix));
        }
    }
    api_five(disabled);
    try std.testing.expectEqual(@as(usize, 4), records.items.len);
}
test "random canary is redacted before transport and default fields are empty" {
    defer clear();
    var random: [24]u8 = undefined;
    c.arc4random_buf(&random, random.len);
    const private = try std.fmt.allocPrintSentinel(allocator, "private-{x}", .{random}, 0);
    defer allocator.free(private);
    const public = try std.fmt.allocPrintSentinel(allocator, "public-{x}", .{random}, 0);
    defer allocator.free(public);
    api_emit(default, 1, private, public);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    const r = records.items[0];
    try std.testing.expect(!has(r, private));
    try std.testing.expect(has(r, public));
    try std.testing.expect(has(r, "<private>"));
    try std.testing.expect(has(r, "[org.rmxos.logd.subsystem \\000]"));
    try std.testing.expect(has(r, "[org.rmxos.logd.category \\000]"));
}
test "unsupported capital S and malformed buffers send no record" {
    defer clear();
    api_wide(default);
    var bytes = [_]u8{ 0, 1, 0, 8, 1 };
    c._os_log_impl(null, default, 0, "%d", &bytes, bytes.len);
    try std.testing.expectEqual(@as(usize, 0), records.items.len);
    const invalid_pointer = [_]u8{ 2, 1, 0x22, 8, 1, 0, 0, 0, 0, 0, 0, 0 };
    c._os_log_impl(null, default, 0, "%{public}s", &invalid_pointer, invalid_pointer.len);
    try std.testing.expectEqual(@as(usize, 0), records.items.len);
}
test "enabled arguments evaluate once and disabled arguments never evaluate" {
    defer clear();
    var value: c_int = 0;
    api_once(disabled, &value);
    try std.testing.expect(value == 0 and records.items.len == 0);
    api_once(default, &value);
    try std.testing.expect(value == 1 and records.items.len == 1);
}
test "generic retain delegates to a runtime loaded after process startup" {
    const handle = c.dlopen("generic_runtime.so", c.RTLD_NOW | c.RTLD_GLOBAL);
    try std.testing.expect(handle != null);
    defer _ = c.dlclose(handle);
    const Object = extern struct { isa: ?*anyopaque = null, refs: c_int = 0, xrefs: c_int = 0 };
    var object: Object = .{};
    try std.testing.expect(c.os_retain(&object) == @as(?*anyopaque, @ptrCast(&object)));
    try std.testing.expect(object.xrefs == 1);
    c.os_release(&object);
    try std.testing.expect(object.xrefs == 0);
}

fn publicString(text: [*]const u8) [12]u8 {
    var buffer = [_]u8{ 2, 1, 0x22, 8, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, buffer[4..12], @intFromPtr(text), .little);
    return buffer;
}

fn logPublicString(text: [*]const u8) void {
    const buffer = publicString(text);
    c._os_log_impl(null, default, 0, "%{public}s", &buffer, buffer.len);
}

test "op697 guarded capture" {
    defer clear();
    const page: usize = @intCast(c.getpagesize());
    const mapping = c.mmap(null, page * 2, c.PROT_READ | c.PROT_WRITE, c.MAP_ANON | c.MAP_PRIVATE, -1, 0);
    try std.testing.expect(mapping != c.MAP_FAILED);
    defer _ = c.munmap(mapping, page * 2);
    const bytes: [*]u8 = @ptrCast(mapping.?);
    try std.testing.expectEqual(@as(c_int, 0), c.mprotect(bytes + page, page, c.PROT_NONE));
    @memcpy(bytes[page - 4 .. page], "abc\x00");
    logPublicString(bytes + page - 4);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqualStrings("abc", try field(records.items[0], "Message"));
    bytes[page - 1] = 'd';
    const pointer = bytes + page - 4;
    var buffer = [_]u8{ 2, 2, 0x10, 4, 4, 0, 0, 0, 0x22, 8, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, buffer[10..18], @intFromPtr(pointer), .little);
    c._os_log_impl(null, default, 0, "%{public}.4s", &buffer, buffer.len);
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqualStrings("abcd", try field(records.items[1], "Message"));
    logPublicString(pointer);
    logPublicString(bytes + page);
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqual(@as(c_int, 0), c.mprotect(bytes + page, page, c.PROT_READ | c.PROT_WRITE));
    @memcpy(bytes[page .. page + 4], "xyz\x00");
    logPublicString(pointer);
    try std.testing.expectEqual(@as(usize, 3), records.items.len);
    try std.testing.expectEqualStrings("abcdxyz", try field(records.items[2], "Message"));
}

const page_sample: [200:0]u8 align(4096) = @splat('x');
fn mark(comptime message: [:0]const u8) void {
    _ = c.utrace(message.ptr, message.len);
}

test "op697 syscall trace" {
    defer clear();
    mark("op697 string begin");
    logPublicString(&page_sample);
    mark("op697 string end");
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqualStrings(&page_sample, try field(records.items[0], "Message"));

    mark("op697 literal begin");
    const buffer = [_]u8{ 0, 0 };
    c._os_log_impl(null, default, 0, "literal", &buffer, buffer.len);
    mark("op697 literal end");
    try std.testing.expectEqual(@as(usize, 2), records.items.len);

    mark("op697 refusals begin");
    const malformed = [_]u8{ 0, 1, 0, 8, 1 };
    c._os_log_impl(null, default, 0, "%d", &malformed, malformed.len);
    logPublicString(@ptrFromInt(1));
    mark("op697 refusals end");
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
}

fn expectRedactedMessage(which: c_uint) !void {
    defer clear();
    var sample: checks.c.struct_codec_sample = undefined;
    checks.c.fixture_op697(which, &sample);
    c._os_log_impl(null, default, 0, sample.format, &sample.bytes, @intCast(sample.size));
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    const message = try field(records.items[0], "Message");
    defer allocator.free(message);
    try std.testing.expectEqualStrings("42 [<private>] visible", message);
}

test "op697 mask keeps the API record" {
    try expectRedactedMessage(4);
}
test "op697 private dynamic precision keeps the API record" {
    try expectRedactedMessage(5);
}
