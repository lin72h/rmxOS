// SPDX-License-Identifier: BSD-2-Clause
// op-780: a listener holds its own reference on a new peer until its last
// read of it. xpc_connection_receive_one (lib/libxpc/xpc_connection.c) makes
// a new peer with one reference, which belongs to the listener's list, calls
// the listener's handler with the peer, then reads peer->xc_cancelled and
// queues the first message to it. A handler that cancels the peer lets the
// peer's final event and the release of its rights, on the peer's own
// queues, release the list's reference while the listener still reads it.
//
// listenerHoldsNewPeer: the listener's handler gives its first peer a
// finalizer (xpc_connection_set_finalizer_f) and cancels it. The fixture's
// op780_after_handler hook, which the listener calls after the handler
// returns and before its last read of the peer, waits up to 1 s for the
// finalizer. The finalizer has not run by the end of that wait, and it runs
// once after the hook returns.
//
// Linked to the consumer fixture (XPC_CONSUMER_FIXTURE, libxpc_fixture.so.5),
// which has the hook; the product library has none.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    // sys/time.h's bintime inlines do not translate; hide them as the
    // launchd cases do.
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
    @cInclude("dlfcn.h");
    @cInclude("semaphore.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const O = ?*anyopaque;
extern fn xpc_connection_create(?[*:0]const u8, O) O;
extern fn xpc_connection_create_from_endpoint(O) O;
extern fn xpc_endpoint_create(O) O;
extern fn xpc_connection_set_event_handler(O, ?*anyopaque) void;
extern fn xpc_connection_set_context(O, ?*anyopaque) void;
extern fn xpc_connection_set_finalizer_f(O, ?*const fn (?*anyopaque) callconv(.c) void) void;
extern fn xpc_connection_resume(O) void;
extern fn xpc_connection_cancel(O) void;
extern fn xpc_connection_send_message(O, O) void;
extern fn xpc_dictionary_create(O, O, usize) O;
extern fn xpc_dictionary_set_uint64(O, [*:0]const u8, u64) void;
extern fn xpc_get_type(O) ?*const anyopaque;
extern fn xpc_release(O) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern fn op780_install_after_handler(?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void) void;
extern const _xpc_type_connection: u8;
extern var _NSConcreteStackBlock: [32]?*anyopaque;
extern fn _Block_copy(?*const anyopaque) ?*anyopaque;
extern fn _Block_release(?*const anyopaque) void;

fn bump(p: *u64) void {
    _ = @atomicRmw(u64, p, .Add, 1, .seq_cst);
}
fn load(p: *u64) u64 {
    return @atomicLoad(u64, p, .seq_cst);
}
fn nowMs() u64 {
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    return @as(u64, @intCast(t.tv_sec)) * 1000 + @as(u64, @intCast(t.tv_nsec)) / 1_000_000;
}
fn waitMs(s: *c.sem_t, ms: u64) bool {
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &t);
    const ns: u64 = @as(u64, @intCast(t.tv_nsec)) + ms * 1_000_000;
    t.tv_sec += @intCast(ns / 1_000_000_000);
    t.tv_nsec = @intCast(ns % 1_000_000_000);
    return c.sem_timedwait(s, &t) == 0;
}
fn awaitCount(p: *u64, n: u64, ms: u64) bool {
    const start = nowMs();
    while (load(p) < n and nowMs() - start < ms) _ = c.usleep(2_000);
    return load(p) >= n;
}

var failed = false;
fn need(ok: bool, what: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("setup: %s", what);
}
fn fact(case: [*:0]const u8, label: [*:0]const u8, expected: u64, observed: u64) void {
    _ = c.printf("xpc_b0 case=%s fact=%s expected=%llu observed=%llu\n", case, label, expected, observed);
    _ = c.fflush(null);
    if (expected != observed) failed = true;
}
fn library(case: [*:0]const u8) void {
    var info: c.Dl_info = undefined;
    const found = c.dladdr(@ptrCast(&xpc_connection_create), &info) != 0 and info.dli_fname != null;
    const path: [*c]const u8 = if (found) info.dli_fname else "unknown";
    _ = c.printf("xpc_b0 case=%s library=%s\n", case, path);
    _ = c.fflush(null);
}

