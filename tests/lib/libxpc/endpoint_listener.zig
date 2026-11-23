// SPDX-License-Identifier: BSD-2-Clause
// xpc-lite B0: an anonymous listener hands out peers; an endpoint and each
// connection made from it hold their own reference on the listener's port;
// a connection gives that reference up when it is cancelled or its listener
// goes, while its object is still held. All within one process. Quotations
// are from lib/libxpc/xpc/connection.h.
//
// Port names on rmxOS are file descriptors and mach_port_names is not
// implemented (sys/compat/mach/ipc/mach_port.c:233), so the task's names are
// its descriptor table's port entries (kern.proc.filedesc, KF_TYPE_PORT 17
// and KF_TYPE_PORTSET 18, as tests/lib/launchd/fd_inventory.zig counts them).
// The count the cases compare is the names that hold a send right or a dead
// name (mach_port_type). It leaves out every thread's MIG reply port, a
// receive right alone that comes and goes with its thread.
//
// The program links libxpc.so.5 by its soname with no run path, so
// LD_LIBRARY_PATH selects the library under test. Each case prints the path
// of the libxpc it loaded.
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
    @cInclude("mach/mach.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/user.h");
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
extern fn xpc_connection_set_finalizer_f(O, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn xpc_connection_resume(O) void;
extern fn xpc_connection_cancel(O) void;
extern fn xpc_connection_send_message(O, O) void;
extern fn xpc_connection_send_message_with_reply(O, O, O, ?*anyopaque) void;
extern fn xpc_dictionary_create(O, O, usize) O;
extern fn xpc_dictionary_create_reply(O) O;
extern fn xpc_dictionary_set_uint64(O, [*:0]const u8, u64) void;
extern fn xpc_dictionary_get_uint64(O, [*:0]const u8) u64;
extern fn xpc_get_type(O) ?*const anyopaque;
extern fn xpc_release(O) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern const _xpc_error_connection_invalid: u8;
extern const _xpc_error_connection_interrupted: u8;
extern const _xpc_type_connection: u8;
extern const _xpc_type_dictionary: u8;
extern var _NSConcreteStackBlock: [32]?*anyopaque;
extern fn _Block_copy(?*const anyopaque) ?*anyopaque;
extern fn _Block_release(?*const anyopaque) void;

// Event codes: a dictionary's "value" (always below INVALID), or these.
const INVALID: u64 = 1 << 32;
const INTERRUPTED: u64 = INVALID + 1;
const PEER: u64 = INVALID + 2;
const OTHER: u64 = INVALID + 3;
const NONE: u64 = INVALID + 4;
fn eventCode(o: O) u64 {
    if (o == @as(O, @ptrCast(@constCast(&_xpc_error_connection_invalid)))) return INVALID;
    if (o == @as(O, @ptrCast(@constCast(&_xpc_error_connection_interrupted)))) return INTERRUPTED;
    const t = xpc_get_type(o);
    if (t == @as(?*const anyopaque, @ptrCast(&_xpc_type_connection))) return PEER;
    if (t == @as(?*const anyopaque, @ptrCast(&_xpc_type_dictionary))) return xpc_dictionary_get_uint64(o, "value");
    return OTHER;
}

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

// The events one handler saw, in order.
const Events = struct {
    sem: c.sem_t = undefined,
    log: [16]u64 = @splat(0),
    n: u64 = 0,
    fn init(e: *Events) void {
        e.* = .{};
        _ = c.sem_init(&e.sem, 0, 0);
    }
    fn record(e: *Events, code: u64) void {
        const i = @atomicRmw(u64, &e.n, .Add, 1, .seq_cst);
        if (i < e.log.len) e.log[@intCast(i)] = code;
        _ = c.sem_post(&e.sem);
    }
    fn count(e: *Events) u64 {
        return load(&e.n);
    }
    // Read only after waitFor has seen the event.
    fn first(e: *Events) u64 {
        return if (e.count() > 0) e.log[0] else NONE;
    }
    fn waitFor(e: *Events, n: u64, ms: u64) bool {
        var seen: u64 = 0;
        while (seen < n) : (seen += 1) if (!waitMs(&e.sem, ms)) return false;
        return true;
    }
};

// Blocks ABI (BlocksRuntime runtime.c), as in ool_limit.zig: a stack literal
// copied to the heap once. The handler gets its context and the connection
// it was set on, so a peer's handler can reply on its peer.
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
fn block(f: Fn, ctx: ?*anyopaque, conn: O) ?*anyopaque {
    var literal = Block{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = 0, .reserved = 0, .invoke = &blockInvoke, .descriptor = &descriptor, .f = f, .ctx = ctx, .conn = conn };
    return _Block_copy(&literal);
}
fn setHandler(conn: O, f: Fn, ctx: ?*anyopaque) void {
    const b = block(f, ctx, conn);
    xpc_connection_set_event_handler(conn, b);
    _Block_release(b);
}
fn recordInto(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const e: *Events = @ptrCast(@alignCast(ctx.?));
    e.record(eventCode(o));
}
fn message(value: u64) O {
    const m = xpc_dictionary_create(null, null, 0);
    need(m != null, "message dictionary");
    xpc_dictionary_set_uint64(m, "value", value);
    return m;
}
fn sendValue(conn: O, value: u64) void {
    const m = message(value);
    xpc_connection_send_message(conn, m);
    xpc_release(m);
}
fn sendWithReply(conn: O, value: u64, replies: *Events) void {
    const m = message(value);
    const b = block(&recordInto, replies, null);
    xpc_connection_send_message_with_reply(conn, m, null, b);
    _Block_release(b);
    xpc_release(m);
}

// Facts: every observation printed with what the case expects; a case fails
// after printing all of its facts when any differs.
var failed = false;
fn need(ok: bool, what: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("setup: %s", what);
}
fn fact(case: [*:0]const u8, label: [*:0]const u8, expected: u64, observed: u64) void {
    _ = c.printf("xpc_b0 case=%s fact=%s expected=%llu observed=%llu\n", case, label, expected, observed);
    _ = c.fflush(null);
    if (expected != observed) failed = true;
}
fn conclude(case: [*:0]const u8) void {
    if (failed) c.atf_tc_fail("%s: an observation differs from its expected value", case);
}
fn library(case: [*:0]const u8) void {
    var info: c.Dl_info = undefined;
    const found = c.dladdr(@ptrCast(&xpc_connection_create), &info) != 0 and info.dli_fname != null;
    const path: [*c]const u8 = if (found) info.dli_fname else "unknown";
    _ = c.printf("xpc_b0 case=%s library=%s codes=invalid:%llu,interrupted:%llu,peer:%llu,none:%llu\n", case, path, INVALID, INTERRUPTED, PEER, NONE);
    _ = c.fflush(null);
}

// ---- The task's port names -------------------------------------------------

const Snapshot = struct {
    fds: [2048]c_int = undefined,
    types: [2048]u32 = undefined,
    n: usize = 0,
    ports: u64 = 0, // every port and port-set name
    held: u64 = 0, // names holding a send right or a dead name
};
fn snapshot(s: *Snapshot) void {
    s.* = .{};
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_FILEDESC, c.getpid() };
    var size: usize = 0;
    need(c.sysctl(&mib, mib.len, null, &size, null, 0) == 0, "file table size");
    size += size / 2 + 65536;
    const bytes: [*]u8 = @ptrCast(c.malloc(size) orelse c.atf_tc_fail("setup: file table buffer"));
    defer c.free(bytes);
    need(c.sysctl(&mib, mib.len, bytes, &size, null, 0) == 0, "file table");
    // kern_descrip.c:pack_kinfo trims kf_path and rounds each record to 8.
    const minimum = @offsetOf(c.kinfo_file, "kf_fd") + @sizeOf(c_int);
    var offset: usize = 0;
    while (offset < size) {
        need(size - offset >= minimum, "file record truncated");
        const f: *align(1) const c.kinfo_file = @ptrCast(&bytes[offset]);
        need(f.kf_structsize >= minimum and f.kf_structsize <= size - offset, "file record extent");
        if (f.kf_type == 17 or f.kf_type == 18) {
            s.ports += 1;
            var t: c.mach_port_type_t = 0;
            if (f.kf_type == 17 and c.mach_port_type(c.mach_task_self(), @intCast(f.kf_fd), &t) == 0) {
                if ((t & (c.MACH_PORT_TYPE_SEND | c.MACH_PORT_TYPE_DEAD_NAME)) != 0) s.held += 1;
            }
            need(s.n < s.fds.len, "port names fit the snapshot");
            s.fds[s.n] = f.kf_fd;
            s.types[s.n] = t;
            s.n += 1;
        }
        offset += @intCast(f.kf_structsize);
    }
}
// The one port name made between two snapshots that holds a receive right
// and a send right, as a new connection's own port does.
fn onlyNew(a: *const Snapshot, b: *const Snapshot) ?u32 {
    var found: ?u32 = null;
    var count: u32 = 0;
    for (b.fds[0..b.n], b.types[0..b.n]) |fd, t| {
        var old = false;
        for (a.fds[0..a.n]) |x| old = old or x == fd;
        const both = c.MACH_PORT_TYPE_RECEIVE | c.MACH_PORT_TYPE_SEND;
        if (!old and (t & both) == both) {
            count += 1;
            found = @intCast(fd);
        }
    }
    return if (count == 1) found else null;
}
fn held() u64 {
    var s: Snapshot = undefined;
    snapshot(&s);
    return s.held;
}
// The held-name count once it equals target, or its last value after ms.
fn settleHeld(target: u64, ms: u64) u64 {
    const start = nowMs();
    var n = held();
    while (n != target and nowMs() - start < ms) {
        _ = c.usleep(10_000);
        n = held();
    }
    return n;
}
// The held-name count once five readings 50 ms apart agree, within ms.
fn stableHeld(ms: u64) u64 {
    const start = nowMs();
    var last = held();
    var same: u32 = 0;
    while (same < 5 and nowMs() - start < ms) {
        _ = c.usleep(50_000);
        const n = held();
        same = if (n == last) same + 1 else 0;
        last = n;
    }
    return last;
}
fn refs(name: u32, right: c.mach_port_right_t) u64 {
    var n: c.mach_port_urefs_t = 0;
    return if (c.mach_port_get_refs(c.mach_task_self(), name, right, &n) == 0) n else 0;
}
fn settleRefs(name: u32, right: c.mach_port_right_t, target: u64, ms: u64) u64 {
    const start = nowMs();
    var n = refs(name, right);
    while (n != target and nowMs() - start < ms) {
        _ = c.usleep(10_000);
        n = refs(name, right);
    }
    return n;
}
fn isDead(name: u32) bool {
    var t: c.mach_port_type_t = 0;
    return c.mach_port_type(c.mach_task_self(), name, &t) == 0 and (t & c.MACH_PORT_TYPE_DEAD_NAME) != 0;
}

