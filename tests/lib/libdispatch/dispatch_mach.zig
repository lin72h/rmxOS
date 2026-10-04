// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
    @cInclude("semaphore.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("sys/event.h");
});
const Object = ?*anyopaque;
extern var _dispatch_source_type_mach_recv: u8;
extern var _dispatch_source_type_mach_send: u8;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_mach_create_f([*:0]const u8, Object, Object, *const fn (Object, c_ulong, Object, c_int) callconv(.c) void) Object;
extern fn dispatch_mach_connect(Object, u32, u32, Object) void;
extern fn dispatch_mach_reconnect(Object, u32, Object) void;
extern fn dispatch_mach_cancel(Object) void;
extern fn dispatch_mach_msg_get_msg(Object, ?*usize) *c.mach_msg_header_t;
extern fn dispatch_source_create(*u8, usize, usize, Object) Object;
extern fn dispatch_source_set_event_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_set_cancel_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_set_registration_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_cancel(Object) void;
extern fn dispatch_resume(Object) void;
extern fn dispatch_release(Object) void;
// The adapter projects C ABI fields; all scheduling and observations live here.
var fixture_mode: c_int = 0;
var fixture_watched: c_uint = 0;
var fixture_copied: c_uint = 0;
var fixture_released: c_uint = 0;
var fixture_set: c_uint = 0;
var growth_set: c_uint = 0;
var growth_facts: [3]c_uint = .{ 0, 0, 0 };
var fixture_facts: [4]c_uint = .{ 0, 0, 0, 0 };
fn op468_configure(mode: c_int, p: c_uint) void {
    @atomicStore(c_uint, &fixture_watched, p, .seq_cst);
    @atomicStore(c_int, &fixture_mode, mode, .seq_cst);
    @atomicStore(c_uint, &fixture_copied, 0, .seq_cst);
    @atomicStore(c_uint, &fixture_released, 0, .seq_cst);
    @atomicStore(c_uint, &growth_set, 0, .seq_cst);
    for (&growth_facts) |*v| @atomicStore(c_uint, v, 0, .seq_cst);
    for (&fixture_facts) |*v| @atomicStore(c_uint, v, 0, .seq_cst);
}
fn op468_wait_copied() c_int {
    for (0..3000) |_| {
        if (@atomicLoad(c_uint, &fixture_copied, .seq_cst) == 1) return 0;
        _ = c.usleep(1000);
    }
    return 1;
}
fn op468_release() void {
    @atomicStore(c_uint, &fixture_released, 1, .seq_cst);
}
fn op468_copied_set() c_uint {
    return @atomicLoad(c_uint, &fixture_set, .seq_cst);
}
fn op468_facts(out: *[4]c_uint) void {
    for (out, &fixture_facts) |*dest, *v| dest.* = @atomicLoad(c_uint, v, .seq_cst);
}
pub export fn op468_change(filter: c_int, flags: c_uint, ext0: u64, ext1: u64) void {
    if (filter == c.EVFILT_MACHPORT and (flags != 0 or ext0 != 0 or ext1 != 0))
        _ = @atomicRmw(c_uint, &fixture_facts[0], .Add, 1, .seq_cst);
}
pub export fn op468_event(filter: c_int, flags: c_uint, ident: usize, member: usize, local: c_uint) void {
    const mode = @atomicLoad(c_int, &fixture_mode, .seq_cst);
    if (filter != c.EVFILT_MACHPORT or (flags & c.EV_ERROR) != 0 or (mode != 1 and mode != 4)) return;
    const watched = @atomicLoad(c_uint, &fixture_watched, .seq_cst);
    if (mode == 1 and member != watched and local != watched) return;
    if (@cmpxchgStrong(c_uint, &fixture_copied, 0, 2, .seq_cst, .seq_cst) != null) return;
    @atomicStore(c_uint, &fixture_set, @intCast(ident), .seq_cst);
    @atomicStore(c_uint, &fixture_copied, 1, .seq_cst);
    while (@atomicLoad(c_uint, &fixture_released, .seq_cst) == 0) _ = c.usleep(1000);
}
pub export fn op468_move(p: c_uint) void {
    if (@atomicLoad(c_uint, &fixture_released, .seq_cst) != 0 and p == @atomicLoad(c_uint, &fixture_watched, .seq_cst))
        _ = @atomicRmw(c_uint, &fixture_facts[1], .Add, 1, .seq_cst);
}
pub export fn op468_deallocate(p: c_uint) void {
    if (p == @atomicLoad(c_uint, &fixture_watched, .seq_cst))
        _ = @atomicRmw(c_uint, &fixture_facts[2], .Add, 1, .seq_cst);
}
pub export fn op468_received(options: c_uint, name: c_uint, timeout: c_uint, kr: c_int) void {
    if ((options & c.MACH_RCV_MSG) == 0) return;
    if (name != 0 and name == @atomicLoad(c_uint, &growth_set, .seq_cst)) {
        _ = @atomicRmw(c_uint, &growth_facts[1], .Add, 1, .seq_cst);
        if ((options & c.MACH_RCV_LARGE) == 0 or (options & c.MACH_RCV_TIMEOUT) == 0 or timeout != 0 or (options & @as(c_uint, @bitCast(@as(c_int, c.MACH_RCV_TRAILER_MASK)))) == 0)
            _ = @atomicRmw(c_uint, &growth_facts[2], .Add, 1, .seq_cst);
    }
    if (kr == c.MACH_RCV_TOO_LARGE) {
        @atomicStore(c_uint, &growth_set, name, .seq_cst);
        _ = @atomicRmw(c_uint, &growth_facts[0], .Add, 1, .seq_cst);
    }
}
pub export fn op468_registered(p: c_uint, handle: c_uint, kr: c_int) void {
    if (p == @atomicLoad(c_uint, &fixture_watched, .seq_cst) and handle != 0 and kr == 0) _ = c.sem_post(&registered);
}
pub export fn op468_notification(task: c_uint, p: c_uint, notify: c_uint) void {
    if (p != @atomicLoad(c_uint, &fixture_watched, .seq_cst) or notify == 0) return;
    _ = @atomicRmw(c_uint, &fixture_facts[3], .Add, 1, .seq_cst);
    if (@cmpxchgStrong(c_int, &fixture_mode, 3, 0, .seq_cst, .seq_cst) == null)
        _ = c.mach_port_mod_refs(task, p, c.MACH_PORT_RIGHT_RECEIVE, -1);
}
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var sem_initialized = false;
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
    if (sem_initialized) {
        _ = c.sem_destroy(&sem);
        _ = c.sem_destroy(&registered);
    }
    sem_initialized = true;
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
    var rc: c_int = wait(&sem);
    if (count == 2) {
        if (c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) != 0) c.atf_tc_fail("reconnect send ownership");
        // Reconnect an installed receive-only channel; registration must route to the manager.
        dispatch_mach_reconnect(object, p, null);
        send(p, 44702, len);
        rc |= wait(&sem);
    }
    dispatch_mach_cancel(object);
    rc |= wait(&sem);
    var facts: [4]c_uint = undefined;
    op468_facts(&facts);
    _ = c.printf("channel expected=%u observed=%u cancel_expected=1 cancel_observed=%u wire_expected=0 wire_observed=%u size_expected=%zu size_observed=%u wait_rc=%d\n", count, received, canceled, facts[0], len, sizes[0], rc);
    if (len == 32768) {
        var growth: [3]c_uint = undefined;
        for (&growth, &growth_facts) |*dest, *v| dest.* = @atomicLoad(c_uint, v, .seq_cst);
        _ = c.printf("growth oversize_expected_min=1 oversize_observed=%u retry_expected_min=1 retry_observed=%u bad_options_expected=0 bad_options_observed=%u\n", growth[0], growth[1], growth[2]);
        if (growth[0] == 0 or growth[1] == 0 or growth[2] != 0) c.atf_tc_fail("channel receive/count/buffer registration mismatch");
    }
    if (rc != 0 or received != count or canceled != 1 or ids[0] != 44701 or sizes[0] != len or facts[0] != 0) c.atf_tc_fail("channel receive/count/buffer registration mismatch");
    if (count == 2 and ids[1] != 44702) c.atf_tc_fail("second identity");
    if (c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1) != 0) c.atf_tc_fail("borrowed receive was released by channel");
    if (count == 2 and c.mach_port_deallocate(c.mach_task_self(), p) != 0) c.atf_tc_fail("owned send release");
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
    op468_configure(0, p);
    if (cancel) {
        object = source(p, false);
        if (wait(&registered) != 0) c.atf_tc_fail("registration timeout");
    } else {
        const q = dispatch_queue_create("op468.stale", null);
        object = dispatch_mach_create_f("op468", q, null, &channelCall);
        dispatch_mach_connect(object, p, 0, null);
        if (wait(&registered) != 0) c.atf_tc_fail("channel membership timeout");
    }
    op468_configure(1, p);
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
        const claimed: *c.mach_msg_header_t = @ptrCast(&h);
        if (claimed.msgh_id != 44703) {
            op468_release();
            c.atf_tc_fail("competing receive claimed unrelated message");
        }
    }
    if (cancel) dispatch_source_cancel(object) else dispatch_mach_cancel(object);
    op468_release();
    const rc = wait(&sem);
    var facts: [4]c_uint = undefined;
    op468_facts(&facts);
    _ = c.printf("copied expected=1 observed=1 cancel_expected=1 cancel_observed=%u handler_expected=0 handler_observed=%u moves_expected=1 moves_observed=%u wait_rc=%d\n", canceled, callbacks, facts[1], rc);
    if (rc != 0 or canceled != 1 or callbacks != 0 or facts[1] != 1) c.atf_tc_fail("canceled copied record moved member or invoked handler");
    if (c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1) != 0) c.atf_tc_fail("borrowed receive was released by source");
    const newer = port();
    if (newer != p) c.atf_tc_fail("reuse expected=%u observed=%u", p, newer);
    var typ: c.mach_port_type_t = 0;
    const kr = c.mach_port_type(c.mach_task_self(), newer, &typ);
    _ = c.printf("new_receive old_name=%u new_name=%u type_kr=%d type=%u\n", p, newer, kr, typ);
    if (kr != 0 or (typ & c.MACH_PORT_TYPE_RECEIVE) == 0) c.atf_tc_fail("unrelated receive damaged");
    op468_configure(0, newer);
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
    op468_configure(if (during) 3 else 0, p);
    if (!during and !late) _ = c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1);
    object = source(p, true);
    if (late) {
        if (wait(&registered) != 0) c.atf_tc_fail("death registration timeout");
        op468_configure(4, p);
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
    const newer = port();
    if (newer != p) c.atf_tc_fail("reuse expected=%u observed=%u", p, newer);
    var typ: c.mach_port_type_t = 0;
    if (c.mach_port_type(c.mach_task_self(), newer, &typ) != 0 or (typ & c.MACH_PORT_TYPE_RECEIVE) == 0) c.atf_tc_fail("new receive affected by late death");
}
fn deathRegistration(_: [*c]const c.atf_tc_t) callconv(.c) void {
    // Initialize the manager and notification ports before revoking an empty name.
    // Otherwise lazy manager allocation can reuse that name before registration.
    death(false, false);
    death(true, false);
    setup();
    const invalid = port();
    op468_configure(0, invalid);
    _ = c.mach_port_mod_refs(c.mach_task_self(), invalid, c.MACH_PORT_RIGHT_RECEIVE, -1);
    object = source(invalid, true);
    const rc = wait(&sem);
    var facts: [4]c_uint = undefined;
    op468_facts(&facts);
    _ = c.printf("invalid_registration cancel_expected=1 cancel_observed=%u terminal_expected=1 terminal_observed=%u releases_expected=0 releases_observed=%u wait_rc=%d\n", canceled, callbacks, facts[2], rc);
    if (rc != 0 or canceled != 1 or callbacks != 1 or facts[2] != 0) c.atf_tc_fail("invalid registration did not finish cleanly");
}
fn lateDeath(_: [*c]const c.atf_tc_t) callconv(.c) void {
    death(false, true);
}
// Mach's packed user ABI has twelve-byte port descriptors. Express the
// bitfields as their byte-sized ABI fields so Zig owns message construction.
const PortDescriptor = extern struct { name: u32, pad1: u32 = 0, pad2: u16 = 0, disposition: u8 = c.MACH_MSG_TYPE_COPY_SEND, kind: u8 = c.MACH_MSG_PORT_DESCRIPTOR };
var partial_enabled: u32 = 0;
var partial_count: u32 = 0;
var transferred_refs: [2]u32 = .{ 0, 0 };
var previous_name: u32 = 0;
var previous_count: u32 = 0;
var pending_enabled: u32 = 0;
pub export fn op478_receive(h: *c.mach_msg_header_t, options: c_uint, kr: c_int) c_int {
    if (kr != c.MACH_MSG_SUCCESS or (options & c.MACH_RCV_MSG) == 0 or h.msgh_id != 47801) return kr;
    if (@cmpxchgStrong(u32, &partial_enabled, 1, 0, .seq_cst, .seq_cst) != null) return kr;
    const bytes: [*]u8 = @ptrCast(h);
    const desc: [*]const PortDescriptor = @ptrCast(@alignCast(bytes + @sizeOf(c.mach_msg_header_t) + 4));
    for (0..2) |i| {
        var refs: u32 = 0;
        const rc = c.mach_port_get_refs(c.mach_task_self(), desc[i].name, c.MACH_PORT_RIGHT_SEND, &refs);
        @atomicStore(u32, &transferred_refs[i], if (rc == 0) refs else 0, .seq_cst);
    }
    _ = @atomicRmw(u32, &partial_count, .Add, 1, .seq_cst);
    // A successful kernel copyout followed by a controlled BODY_ERROR return
    // exercises dispatch cleanup. Include a real copyout resource-error bit.
    return c.MACH_RCV_BODY_ERROR | c.MACH_MSG_IPC_SPACE;
}
pub export fn op478_previous(p: c_uint, notify: c_uint, previous: c_uint, kr: c_int) void {
    if (@atomicLoad(u32, &pending_enabled, .seq_cst) == 0 or p != @atomicLoad(c_uint, &fixture_watched, .seq_cst) or notify != 0 or kr != 0) return;
    @atomicStore(u32, &previous_name, previous, .seq_cst);
    _ = @atomicRmw(u32, &previous_count, .Add, 1, .seq_cst);
}
fn sendRight(p: u32) void {
    if (c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) != 0) c.atf_tc_fail("owned send setup");
}
fn partialReceive(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    const p = port();
    const rights = [2]u32{ port(), port() };
    for (rights) |r| sendRight(r);
    op468_configure(0, p);
    object = dispatch_mach_create_f("op478.partial", dispatch_queue_create("op478.partial", null), null, &channelCall);
    dispatch_mach_connect(object, p, 0, null);
    if (wait(&registered) != 0) c.atf_tc_fail("partial channel membership timeout");
    var storage: [32768]u8 align(8) = @splat(0);
    const h: *c.mach_msg_header_t = @ptrCast(&storage);
    h.* = std.mem.zeroes(c.mach_msg_header_t);
    h.msgh_bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_MAKE_SEND;
    h.msgh_size = storage.len;
    h.msgh_remote_port = p;
    h.msgh_id = 47801;
    const body: *u32 = @ptrCast(@alignCast(storage[@sizeOf(c.mach_msg_header_t)..].ptr));
    body.* = 2;
    const desc: [*]PortDescriptor = @ptrCast(@alignCast(storage[@sizeOf(c.mach_msg_header_t) + 4 ..].ptr));
    for (rights, 0..) |r, i| desc[i] = .{ .name = r };
    @atomicStore(u32, &partial_enabled, 1, .seq_cst);
    const sent = c.mach_msg(h, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, storage.len, 0, 0, 0, 0);
    if (sent != 0) c.atf_tc_fail("complex send kr=%d", sent);
    send(p, 47802, @sizeOf(c.mach_msg_header_t));
    const response = wait(&sem);
    dispatch_mach_cancel(object);
    const cancellation = wait(&sem);
    var refs: [2]u32 = .{ 0, 0 };
    var ref_rc: c_int = 0;
    for (rights, 0..) |r, i| ref_rc |= c.mach_port_get_refs(c.mach_task_self(), r, c.MACH_PORT_RIGHT_SEND, &refs[i]);
    const injected = @atomicLoad(u32, &partial_count, .seq_cst);
    const before = [2]u32{ @atomicLoad(u32, &transferred_refs[0], .seq_cst), @atomicLoad(u32, &transferred_refs[1], .seq_cst) };
    _ = c.printf("partial injected_expected=1 injected_observed=%u copied_refs_expected=2,2 copied_refs_observed=%u,%u refs_expected=1,1 refs_observed=%u,%u response_expected=47802 response_observed=%d count_expected=1 count_observed=%u cancel_expected=1 cancel_observed=%u wait_rc=%d refs_kr=%d\n", injected, before[0], before[1], refs[0], refs[1], ids[0], received, canceled, response | cancellation, ref_rc);
    if (injected != 1 or before[0] != 2 or before[1] != 2 or response != 0 or cancellation != 0 or received != 1 or ids[0] != 47802 or canceled != 1) c.atf_tc_fail("partial receive fixture or manager response mismatch");
    if (ref_rc != 0 or refs[0] != 1 or refs[1] != 1) c.atf_tc_fail("partial receive leaked copied send rights");
    for (rights) |r| {
        _ = c.mach_port_deallocate(c.mach_task_self(), r);
        _ = c.mach_port_mod_refs(c.mach_task_self(), r, c.MACH_PORT_RIGHT_RECEIVE, -1);
    }
    if (c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1) != 0) c.atf_tc_fail("partial borrowed receive release");
}
fn pendingRequest(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    const p = port();
    sendRight(p);
    op468_configure(0, p);
    @atomicStore(u32, &pending_enabled, 1, .seq_cst);
    object = source(p, true);
    if (wait(&registered) != 0) c.atf_tc_fail("pending watch registration timeout");
    dispatch_source_cancel(object);
    const rc = wait(&sem);
    const previous = @atomicLoad(u32, &previous_name, .seq_cst);
    const requests = @atomicLoad(u32, &previous_count, .seq_cst);
    var once_refs: u32 = 0;
    const once_rc = c.mach_port_get_refs(c.mach_task_self(), previous, c.MACH_PORT_RIGHT_SEND_ONCE, &once_refs);
    var refs: u32 = 0;
    const refs_rc = c.mach_port_get_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_SEND, &refs);
    _ = c.printf("pending returned_expected=1 returned_observed=%u previous=%u absent_expected=%d absent_observed=%d refs_expected=1 refs_observed=%u cancel_expected=1 cancel_observed=%u callbacks_expected=0 callbacks_observed=%u wait_rc=%d refs_kr=%d\n", requests, previous, @as(c_int, c.KERN_INVALID_NAME), once_rc, refs, canceled, callbacks, rc, refs_rc);
    if (rc != 0 or requests != 1 or previous == 0 or once_rc != c.KERN_INVALID_NAME or refs_rc != 0 or refs != 1 or canceled != 1 or callbacks != 0) c.atf_tc_fail("pending request right or owner uref imbalance");
    _ = c.mach_port_deallocate(c.mach_task_self(), p);
    if (c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, -1) != 0) c.atf_tc_fail("pending watched receive release");
}
const names = [_][*:0]const u8{ "channel_two", "set_large_retry", "stale_readiness", "cancel_copied", "send_death_registration", "late_death", "partial_receive_cleanup", "pending_request_cancel" };
const bodies = .{ &two, &large, &stale, &cancelCopied, &deathRegistration, &lateDeath, &partialReceive, &pendingRequest };
var cases: [8]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (0..8) |i| {
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