// Blocks ABI (BlocksRuntime runtime.c), as in reply_right.zig.
const Fn = *const fn (?*anyopaque, O, O) callconv(.c) void;
const Descriptor = extern struct { reserved: c_ulong, size: c_ulong };
const Block = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*Block, O) callconv(.c) void,
    descriptor: *const Descriptor,
    f: Fn,
    ctx: ?*anyopaque,
    conn: O,
};
fn blockInvoke(b: *Block, o: O) callconv(.c) void {
    b.f(b.ctx, b.conn, o);
}
const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Block) };
fn setHandler(conn: O, f: Fn, ctx: ?*anyopaque) void {
    var literal = Block{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = 0, .reserved = 0, .invoke = &blockInvoke, .descriptor = &descriptor, .f = f, .ctx = ctx, .conn = conn };
    const b = _Block_copy(&literal);
    xpc_connection_set_event_handler(conn, b);
    _Block_release(b);
}
fn ignore(_: ?*anyopaque, _: O, _: O) callconv(.c) void {}

// ---- listenerHoldsNewPeer --------------------------------------------------------

const State = struct {
    peer: O = null, // the first peer the listener's handler saw; compared, never read
    peers: u64 = 0,
    finalized: u64 = 0,
    hook_ran: u64 = 0,
    hook_wait_ms: u64 = 0,
    finalized_at_hook: u64 = 0,
    finalized_sem: c.sem_t = undefined,
};
var state: State = .{};
fn finalizer(_: ?*anyopaque) callconv(.c) void {
    bump(&state.finalized);
    _ = c.sem_post(&state.finalized_sem);
}
// The listener's handler: its first peer gets the finalizer and is cancelled.
// The handler keeps no reference of its own.
fn listenerEvent(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    if (xpc_get_type(o) != @as(?*const anyopaque, @ptrCast(&_xpc_type_connection))) return;
    bump(&state.peers);
    if (@atomicLoad(O, &state.peer, .seq_cst) != null) return;
    @atomicStore(O, &state.peer, o, .seq_cst);
    xpc_connection_set_context(o, &state);
    xpc_connection_set_finalizer_f(o, &finalizer);
    xpc_connection_cancel(o);
}
// After the handler returns, on the listener's receive queue: up to 1 s for
// the finalizer, which must not come while the listener still reads the peer.
fn afterHandler(_: ?*anyopaque, peer: ?*anyopaque) callconv(.c) void {
    if (peer == null or peer != @atomicLoad(O, &state.peer, .seq_cst) or load(&state.hook_ran) != 0) return;
    const start = nowMs();
    _ = waitMs(&state.finalized_sem, 1000);
    @atomicStore(u64, &state.hook_wait_ms, nowMs() - start, .seq_cst);
    @atomicStore(u64, &state.finalized_at_hook, load(&state.finalized), .seq_cst);
    bump(&state.hook_ran);
}
fn listenerHoldsNewPeer(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "listenerHoldsNewPeer";
    library(case);
    state = .{};
    _ = c.sem_init(&state.finalized_sem, 0, 0);
    op780_install_after_handler(&afterHandler);
    const l = xpc_connection_create(null, dispatch_queue_create("op780.peer", null));
    need(l != null, "listener");
    setHandler(l, &listenerEvent, null);
    xpc_connection_resume(l);
    const e = xpc_endpoint_create(l);
    need(e != null, "endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "client");
    xpc_release(e);
    setHandler(conn, &ignore, null);
    xpc_connection_resume(conn);
    const m = xpc_dictionary_create(null, null, 0);
    need(m != null, "message");
    xpc_dictionary_set_uint64(m, "value", 1);
    xpc_connection_send_message(conn, m);
    xpc_release(m);
    const hooked = awaitCount(&state.hook_ran, 1, 5000);
    const finalized = awaitCount(&state.finalized, 1, 3000);
    // A second run of the finalizer would come here.
    _ = c.usleep(300_000);
    op780_install_after_handler(null);
    _ = c.printf("xpc_b0 case=%s observed peers=%llu hook_ran=%llu hook_wait_ms=%llu finalized_at_hook=%llu finalized=%llu\n", case, load(&state.peers), load(&state.hook_ran), load(&state.hook_wait_ms), load(&state.finalized_at_hook), load(&state.finalized));
    fact(case, "handler_saw_peer", 1, @intFromBool(@atomicLoad(O, &state.peer, .seq_cst) != null));
    fact(case, "hook_ran", 1, @intFromBool(hooked));
    fact(case, "finalized_before_last_read", 0, load(&state.finalized_at_hook));
    fact(case, "finalized_after", 1, @intFromBool(finalized));
    fact(case, "finalizer_runs", 1, load(&state.finalized));
    xpc_connection_cancel(conn);
    xpc_release(conn);
    xpc_connection_cancel(l);
    xpc_release(l);
    if (failed) c.atf_tc_fail("%s: an observation differs from its expected value", case);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
var tc: c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "listenerHoldsNewPeer", &head, &listenerHoldsNewPeer, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    const added = c.atf_tp_add_tc(tp, &tc);
    if (c.atf_is_error(added)) return added;
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
