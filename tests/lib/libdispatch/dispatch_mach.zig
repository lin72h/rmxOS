// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
    @cInclude("semaphore.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const Object = ?*anyopaque;
extern var _dispatch_source_type_mach_recv: u8;
extern var _dispatch_source_type_mach_send: u8;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_mach_create_f([*:0]const u8, Object, Object, *const fn (Object, c_ulong, Object, c_int) callconv(.c) void) Object;
extern fn dispatch_mach_connect(Object, u32, u32, Object) void;
extern fn dispatch_mach_cancel(Object) void;
extern fn dispatch_mach_msg_get_msg(Object, ?*usize) *c.mach_msg_header_t;
extern fn dispatch_source_create(*u8, usize, usize, Object) Object;
extern fn dispatch_source_set_event_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_set_cancel_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_set_registration_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_cancel(Object) void;
extern fn dispatch_resume(Object) void;
extern fn dispatch_release(Object) void;
extern fn op468_configure(c_int, c_uint) void;
extern fn op468_wait_copied() c_int;
extern fn op468_release() void;
extern fn op468_copied_set() c_uint;
extern fn op468_facts(*[4]c_uint) void;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var sem: c.sem_t = undefined;
var registered: c.sem_t = undefined;
var object: Object = null;
var received: u32 = 0;
var canceled: u32 = 0;
var callbacks: u32 = 0;
var ids: [2]i32 = .{ 0, 0 };
var sizes: [2]u32 = .{ 0, 0 };
fn signal(_: Object) callconv(.c) void {
    _ = c.sem_post(&registered);
}
fn canceledCall(_: Object) callconv(.c) void {
    canceled += 1;
    _ = c.sem_post(&sem);
}
fn sourceCall(_: Object) callconv(.c) void {
    callbacks += 1;
    dispatch_source_cancel(object);
}
fn channelCall(_: Object, reason: c_ulong, message: Object, _: c_int) callconv(.c) void {
    // mach_private.h enum starts at DISPATCH_MACH_CONNECTED = 1.
    if (reason == 2) {
        const hdr = dispatch_mach_msg_get_msg(message, null);
        if (received < 2) {
            ids[received] = hdr.msgh_id;
            sizes[received] = hdr.msgh_size;
        }
        received += 1;
        _ = c.sem_post(&sem);
    } else if (reason == 8) {
        canceled += 1;
        _ = c.sem_post(&sem);
    }
}
fn setup() void {
    received = 0;
    canceled = 0;
    callbacks = 0;
    ids = .{ 0, 0 };
    sizes = .{ 0, 0 };
    if (c.sem_init(&sem, 0, 0) != 0 or c.sem_init(&registered, 0, 0) != 0) c.atf_tc_fail("semaphore setup");
}
fn wait(s: *c.sem_t) c_int {
    var t: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &t);
    t.tv_sec += 3;
    return c.sem_timedwait(s, &t);
}
fn port() u32 {
    var p: u32 = 0;
    const kr = c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p);
    if (kr != 0) c.atf_tc_fail("receive allocation kr=%d", kr);
    return p;
}
fn send(p: u32, id: i32, len: usize) void {
    const storage = std.heap.c_allocator.alignedAlloc(u8, .@"8", len) catch c.atf_tc_fail("allocation");
    defer std.heap.c_allocator.free(storage);
    @memset(storage, 0);
    const h: *c.mach_msg_header_t = @ptrCast(storage.ptr);
    h.* = std.mem.zeroes(c.mach_msg_header_t);
    h.msgh_bits = c.MACH_MSG_TYPE_MAKE_SEND;
    h.msgh_size = @intCast(len);
    h.msgh_remote_port = p;
    h.msgh_id = id;
    const kr = c.mach_msg(h, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, @intCast(len), 0, 0, 0, 0);
    if (kr != 0) c.atf_tc_fail("send kr=%d", kr);
}
fn source(p: u32, is_death: bool) Object {
    const q = dispatch_queue_create("op468.source", null);
    const s = dispatch_source_create(if (is_death) &_dispatch_source_type_mach_send else &_dispatch_source_type_mach_recv, p, if (is_death) 1 else 0, q);
    if (s == null) c.atf_tc_fail("source creation");
    object = s;
    dispatch_source_set_event_handler_f(s, &sourceCall);
    dispatch_source_set_cancel_handler_f(s, &canceledCall);
    dispatch_source_set_registration_handler_f(s, &signal);
    dispatch_resume(s);
    return s;
}
fn channel(len: usize, count: u32) void {
    setup();
    const p = port();
    op468_configure(0, p);
    const q = dispatch_queue_create("op468.channel", null);
    object = dispatch_mach_create_f("op468", q, null, &channelCall);
    dispatch_mach_connect(object, p, 0, null);
    send(p, 44701, len);
    if (count == 2) send(p, 44702, len);
    var rc: c_int = 0;
    for (0..count) |_| {
        rc |= wait(&sem);
    }
    dispatch_mach_cancel(object);
    rc |= wait(&sem);
    var facts: [4]c_uint = undefined;
    op468_facts(&facts);
    _ = c.printf("channel expected=%u observed=%u cancel_expected=1 cancel_observed=%u wire_expected=0 wire_observed=%u size_expected=%zu size_observed=%u wait_rc=%d\n", count, received, canceled, facts[0], len, sizes[0], rc);
    if (rc != 0 or received != count or canceled != 1 or ids[0] != 44701 or sizes[0] != len or facts[0] != 0) c.atf_tc_fail("channel receive/count/buffer registration mismatch");
    if (count == 2 and ids[1] != 44702) c.atf_tc_fail("second identity");
    _ = c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1);
}
fn two(_: [*c]const c.atf_tc_t) callconv(.c) void {
    channel(@sizeOf(c.mach_msg_header_t) + 8, 2);
}
fn large(_: [*c]const c.atf_tc_t) callconv(.c) void {
    channel(32768, 1);
}
fn copied(cancel: bool) void {
    setup();
    const p = port();
    op468_configure(1, p);
    if (cancel) {
        object = source(p, false);
        if (wait(&registered) != 0) c.atf_tc_fail("registration timeout");
    } else {
        const q = dispatch_queue_create("op468.stale", null);
        object = dispatch_mach_create_f("op468", q, null, &channelCall);
        dispatch_mach_connect(object, p, 0, null);
    }
    send(p, 44703, @sizeOf(c.mach_msg_header_t));
    const copy_rc = op468_wait_copied();
    if (copy_rc != 0) {
        op468_release();
        c.atf_tc_fail("copied-event fixture timeout");
    }
    if (!cancel) {
        var h: [128]u8 align(8) = @splat(0);
        const kr = c.mach_msg(@ptrCast(&h), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, h.len, op468_copied_set(), 0, 0);
        if (kr != 0) {
            op468_release();
            c.atf_tc_fail("competing receive kr=%d", kr);
        }
    }
    if (cancel) dispatch_source_cancel(object) else dispatch_mach_cancel(object);
    op468_release();
    const rc = wait(&sem);
    var facts: [4]c_uint = undefined;
    op468_facts(&facts);
    _ = c.printf("copied expected=1 observed=1 cancel_expected=1 cancel_observed=%u handler_expected=0 handler_observed=%u moves_expected=1 moves_observed=%u wait_rc=%d\n", canceled, callbacks, facts[1], rc);
    if (rc != 0 or canceled != 1 or callbacks != 0 or facts[1] != 1) c.atf_tc_fail("canceled copied record moved member or invoked handler");
    _ = c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1);
    const reuse_kr = c.mach_port_allocate_name(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, p);
    if (reuse_kr != 0) c.atf_tc_fail("controlled name reuse kr=%d", reuse_kr);
    const newer = p;
    var typ: c.mach_port_type_t = 0;
    const kr = c.mach_port_type(c.mach_task_self(), newer, &typ);
    _ = c.printf("new_receive old_name=%u new_name=%u type_kr=%d type=%u\n", p, newer, kr, typ);
    if (kr != 0 or (typ & c.MACH_PORT_TYPE_RECEIVE) == 0) c.atf_tc_fail("unrelated receive damaged");
    object = source(newer, false);
    if (wait(&registered) != 0) c.atf_tc_fail("new source registration");
    dispatch_source_cancel(object);
    if (wait(&sem) != 0 or callbacks != 0) c.atf_tc_fail("old readiness ran new handler");
}
fn stale(_: [*c]const c.atf_tc_t) callconv(.c) void {
    copied(false);
}
fn cancelCopied(_: [*c]const c.atf_tc_t) callconv(.c) void {
    copied(true);
}
fn death(during: bool, late: bool) void {
    setup();
    const p = port();
    if (c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) != 0) c.atf_tc_fail("send setup");
    op468_configure(if (during) 3 else if (late) 1 else 0, p);
    if (!during and !late) _ = c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1);
    object = source(p, true);
    if (late) {
        if (wait(&registered) != 0) c.atf_tc_fail("death registration timeout");
        _ = c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1);
        const rc = op468_wait_copied();
        if (rc != 0) {
            op468_release();
            c.atf_tc_fail("late death copy timeout");
        }
        dispatch_source_cancel(object);
        op468_release();
    }
    const rc = wait(&sem);
    var facts: [4]c_uint = undefined;
    op468_facts(&facts);
    var refs: c.mach_port_urefs_t = 0;
    const kr = c.mach_port_get_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_DEAD_NAME, &refs);
    _ = c.printf("death during=%d late=%d cancel_expected=1 cancel_observed=%u callbacks=%u releases=%u refs_expected=1 refs_observed=%u refs_kr=%d wait_rc=%d\n", @as(c_int, @intFromBool(during)), @as(c_int, @intFromBool(late)), canceled, callbacks, facts[2], refs, kr, rc);
    if (rc != 0 or canceled != 1 or kr != 0 or refs != 1 or facts[2] != 1 or callbacks != (if (late) @as(u32, 0) else @as(u32, 1))) c.atf_tc_fail("death callback or extra uref imbalance");
    _ = c.mach_port_deallocate(c.mach_task_self(), p);
    const reuse_kr = c.mach_port_allocate_name(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, p);
    if (reuse_kr != 0) c.atf_tc_fail("controlled name reuse kr=%d", reuse_kr);
    const newer = p;
    var typ: c.mach_port_type_t = 0;
    if (c.mach_port_type(c.mach_task_self(), newer, &typ) != 0 or (typ & c.MACH_PORT_TYPE_RECEIVE) == 0) c.atf_tc_fail("new receive affected by late death");
}
fn deathRegistration(_: [*c]const c.atf_tc_t) callconv(.c) void {
    death(false, false);
    death(true, false);
}
fn lateDeath(_: [*c]const c.atf_tc_t) callconv(.c) void {
    death(false, true);
}
const names = [_][*:0]const u8{ "channel_two", "set_large_retry", "stale_readiness", "cancel_copied", "send_death_registration", "late_death" };
const bodies = .{ &two, &large, &stale, &cancelCopied, &deathRegistration, &lateDeath };
var cases: [6]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (0..6) |i| {
        const err = c.atf_tc_init(&cases[i], names[i], &head, bodies[i], null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
