// SPDX-License-Identifier: BSD-2-Clause
// Runtime facts and controlled interleavings for the real libxpc consumer.
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
    @cInclude("semaphore.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const O = ?*anyopaque;
const Handler = *const fn (O, O) callconv(.c) void;
extern fn xpc_connection_create(?[*:0]const u8, O) O;
extern fn xpc_connection_resume(O) void;
extern fn xpc_connection_suspend(O) void;
extern fn dispatch_suspend(O) void;
extern fn dispatch_resume(O) void;
extern fn xpc_connection_cancel(O) void;
extern fn xpc_connection_set_context(O, O) void;
extern fn xpc_connection_set_finalizer_f(O, *const fn (O) callconv(.c) void) void;
extern fn xpc_release(O) void;
extern fn xpc_dictionary_create(O, O, usize) O;
extern fn xpc_dictionary_set_uint64(O, [*:0]const u8, u64) void;
extern fn xpc_dictionary_get_uint64(O, [*:0]const u8) u64;
extern var _xpc_error_connection_invalid: u8;
extern var _xpc_error_connection_interrupted: u8;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern fn dispatch_sync_f(O, O, *const fn (O) callconv(.c) void) void;
extern fn dispatch_release(O) void;
extern fn op500_event_handler(O, O, Handler) void;
extern fn op500_reply(O, O, O, O, Handler) void;
extern fn op500_local(O) u32;
extern fn op500_remote(O, u32) void;
extern fn op500_cancel_count(O) u32;
extern fn op500_cancelled(O) u32;
extern fn op500_send_queue(O) O;
extern fn op500_recv_queue(O) O;
extern fn op500_pipe_send(O, u32, u32, u64) c_int;
const Hooks = extern struct {
    before_handler: *const fn (O) callconv(.c) void,
    after_receive: *const fn (O, c_int) callconv(.c) void,
    receive: *const fn (*c.mach_msg_header_t, c_int, u32, u32, u32, u32, u32) callconv(.c) c_int,
    unpack: *const fn (O, usize) callconv(.c) void,
    source_cancelled: *const fn (O) callconv(.c) void,
    port_release: *const fn (O, u32, u32) callconv(.c) void,
    pending_free: *const fn (O) callconv(.c) void,
};
extern fn op500_install(*const Hooks) void;
const Slot = struct { calls: u64 = 0, invalid: u64 = 0, interrupted: u64 = 0 };
var slots: [2]Slot = @splat(.{});
var conn: O = null;
var local: u32 = 0;
var remote: u32 = 0;
var mode: u32 = 0;
var paused: u32 = 0;
var cancel_paused: u32 = 0;
var injected: u32 = 0;
var entered: c.sem_t = undefined;
var gate: c.sem_t = undefined;
var after: c.sem_t = undefined;
var event_done: c.sem_t = undefined;
var reply_done: c.sem_t = undefined;
var finished: c.sem_t = undefined;
var cancel_entered: c.sem_t = undefined;
var cancel_gate: c.sem_t = undefined;
var receives: u64 = 0;
var first_result: u32 = 0;
var first_options: u32 = 0;
var native_result: u32 = 0;
var parses: u64 = 0;
var events: u64 = 0;
var valid: u64 = 0;
var invalid: u64 = 0;
var interrupted: u64 = 0;
var values: u64 = 0;
var local_releases: u64 = 0;
var remote_releases: u64 = 0;
var finalizers: u64 = 0;
var source_completions: u64 = 0;
var pending_frees: u64 = 0;
var observation_mismatch = false;
fn get(v: *u64) u64 {
    return @atomicLoad(u64, v, .seq_cst);
}
fn add(v: *u64) void {
    _ = @atomicRmw(u64, v, .Add, 1, .seq_cst);
}
fn wait(s: *c.sem_t, ms: u64) bool {
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &t);
    const ns: u64 = @as(u64, @intCast(t.tv_nsec)) + ms * 1_000_000;
    t.tv_sec += @intCast(ns / 1_000_000_000);
    t.tv_nsec = @intCast(ns % 1_000_000_000);
    return c.sem_timedwait(s, &t) == 0;
}
fn need(ok: bool, what: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("fixture setup: %s", what);
}
fn noop(_: O) callconv(.c) void {}
fn fence(q: O) void {
    // A first fence may precede delivery enqueued by the running handler.
    // A second fence necessarily follows that delivery on this serial queue.
    dispatch_sync_f(q, null, &noop);
    dispatch_sync_f(q, null, &noop);
}
fn beforeHandler(p: O) callconv(.c) void {
    if (p != conn or (mode != 1 and mode != 3)) return;
    if (@cmpxchgStrong(u32, &paused, 0, 1, .seq_cst, .seq_cst) != null) return;
    _ = c.sem_post(&entered);
    _ = c.sem_wait(&gate);
}
fn afterReceive(p: O, kr: c_int) callconv(.c) void {
    if (p != conn) return;
    if (@atomicRmw(u64, &receives, .Add, 1, .seq_cst) == 0) first_result = @bitCast(kr);
    _ = c.sem_post(&after);
}
fn receive(h: *c.mach_msg_header_t, opts: c_int, send_size: u32, size: u32, name: u32, timeout: u32, notify: u32) callconv(.c) c_int {
    if (name != local) return c.mach_msg(h, opts, send_size, size, name, timeout, notify);
    if (get(&receives) == 0) first_options = @bitCast(opts);
    var kr = c.mach_msg(h, opts, send_size, size, name, timeout, notify);
    if (mode == 2 and kr == 0 and @cmpxchgStrong(u32, &injected, 0, 1, .seq_cst, .seq_cst) == null) {
        // Seed the buffer with a real valid wire message, then report a receive
        // failure. Drop its copied reply right: it belongs to this injection.
        if (h.msgh_remote_port != 0) _ = c.mach_port_deallocate(c.mach_task_self(), h.msgh_remote_port);
        h.msgh_remote_port = 0;
        kr = c.MACH_RCV_INTERRUPTED;
    } else if (kr != 0) {
        native_result = @bitCast(kr);
        // Keep the faulty baseline's speculative parse bounded. The real
        // receive result is preserved; only inaccessible wire data is zeroed.
        const bytes: [*]u8 = @ptrCast(h);
        @memset(bytes[0..size], 0);
    }
    return kr;
}
fn unpack(_: O, _: usize) callconv(.c) void {
    add(&parses);
}
fn sourceCancelled(p: O) callconv(.c) void {
    if (p != conn) return;
    add(&source_completions);
    if (mode != 5 or @cmpxchgStrong(u32, &cancel_paused, 0, 1, .seq_cst, .seq_cst) != null) return;
    _ = c.sem_post(&cancel_entered);
    _ = c.sem_wait(&cancel_gate);
}
fn portRelease(p: O, _: u32, kind: u32) callconv(.c) void {
    if (p != conn) return;
    if (kind == 1) add(&remote_releases) else if (kind == 2) add(&local_releases);
}
fn pendingFree(_: O) callconv(.c) void {
    add(&pending_frees);
}
fn event(_: O, obj: O) callconv(.c) void {
    add(&events);
    if (obj == @as(O, @ptrCast(&_xpc_error_connection_invalid))) add(&invalid) else if (obj == @as(O, @ptrCast(&_xpc_error_connection_interrupted))) add(&interrupted) else {
        add(&valid);
        const n = xpc_dictionary_get_uint64(obj, "value");
        if (n < 64) _ = @atomicRmw(u64, &values, .Or, @as(u64, 1) << @intCast(n), .seq_cst);
    }
    _ = c.sem_post(&event_done);
}
fn reply(ctx: O, obj: O) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(ctx.?));
    add(&slot.calls);
    if (obj == @as(O, @ptrCast(&_xpc_error_connection_invalid))) add(&slot.invalid);
    if (obj == @as(O, @ptrCast(&_xpc_error_connection_interrupted))) add(&slot.interrupted);
    _ = c.sem_post(&reply_done);
}
fn finalize(_: O) callconv(.c) void {
    add(&finalizers);
    _ = c.sem_post(&finished);
}
fn port() u32 {
    var p: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) == 0, "allocate right");
    need(c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "make send");
    return p;
}
fn start(which: u32) O {
    mode = which;
    for ([_]*c.sem_t{ &entered, &gate, &after, &event_done, &reply_done, &finished, &cancel_entered, &cancel_gate }) |s| need(c.sem_init(s, 0, 0) == 0, "semaphore");
    const hooks = Hooks{ .before_handler = &beforeHandler, .after_receive = &afterReceive, .receive = &receive, .unpack = &unpack, .source_cancelled = &sourceCancelled, .port_release = &portRelease, .pending_free = &pendingFree };
    op500_install(&hooks);
    const target = dispatch_queue_create("op500.target", null);
    need(target != null, "target queue");
    conn = xpc_connection_create(null, target);
    dispatch_release(target);
    need(conn != null, "connection");
    local = op500_local(conn);
    remote = port();
    need(c.mach_port_mod_refs(c.mach_task_self(), remote, c.MACH_PORT_RIGHT_SEND, 1) == 0, "owned remote uref");
    op500_remote(conn, remote);
    op500_event_handler(conn, null, &event);
    xpc_connection_set_context(conn, null);
    xpc_connection_set_finalizer_f(conn, &finalize);
    xpc_connection_resume(conn);
    return op500_recv_queue(conn);
}
fn send(value: u64) void {
    const obj = xpc_dictionary_create(null, null, 0);
    need(obj != null, "dictionary");
    xpc_dictionary_set_uint64(obj, "value", value);
    need(op500_pipe_send(obj, local, remote, value) == 0, "send wire message");
    xpc_release(obj);
}
fn drain(name: u32) void {
    var bytes: [8192]u8 align(8) = @splat(0);
    const h: *c.mach_msg_header_t = @ptrCast(&bytes);
    need(c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, name, 0, 0) == 0, "competing receive");
    c.mach_msg_destroy(h);
}
fn finish() void {
    xpc_connection_cancel(conn);
    xpc_release(conn);
    need(wait(&finished, 3000), "cancellation finalizer");
}
fn fact(name: [*:0]const u8, i: usize, expected: u64, observed: u64) void {
    _ = c.printf("xpc case=%s fact=%u expected=%llu observed=%llu\n", name, @as(c_uint, @intCast(i)), expected, observed);
}
fn report(name: [*:0]const u8, want: []const u64, got: []const u64) void {
    for (want, got, 0..) |e, o, i| fact(name, i, e, o);
    var differs = false;
    for (want, got) |e, o| differs = differs or e != o;
    var kind: c.mach_port_type_t = 0;
    const local_gone = @intFromBool(c.mach_port_type(c.mach_task_self(), local, &kind) == c.KERN_INVALID_NAME);
    var count: u32 = 0;
    const right: u32 = if (mode == 4 or mode == 6) c.MACH_PORT_RIGHT_DEAD_NAME else c.MACH_PORT_RIGHT_SEND;
    const remaining = if (c.mach_port_get_refs(c.mach_task_self(), remote, right, &count) == 0) count else 0;
    fact(name, want.len, 1, local_gone);
    fact(name, want.len + 1, 1, remaining);
    differs = differs or local_gone != 1 or remaining != 1;
    _ = c.mach_port_destroy(c.mach_task_self(), remote);
    observation_mismatch = observation_mismatch or differs;
}
fn conclude() void {
    if (observation_mismatch) c.atf_tc_fail("xpc consumer observations differ");
}
fn released() [4]u64 {
    return .{ get(&local_releases), get(&remote_releases), get(&finalizers), get(&source_completions) };
}
fn stale(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const q = start(1);
    send(1);
    need(wait(&entered, 3000), "handler entered");
    drain(local);
    _ = c.sem_post(&gate);
    const returned = wait(&after, 300);
    // Same rescue/next message on both images. Base uses it to escape a
    // blocking receive; fixed receives it during a later source invocation.
    send(2);
    need(wait(&event_done, 3000), "next event");
    fence(q);
    const result = first_result;
    const options = first_options;
    const seen = get(&valid);
    const mask = get(&values);
    finish();
    const r = released();
    report("stale_readiness", &.{ 1, 1, c.MACH_RCV_TIMED_OUT, 1, 4, 1, 1, 1, 2 }, &.{ @intFromBool(returned), @intFromBool((options & c.MACH_RCV_TIMEOUT) != 0), result, seen, mask, r[0], r[1], r[2], r[3] });
    conclude();
}
fn failed(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const q = start(2);
    send(1);
    need(wait(&after, 3000), "failed receive returned");
    fence(q);
    const p = get(&parses);
    const v = get(&valid);
    const kr = first_result;
    while (c.sem_trywait(&event_done) == 0) {}
    send(2);
    need(wait(&event_done, 3000), "next event");
    fence(q);
    const sum = get(&values);
    finish();
    report("failed_receive", &.{ 1, c.MACH_RCV_INTERRUPTED, 0, 0, 4, 1, 1, 1 }, &.{ injected, kr, p, v, sum, get(&local_releases), get(&remote_releases), get(&finalizers) });
    conclude();
}
fn gone(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const q = start(3);
    send(1);
    need(wait(&entered, 3000), "local handler entered");
    // The connection's existing send/dead-name uref reserves this name until
    // its own cancellation closes it. Revoke the receive right, not the name.
    need(c.mach_port_mod_refs(c.mach_task_self(), local, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0, "external local receive revocation");
    _ = c.sem_post(&gate);
    need(wait(&after, 3000), "terminal receive returned");
    fence(q);
    const cancelled = op500_cancelled(conn);
    const terminal_event = get(&invalid);
    const kr = first_result;
    const p = get(&parses);
    finish();
    report("local_port_gone", &.{ c.MACH_RCV_INVALID_NAME, c.MACH_RCV_INVALID_NAME, 0, 1, 1, 1, 1, 1, 2 }, &.{ native_result, kr, p, cancelled, terminal_event, get(&invalid), get(&local_releases), get(&remote_releases), get(&source_completions) });
    conclude();
}
fn pending() O {
    const q = dispatch_queue_create("op500.replies", null);
    need(q != null, "reply queue");
    const obj = xpc_dictionary_create(null, null, 0);
    need(obj != null, "request dictionary");
    for (&slots) |*slot| op500_reply(conn, obj, q, slot, &reply);
    xpc_release(obj);
    fence(op500_send_queue(conn));
    drain(remote);
    drain(remote);
    return q;
}
fn remoteDeath(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const q = start(4);
    const replies = pending();
    need(c.mach_port_mod_refs(c.mach_task_self(), remote, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0, "remote receive death");
    need(wait(&reply_done, 3000) and wait(&reply_done, 3000), "two remote-death replies");
    need(wait(&event_done, 3000), "remote-death event");
    fence(q);
    fence(replies);
    const cancelled = op500_cancelled(conn);
    const event_invalid = get(&invalid);
    finish();
    dispatch_release(replies);
    report("remote_pending", &.{ 1, 1, 1, 1, 0, 0, 1, 1, 2, 1, 1, 1 }, &.{ get(&slots[0].calls), get(&slots[1].calls), get(&slots[0].invalid), get(&slots[1].invalid), get(&slots[0].interrupted), get(&slots[1].interrupted), cancelled, event_invalid, get(&pending_frees), get(&local_releases), get(&remote_releases), get(&finalizers) });
    remoteSendError();
    conclude();
}
fn resetPhase() void {
    for ([_]*c.sem_t{ &entered, &gate, &after, &event_done, &reply_done, &finished, &cancel_entered, &cancel_gate }) |s| _ = c.sem_destroy(s);
    slots = @splat(.{});
    conn = null;
    local = 0;
    remote = 0;
    paused = 0;
    cancel_paused = 0;
    injected = 0;
    receives = 0;
    first_result = 0;
    first_options = 0;
    native_result = 0;
    parses = 0;
    events = 0;
    valid = 0;
    invalid = 0;
    interrupted = 0;
    values = 0;
    local_releases = 0;
    remote_releases = 0;
    finalizers = 0;
    source_completions = 0;
    pending_frees = 0;
}
fn remoteSendError() void {
    resetPhase();
    const q = start(6);
    // Prevent the send-death callback from completing the requests first.
    xpc_connection_suspend(conn);
    const sends = op500_send_queue(conn);
    dispatch_suspend(sends);
    const replies = dispatch_queue_create("op500.send-error.replies", null);
    need(replies != null, "send-error reply queue");
    const obj = xpc_dictionary_create(null, null, 0);
    need(obj != null, "send-error dictionary");
    for (&slots) |*slot| op500_reply(conn, obj, replies, slot, &reply);
    xpc_release(obj);
    need(c.mach_port_mod_refs(c.mach_task_self(), remote, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0, "death before send");
    dispatch_resume(sends);
    need(wait(&reply_done, 3000) and wait(&reply_done, 3000), "two send-error replies");
    fence(sends);
    xpc_connection_resume(conn);
    need(wait(&event_done, 3000), "send-error event");
    fence(q);
    fence(replies);
    const cancelled = op500_cancelled(conn);
    const event_invalid = get(&invalid);
    finish();
    dispatch_release(replies);
    report("remote_send_error", &.{ 1, 1, 1, 1, 0, 0, 1, 1, 2, 1, 1, 1 }, &.{ get(&slots[0].calls), get(&slots[1].calls), get(&slots[0].invalid), get(&slots[1].invalid), get(&slots[0].interrupted), get(&slots[1].interrupted), cancelled, event_invalid, get(&pending_frees), get(&local_releases), get(&remote_releases), get(&finalizers) });
}

fn cancelling(_: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = start(5);
    const replies = pending();
    xpc_connection_cancel(conn);
    need(wait(&cancel_entered, 3000), "cancellation completion held");
    xpc_connection_cancel(conn);
    xpc_release(conn);
    need(wait(&reply_done, 3000) and wait(&reply_done, 3000), "cancellation replies");
    fence(replies);
    const held = @intFromBool(op500_cancel_count(conn) > 0);
    const early_local = get(&local_releases);
    const early_remote = get(&remote_releases);
    var kind: c.mach_port_type_t = 0;
    const alive_local = @intFromBool(c.mach_port_type(c.mach_task_self(), local, &kind) == 0 and (kind & c.MACH_PORT_TYPE_RECEIVE) != 0);
    const alive_remote = @intFromBool(c.mach_port_type(c.mach_task_self(), remote, &kind) == 0 and (kind & c.MACH_PORT_TYPE_SEND) != 0);
    _ = c.sem_post(&cancel_gate);
    need(wait(&finished, 3000), "completion finalizer");
    dispatch_release(replies);
    report("cancel_inflight", &.{ 1, 0, 0, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 2 }, &.{ held, early_local, early_remote, alive_local, alive_remote, get(&invalid), get(&slots[0].calls), get(&slots[1].calls), get(&slots[0].invalid) + get(&slots[1].invalid), get(&pending_frees), get(&local_releases), get(&remote_releases), get(&finalizers), get(&source_completions) });
    conclude();
}
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [5]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "25");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "stale_readiness", "failed_receive", "local_port_gone", "remote_pending", "cancel_inflight" };
    const bodies = .{ &stale, &failed, &gone, &remoteDeath, &cancelling };
    inline for (0..5) |i| {
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