// ---- A listener and its peers ----------------------------------------------

const Mode = enum { serve, refuse };
const Listen = struct {
    mode: Mode,
    listener_events: Events = .{},
    peer_events: Events = .{},
    finalized: c.sem_t = undefined,
    fn init(s: *Listen, mode: Mode) void {
        s.* = .{ .mode = mode };
        s.listener_events.init();
        s.peer_events.init();
        _ = c.sem_init(&s.finalized, 0, 0);
    }
};
fn peerFinalized(ctx: ?*anyopaque) callconv(.c) void {
    const s: *Listen = @ptrCast(@alignCast(ctx.?));
    _ = c.sem_post(&s.finalized);
}
// A peer answers each request with value + 1.
fn peerEvent(ctx: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const s: *Listen = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    if (code < INVALID) {
        const r = xpc_dictionary_create_reply(o);
        if (r != null) {
            xpc_dictionary_set_uint64(r, "value", code + 1);
            xpc_connection_send_message(peer, r);
            xpc_release(r);
        }
    }
    s.peer_events.record(code);
}
// "listener connections will receive connections and not messages ... You
// must set an event handler and resume the connection. If you do not wish to
// accept the connection, you may simply call xpc_connection_cancel() on it."
fn listenerEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const s: *Listen = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    s.listener_events.record(code);
    if (code != PEER) return;
    switch (s.mode) {
        .serve => {
            setHandler(o, &peerEvent, s);
            xpc_connection_resume(o);
        },
        .refuse => {
            xpc_connection_set_context(o, s);
            xpc_connection_set_finalizer_f(o, &peerFinalized);
            xpc_connection_cancel(o);
        },
    }
}

