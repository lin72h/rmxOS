// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const fm = @import("file_message.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{ "reply_send", "terminate" };
var cases: [names.len]c.atf_tc_t = undefined;
fn fact(name: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("round2 check=%s expected=%lld observed=%lld\n", name, @as(c_longlong, expected), @as(c_longlong, observed));
    if (expected != observed) c.atf_tc_fail("round2 observation differs");
}
fn sendHeader(dest: u32, reply: u32, id: i32) i32 {
    var h = std.mem.zeroes(c.mach_msg_header_t);
    h.msgh_bits = @as(u32, c.MACH_MSG_TYPE_COPY_SEND) | (if (reply == 0) @as(u32, 0) else @as(u32, c.MACH_MSG_TYPE_COPY_SEND << 8));
    h.msgh_size = @sizeOf(c.mach_msg_header_t);
    h.msgh_remote_port = dest;
    h.msgh_local_port = reply;
    h.msgh_id = id;
    return c.mach_msg(&h, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, h.msgh_size, 0, 0, 2000, 0);
}
fn receive(port: u32, buffer: []u8) i32 {
    return c.mach_msg(@ptrCast(@alignCast(buffer.ptr)), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @intCast(buffer.len), port, 2000, 0);
}
fn replySend() void {
    const task = c.mach_task_self();
    const channel = fm.allocate();
    fact("channel_send", 0, c.mach_port_insert_right(task, channel, channel, c.MACH_MSG_TYPE_MAKE_SEND));
    var saved: u32 = 0;
    fact("bootstrap_save", 0, c.task_get_special_port(task, c.TASK_BOOTSTRAP_PORT, &saved));
    fact("bootstrap_set", 0, c.task_set_special_port(task, c.TASK_BOOTSTRAP_PORT, channel));
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork setup failed");
    if (pid == 0) {
        _ = c.alarm(10);
        var dest: u32 = 0;
        if (c.task_get_special_port(c.mach_task_self(), c.TASK_BOOTSTRAP_PORT, &dest) != 0) c._exit(90);
        const reply = fm.allocate();
        var transfer = fm.Message{ .header = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = 40, .remote = dest, .local = 0, .voucher = 0, .id = 607 }, .count = 1, .descriptor = .{ .name = reply, .pad = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_MAKE_SEND, .kind = 0 }, .trailer = @splat(0) };
        if (c.mach_msg(@ptrCast(&transfer), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 40, 0, 0, 2000, 0) != 0) c._exit(91);
        var buf: [256]u8 align(8) = @splat(0);
        if (receive(reply, &buf) != 0) c._exit(92);
        var h: *c.mach_msg_header_t = @ptrCast(&buf);
        if (h.msgh_id != 608) c._exit(93);
        if (receive(reply, &buf) != 0) c._exit(94);
        h = @ptrCast(&buf);
        if (h.msgh_id != 609 or h.msgh_remote_port != reply) c._exit(95);
        c._exit(0);
    }
    fact("bootstrap_restore", 0, c.task_set_special_port(task, c.TASK_BOOTSTRAP_PORT, saved));
    if (saved != 0) _ = c.mach_port_deallocate(task, saved);
    var packet: fm.Message = undefined;
    fact("child_reply_transfer", 0, receive(channel, std.mem.asBytes(&packet)));
    const other = packet.descriptor.name;
    fact("foreign_reply_send", 0, sendHeader(channel, other, 608));
    var buf: [256]u8 align(8) = @splat(0);
    fact("foreign_reply_delivery", 0, receive(channel, &buf));
    const h: *c.mach_msg_header_t = @ptrCast(&buf);
    fact("foreign_reply_name", other, h.msgh_remote_port);
    fact("reply_to_child", 0, sendHeader(h.msgh_remote_port, 0, 608));
    fact("same_destination_reply", 0, sendHeader(other, other, 609));
    var status: c_int = 0;
    fact("child_wait", pid, c.waitpid(pid, &status, 0));
    fact("child_reply_observation", 0, status);
    _ = c.close(@intCast(other));
    _ = c.close(@intCast(channel));
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(t));
    if (std.mem.eql(u8, name, "terminate")) {
        const task = c.mach_task_self();
        fact("terminate_unsupported", 46, c.task_terminate(task));
        fact("task_self_survives", task, c.mach_task_self());
        var port: u32 = 0;
        fact("task_still_usable", 0, c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &port));
        fact("task_cleanup", 0, c.close(@intCast(port)));
    } else replySend();
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, null, &body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
