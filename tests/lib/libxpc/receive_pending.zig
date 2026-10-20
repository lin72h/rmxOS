// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/types.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
    @cInclude("semaphore.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const O = ?*anyopaque;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn xpc_connection_create(?[*:0]const u8, O) O;
extern fn xpc_connection_resume(O) void;
extern fn xpc_connection_cancel(O) void;
extern fn xpc_connection_send_message_with_reply_sync(O, O) O;
extern fn xpc_dictionary_create(O, O, usize) O;
extern fn xpc_dictionary_set_uint64(O, [*:0]const u8, u64) void;
extern fn xpc_dictionary_set_data(O, [*:0]const u8, O, usize) void;
extern fn xpc_release(O) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern fn dispatch_sync_f(O, O, *const fn (O) callconv(.c) void) void;
extern fn dispatch_async_f(O, O, *const fn (O) callconv(.c) void) void;
extern fn dispatch_suspend(O) void;
extern fn dispatch_resume(O) void;
extern fn dispatch_release(O) void;
extern fn op500_reply(O, O, O, O, *const fn (O, O) callconv(.c) void) void;
extern fn op500_send_queue(O) O;
extern fn op736_fail_pending_alloc() void;
extern fn op500_pipe_send(O, u32, u32, u64) c_int;
extern fn op736_pipe_receive(u32, *u32, *O, *u64) c_int;
extern fn xpc_pipe_try_receive(u32, *O, *u32, *const fn (*c.mach_msg_header_t, *c.mach_msg_header_t) callconv(.c) c_int, u32, c_int) c_int;
extern fn xpc_pipe_routine_reply(O) c_int;
extern var _xpc_error_connection_invalid: u8;
const Hooks = extern struct {
    before_handler: O = null,
    after_receive: O = null,
    receive: ?*const fn (*c.mach_msg_header_t, c_int, u32, u32, u32, u32, u32) callconv(.c) c_int = null,
    unpack: O = null,
    source_cancelled: O = null,
    port_release: O = null,
    pending_free: O = null,
    lookup: O = null,
};
extern fn op500_install(*const Hooks) void;
var mode: u32 = 0;
fn need(ok: bool, message: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", message);
}
fn wait(sem: *c.sem_t) void {
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &t);
    t.tv_sec += 8;
    need(c.sem_timedwait(sem, &t) == 0, "completion deadline");
}
fn port() u32 {
    var p: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) == 0, "port allocation");
    need(c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "send right setup");
    return p;
}
fn refs(p: u32) u32 {
    var n: u32 = 0;
    need(c.mach_port_get_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_SEND, &n) == 0, "send refs");
    return n;
}
fn noDemux(_: *c.mach_msg_header_t, _: *c.mach_msg_header_t) callconv(.c) c_int {
    return 0;
}
const Slot = struct { calls: u32 = 0, invalid: u32 = 0, done: *c.sem_t };
fn handler(ctx: O, reply: O) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(ctx.?));
    _ = @atomicRmw(u32, &slot.calls, .Add, 1, .seq_cst);
    if (reply == @as(O, @ptrCast(&_xpc_error_connection_invalid))) _ = @atomicRmw(u32, &slot.invalid, .Add, 1, .seq_cst);
    _ = c.sem_post(slot.done);
}
fn empty(_: O) callconv(.c) void {}
fn cancelled(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const queue = dispatch_queue_create("op736.cancelled", null);
    const conn = xpc_connection_create(null, queue);
    const message = xpc_dictionary_create(null, null, 0);
    need(conn != null and message != null, "connection setup");
    xpc_connection_cancel(conn);
    var done: c.sem_t = undefined;
    need(c.sem_init(&done, 0, 0) == 0, "semaphore");
    var slot = Slot{ .done = &done };
    op500_reply(conn, message, queue, &slot, &handler);
    wait(&done);
    const result = xpc_connection_send_message_with_reply_sync(conn, message);
    need(result == @as(O, @ptrCast(&_xpc_error_connection_invalid)), "sync cancelled result");
    xpc_release(result);
    dispatch_sync_f(queue, null, &empty);
    need(slot.calls == 1 and slot.invalid == 1, "cancelled async once");
    _ = c.printf("pending_cancelled expected_handlers=1 observed_handlers=%u expected_invalid=1 observed_invalid=%u sync_invalid=1\n", slot.calls, slot.invalid);
    xpc_release(message);
    xpc_release(conn);
    dispatch_release(queue);
    _ = c.sem_destroy(&done);
}
var pending_conn: O = null;
var pending_message: O = null;
var replies: O = null;
var submitted: c.sem_t = undefined;
fn sendPending(ctx: O) callconv(.c) void {
    op500_reply(pending_conn, pending_message, replies, ctx, &handler);
    _ = c.sem_post(&submitted);
}
fn cancelPending(_: [*c]const c.atf_tc_t) callconv(.c) void {
    replies = dispatch_queue_create("op736.replies", null);
    pending_conn = xpc_connection_create(null, replies);
    pending_message = xpc_dictionary_create(null, null, 0);
    need(pending_conn != null and pending_message != null, "pending setup");
    const sendq = op500_send_queue(pending_conn);
    dispatch_suspend(sendq);
    var done: c.sem_t = undefined;
    need(c.sem_init(&done, 0, 0) == 0 and c.sem_init(&submitted, 0, 0) == 0, "pending semaphores");
    var slots: [100]Slot = undefined;
    var queues: [4]O = undefined;
    for (&queues) |*q| q.* = dispatch_queue_create("op736.submit", null);
    for (&slots, 0..) |*slot, i| {
        slot.* = .{ .done = &done };
        dispatch_async_f(queues[i % 4], slot, &sendPending);
    }
    for (0..100) |_| wait(&submitted);
    xpc_connection_cancel(pending_conn);
    dispatch_resume(sendq);
    for (0..100) |_| wait(&done);
    for (queues) |q| {
        dispatch_sync_f(q, null, &empty);
        dispatch_release(q);
    }
    dispatch_sync_f(sendq, null, &empty);
    dispatch_sync_f(replies, null, &empty);
    for (slots) |slot| need(slot.calls == 1 and slot.invalid == 1, "each pending handler exactly once");
    _ = c.printf("pending_cancel expected_entries=100 observed_entries=100 expected_handlers=100 observed_handlers=100\n");
    xpc_release(pending_message);
    xpc_release(pending_conn);
    dispatch_release(replies);
    _ = c.sem_destroy(&done);
    _ = c.sem_destroy(&submitted);
}
fn allocFailure(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const queue = dispatch_queue_create("op736.alloc", null);
    const conn = xpc_connection_create(null, queue);
    const message = xpc_dictionary_create(null, null, 0);
    var done: c.sem_t = undefined;
    need(conn != null and message != null and c.sem_init(&done, 0, 0) == 0, "allocation setup");
    var slot = Slot{ .done = &done };
    op736_fail_pending_alloc();
    op500_reply(conn, message, queue, &slot, &handler);
    wait(&done);
    op736_fail_pending_alloc();
    const result = xpc_connection_send_message_with_reply_sync(conn, message);
    need(result == @as(O, @ptrCast(&_xpc_error_connection_invalid)), "sync allocation failure");
    xpc_release(result);
    need(slot.calls == 1 and slot.invalid == 1, "allocation failure completion once");
    xpc_connection_cancel(conn);
    dispatch_sync_f(queue, null, &empty);
    xpc_release(conn);
    xpc_release(message);
    dispatch_release(queue);
    _ = c.sem_destroy(&done);
}
// Wrapper is the unchanged NextBSD nvlist wire format: header, size, ID, bytes.
const Wire = extern struct { header: c.mach_msg_header_t, size: usize, id: u64, data: [8192]u8 };
fn prepare(dst: u32, reply: u32, length: u32) Wire {
    const obj = xpc_dictionary_create(null, null, 0);
    need(obj != null, "wire dictionary");
    xpc_dictionary_set_uint64(obj, "value", 736);
    need(op500_pipe_send(obj, dst, 0, 736) == 0, "serialize nvlist");
    xpc_release(obj);
    var wire = std.mem.zeroes(Wire);
    need(c.mach_msg(&wire.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Wire), dst, 1000, 0) == 0, "capture serialized wire");
    need(wire.header.msgh_size <= length, "wire fits padded message");
    wire.header.msgh_size = length;
    wire.header.msgh_bits = c.MACH_MSGH_BITS(c.MACH_MSG_TYPE_COPY_SEND, c.MACH_MSG_TYPE_MAKE_SEND);
    wire.header.msgh_remote_port = dst;
    wire.header.msgh_local_port = reply;
    wire.header.msgh_id = 736;
    return wire;
}
fn send(wire: *Wire) void {
    need(c.mach_msg(&wire.header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, wire.header.msgh_size, 0, 0, 1000, 0) == 0, "raw wrapper send");
}
fn receiveHook(h: *c.mach_msg_header_t, o: c_int, s: u32, r: u32, p: u32, t: u32, n: u32) callconv(.c) c_int {
    const kr = c.mach_msg(h, o, s, r, p, t, n);
    if (kr == 0 and mode == 1) {
        const trailer: *align(4) c.mach_msg_audit_trailer_t = @ptrFromInt(@intFromPtr(h) + ((h.msgh_size + 3) & ~@as(u32, 3)));
        trailer.msgh_trailer_size = @sizeOf(c.mach_msg_trailer_t);
    }
    return kr;
}
fn sizes(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const dst = port();
    const reply = port();
    const before = refs(reply);
    for ([_]u32{ 8192, 8191, 8192 }, [_]u32{ 8140, 8140, 8144 }, 0..) |capacity, length, i| {
        var wire = prepare(dst, reply, length);
        send(&wire);
        var obj: O = null;
        var remote: u32 = 0;
        const rc = xpc_pipe_try_receive(dst, &obj, &remote, &noDemux, capacity, 0);
        _ = c.printf("receive_size capacity=%u message=%u expected_success=%u observed_rc=%d\n", capacity, length, @as(u32, if (i == 0) 1 else 0), rc);
        if (i == 0) {
            need(rc == 0 and obj != null, "8140 at 8192 must fit audit trailer");
            // Audit data is inspected through a fixture projection, not guessed layout.
            need(op736_audit_pid(obj) == c.getpid(), "full audit token has sender PID");
            xpc_release(obj);
        } else need(rc == c.MACH_RCV_TOO_LARGE and obj == null, "over-capacity defined receive error");
        need(refs(reply) == before, "capacity reply right cleanup");
    }
    const obj = xpc_dictionary_create(null, null, 0);
    var bytes: [8192]u8 = @splat(0x61);
    xpc_dictionary_set_data(obj, "large", &bytes, bytes.len);
    need(op500_pipe_send(obj, dst, reply, 1) == c.EMSGSIZE, "sender refuses over capacity");
    xpc_release(obj);
    need(c.mach_port_destroy(c.mach_task_self(), dst) == 0 and c.mach_port_destroy(c.mach_task_self(), reply) == 0, "size ports cleanup");
}
extern fn op736_audit_pid(O) c_int;
fn rejected(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const dst = port();
    const reply = port();
    const before = refs(reply);
    const hooks = Hooks{ .receive = &receiveHook };
    op500_install(&hooks);
    for (0..4) |bad| {
        for (0..2) |pipe| {
            var wire = prepare(dst, reply, 512);
            mode = 0;
            if (bad == 0) @memset(wire.data[0..wire.size], 0);
            if (bad == 1) wire.size = 1;
            if (bad == 2) mode = 1;
            if (bad == 3) wire.header.msgh_size = @sizeOf(c.mach_msg_header_t);
            send(&wire);
            var obj: O = null;
            var remote: u32 = 0;
            var id: u64 = 0;
            const rc = if (pipe == 0) xpc_pipe_try_receive(dst, &obj, &remote, &noDemux, 0, 0) else op736_pipe_receive(dst, &remote, &obj, &id);
            need(rc == c.EINVAL and obj == null, "malformed wrapper rejected");
            need(refs(reply) == before, "rejected wrapper reply right restored");
            mode = 0;
            wire = prepare(dst, reply, 512);
            send(&wire);
            const next = if (pipe == 0) xpc_pipe_try_receive(dst, &obj, &remote, &noDemux, 0, 0) else op736_pipe_receive(dst, &remote, &obj, &id);
            need(next == 0 and obj != null and op736_audit_pid(obj) == c.getpid(), "next valid wrapper with sender audit token");
            xpc_release(obj);
            if (pipe == 1) need(c.mach_port_deallocate(c.mach_task_self(), remote) == 0, "connection pipe owns returned right");
            need(refs(reply) == before, "valid wrapper reply right restored");
        }
    }
    op500_install(&Hooks{});
    need(c.mach_port_destroy(c.mach_task_self(), dst) == 0 and c.mach_port_destroy(c.mach_task_self(), reply) == 0, "reject ports cleanup");
}
fn nonmig(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const dst = port();
    const reply = port();
    const before = refs(reply);
    for ([_][*:0]const u8{ "XPC key op", "XPC process key op" }) |key| {
        const obj = xpc_dictionary_create(null, null, 0);
        xpc_dictionary_set_uint64(obj, key, 1);
        need(op500_pipe_send(obj, dst, reply, 1) == 0, "non-MIG request send");
        need(xpc_pipe_routine_reply(obj) == c.ENOTSUP, "unsupported routine reply");
        xpc_release(obj);
        var request: O = null;
        var remote: u32 = 0;
        need(xpc_pipe_try_receive(dst, &request, &remote, &noDemux, 0, 0) == 0, "launchd-shaped non-MIG receive");
        // The preview's launchd policy is to release this unsupported request.
        xpc_release(request);
        need(refs(reply) == before, "unsupported request reply right released");
        var message: [256]u8 align(8) = undefined;
        need(c.mach_msg(@ptrCast(&message), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, message.len, reply, 0, 0) == c.MACH_RCV_TIMED_OUT, "unsupported request has no reply");
    }
    need(c.mach_port_destroy(c.mach_task_self(), dst) == 0 and c.mach_port_destroy(c.mach_task_self(), reply) == 0, "non-MIG ports cleanup");
}
extern fn dispatch_queue_set_specific(O, O, O, O) void;
extern fn dispatch_get_specific(O) O;
extern fn dispatch_set_context(O, O) void;
extern fn dispatch_set_finalizer_f(O, *const fn (O) callconv(.c) void) void;
extern fn xpc_connection_set_context(O, O) void;
extern fn xpc_connection_set_finalizer_f(O, *const fn (O) callconv(.c) void) void;
extern fn op746_fail_audit_alloc() void;
extern fn xpc_array_create(O, usize) O;
const Gate = struct { entered: c.sem_t, release: c.sem_t };
fn post(ctx: O) callconv(.c) void {
    const sem: *c.sem_t = @ptrCast(@alignCast(ctx.?));
    _ = c.sem_post(sem);
}
fn blockQueue(ctx: O) callconv(.c) void {
    const gate: *Gate = @ptrCast(@alignCast(ctx.?));
    _ = c.sem_post(&gate.entered);
    wait(&gate.release);
}
fn initSem(sem: *c.sem_t) void {
    need(c.sem_init(sem, 0, 0) == 0, "semaphore initialization");
}
fn ownedTarget(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const queue = dispatch_queue_create("op746.owned", null);
    const conn = xpc_connection_create(null, queue);
    const message = xpc_dictionary_create(null, null, 0);
    need(queue != null and conn != null and message != null, "owned queue setup");
    var gate: Gate = undefined;
    var done: c.sem_t = undefined;
    var destroyed: c.sem_t = undefined;
    var queueDestroyed: c.sem_t = undefined;
    for ([_]*c.sem_t{ &gate.entered, &gate.release, &done, &destroyed, &queueDestroyed }) |sem| initSem(sem);
    xpc_connection_set_context(conn, &destroyed);
    xpc_connection_set_finalizer_f(conn, &post);
    dispatch_set_context(queue, &queueDestroyed);
    dispatch_set_finalizer_f(queue, &post);
    dispatch_async_f(queue, &gate, &blockQueue);
    wait(&gate.entered);
    // Drop the creator's queue reference. Only connection/completion own it.
    dispatch_release(queue);
    const sendq = op500_send_queue(conn);
    dispatch_suspend(sendq);
    var slot = Slot{ .done = &done };
    op500_reply(conn, message, null, &slot, &handler);
    xpc_connection_cancel(conn);
    dispatch_resume(sendq);
    dispatch_sync_f(sendq, null, &empty);
    xpc_release(conn);
    wait(&destroyed);
    need(@atomicLoad(u32, &slot.calls, .seq_cst) == 0, "blocker holds completion after connection destruction");
    _ = c.sem_post(&gate.release);
    wait(&done);
    wait(&queueDestroyed);
    need(slot.calls == 1 and slot.invalid == 1, "owned target completion exactly once");
    _ = c.printf("queue_owned_target expected_handlers=1 observed_handlers=%u connection_destroyed_before_release=1 queue_finalized=1\n", slot.calls);
    xpc_release(message);
    for ([_]*c.sem_t{ &gate.entered, &gate.release, &done, &destroyed, &queueDestroyed }) |sem| _ = c.sem_destroy(sem);
}
var specific_key: u8 = 0;
var specific_value: u8 = 0;
const QueueSlot = struct { slot: Slot, returned: u32 = 0, on_queue: u32 = 0, after_return: u32 = 0 };
fn queuedHandler(ctx: O, reply: O) callconv(.c) void {
    const state: *QueueSlot = @ptrCast(@alignCast(ctx.?));
    state.on_queue = @intFromBool(dispatch_get_specific(&specific_key) == @as(O, &specific_value));
    state.after_return = @atomicLoad(u32, &state.returned, .seq_cst);
    handler(&state.slot, reply);
}
fn failureQueue(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const queue = dispatch_queue_create("op746.failures", null);
    dispatch_queue_set_specific(queue, &specific_key, &specific_value, null);
    var done: c.sem_t = undefined;
    initSem(&done);
    for (0..2) |kind| {
        const conn = xpc_connection_create(null, queue);
        const message = xpc_dictionary_create(null, null, 0);
        need(conn != null and message != null, "failure queue setup");
        if (kind == 0) xpc_connection_cancel(conn) else op736_fail_pending_alloc();
        var state = QueueSlot{ .slot = .{ .done = &done } };
        dispatch_suspend(queue);
        op500_reply(conn, message, queue, &state, &queuedHandler);
        @atomicStore(u32, &state.returned, 1, .seq_cst);
        need(@atomicLoad(u32, &state.slot.calls, .seq_cst) == 0, "failure completion is asynchronous");
        dispatch_resume(queue);
        wait(&done);
        dispatch_sync_f(queue, null, &empty);
        need(state.slot.calls == 1 and state.slot.invalid == 1 and state.on_queue == 1 and state.after_return == 1, "failure on requested queue after return, exactly once");
        _ = c.printf("failure_queue kind=%zu expected_handlers=1 observed_handlers=%u expected_queue=1 observed_queue=%u expected_after_return=1 observed_after_return=%u\n", kind, state.slot.calls, state.on_queue, state.after_return);
        xpc_connection_cancel(conn);
        xpc_release(conn);
        xpc_release(message);
    }
    dispatch_release(queue);
    _ = c.sem_destroy(&done);
}
const SyncState = struct { conn: O, message: O, started: c.sem_t, done: c.sem_t, invalid: bool = false };
fn syncWork(ctx: O) callconv(.c) void {
    const state: *SyncState = @ptrCast(@alignCast(ctx.?));
    _ = c.sem_post(&state.started);
    const result = xpc_connection_send_message_with_reply_sync(state.conn, state.message);
    state.invalid = result == @as(O, @ptrCast(&_xpc_error_connection_invalid));
    xpc_release(result);
    _ = c.sem_post(&state.done);
}
extern fn op500_recv_queue(O) O;
fn syncSuspended(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const queue = dispatch_queue_create("op746.sync", null);
    const conn = xpc_connection_create(null, queue);
    const message = xpc_dictionary_create(null, null, 0);
    need(conn != null and message != null, "suspended sync setup");
    // This additional fixture suspension remains even when cancel balances the
    // connection's own suspension. A completion on recv_queue would hang here.
    const recvq = op500_recv_queue(conn);
    dispatch_suspend(recvq);
    const worker = dispatch_queue_create("op746.sync.caller", null);
    var state = SyncState{ .conn = conn, .message = message, .started = undefined, .done = undefined };
    initSem(&state.started);
    initSem(&state.done);
    dispatch_async_f(worker, &state, &syncWork);
    wait(&state.started);
    xpc_connection_cancel(conn);
    wait(&state.done);
    need(state.invalid, "synchronous suspended/cancelled call returns invalid");
    dispatch_sync_f(worker, null, &empty);
    dispatch_resume(recvq);
    dispatch_sync_f(recvq, null, &empty);
    _ = c.printf("sync_suspended expected_invalid=1 observed_invalid=%u recv_queue_held=1\n", @as(u32, @intFromBool(state.invalid)));
    xpc_release(conn);
    xpc_release(message);
    dispatch_release(worker);
    dispatch_release(queue);
    _ = c.sem_destroy(&state.started);
    _ = c.sem_destroy(&state.done);
}
fn decodeHook(h: *c.mach_msg_header_t, o: c_int, s: u32, r: u32, p: u32, t: u32, n: u32) callconv(.c) c_int {
    const kr = c.mach_msg(h, o, s, r, p, t, n);
    if (kr == 0) {
        const tr: *align(4) c.mach_msg_audit_trailer_t = @ptrFromInt(@intFromPtr(h) + ((h.msgh_size + 3) & ~@as(u32, 3)));
        switch (mode) {
            10 => h.msgh_size = @sizeOf(c.mach_msg_header_t),
            12 => h.msgh_size = r + 4,
            14 => tr.msgh_trailer_type = c.MACH_MSG_TRAILER_FORMAT_0 + 1,
            15 => tr.msgh_trailer_size = @sizeOf(c.mach_msg_trailer_t),
            19 => tr.msgh_trailer_size = r,
            else => {},
        }
    }
    return kr;
}
fn decodeRefusals(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const dst = port();
    const reply = port();
    const before = refs(reply);
    op500_install(&Hooks{ .receive = &decodeHook });
    // Short header, declared length, body capacity, complex wrapper, trailer
    // type, short trailer, unpack, array root, audit malloc, oversized trailer.
    for (0..10) |bad| {
        for (0..2) |pipe| {
            var wire = prepare(dst, reply, 512);
            if (bad == 1) wire.size = wire.header.msgh_size;
            if (bad == 3) {
                wire.size = 0; // complex body's descriptor count is zero
                wire.header.msgh_bits |= c.MACH_MSGH_BITS_COMPLEX;
            }
            if (bad == 6) @memset(wire.data[0..wire.size], 0);
            if (bad == 7) {
                const array = xpc_array_create(null, 0);
                need(array != null and op500_pipe_send(array, dst, 0, 746) == 0, "serialize array root");
                xpc_release(array);
                var arrayWire = std.mem.zeroes(Wire);
                need(c.mach_msg(&arrayWire.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Wire), dst, 1000, 0) == 0, "capture array root");
                wire.size = arrayWire.size;
                @memcpy(wire.data[0..wire.size], arrayWire.data[0..wire.size]);
            }
            mode = @intCast(10 + bad);
            send(&wire);
            if (bad == 8) op746_fail_audit_alloc();
            var obj: O = null;
            var remote: u32 = 0;
            var id: u64 = 0;
            const rc = if (pipe == 0) xpc_pipe_try_receive(dst, &obj, &remote, &noDemux, 0, 0) else op736_pipe_receive(dst, &remote, &obj, &id);
            const expected = if (bad == 8) c.ENOMEM else c.EINVAL;
            const after = refs(reply);
            _ = c.printf("decode_refusal branch=%zu pipe=%zu expected_rc=%d observed_rc=%d expected_refs=%u observed_refs=%u\n", bad, pipe, expected, rc, before, after);
            need(rc == expected and obj == null and after == before, "decode refusal releases message once");
            mode = 0;
            wire = prepare(dst, reply, 512);
            send(&wire);
            const next = if (pipe == 0) xpc_pipe_try_receive(dst, &obj, &remote, &noDemux, 0, 0) else op736_pipe_receive(dst, &remote, &obj, &id);
            need(next == 0 and obj != null, "valid receive after each decode refusal");
            xpc_release(obj);
            if (pipe == 1) need(c.mach_port_deallocate(c.mach_task_self(), remote) == 0, "valid returned reply right release");
            need(refs(reply) == before, "next valid reply right restored");
        }
    }
    mode = 0;
    op500_install(&Hooks{});
    need(c.mach_port_destroy(c.mach_task_self(), dst) == 0 and c.mach_port_destroy(c.mach_task_self(), reply) == 0, "decode ports cleanup");
}
fn replyTwice(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const dst = port();
    const reply = port();
    const before = refs(reply);
    var objects: [2]O = @splat(null);
    for (&objects, 0..) |*obj, i| {
        var wire = prepare(dst, reply, 512);
        send(&wire);
        var remote: u32 = 0;
        need(xpc_pipe_try_receive(dst, obj, &remote, &noDemux, 0, 0) == 0 and obj.* != null, "two owned request receives");
        need(refs(reply) == before + i + 1, "each received request owns one reply right");
    }
    for (objects, 0..) |obj, i| {
        xpc_release(obj);
        const after = refs(reply);
        _ = c.printf("reply_port_twice released=%zu expected_refs=%zu observed_refs=%u\n", i + 1, before + 1 - i, after);
        need(after == before + 1 - i, "each request releases reply right exactly once");
    }
    need(c.mach_port_destroy(c.mach_task_self(), dst) == 0 and c.mach_port_destroy(c.mach_task_self(), reply) == 0, "two request ports cleanup");
}

fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "20");
}
var cases: [11]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "cancelled_reply", "cancel_pending", "allocation_reply", "receive_sizes", "rejected_receive", "nonmig_request", "queue_owned_target", "failure_on_reply_queue", "sync_on_suspended", "decode_refusals", "reply_port_twice" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &cancelled, &cancelPending, &allocFailure, &sizes, &rejected, &nonmig, &ownedTarget, &failureQueue, &syncSuspended, &decodeRefusals, &replyTwice };
    for (&cases, names, bodies) |*tc, name, body| {
        var e = c.atf_tc_init(tc, name, &head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
