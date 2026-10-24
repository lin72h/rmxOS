// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
    @cInclude("asl.h");
    @cInclude("notify.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("pthread.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn op_add(i64, *i64) i64;
extern fn op_lock() void;
extern fn op_unlock() void;

extern fn op_inc(*i32, c_int) i32;
extern fn op_dec(*i32, c_int) i32;
extern fn op_bit(c_uint, *anyopaque) c_int;
extern fn op_cas32(i32, i32, *i32) c_int;
extern fn op_caslong(c_long, c_long, *c_long) c_int;
fn arithmetic() !void {
    for (0..2) |b| {
        var v: i32 = 1;
        try std.testing.expectEqual(@as(i32, 2), op_inc(&v, @intCast(b)));
        try std.testing.expectEqual(@as(i32, 1), op_dec(&v, @intCast(b)));
    }
}
fn bits() !void {
    for (0..64) |n| {
        var v: [12]u8 = @splat(0);
        v[0] = 0xa5;
        v[1] = 0x5a;
        v[10] = 0xa5;
        v[11] = 0x5a;
        try std.testing.expectEqual(@as(c_int, 0), op_bit(@intCast(n), @ptrCast(&v[2])));
        try std.testing.expectEqual(@as(c_int, 1), op_bit(@intCast(n), @ptrCast(&v[2])));
        for (v[2..10], 0..) |byte, i| try std.testing.expectEqual(if (i == n / 8) @as(u8, 0x80) >> @as(u3, @intCast(n & 7)) else @as(u8, 0), byte);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0x5a }, v[0..2]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0x5a }, v[10..12]);
    }
}
fn swaps() !void {
    var v: i32 = 3;
    var w: c_long = 3;
    try std.testing.expectEqual(@as(c_int, 0), op_cas32(2, 9, &v));
    try std.testing.expectEqual(@as(c_int, 1), op_cas32(3, 9, &v));
    try std.testing.expectEqual(@as(i32, 9), v);
    try std.testing.expectEqual(@as(c_int, 0), op_caslong(2, 9, &w));
    try std.testing.expectEqual(@as(c_int, 1), op_caslong(3, 9, &w));
    try std.testing.expectEqual(@as(c_long, 9), w);
}

var protected_count: u64 = 0;
fn worker(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    for (0..15000) |_| {
        op_lock();
        protected_count += 1;
        op_unlock();
    }
    return null;
}
fn semantics(_: [*c]const c.atf_tc_t) callconv(.c) void {
    arithmetic() catch c.atf_tc_fail("atomic arithmetic result");
    bits() catch c.atf_tc_fail("atomic Apple bit numbering or guard");
    swaps() catch c.atf_tc_fail("atomic CAS contract");
    var guard = extern struct { before: u64, value: i64, after: u64 }{ .before = 0x123456789abcdef0, .value = 0x100000001, .after = 0xfedcba9876543210 };
    if (op_add(3, &guard.value) != 0x100000004 or op_add(-4, &guard.value) != 0x100000000 or guard.value != 0x100000000 or guard.before != 0x123456789abcdef0 or guard.after != 0xfedcba9876543210) c.atf_tc_fail("64-bit add result or adjacent guard");
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork lock bounded test");
    if (pid == 0) {
        var threads: [4]c.pthread_t = undefined;
        for (&threads) |*thread| if (c.pthread_create(thread, null, worker, null) != 0) c._exit(2);
        for (threads) |thread| if (c.pthread_join(thread, null) != 0) c._exit(3);
        c._exit(if (protected_count == 60000) 0 else 4);
    }
    var status: c_int = 0;
    var done = false;
    for (0..1000) |_| {
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
            done = true;
            break;
        }
        _ = c.usleep(1000);
    }
    if (!done) {
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, &status, 0);
    }
    if (!done or status != 0) c.atf_tc_fail("lock exclusion/forward progress status=%d", status);
}
extern fn mallctl([*:0]const u8, ?*anyopaque, ?*usize, ?*anyopaque, usize) c_int;
extern fn asl_string_new(u32) ?*anyopaque;
extern fn asl_string_append(?*anyopaque, [*:0]const u8) ?*anyopaque;
extern fn asl_string_release(?*anyopaque) void;
fn allocated() !usize {
    var epoch: u64 = 1;
    var size: usize = @sizeOf(u64);
    try std.testing.expectEqual(@as(c_int, 0), mallctl("epoch", &epoch, &size, &epoch, @sizeOf(u64)));
    var value: usize = 0;
    size = @sizeOf(usize);
    try std.testing.expectEqual(@as(c_int, 0), mallctl("stats.allocated", &value, &size, null, 0));
    return value;
}
fn cycle(n: usize) !void {
    for (0..n) |_| {
        const str = asl_string_new(0) orelse return error.NoMemory;
        try std.testing.expect(asl_string_append(str, "one retained string with bounded lifetime") != null);
        asl_string_release(str);
        const msg = c.asl_new(c.ASL_TYPE_MSG) orelse return error.NoMemory;
        try std.testing.expectEqual(@as(c_int, 0), c.asl_set(msg, "Message", "released message"));
        const list = c.asl_new(c.ASL_TYPE_LIST) orelse return error.NoMemory;
        c.asl_append(list, msg);
        c.asl_release(msg);
        c.asl_release(list);
    }
}
fn flat() !void {
    try cycle(1000);
    const before = try allocated();
    try cycle(50000);
    const after = try allocated();
    _ = c.printf("asl_release expected_max_growth=1048576 before=%zu after=%zu\n", before, after);
    try std.testing.expect(after <= before + 1048576);
}

fn releaseFlat(_: [*c]const c.atf_tc_t) callconv(.c) void {
    flat() catch c.atf_tc_fail("ASL release memory growth");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "30");
}
fn tokenIds(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var token: c_int = -1;
    if (c.notify_register_check("self.op803.atomic.first", &token) != 0 or token != 1) c.atf_tc_fail("first token expected=1 observed=%d", token);
    if (c.notify_cancel(token) != 0) c.atf_tc_fail("cancel first token");
}
var cases: [3]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "semantics", "release_flat", "token_ids" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ semantics, releaseFlat, tokenIds };
    for (&cases, names, bodies) |*tc, name, body| {
        var err = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
