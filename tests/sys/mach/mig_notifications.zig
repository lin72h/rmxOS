// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/notify.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});
const fm = @import("file_message.zig");
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn libdispatch_internal_protocol_server(*c.mach_msg_header_t, *c.mach_msg_header_t) c_int;
extern fn notify_server(*c.mach_msg_header_t, *c.mach_msg_header_t) c_int;
var selector: i32 = 0;
var value: u32 = 0;
var called: u32 = 0;
fn callback(id: i32, data: u32) c_int {
    selector = id;
    value = data;
    called += 1;
    return 0;
}
pub export fn _dispatch_mach_notify_port_deleted(_: u32, name: u32) c_int {
    return callback(65, name);
}
pub export fn _dispatch_mach_notify_send_possible(_: u32, name: u32) c_int {
    return callback(66, name);
}
pub export fn _dispatch_mach_notify_port_destroyed(_: u32, rights: u32) c_int {
    return callback(69, rights);
}
pub export fn _dispatch_mach_notify_no_senders(_: u32, count: u32) c_int {
    return callback(70, count);
}
pub export fn _dispatch_mach_notify_send_once(_: u32) c_int {
    return callback(71, 0);
}
pub export fn _dispatch_mach_notify_dead_name(_: u32, name: u32) c_int {
    return callback(72, name);
}
pub export fn _dispatch_wakeup_runloop_thread(_: u32) c_int {
    return callback(-1, 0);
}
pub export fn _dispatch_consume_send_once_right(_: u32) c_int {
    return callback(-1, 0);
}
pub export fn do_mach_notify_port_deleted(_: u32, name: u32) c_int {
    return callback(65, name);
}
pub export fn do_mach_notify_port_destroyed(_: u32, rights: u32) c_int {
    return callback(69, rights);
}
pub export fn do_mach_notify_no_senders(_: u32, count: u32) c_int {
    return callback(70, count);
}
pub export fn do_mach_notify_send_once(_: u32) c_int {
    return callback(71, 0);
}
pub export fn do_mach_notify_dead_name(_: u32, name: u32) c_int {
    return callback(72, name);
}
fn fact(label: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("mig_notification check=%s expected=%lld observed=%lld\n", label, @as(c_longlong, expected), @as(c_longlong, observed));
    if (expected != observed) c.atf_tc_fail("kernel notification receiver mismatch");
}
fn request(peer: u32, id: i32, notify: u32, sync: u32) void {
    var previous: u32 = 0;
    fact("request", 0, c.mach_port_request_notification(c.mach_task_self(), peer, id, sync, notify, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous));
    fact("previous", 0, previous);
}
fn message(peer: u32, options: i32) i32 {
    var h = fm.Header{ .bits = c.MACH_MSG_TYPE_COPY_SEND, .size = 24, .remote = peer, .local = 0, .voucher = 0, .id = 63100 };
    const kr = c.mach_msg(@ptrCast(&h), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT | options, 24, 0, 0, 0, 0);
    if (kr != 0) c.mach_msg_destroy(@ptrCast(&h));
    return kr;
}
fn run(id: i32) void {
    const task = c.mach_task_self();
    const peer = fm.allocate();
    const notify = fm.allocate();
    defer _ = c.close(@intCast(notify));
    fact("make_send", 0, c.mach_port_insert_right(task, peer, peer, c.MACH_MSG_TYPE_MAKE_SEND));
    var expected: u32 = peer;
    if (id == 66) {
        var limits: c.mach_port_limits_t = .{ .mpl_qlimit = 1 };
        fact("limit", 0, c.mach_port_set_attributes(task, peer, c.MACH_PORT_LIMITS_INFO, @ptrCast(&limits), 1));
        request(peer, id, notify, 0);
        fact("fill", 0, message(peer, 0));
        fact("arm", c.MACH_SEND_TIMED_OUT, message(peer, c.MACH_SEND_NOTIFY));
        var drain: [256]u8 align(8) = @splat(0);
        fact("drain", 0, c.mach_msg(@ptrCast(&drain), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, drain.len, peer, 1000, 0));
    } else if (id == 71) {
        var once: u32 = 0;
        var disposition: c.mach_msg_type_name_t = 0;
        fact("make_once", 0, c.mach_port_extract_right(task, notify, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, &once, &disposition));
        fact("drop_once", 0, c.mach_port_deallocate(task, once));
        expected = 0;
    } else {
        request(peer, if (id == 65) c.MACH_NOTIFY_DEAD_NAME else id, notify, if (id == 70 or id == 72 or id == 65) 1 else 0);
        if (id == 65) {
            fact("remove_name", 0, c.close(@intCast(peer)));
        } else if (id == 70) {
            fact("drop_sender", 0, c.mach_port_mod_refs(task, peer, c.MACH_PORT_RIGHT_SEND, -1));
            expected = 1;
        } else {
            fact("drop_receiver", 0, c.mach_port_mod_refs(task, peer, c.MACH_PORT_RIGHT_RECEIVE, -1));
        }
    }
    var data: [512]u8 align(8) = @splat(0);
    fact("receive", 0, c.mach_msg(@ptrCast(&data), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, data.len, notify, 1000, 0));
    const h: *c.mach_msg_header_t = @ptrCast(&data);
    fact("selector", id, h.msgh_id);
    fact("complex", if (id == 69) 1 else 0, @intFromBool((h.msgh_bits & @as(u32, c.MACH_MSGH_BITS_COMPLEX)) != 0));
    for (0..(if (id == 66) @as(usize, 1) else @as(usize, 2))) |receiver| {
        var reply: [256]u8 align(8) = @splat(0);
        called = 0;
        const accepted = if (receiver == 0) libdispatch_internal_protocol_server(h, @ptrCast(&reply)) else notify_server(h, @ptrCast(&reply));
        _ = c.printf("mig_notification receiver=%s id=%d size=%u\n", if (receiver == 0) @as([*:0]const u8, "dispatch") else "launchd", id, h.msgh_size);
        fact("accepted", 1, accepted);
        fact("callback_count", 1, called);
        fact("callback_selector", id, selector);
        if (id == 69) {
            if (value == 0) c.atf_tc_fail("received right is empty");
        } else fact("callback_value", expected, value);
    }
    c.mach_msg_destroy(h);
    if (id != 65) _ = c.close(@intCast(peer));
}
const names = [_][*:0]const u8{ "port_deleted", "send_possible", "port_destroyed", "no_senders", "send_once", "dead_name" };
const ids = [_]i32{ 65, 66, 69, 70, 71, 72 };
var cases: [names.len]c.atf_tc_t = undefined;
fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    for (names, ids) |n, id| {
        if (std.mem.eql(u8, name, std.mem.span(n))) {
            run(id);
            return;
        }
    }
    c.atf_tc_fail("unknown notification");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "10");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |n, i| {
        var err = c.atf_tc_init(&cases[i], n, &head, &body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