// ---- anonymousListenerPeer ---------------------------------------------------

fn anonymousListenerPeer(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "anonymousListenerPeer";
    library(case);
    // A listener that refuses its peer. The client's own port is found
    // before anything is resumed, while nothing else makes or frees names.
    var refuse: Listen = undefined;
    refuse.init(.refuse);
    var refused_client: Events = undefined;
    refused_client.init();
    const la = xpc_connection_create(null, dispatch_queue_create("op751.refuse", null));
    need(la != null, "refusing listener");
    setHandler(la, &listenerEvent, &refuse);
    const ea = xpc_endpoint_create(la);
    need(ea != null, "refusing listener's endpoint");
    var before: Snapshot = undefined;
    var after: Snapshot = undefined;
    snapshot(&before);
    const ca = xpc_connection_create_from_endpoint(ea);
    snapshot(&after);
    need(ca != null, "connection from the refusing listener's endpoint");
    xpc_release(ea);
    const local = onlyNew(&before, &after) orelse c.atf_tc_fail("setup: one new port for the connection");
    const own = refs(local, c.MACH_PORT_RIGHT_SEND);
    setHandler(ca, &recordInto, &refused_client);
    xpc_connection_resume(la);
    xpc_connection_resume(ca);
    sendValue(ca, 7);
    const heard = refuse.listener_events.waitFor(1, 3000);
    const disposed = heard and refuse.listener_events.first() == PEER and waitMs(&refuse.finalized, 3000);
    fact(case, "refuse_listener_first_event", PEER, if (heard) refuse.listener_events.first() else NONE);
    fact(case, "refused_peer_disposed", 1, @intFromBool(disposed));
    // The send right the message carried for replies was the peer's to drop.
    fact(case, "refused_reply_right_released", own, settleRefs(local, c.MACH_PORT_RIGHT_SEND, own, 3000));
    fact(case, "refused_peer_events", 0, refuse.peer_events.count());
    fact(case, "refuse_listener_events", 1, refuse.listener_events.count());
    conclude(case);

    // A listener that serves its peer: one connection to the listener, the
    // message to the peer once it has a handler and is resumed, and the
    // peer's reply to the sender.
    var serve: Listen = undefined;
    serve.init(.serve);
    var client: Events = undefined;
    client.init();
    var replies: Events = undefined;
    replies.init();
    const lb = xpc_connection_create(null, dispatch_queue_create("op751.serve", null));
    need(lb != null, "serving listener");
    setHandler(lb, &listenerEvent, &serve);
    xpc_connection_resume(lb);
    const eb = xpc_endpoint_create(lb);
    need(eb != null, "serving listener's endpoint");
    const cb = xpc_connection_create_from_endpoint(eb);
    need(cb != null, "connection from the serving listener's endpoint");
    xpc_release(eb);
    setHandler(cb, &recordInto, &client);
    xpc_connection_resume(cb);
    sendWithReply(cb, 751, &replies);
    const replied = replies.waitFor(1, 3000);
    const served = serve.peer_events.waitFor(1, 3000);
    fact(case, "reply_value", 752, if (replied) replies.first() else NONE);
    fact(case, "peer_first_event", 751, if (served) serve.peer_events.first() else NONE);
    fact(case, "peer_events", 1, serve.peer_events.count());
    fact(case, "listener_first_event", PEER, serve.listener_events.first());
    fact(case, "listener_events", 1, serve.listener_events.count());
    fact(case, "client_events", 0, client.count());
    xpc_connection_cancel(cb);
    xpc_release(cb);
    xpc_connection_cancel(ca);
    xpc_release(ca);
    xpc_connection_cancel(lb);
    xpc_release(lb);
    xpc_connection_cancel(la);
    xpc_release(la);
    conclude(case);
}

