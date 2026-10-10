// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const fm = @import("file_message.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{"headroom"};
var cases: [names.len]c.atf_tc_t = undefined;
fn fact(name: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("round3 check=%s expected=%lld observed=%lld\n", name, @as(c_longlong, expected), @as(c_longlong, observed));
    if (expected != observed) c.atf_tc_fail("round3 observation differs");
}
fn send(buffer: []u8) i32 {
    return c.mach_msg(@ptrCast(@alignCast(buffer.ptr)), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, @intCast(buffer.len), 0, 0, 2000, 0);
}
fn receive(port: u32, buffer: []u8) i32 {
    return c.mach_msg(@ptrCast(@alignCast(buffer.ptr)), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @intCast(buffer.len), port, 2000, 0);
}
fn sendRight(port: u32) void {
    fact("make_send", 0, c.mach_port_insert_right(c.mach_task_self(), port, port, c.MACH_MSG_TYPE_MAKE_SEND));
}
const State = extern struct { size: u64, next: u64, prev: u64 };
const KmsgObservation = extern struct { result: c_int, pad: c_int, before: State, after: State };
fn headroom() void {
    const dest = fm.allocate();
    const carried = fm.allocate();
    sendRight(dest);
    sendRight(carried);
    defer _ = c.close(@intCast(dest));
    defer _ = c.close(@intCast(carried));
    for ([_]u32{ 1, 5, 11, 64 }) |count| {
        var msg: [1024]u8 align(8) = @splat(0);
        const size = 28 + 12 * count + 16;
        const h: *fm.Header = @ptrCast(&msg);
        h.* = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = size, .remote = dest, .local = 0, .voucher = 0, .id = 61701 };
        const n: *u32 = @ptrCast(@alignCast(msg[24..].ptr));
        n.* = count;
        for (0..count) |i| {
            const d: *align(1) fm.Descriptor = @ptrCast(msg[28 + 12 * i ..].ptr);
            d.* = .{ .name = carried, .pad = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = 0 };
        }
        @memset(msg[size - 16 .. size], 0xa7);
        var control: extern struct { address: u64, size: u32, pad: u32 } = .{ .address = @intFromPtr(&msg), .size = size, .pad = 0 };
        var observed: KmsgObservation = undefined;
        var len: usize = @sizeOf(KmsgObservation);
        fact("copyin_observe", 0, c.sysctlbyname("debug.rmx_kmsg_state", &observed, &len, &control, @sizeOf(@TypeOf(control))));
        fact("copyin_result", 0, observed.result);
        fact("queue_size", @intCast(observed.before.size), @intCast(observed.after.size));
        fact("queue_next", @bitCast(observed.before.next), @bitCast(observed.after.next));
        fact("queue_prev", @bitCast(observed.before.prev), @bitCast(observed.after.prev));
        fact("descriptor_send", 0, send(msg[0..size]));
        var out: [1200]u8 align(8) = @splat(0);
        fact("descriptor_receive", 0, receive(dest, &out));
        const rh: *fm.Header = @ptrCast(&out);
        fact("message_size", size, rh.size);
        fact("message_id", 61701, rh.id);
        fact("descriptor_count", count, @as(*u32, @ptrCast(@alignCast(out[24..].ptr))).*);
        for (0..count) |i| {
            const d: *align(1) fm.Descriptor = @ptrCast(out[28 + 12 * i ..].ptr);
            fact("descriptor_name", carried, d.name);
            fact("descriptor_type", 0, d.kind);
            fact("descriptor_right", c.MACH_MSG_TYPE_PORT_SEND, d.disposition);
        }
        for (out[size - 16 .. size]) |byte| fact("payload_byte", 0xa7, byte);
        c.mach_msg_destroy(@ptrCast(&out));
    }
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "25");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.alarm(25);
    var path: [4096]u8 = undefined;
    const n = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (n < 0 or n >= path.len) c.atf_tc_fail("fixture path too long");
    const module = c.kldload(&path);
    if (module < 0) c.atf_tc_fail("fixture load failed");
    defer _ = c.kldunload(module);
    headroom();
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) _ = c.kldunload(module);
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, &head, &body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
