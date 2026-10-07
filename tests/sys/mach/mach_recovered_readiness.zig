// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/notify.h");
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Port = extern struct { name: u32, pad: u32 = 0, pad2: u16 = 0, disposition: u8, kind: u8 = c.MACH_MSG_PORT_DESCRIPTOR };
const Packet = extern struct { header: c.mach_msg_header_t, count: u32, descriptor: Port, trailer: [128]u8 = @splat(0) };
var tc: c.atf_tc_t = undefined;
var index: usize = 0;
var differs = false;
fn fact(expected: i64, observed: i64) void {
    _ = c.printf("mach524 case=recovered_receive fact=%zu expected=%lld observed=%lld\n", index, @as(c_longlong, expected), @as(c_longlong, observed));
    index += 1;
    differs = differs or expected != observed;
}
fn alloc(right: u32) u32 {
    var name: u32 = 0;
    if (c.mach_port_allocate(c.mach_task_self(), right, &name) != 0) c.atf_tc_fail("recovery allocation failed");
    return name;
}
fn send(name: u32, id: i32) void {
    var header = std.mem.zeroes(c.mach_msg_header_t);
    header.msgh_bits = c.MACH_MSG_TYPE_MAKE_SEND;
    header.msgh_size = @sizeOf(c.mach_msg_header_t);
    header.msgh_remote_port = name;
    header.msgh_id = id;
    if (c.mach_msg(&header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, header.msgh_size, 0, 0, 500, 0) != 0) c.atf_tc_fail("recovery send failed");
}
fn receive(name: u32, packet: *Packet, timeout: u32) c_int {
    packet.* = std.mem.zeroes(Packet);
    return c.mach_msg(&packet.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Packet), name, timeout, 0);
}
fn observeReady(q: c_int, port: u32) void {
    var event = std.mem.zeroes(c.struct_kevent);
    var bound = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 500_000_000 };
    const n = c.kevent(q, null, 0, &event, 1, &bound);
    fact(1, n);
    fact(1, @intFromBool(n == 1 and event.data == port));
    fact(1, @intFromBool(n == 1 and event.fflags == 0 and event.flags & (c.EV_EOF | c.EV_ERROR) == 0 and std.mem.eql(u64, &event.ext, &.{ 0, 0, 0, 0 })));
    _ = c.printf("mach524_hint receive_name=%u count=%d hint=%lld\n", port, n, @as(c_longlong, event.data));
}
fn throughSet(set: u32, id: i32) void {
    var packet: Packet = undefined;
    fact(0, receive(set, &packet, 0));
    fact(id, packet.header.msgh_id);
}
fn residual(port: u32) void {
    var packet: Packet = undefined;
    var count: i64 = 0;
    // A defective set receive leaves messages queued; preserve that observation
    // and release them directly so the subsequent transfer has no hidden input.
    for (0..3) |_| {
        const rc = receive(port, &packet, 0);
        if (rc == c.MACH_RCV_TIMED_OUT) break;
        if (rc != 0) c.atf_tc_fail("recovery direct drain failed");
        count += 1;
    }
    fact(0, count);
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    index = 0;
    differs = false;
    const backup = alloc(c.MACH_PORT_RIGHT_RECEIVE);
    defer _ = c.mach_port_destroy(c.mach_task_self(), backup);
    const owner = alloc(c.MACH_PORT_RIGHT_RECEIVE);
    var previous: u32 = 0;
    const setup = c.mach_port_request_notification(c.mach_task_self(), owner, c.MACH_NOTIFY_PORT_DESTROYED, 0, backup, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous);
    fact(0, setup);
    fact(0, previous);
    if (setup != 0 or previous != 0) c.atf_tc_fail("port-destroyed request setup failed");
    // Native close exercises the revocation path; mod_refs bypasses it.
    fact(0, c.close(@intCast(owner)));
    const temporary = c.open("/dev/null", c.O_RDONLY);
    if (temporary < 0) c.atf_tc_fail("retired-name guard failed");
    const guard = c.dup2(temporary, @intCast(owner));
    if (temporary != owner) _ = c.close(temporary);
    if (guard != owner) c.atf_tc_fail("retired-name reservation failed");
    defer _ = c.close(guard);
    fact(1, @intFromBool(guard == owner));
    var notification: Packet = undefined;
    const received = receive(backup, &notification, 1000);
    fact(0, received);
    if (received != 0) c.atf_tc_fail("port-destroyed delivery missing");
    fact(c.MACH_NOTIFY_PORT_DESTROYED, notification.header.msgh_id);
    fact(1, @intFromBool(notification.header.msgh_bits & c.MACH_MSGH_BITS_COMPLEX != 0 and notification.count == 1 and notification.descriptor.kind == c.MACH_MSG_PORT_DESCRIPTOR and notification.descriptor.disposition == c.MACH_MSG_TYPE_PORT_RECEIVE));
    const recovered = notification.descriptor.name;
    var owned = recovered;
    defer if (owned != 0) {
        _ = c.mach_port_destroy(c.mach_task_self(), owned);
    };
    fact(1, @intFromBool(recovered != owner and recovered != 0));
    const set = alloc(c.MACH_PORT_RIGHT_PORT_SET);
    defer _ = c.mach_port_destroy(c.mach_task_self(), set);
    const q = c.kqueue();
    if (q < 0) c.atf_tc_fail("recovery kqueue failed");
    defer _ = c.close(q);
    var note = c.struct_kevent{ .ident = set, .filter = c.EVFILT_MACHPORT, .flags = c.EV_ADD, .fflags = 0, .data = 0, .udata = null, .ext = .{ 0, 0, 0, 0 } };
    if (c.kevent(q, &note, 1, null, 0, null) != 0) c.atf_tc_fail("recovery note attach failed");
    // Join must publish a message already queued on the recovered right.
    send(recovered, 52401);
    fact(0, c.mach_port_move_member(c.mach_task_self(), recovered, set));
    observeReady(q, recovered);
    throughSet(set, 52401);
    // Enqueue while joined must also publish the recovered member.
    send(recovered, 52402);
    observeReady(q, recovered);
    throughSet(set, 52402);
    residual(recovered);
    // Move that same live receive right through ordinary message copyout too.
    const transport = alloc(c.MACH_PORT_RIGHT_RECEIVE);
    defer _ = c.mach_port_destroy(c.mach_task_self(), transport);
    var moved = std.mem.zeroes(Packet);
    moved.header.msgh_bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_MAKE_SEND;
    moved.header.msgh_size = 40;
    moved.header.msgh_remote_port = transport;
    moved.header.msgh_id = 52403;
    moved.count = 1;
    moved.descriptor = .{ .name = recovered, .disposition = c.MACH_MSG_TYPE_MOVE_RECEIVE };
    const sent = c.mach_msg(&moved.header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 40, 0, 0, 500, 0);
    fact(0, sent);
    if (sent != 0) c.atf_tc_fail("ordinary receive-right send failed");
    owned = 0;
    var returned: Packet = undefined;
    const copied = receive(transport, &returned, 1000);
    fact(0, copied);
    if (copied != 0) c.atf_tc_fail("ordinary receive-right transfer failed");
    fact(52403, returned.header.msgh_id);
    fact(1, @intFromBool(returned.count == 1 and returned.descriptor.disposition == c.MACH_MSG_TYPE_PORT_RECEIVE));
    const next = returned.descriptor.name;
    defer _ = c.mach_port_destroy(c.mach_task_self(), next);
    fact(0, c.mach_port_move_member(c.mach_task_self(), next, set));
    send(next, 52404);
    observeReady(q, next);
    throughSet(set, 52404);
    residual(next);
    if (differs) c.atf_tc_fail("recovered receive right lost readiness");
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "15");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "recovered_receive", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