// ---- endpointOwnsRight -------------------------------------------------------

// In one task every send right to the listener's port shares the name of its
// receive right, so the references on that name are what can be counted.
fn endpointOwnsRight(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointOwnsRight";
    library(case);
    var serve: Listen = undefined;
    serve.init(.serve);
    var client: Events = undefined;
    client.init();
    var replies: Events = undefined;
    replies.init();
    var before: Snapshot = undefined;
    var after: Snapshot = undefined;
    snapshot(&before);
    const l = xpc_connection_create(null, dispatch_queue_create("op751.owns", null));
    snapshot(&after);
    need(l != null, "listener");
    const name = onlyNew(&before, &after) orelse c.atf_tc_fail("setup: one new port for the listener");
    const send = c.MACH_PORT_RIGHT_SEND;
    fact(case, "send_refs_listener", 1, refs(name, send));
    const e = xpc_endpoint_create(l);
    need(e != null, "endpoint");
    fact(case, "send_refs_with_endpoint", 2, refs(name, send));
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "connection from the endpoint");
    fact(case, "send_refs_with_connection", 3, refs(name, send));
    xpc_release(e);
    fact(case, "send_refs_endpoint_released", 2, refs(name, send));
    conclude(case);

    setHandler(l, &listenerEvent, &serve);
    xpc_connection_resume(l);
    setHandler(conn, &recordInto, &client);
    xpc_connection_resume(conn);
    sendWithReply(conn, 41, &replies);
    const replied = replies.waitFor(1, 3000);
    fact(case, "reply_after_endpoint_released", 42, if (replied) replies.first() else NONE);
    fact(case, "send_refs_connected", 2, refs(name, send));
    xpc_connection_cancel(conn);
    fact(case, "send_refs_after_cancel", 1, settleRefs(name, send, 1, 3000));
    const ended = client.waitFor(1, 3000);
    fact(case, "client_final_event", INVALID, if (ended) client.first() else NONE);
    // The last reference: xpc_connection_destroy must not release it again.
    xpc_release(conn);
    _ = c.usleep(100_000);
    fact(case, "send_refs_after_release", 1, refs(name, send));
    fact(case, "client_events", 1, client.count());
    xpc_connection_cancel(l);
    xpc_release(l);
    conclude(case);
}

