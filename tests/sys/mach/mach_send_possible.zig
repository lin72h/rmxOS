// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const fm = @import("file_message.zig");
const arrays = @import("mig_arrays.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/notify.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/linker.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{ "full", "rearm", "cancel", "death", "early", "replace", "qlimit", "already_dead", "mig_limits", "mig_tempowner", "mig_launchd", "mig_maximum", "mig_inventory" };
var cases: [names.len]c.atf_tc_t = undefined;
fn fact(name: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("send_possible check=%s expected=%lld observed=%lld\n", name, @as(c_longlong, expected), @as(c_longlong, observed));
    if (expected != observed) c.atf_tc_fail("send-possible observation differs");
}
fn send(port: u32, options: c_int) i32 {
    var msg = fm.Header{ .bits = c.MACH_MSG_TYPE_COPY_SEND, .size = 24, .remote = port, .local = 0, .voucher = 0, .id = 62201 };
    const result = c.mach_msg(@ptrCast(&msg), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT | options, 24, 0, 0, 0, 0);
    // Pseudo-copyout returns the copied destination as an owned MOVE_SEND
    // right. This test discards the failed message rather than retrying it.
    if (result == c.MACH_SEND_TIMED_OUT) c.mach_msg_destroy(@ptrCast(&msg));
    return result;
}
fn receive(port: u32, out: []u8) i32 {
    return c.mach_msg(@ptrCast(@alignCast(out.ptr)), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @intCast(out.len), port, 0, 0);
}
fn empty(port: u32) void {
    var out: [256]u8 align(8) = @splat(0);
    fact("no_notification", c.MACH_RCV_TIMED_OUT, receive(port, &out));
}
fn notification(port: u32, id: i32, name: u32) void {
    var out: [256]u8 align(8) = @splat(0);
    fact("notification_receive", 0, receive(port, &out));
    fact("notification_selector", id, @as(*fm.Header, @ptrCast(&out)).id);
    fact("notification_name", name, @as(*u32, @ptrCast(@alignCast(out[32..].ptr))).*);
    empty(port);
}
fn take(port: u32) void {
    var out: [256]u8 align(8) = @splat(0);
    fact("peer_receive", 0, receive(port, &out));
    fact("peer_message", 62201, @as(*fm.Header, @ptrCast(&out)).id);
}
fn limit(port: u32, count: u32) void {
    var limits: c.mach_port_limits_t = .{ .mpl_qlimit = count };
    fact("queue_limit", 0, c.mach_port_set_attributes(c.mach_task_self(), port, c.MACH_PORT_LIMITS_INFO, @ptrCast(&limits), c.MACH_PORT_LIMITS_INFO_COUNT));
}
fn request(port: u32, notify: u32, sync: u32) u32 {
    var previous: u32 = 0;
    fact("request", 0, c.mach_port_request_notification(c.mach_task_self(), port, c.MACH_NOTIFY_SEND_POSSIBLE, sync, notify, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous));
    return previous;
}
const Refs = extern struct { refs: u32, active: u32 };
fn watch(command: u32, name: u32) Refs {
    var control: extern struct { command: u32, name: u32 } = .{ .command = command, .name = name };
    var out: Refs = undefined;
    var len: usize = @sizeOf(Refs);
    fact("watch", 0, c.sysctlbyname("debug.rmx_reply_refs", &out, &len, &control, @sizeOf(@TypeOf(control))));
    return out;
}
fn delayed(command: u32, name: u32) u64 {
    var control: extern struct { command: u32, name: u32 } = .{ .command = command, .name = name };
    var out: u64 = 0;
    var len: usize = 8;
    fact("delayed_control", 0, c.sysctlbyname("debug.rmx_send_notify_control", &out, &len, &control, @sizeOf(@TypeOf(control))));
    return out;
}
fn run(name: []const u8) void {
    if (std.mem.startsWith(u8, name, "mig_")) {
        if (std.mem.eql(u8, name, "mig_limits")) arrays.limits(1, false) else if (std.mem.eql(u8, name, "mig_tempowner")) arrays.limits(0, true) else if (std.mem.eql(u8, name, "mig_launchd")) arrays.limits(@sizeOf(c.mach_port_limits_t), false) else if (std.mem.eql(u8, name, "mig_maximum")) arrays.maximum() else arrays.inventory();
        return;
    }
    fact("public_selector", 66, c.MACH_NOTIFY_SEND_POSSIBLE);
    const peer = fm.allocate();
    fact("peer_send_right", 0, c.mach_port_insert_right(c.mach_task_self(), peer, peer, c.MACH_MSG_TYPE_MAKE_SEND));
    const notify = fm.allocate();
    defer _ = c.close(@intCast(notify));
    const baseline = watch(0, notify);
    defer _ = watch(2, 0);
    if (std.mem.eql(u8, name, "already_dead")) {
        fact("already_dead_receive_release", 0, c.mach_port_mod_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_RECEIVE, -1));
        var refs: u32 = 0;
        fact("initial_dead_refs_call", 0, c.mach_port_get_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_DEAD_NAME, &refs));
        fact("initial_dead_refs", 1, refs);
        fact("already_dead_previous", 0, request(peer, notify, 0));
        notification(notify, c.MACH_NOTIFY_DEAD_NAME, peer);
        fact("notified_dead_refs_call", 0, c.mach_port_get_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_DEAD_NAME, &refs));
        fact("notified_dead_refs", 2, refs);
        fact("notification_references_return", baseline.refs, watch(1, 0).refs);
        var previous: u32 = 0;
        fact("plain_dead_name_sync_zero", c.KERN_INVALID_ARGUMENT, c.mach_port_request_notification(c.mach_task_self(), peer, c.MACH_NOTIFY_DEAD_NAME, 0, notify, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous));
        // The refused request releases its supplied send-once right.
        var out: [256]u8 align(8) = @splat(0);
        fact("refused_once_receive", 0, receive(notify, &out));
        fact("refused_once_selector", c.MACH_NOTIFY_SEND_ONCE, @as(*fm.Header, @ptrCast(&out)).id);
        empty(notify);
        fact("refused_dead_refs_call", 0, c.mach_port_get_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_DEAD_NAME, &refs));
        fact("refused_dead_refs", 2, refs);
        fact("refused_references_return", baseline.refs, watch(1, 0).refs);
        fact("already_dead_cleanup", 0, c.mach_port_mod_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_DEAD_NAME, -2));
        return;
    }
    limit(peer, 1);
    fact("fill_queue", 0, send(peer, 0));
    fact("previous_empty", 0, request(peer, notify, 0));
    empty(notify);
    fact("registered_reference", baseline.refs + 1, watch(1, 0).refs);
    if (std.mem.eql(u8, name, "early") or std.mem.eql(u8, name, "replace")) {
        // Exercise the actual capture/arm helpers with a deterministic gap.
        const generation = delayed(1, peer);
        if (generation == 0) c.atf_tc_fail("registration was not captured");
        if (std.mem.eql(u8, name, "replace")) {
            const old = request(peer, notify, 0);
            if (old == 0) c.atf_tc_fail("replacement lost prior right");
            fact("replacement_release", 0, c.mach_port_deallocate(c.mach_task_self(), old));
            var discarded: [256]u8 align(8) = @splat(0);
            fact("replacement_once_cleanup", 0, receive(notify, &discarded));
        }
        take(peer);
        empty(notify); // Registered does not mean armed.
        _ = delayed(2, peer);
        if (std.mem.eql(u8, name, "replace")) {
            empty(notify); // The old send must not arm the new generation.
            fact("refill_queue", 0, send(peer, 0));
            fact("new_generation_timeout", c.MACH_SEND_TIMED_OUT, send(peer, c.MACH_SEND_NOTIFY));
            take(peer);
        }
        notification(notify, 66, peer);
    } else if (std.mem.eql(u8, name, "cancel")) {
        fact("armed_timeout", c.MACH_SEND_TIMED_OUT, send(peer, c.MACH_SEND_NOTIFY));
        const previous = request(peer, 0, 0);
        if (previous == 0) c.atf_tc_fail("cancellation lost prior right");
        fact("cancel_previous_release", 0, c.mach_port_deallocate(c.mach_task_self(), previous));
        var out: [256]u8 align(8) = @splat(0);
        fact("cancel_once_cleanup", 0, receive(notify, &out));
        fact("cancel_once_selector", c.MACH_NOTIFY_SEND_ONCE, @as(*fm.Header, @ptrCast(&out)).id);
        take(peer);
        empty(notify);
    } else if (std.mem.eql(u8, name, "death")) {
        fact("armed_timeout", c.MACH_SEND_TIMED_OUT, send(peer, c.MACH_SEND_NOTIFY));
        fact("peer_receive_death", 0, c.mach_port_mod_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_RECEIVE, -1));
        notification(notify, c.MACH_NOTIFY_DEAD_NAME, peer);
        var refs: u32 = 0;
        fact("dead_name_refs_call", 0, c.mach_port_get_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_DEAD_NAME, &refs));
        fact("dead_name_refs", 2, refs);
        fact("dead_name_cleanup", 0, c.mach_port_mod_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_DEAD_NAME, -2));
    } else {
        // A timeout without NOTIFY does not arm a registered request.
        fact("unarmed_timeout", c.MACH_SEND_TIMED_OUT, send(peer, 0));
        take(peer);
        empty(notify);
        fact("refill_queue", 0, send(peer, 0));
        fact("armed_timeout", c.MACH_SEND_TIMED_OUT, send(peer, c.MACH_SEND_NOTIFY));
        empty(notify);
        if (std.mem.eql(u8, name, "qlimit")) {
            limit(peer, 2);
        } else take(peer);
        notification(notify, 66, peer);
        fact("delivered_reference", baseline.refs, watch(1, 0).refs);
        if (std.mem.eql(u8, name, "rearm")) {
            fact("previous_consumed", 0, request(peer, notify, 0));
            fact("refill_queue", 0, send(peer, 0));
            fact("rearmed_timeout", c.MACH_SEND_TIMED_OUT, send(peer, c.MACH_SEND_NOTIFY));
            take(peer);
            notification(notify, 66, peer);
            // Immediate registration on an already available queue delivers once.
            fact("immediate_previous", 0, request(peer, notify, 1));
            notification(notify, 66, peer);
        }
    }
    fact("references_return", baseline.refs, watch(1, 0).refs);
    if (!std.mem.eql(u8, name, "death")) {
        // Consumed send-possible rights must not add a dead-name user reference.
        fact("peer_receive_cleanup", 0, c.mach_port_mod_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_RECEIVE, -1));
        empty(notify);
        var refs: u32 = 0;
        fact("consumed_dead_refs_call", 0, c.mach_port_get_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_DEAD_NAME, &refs));
        fact("consumed_dead_refs", 1, refs);
        fact("peer_dead_cleanup", 0, c.mach_port_mod_refs(c.mach_task_self(), peer, c.MACH_PORT_RIGHT_DEAD_NAME, -1));
    }
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.alarm(20);
    var path: [4096]u8 = undefined;
    _ = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    const module = c.kldload(&path);
    if (module < 0) c.atf_tc_fail("fixture load failed");
    defer _ = c.kldunload(module);
    run(std.mem.span(c.atf_tc_get_ident(t)));
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) {
        _ = delayed(3, 0);
        _ = watch(2, 0);
        _ = c.kldunload(module);
    }
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var err = c.atf_tc_init(&cases[i], name, &head, &body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