// ---- deadEndpointInvalid -----------------------------------------------------

// "this connection will receive XPC_ERROR_CONNECTION_INVALID if the listening
// side crashes, exits or cancels the listener connection."
fn deadEndpointInvalid(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "deadEndpointInvalid";
    library(case);
    var events: Events = undefined;
    events.init();
    var queued: Events = undefined;
    queued.init();
    var later: Events = undefined;
    later.init();
    var before: Snapshot = undefined;
    var after: Snapshot = undefined;
    snapshot(&before);
    const l = xpc_connection_create(null, null);
    snapshot(&after);
    need(l != null, "listener");
    const name = onlyNew(&before, &after) orelse c.atf_tc_fail("setup: one new port for the listener");
    const e = xpc_endpoint_create(l);
    need(e != null, "endpoint");
    xpc_connection_cancel(l);
    xpc_release(l);
    // The listener's receive right goes on its send queue; the endpoint's
    // right then names a dead port.
    const start = nowMs();
    while (!isDead(name) and nowMs() - start < 3000) _ = c.usleep(10_000);
    const dead = c.MACH_PORT_RIGHT_DEAD_NAME;
    fact(case, "endpoint_name_dead", 1, @intFromBool(isDead(name)));
    fact(case, "dead_refs_endpoint", 1, refs(name, dead));
    conclude(case);

    const conn = xpc_connection_create_from_endpoint(e);
    fact(case, "connection_returned", 1, @intFromBool(conn != null));
    conclude(case);
    fact(case, "dead_refs_with_connection", 2, refs(name, dead));
    xpc_release(e);
    fact(case, "dead_refs_endpoint_released", 1, refs(name, dead));
    setHandler(conn, &recordInto, &events);
    sendWithReply(conn, 1, &queued);
    xpc_connection_resume(conn);
    sendWithReply(conn, 2, &later);
    const ended = events.waitFor(1, 3000);
    const queued_done = queued.waitFor(1, 3000);
    const later_done = later.waitFor(1, 3000);
    // A second handler event would arrive here.
    _ = c.usleep(200_000);
    fact(case, "handler_first_event", INVALID, if (ended) events.first() else NONE);
    fact(case, "handler_events", 1, events.count());
    fact(case, "queued_send_reply", INVALID, if (queued_done) queued.first() else NONE);
    fact(case, "later_send_reply", INVALID, if (later_done) later.first() else NONE);
    // The connection gives up its dead name at cancellation.
    fact(case, "dead_refs_after_invalid", 0, settleRefs(name, dead, 0, 3000));
    xpc_release(conn);
    conclude(case);
}

// ---- heldConnectionReleases, cancelledConnectionReleases ---------------------

// One round: a listener stands for a client and gets one progress update
// from a connection made from its endpoint, which stands for the server.
const Round = struct {
    updates: u64 = 0,
    update_sem: c.sem_t = undefined,
    server_invalid: u64 = 0,
    server_other: u64 = 0,
    server_sem: c.sem_t = undefined,
    peers: u64 = 0,
    fn init(r: *Round) void {
        r.* = .{};
        _ = c.sem_init(&r.update_sem, 0, 0);
        _ = c.sem_init(&r.server_sem, 0, 0);
    }
};
fn clientUpdate(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const r: *Round = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) < INVALID) {
        bump(&r.updates);
        _ = c.sem_post(&r.update_sem);
    }
}
// The client's listener accepts its peer. A library whose anonymous
// connection is not a listener gives the update to this handler itself; it
// counts as delivered, so the round goes on to the release under test.
fn clientListener(ctx: ?*anyopaque, x: O, o: O) callconv(.c) void {
    const r: *Round = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) == PEER) {
        bump(&r.peers);
        setHandler(o, &clientUpdate, r);
        xpc_connection_resume(o);
        return;
    }
    clientUpdate(ctx, x, o);
}
fn serverEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const r: *Round = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) == INVALID) bump(&r.server_invalid) else bump(&r.server_other);
    _ = c.sem_post(&r.server_sem);
}
fn oneRound(r: *Round, value: u64, cancel_server: bool, q: O) O {
    const l = xpc_connection_create(null, q);
    need(l != null, "client listener");
    setHandler(l, &clientListener, r);
    xpc_connection_resume(l);
    const e = xpc_endpoint_create(l);
    need(e != null, "client listener's endpoint");
    const s = xpc_connection_create_from_endpoint(e);
    need(s != null, "server connection from the endpoint");
    xpc_release(e);
    setHandler(s, &serverEvent, r);
    xpc_connection_resume(s);
    sendValue(s, value);
    need(waitMs(&r.update_sem, 3000), "progress update reached the client");
    if (cancel_server) {
        xpc_connection_cancel(s);
        need(waitMs(&r.server_sem, 3000), "cancelled server connection's final event");
    }
    // The request is finished: the client cancels its listener.
    xpc_connection_cancel(l);
    xpc_release(l);
    return s;
}
const ROUNDS = 100;
fn heldRounds(case: [*:0]const u8, cancel_server: bool) void {
    library(case);
    var names_rc: c_int = 0;
    {
        var list: c.mach_port_name_array_t = null;
        var types: c.mach_port_type_array_t = null;
        var n: c.mach_msg_type_number_t = 0;
        var t: c.mach_msg_type_number_t = 0;
        names_rc = c.mach_port_names(c.mach_task_self(), &list, &n, &types, &t);
    }
    _ = c.printf("xpc_b0 case=%s mach_port_names_rc=%d counted=kern.proc.filedesc names_with_send_or_dead_name\n", case, names_rc);
    const q = dispatch_queue_create("op751.client", null);
    need(q != null, "client queue");
    // A first round lets libdispatch and libxpc make their one-time names.
    var warm: Round = undefined;
    warm.init();
    const w = oneRound(&warm, 1000, cancel_server, q);
    if (!cancel_server) _ = waitMs(&warm.server_sem, 3000);
    xpc_release(w);
    const baseline = stableHeld(3000);
    var start: Snapshot = undefined;
    snapshot(&start);

    var r: Round = undefined;
    r.init();
    var servers: [ROUNDS]O = @splat(null);
    for (&servers, 0..) |*s, i| s.* = oneRound(&r, i, cancel_server, q);
    // Held and never cancelled, each server connection still hears that its
    // listener is gone.
    const t0 = nowMs();
    while (load(&r.server_invalid) < ROUNDS and nowMs() - t0 < 5000) _ = c.usleep(10_000);
    const settled = settleHeld(baseline, 5000);
    var end: Snapshot = undefined;
    snapshot(&end);
    _ = c.printf("xpc_b0 case=%s ports_start=%llu ports_end=%llu held_start=%llu held_end=%llu\n", case, start.ports, end.ports, start.held, end.held);
    fact(case, "rounds_delivered", ROUNDS, load(&r.updates));
    fact(case, "client_peers", ROUNDS, load(&r.peers));
    fact(case, "server_invalid", ROUNDS, load(&r.server_invalid));
    fact(case, "server_other_events", 0, load(&r.server_other));
    fact(case, "held_names_after_rounds", baseline, settled);
    for (servers) |s| xpc_release(s);
    fact(case, "held_names_after_release", baseline, settleHeld(baseline, 2000));
    conclude(case);
}
fn heldConnectionReleases(_: [*c]const c.atf_tc_t) callconv(.c) void {
    heldRounds("heldConnectionReleases", false);
}
fn cancelledConnectionReleases(_: [*c]const c.atf_tc_t) callconv(.c) void {
    heldRounds("cancelledConnectionReleases", true);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn shortHead(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn longHead(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "30");
}
var cases: [5]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "anonymousListenerPeer", "endpointOwnsRight", "deadEndpointInvalid", "heldConnectionReleases", "cancelledConnectionReleases" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &anonymousListenerPeer, &endpointOwnsRight, &deadEndpointInvalid, &heldConnectionReleases, &cancelledConnectionReleases };
    const heads = [_]*const fn ([*c]c.atf_tc_t) callconv(.c) void{ &shortHead, &shortHead, &shortHead, &longHead, &longHead };
    for (&cases, names, bodies, heads) |*tc, name, body, head| {
        var err = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
