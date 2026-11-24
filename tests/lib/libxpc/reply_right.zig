// SPDX-License-Identifier: BSD-2-Clause
// op-757: a send-once reply right per request. connection.h on
// xpc_connection_send_message_with_reply: "If the remote service exits
// prematurely before the reply was received, the
// XPC_ERROR_CONNECTION_INTERRUPTED error will be returned." A request that
// expects a reply carries its own send-once right to a reply port of its
// own; a server that drops the request unanswered (releases it, or exits
// holding it) makes the kernel send MACH_NOTIFY_SEND_ONCE to that port, and
// the call completes once with an error.
//
// The program links libxpc.so.5 by its soname with no run path, so
// LD_LIBRARY_PATH selects the library under test; each case prints the path
// of the libxpc it loaded. A forked child keeps its parent's library.
//
// Port names on rmxOS are file descriptors (kern.proc.filedesc, KF_TYPE_PORT
// 17); mach_port_names is not implemented.
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
    @cInclude("mach/notify.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/user.h");
    @cInclude("sys/wait.h");
    @cInclude("dlfcn.h");
    @cInclude("poll.h");
    @cInclude("semaphore.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const O = ?*anyopaque;
extern fn xpc_connection_create(?[*:0]const u8, O) O;
extern fn xpc_connection_create_mach_service([*:0]const u8, O, u64) O;
extern fn xpc_connection_create_from_endpoint(O) O;
extern fn xpc_endpoint_create(O) O;
extern fn xpc_connection_set_event_handler(O, ?*anyopaque) void;
extern fn xpc_connection_resume(O) void;
extern fn xpc_connection_cancel(O) void;
extern fn xpc_connection_send_message(O, O) void;
extern fn xpc_connection_send_message_with_reply(O, O, O, ?*anyopaque) void;
extern fn xpc_dictionary_create(O, O, usize) O;
extern fn xpc_dictionary_create_reply(O) O;
extern fn xpc_dictionary_set_uint64(O, [*:0]const u8, u64) void;
extern fn xpc_dictionary_get_uint64(O, [*:0]const u8) u64;
extern fn xpc_get_type(O) ?*const anyopaque;
extern fn xpc_retain(O) O;
extern fn xpc_release(O) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern const _xpc_error_connection_invalid: u8;
extern const _xpc_error_connection_interrupted: u8;
extern const _xpc_type_connection: u8;
extern const _xpc_type_dictionary: u8;
extern var _NSConcreteStackBlock: [32]?*anyopaque;
extern fn _Block_copy(?*const anyopaque) ?*anyopaque;
extern fn _Block_release(?*const anyopaque) void;
const LISTENER: u64 = 1; // XPC_CONNECTION_MACH_SERVICE_LISTENER

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
const LIMIT_MS: u64 = 2000;

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

// The events one handler saw, in order, with the time of the first.
const Events = struct {
    sem: c.sem_t = undefined,
    log: [16]u64 = @splat(0),
    n: u64 = 0,
    first_ms: u64 = 0,
    fn init(e: *Events) void {
        e.* = .{};
        _ = c.sem_init(&e.sem, 0, 0);
    }
    fn record(e: *Events, code: u64) void {
        const i = @atomicRmw(u64, &e.n, .Add, 1, .seq_cst);
        if (i == 0) @atomicStore(u64, &e.first_ms, nowMs(), .seq_cst);
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

// Blocks ABI (BlocksRuntime runtime.c), as in endpoint_listener.zig.
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
    _ = c.printf("xpc_b0 case=%s library=%s codes=invalid:%llu,interrupted:%llu,peer:%llu,none:%llu limit_ms=%llu\n", case, path, INVALID, INTERRUPTED, PEER, NONE, LIMIT_MS);
    _ = c.fflush(null);
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
fn portType(name: u32) c.mach_port_type_t {
    var t: c.mach_port_type_t = 0;
    return if (c.mach_port_type(c.mach_task_self(), name, &t) == 0) t else 0;
}

// ---- The task's port names -------------------------------------------------

const Names = struct {
    fds: [2048]c_int = undefined,
    types: [2048]u32 = undefined,
    n: usize = 0,
    receive_only: u64 = 0, // a receive right without a send right
    contexts: [2048]u64 = undefined, // a receive right's context, else 0
    reply_ports: u64 = 0, // receive rights that carry libxpc's reply-port mark
};
// libxpc's mark on each call's reply port (XPC_REPLY_PORT_CONTEXT, op-775,
// lib/libxpc/xpc_internal.h): "xpc.rply". A thread's MIG reply port, the other
// receive-only right a task makes per thread, has none. op-751's and op-757's
// libraries mark nothing.
const REPLY_PORT_CONTEXT: u64 = 0x7870632e72706c79;
fn contextOf(name: u32) u64 {
    var v: c.mach_vm_address_t = 0;
    return if (c.mach_port_get_context(c.mach_task_self(), name, &v) == 0) v else 0;
}
fn names(s: *Names) void {
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
        if (f.kf_type == 17) {
            const t = portType(@intCast(f.kf_fd));
            if ((t & c.MACH_PORT_TYPE_RECEIVE) != 0 and (t & c.MACH_PORT_TYPE_SEND) == 0) s.receive_only += 1;
            need(s.n < s.fds.len, "port names fit the snapshot");
            s.fds[s.n] = f.kf_fd;
            s.types[s.n] = t;
            s.contexts[s.n] = if ((t & c.MACH_PORT_TYPE_RECEIVE) != 0) contextOf(@intCast(f.kf_fd)) else 0;
            if (s.contexts[s.n] == REPLY_PORT_CONTEXT) s.reply_ports += 1;
            s.n += 1;
        }
        offset += @intCast(f.kf_structsize);
    }
}
fn receiveOnly() u64 {
    var s: Names = undefined;
    names(&s);
    return s.receive_only;
}
// The count once it is at or below target, or its last value after ms. A
// worker thread keeps the MIG reply port it made (mig_support.c,
// mig_get_reply_port) until it exits, so threads that end lower the count;
// a reply port that stays raises it.
fn settleReceiveOnly(target: u64, ms: u64) u64 {
    const start = nowMs();
    var n = receiveOnly();
    while (n > target and nowMs() - start < ms) {
        _ = c.usleep(10_000);
        n = receiveOnly();
    }
    return n;
}
fn stableReceiveOnly(ms: u64) u64 {
    const start = nowMs();
    var last = receiveOnly();
    var same: u32 = 0;
    while (same < 5 and nowMs() - start < ms) {
        _ = c.usleep(50_000);
        const n = receiveOnly();
        same = if (n == last) same + 1 else 0;
        last = n;
    }
    return last;
}
// The one name made between two snapshots that holds a receive right and a
// send right, as a new connection's own port does.
fn onlyNew(a: *const Names, b: *const Names) ?u32 {
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

// ---- An in-process server ----------------------------------------------------

// Its peer answers an even value with value + 1 and releases an odd one
// unanswered: the request's last reference goes after the handler returns.
const Server = struct {
    listener_events: Events = .{},
    peer_events: Events = .{},
    answered: u64 = 0,
    released: u64 = 0,
    fn init(s: *Server) void {
        s.* = .{};
        s.listener_events.init();
        s.peer_events.init();
    }
};
fn peerEvent(ctx: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    if (code < INVALID) {
        if (code % 2 == 0) {
            const r = xpc_dictionary_create_reply(o);
            if (r != null) {
                xpc_dictionary_set_uint64(r, "value", code + 1);
                xpc_connection_send_message(peer, r);
                xpc_release(r);
            }
            bump(&s.answered);
        } else bump(&s.released);
    }
    s.peer_events.record(code);
}
fn listenerEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    s.listener_events.record(code);
    if (code != PEER) return;
    setHandler(o, &peerEvent, s);
    xpc_connection_resume(o);
}
// An anonymous listener, resumed, and a client made from its endpoint.
const Pair = struct { listener: O, client: O };
fn pair(s: *Server, client_events: *Events, tag: [*:0]const u8) Pair {
    const l = xpc_connection_create(null, dispatch_queue_create(tag, null));
    need(l != null, "listener");
    setHandler(l, &listenerEvent, s);
    xpc_connection_resume(l);
    const e = xpc_endpoint_create(l);
    need(e != null, "listener's endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "connection from the endpoint");
    xpc_release(e);
    setHandler(conn, &recordInto, client_events);
    xpc_connection_resume(conn);
    return .{ .listener = l, .client = conn };
}
fn retire(p: Pair) void {
    xpc_connection_cancel(p.client);
    xpc_release(p.client);
    xpc_connection_cancel(p.listener);
    xpc_release(p.listener);
}

// ---- unrepliedRequestInterrupted_released ----------------------------------

fn unrepliedReleased(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "unrepliedRequestInterrupted_released";
    library(case);
    var s: Server = undefined;
    s.init();
    var client: Events = undefined;
    client.init();
    const p = pair(&s, &client, "op757.released");
    // The server releases value 1 unanswered, while it lives.
    var first: Events = undefined;
    first.init();
    const t0 = nowMs();
    sendWithReply(p.client, 1, &first);
    const done = first.waitFor(1, LIMIT_MS);
    const elapsed = if (done) load(&first.first_ms) - t0 else nowMs() - t0;
    _ = c.printf("xpc_b0 case=%s first_reply_ms=%llu\n", case, elapsed);
    fact(case, "released_reply", INTERRUPTED, if (done) first.first() else NONE);
    fact(case, "released_within_limit", 1, @intFromBool(done and elapsed <= LIMIT_MS));
    fact(case, "server_released", 1, load(&s.released));
    // The connection stays usable: value 2 is answered with 3.
    var second: Events = undefined;
    second.init();
    sendWithReply(p.client, 2, &second);
    const answered = second.waitFor(1, LIMIT_MS);
    // A second completion of either call would arrive here.
    _ = c.usleep(200_000);
    fact(case, "next_reply", 3, if (answered) second.first() else NONE);
    fact(case, "released_completions", 1, first.count());
    fact(case, "next_completions", 1, second.count());
    fact(case, "client_events", 0, client.count());
    fact(case, "listener_peers", 1, s.listener_events.count());
    retire(p);
    conclude(case);
}

// ---- unrepliedRequestInterrupted_exit --------------------------------------

// A named service served from a forked child (stage_a.zig's listeners serve
// theirs in one process). The child exits holding the first request, before
// it has sent the client anything.
//
// op-775: a forked child's checked-in service port dies with it, and the
// client's dead-name path then interrupts the connection on any library. So
// before it exits the child gives the service port's receive right back to
// the parent, on a channel port the parent checked in. The service port
// lives on; only the held request's send-once right ends at exit.
extern var bootstrap_port: u32;
extern fn bootstrap_check_in(u32, [*:0]const u8, *u32) c_int;
extern fn bootstrap_look_up(u32, [*:0]const u8, *u32) c_int;
const PortMessage = extern struct { header: c.mach_msg_header_t, count: u32, port: PortDescriptor, trailer: [128]u8 };
var child_held: c_int = -1;
var child_service: u32 = 0;
var child_back: u32 = 0;
fn childServer(name: [*:0]const u8, back_name: [*:0]const u8, ready: c_int, held: c_int) noreturn {
    _ = c.alarm(10);
    child_held = held;
    const l = xpc_connection_create_mach_service(name, dispatch_queue_create("op757.child", null), LISTENER);
    if (l == null) c._exit(80);
    setHandler(l, &childListener, null);
    xpc_connection_resume(l);
    // In one task a send right shares the name of its receive right: the
    // look-up names the receive right the listener checked in.
    if (bootstrap_look_up(bootstrap_port, name, &child_service) != 0) c._exit(83);
    if ((portType(child_service) & c.MACH_PORT_TYPE_RECEIVE) == 0) c._exit(84);
    if (bootstrap_look_up(bootstrap_port, back_name, &child_back) != 0) c._exit(85);
    var b: u8 = 'r';
    if (c.write(ready, &b, 1) != 1) c._exit(81);
    while (true) _ = c.pause();
}
fn childListener(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    if (eventCode(o) != PEER) return;
    setHandler(o, &childPeer, null);
    xpc_connection_resume(o);
}
fn childPeer(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    if (eventCode(o) >= INVALID) return;
    // Hold the request, give the service port back, say so, and exit with
    // the request unanswered.
    _ = xpc_retain(o);
    var m = std.mem.zeroes(PortMessage);
    m.header.msgh_bits = COMPLEX | c.MACH_MSG_TYPE_COPY_SEND;
    m.header.msgh_size = @offsetOf(PortMessage, "trailer");
    m.header.msgh_remote_port = child_back;
    m.header.msgh_id = 775;
    m.count = 1;
    m.port = .{ .name = child_service, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_MOVE_RECEIVE, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
    if (c.mach_msg(&m.header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, m.header.msgh_size, 0, 0, 1000, 0) != 0) c._exit(86);
    var b: u8 = 'h';
    if (c.write(child_held, &b, 1) != 1) c._exit(82);
    c._exit(0);
}
fn readByte(fd: c_int, want: u8, ms: c_int) bool {
    var ready = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    var b: u8 = 0;
    return c.poll(&ready, 1, ms) == 1 and c.read(fd, &b, 1) == 1 and b == want;
}
fn unrepliedExit(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "unrepliedRequestInterrupted_exit";
    library(case);
    var buf: [96]u8 = undefined;
    const n = c.snprintf(&buf, buf.len, "org.rmxos.op757.exit.%d", c.getpid());
    need(n > 0 and n < buf.len, "service name");
    const name: [*:0]const u8 = @ptrCast(&buf);
    var back_buf: [96]u8 = undefined;
    const bn = c.snprintf(&back_buf, back_buf.len, "org.rmxos.op757.back.%d", c.getpid());
    need(bn > 0 and bn < back_buf.len, "channel name");
    const back_name: [*:0]const u8 = @ptrCast(&back_buf);
    var back: u32 = 0;
    need(bootstrap_check_in(bootstrap_port, back_name, &back) == 0, "channel check-in");
    var ready: [2]c_int = undefined;
    var held: [2]c_int = undefined;
    need(c.pipe(&ready) == 0 and c.pipe(&held) == 0, "pipes");
    // Fork before this process uses libdispatch or libxpc.
    const pid = c.fork();
    need(pid >= 0, "fork");
    if (pid == 0) {
        _ = c.close(ready[0]);
        _ = c.close(held[0]);
        childServer(name, back_name, ready[1], held[1]);
    }
    _ = c.close(ready[1]);
    _ = c.close(held[1]);
    const served = readByte(ready[0], 'r', 3000);
    fact(case, "child_serving", 1, @intFromBool(served));
    if (!served) {
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
        conclude(case);
    }
    var client: Events = undefined;
    client.init();
    const conn = xpc_connection_create_mach_service(name, dispatch_queue_create("op757.exit.client", null), 0);
    need(conn != null, "named client");
    setHandler(conn, &recordInto, &client);
    xpc_connection_resume(conn);
    var reply: Events = undefined;
    reply.init();
    sendWithReply(conn, 7, &reply);
    const holding = readByte(held[0], 'h', 3000);
    const t0 = nowMs();
    fact(case, "server_held_request", 1, @intFromBool(holding));
    // The service port's receive right, back from the child: it outlives it.
    var m = std.mem.zeroes(PortMessage);
    const got = c.mach_msg(&m.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(PortMessage), back, 2000, 0);
    const returned = got == 0 and (m.header.msgh_bits & COMPLEX) != 0 and m.count == 1 and m.port.disposition == c.MACH_MSG_TYPE_PORT_RECEIVE;
    const service: u32 = if (returned) m.port.name else 0;
    fact(case, "service_port_returned", 1, @intFromBool(returned));
    const done = reply.waitFor(1, LIMIT_MS);
    const elapsed = if (done) load(&reply.first_ms) -| t0 else nowMs() - t0;
    _ = c.printf("xpc_b0 case=%s reply_ms_after_hold=%llu service_type=0x%x\n", case, elapsed, if (returned) portType(service) else 0);
    var status: c_int = -1;
    var reaped: c_int = 0;
    const w0 = nowMs();
    while (reaped == 0 and nowMs() - w0 < 3000) {
        reaped = c.waitpid(pid, &status, c.WNOHANG);
        if (reaped == 0) _ = c.usleep(10_000);
    }
    if (reaped == 0) {
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, &status, 0);
    }
    // A second completion, or the connection's own interruption, would
    // arrive here; the service port is alive, so the connection has none.
    _ = c.usleep(200_000);
    fact(case, "exit_reply", INTERRUPTED, if (done) reply.first() else NONE);
    fact(case, "exit_within_limit", 1, @intFromBool(done and elapsed <= LIMIT_MS));
    fact(case, "exit_completions", 1, reply.count());
    fact(case, "connection_events_while_service_lives", 0, client.count());
    fact(case, "child_exited_zero", 1, @intFromBool(reaped == pid and status == 0));
    xpc_connection_cancel(conn);
    xpc_release(conn);
    if (returned) _ = c.mach_port_mod_refs(c.mach_task_self(), service, c.MACH_PORT_RIGHT_RECEIVE, -1);
    _ = c.mach_port_mod_refs(c.mach_task_self(), back, c.MACH_PORT_RIGHT_RECEIVE, -1);
    _ = c.close(ready[0]);
    _ = c.close(held[0]);
    conclude(case);
}

// ---- unexpectedDescriptorReleased ------------------------------------------

const PortDescriptor = extern struct { name: u32, pad1: u32, pad2: u16, disposition: u8, kind: u8 };
const COMPLEX: u32 = 0x80000000;
// header, body count, up to two port descriptors, size, ID, nvlist bytes.
const Bad = extern struct {
    header: c.mach_msg_header_t,
    count: u32,
    ports: [2]PortDescriptor,
    rest: [1040]u8, // size and ID right after the last descriptor used, then bytes
};
// The nvlist bytes a real libxpc message carries, from a message this
// process sends itself: whichever wire form the library uses, its payload.
fn capture(out: *[1024]u8) usize {
    var before: Names = undefined;
    var after: Names = undefined;
    names(&before);
    const l = xpc_connection_create(null, null);
    names(&after);
    need(l != null, "capture listener");
    const port = onlyNew(&before, &after) orelse c.atf_tc_fail("setup: one new port for the capture listener");
    // Never resumed: the message stays queued on its port.
    const e = xpc_endpoint_create(l);
    need(e != null, "capture endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "capture connection");
    xpc_release(e);
    var ignore: Events = undefined;
    ignore.init();
    setHandler(conn, &recordInto, &ignore);
    xpc_connection_resume(conn);
    sendValue(conn, 9);
    var bytes: [8192]u8 align(8) = @splat(0);
    const h: *c.mach_msg_header_t = @ptrCast(&bytes);
    need(c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, port, 3000, 0) == 0, "captured message");
    const offset: usize = if ((h.msgh_bits & COMPLEX) != 0) 40 else 24;
    const size = std.mem.readInt(u64, bytes[offset..][0..8], .little);
    need(size <= out.len and offset + 16 + size <= h.msgh_size, "captured payload fits");
    @memcpy(out[0..size], bytes[offset + 16 ..][0..size]);
    c.mach_msg_destroy(h);
    xpc_connection_cancel(conn);
    xpc_release(conn);
    xpc_connection_cancel(l);
    xpc_release(l);
    return size;
}
fn sendBad(dest: u32, reply: u32, ports: []const PortDescriptor, payload: []const u8) c_int {
    var m = std.mem.zeroes(Bad);
    const used = @offsetOf(Bad, "ports") + ports.len * @sizeOf(PortDescriptor);
    // The size, ID and bytes follow the descriptors the count names.
    const bytes: [*]u8 = @ptrCast(&m);
    const total = (used + 16 + payload.len + 7) & ~@as(usize, 7);
    m.header.msgh_bits = COMPLEX | c.MACH_MSGH_BITS(c.MACH_MSG_TYPE_COPY_SEND, c.MACH_MSG_TYPE_MAKE_SEND);
    m.header.msgh_size = @intCast(total);
    m.header.msgh_remote_port = dest;
    m.header.msgh_local_port = reply;
    m.header.msgh_id = 0x10000000; // XPC_PIPE_MESSAGE_ID
    m.count = @intCast(ports.len);
    for (ports, 0..) |p, i| m.ports[i] = p;
    std.mem.writeInt(u64, bytes[used..][0..8], payload.len, .little);
    std.mem.writeInt(u64, bytes[used + 8 ..][0..8], 757, .little);
    @memcpy(bytes[used + 16 ..][0..payload.len], payload);
    return c.mach_msg(&m.header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, m.header.msgh_size, 0, 0, 1000, 0);
}
fn newReceive() u32 {
    var p: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) == 0, "receive right");
    return p;
}
fn unexpectedDescriptorReleased(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "unexpectedDescriptorReleased";
    library(case);
    var payload: [1024]u8 = undefined;
    const len = capture(&payload);
    // A send right of the test's own (one reference), a port that receives
    // send-once notices, the receive right of a port the test keeps a send
    // right to, and the client port for each message's header reply right.
    const sendable = newReceive();
    need(c.mach_port_insert_right(c.mach_task_self(), sendable, sendable, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "send right");
    const notices = newReceive();
    const given = newReceive();
    need(c.mach_port_insert_right(c.mach_task_self(), given, given, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "kept send right");
    const client_port = newReceive();
    var s: Server = undefined;
    s.init();
    var before: Names = undefined;
    var after: Names = undefined;
    names(&before);
    const l = xpc_connection_create(null, dispatch_queue_create("op757.unexpected", null));
    names(&after);
    need(l != null, "listener");
    const port = onlyNew(&before, &after) orelse c.atf_tc_fail("setup: one new port for the listener");
    setHandler(l, &listenerEvent, &s);
    const SO = c.MACH_MSG_TYPE_MAKE_SEND_ONCE;
    // Queued before the listener is resumed, each ahead of the next: a
    // port descriptor with a send right, two send-once rights, a receive
    // right, then the real client's message.
    fact(case, "send_right_descriptor_sent", 0, @bitCast(@as(i64, sendBad(port, client_port, &.{.{ .name = sendable, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_PORT_DESCRIPTOR }}, payload[0..len]))));
    fact(case, "two_send_once_sent", 0, @bitCast(@as(i64, sendBad(port, client_port, &.{ .{ .name = notices, .pad1 = 0, .pad2 = 0, .disposition = SO, .kind = c.MACH_MSG_PORT_DESCRIPTOR }, .{ .name = notices, .pad1 = 0, .pad2 = 0, .disposition = SO, .kind = c.MACH_MSG_PORT_DESCRIPTOR } }, payload[0..len]))));
    fact(case, "receive_right_descriptor_sent", 0, @bitCast(@as(i64, sendBad(port, client_port, &.{.{ .name = given, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_MOVE_RECEIVE, .kind = c.MACH_MSG_PORT_DESCRIPTOR }}, payload[0..len]))));
    conclude(case);
    const e = xpc_endpoint_create(l);
    need(e != null, "endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "client");
    xpc_release(e);
    var client: Events = undefined;
    client.init();
    setHandler(conn, &recordInto, &client);
    xpc_connection_resume(conn);
    sendValue(conn, 12);
    // Let the client's message reach the listener's queue, then serve.
    _ = c.usleep(100_000);
    xpc_connection_resume(l);
    const delivered = s.peer_events.waitFor(1, 3000);
    fact(case, "next_message_delivered", 12, if (delivered) s.peer_events.first() else NONE);
    // Each right of the refused messages, released once.
    var notice_ids: [2]i64 = .{ -1, -1 };
    for (&notice_ids) |*id| {
        var bytes: [256]u8 align(8) = @splat(0);
        const h: *c.mach_msg_header_t = @ptrCast(&bytes);
        if (c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, notices, @intCast(LIMIT_MS), 0) == 0) id.* = h.msgh_id;
    }
    var extra: [256]u8 align(8) = @splat(0);
    const third = c.mach_msg(@ptrCast(&extra), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, extra.len, notices, 200, 0);
    _ = c.usleep(200_000);
    fact(case, "send_once_notice_1", c.MACH_NOTIFY_SEND_ONCE, @bitCast(notice_ids[0]));
    fact(case, "send_once_notice_2", c.MACH_NOTIFY_SEND_ONCE, @bitCast(notice_ids[1]));
    fact(case, "no_third_notice", c.MACH_RCV_TIMED_OUT, @bitCast(@as(i64, third)));
    fact(case, "send_right_refs", 1, settleRefs(sendable, c.MACH_PORT_RIGHT_SEND, 1, 2000));
    fact(case, "header_reply_refs", 0, settleRefs(client_port, c.MACH_PORT_RIGHT_SEND, 0, 2000));
    const start = nowMs();
    while ((portType(given) & c.MACH_PORT_TYPE_DEAD_NAME) == 0 and nowMs() - start < 2000) _ = c.usleep(10_000);
    fact(case, "receive_right_destroyed", 1, @intFromBool((portType(given) & c.MACH_PORT_TYPE_DEAD_NAME) != 0));
    fact(case, "listener_peers", 1, s.listener_events.count());
    fact(case, "peer_events", 1, s.peer_events.count());
    xpc_connection_cancel(conn);
    xpc_release(conn);
    xpc_connection_cancel(l);
    xpc_release(l);
    for ([_]u32{ sendable, notices, client_port }) |p| _ = c.mach_port_destroy(c.mach_task_self(), p);
    _ = c.mach_port_deallocate(c.mach_task_self(), given);
    conclude(case);
}

// ---- replyPortsReleased ------------------------------------------------------

const Tally = struct {
    replies: u64 = 0,
    interrupted: u64 = 0,
    invalid: u64 = 0,
    other: u64 = 0,
    sem: c.sem_t = undefined,
};
fn tallyReply(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const t: *Tally = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    if (code == INTERRUPTED) bump(&t.interrupted) else if (code == INVALID) bump(&t.invalid) else if (code < INVALID) bump(&t.replies) else bump(&t.other);
    _ = c.sem_post(&t.sem);
}
// count requests: even values answered, odd ones released unanswered.
fn burst(conn: O, t: *Tally, count: u64) void {
    for (0..count) |i| {
        const m = message(i);
        const b = block(&tallyReply, t, null);
        xpc_connection_send_message_with_reply(conn, m, null, b);
        _Block_release(b);
        xpc_release(m);
    }
}
fn awaitCount(what: *u64, n: u64, ms: u64) bool {
    const start = nowMs();
    while (load(what) < n and nowMs() - start < ms) _ = c.usleep(5_000);
    return load(what) >= n;
}
const ROUNDS = 100;
fn replyPorts() u64 {
    var s: Names = undefined;
    names(&s);
    return s.reply_ports;
}
// The reply-port count once it is at or below target, or its last value
// after ms.
fn settleReplyPorts(target: u64, ms: u64) u64 {
    const start = nowMs();
    var n = replyPorts();
    while (n > target and nowMs() - start < ms) {
        _ = c.usleep(10_000);
        n = replyPorts();
    }
    return n;
}
// The task's threads (kern.proc.pid with KERN_PROC_INC_THREAD: one record each).
fn threads() u64 {
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID | c.KERN_PROC_INC_THREAD, c.getpid() };
    var size: usize = 0;
    if (c.sysctl(&mib, mib.len, null, &size, null, 0) != 0) return 0;
    return size / @sizeOf(c.struct_kinfo_proc);
}
// Each receive-only name of b that a is without, with its receive status
// (MACH_PORT_RECEIVE_STATUS) and its context: what tells a reply port from
// a thread's MIG reply port.
fn printAddedReceive(case: [*:0]const u8, a: *const Names, b: *const Names) void {
    var added: u32 = 0;
    for (b.fds[0..b.n], b.types[0..b.n], b.contexts[0..b.n]) |fd, t, ctx| {
        if ((t & c.MACH_PORT_TYPE_RECEIVE) == 0 or (t & c.MACH_PORT_TYPE_SEND) != 0) continue;
        var old = false;
        for (a.fds[0..a.n], a.types[0..a.n]) |x, u| old = old or (x == fd and u == t);
        if (old) continue;
        added += 1;
        var st: c.mach_port_status_t = std.mem.zeroes(c.mach_port_status_t);
        var count: c.mach_msg_type_number_t = @sizeOf(c.mach_port_status_t) / @sizeOf(c.natural_t);
        const rc = c.mach_port_get_attributes(c.mach_task_self(), @intCast(fd), c.MACH_PORT_RECEIVE_STATUS, @ptrCast(&st), &count);
        _ = c.printf("xpc_b0 case=%s added_receive=%d reply_port=%u context=0x%llx status_rc=%d sorights=%u pset=%u msgcount=%u seqno=%u qlimit=%u srights=%u\n", case, fd, @as(c_uint, @intFromBool(ctx == REPLY_PORT_CONTEXT)), ctx, rc, st.mps_sorights, st.mps_pset, st.mps_msgcount, st.mps_seqno, st.mps_qlimit, @as(c_uint, @intCast(st.mps_srights)));
    }
    _ = c.printf("xpc_b0 case=%s added_receive_names=%u\n", case, added);
    _ = c.fflush(null);
}
fn replyPortsReleased(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "replyPortsReleased";
    library(case);
    var s: Server = undefined;
    s.init();
    var client: Events = undefined;
    client.init();
    const p = pair(&s, &client, "op757.ports");
    // A first burst of the same size lets libdispatch and libxpc make their
    // threads and one-time names.
    var warm: Tally = .{};
    _ = c.sem_init(&warm.sem, 0, 0);
    burst(p.client, &warm, 2 * ROUNDS);
    _ = awaitCount(&warm.replies, ROUNDS, 5000);
    _ = awaitCount(&warm.interrupted, ROUNDS, 2000);
    const reply_start = settleReplyPorts(0, 3000);
    var start: Names = undefined;
    names(&start);
    const threads_start = threads();
    var t: Tally = .{};
    _ = c.sem_init(&t.sem, 0, 0);
    burst(p.client, &t, 2 * ROUNDS);
    var during: Names = undefined;
    names(&during);
    const answered = awaitCount(&t.replies, ROUNDS, 5000);
    const dropped = awaitCount(&t.interrupted, ROUNDS, 3000);
    const settled = settleReplyPorts(reply_start, 5000);
    var end: Names = undefined;
    names(&end);
    const threads_end = threads();
    _ = c.printf("xpc_b0 case=%s observed answered=%u dropped=%u replies=%llu interrupted=%llu invalid=%llu other=%llu server_answered=%llu server_released=%llu\n", case, @as(c_uint, @intFromBool(answered)), @as(c_uint, @intFromBool(dropped)), load(&t.replies), load(&t.interrupted), load(&t.invalid), load(&t.other), load(&s.answered), load(&s.released));
    _ = c.printf("xpc_b0 case=%s reply_ports_start=%llu reply_ports_during=%llu reply_ports_settled=%llu receive_only_start=%llu receive_only_end=%llu threads_start=%llu threads_end=%llu\n", case, reply_start, during.reply_ports, settled, start.receive_only, end.receive_only, threads_start, threads_end);
    printAddedReceive(case, &start, &end);
    // Only names that carry libxpc's reply-port mark count: a thread's MIG
    // reply port is receive-only too, and threads come and go.
    fact(case, "reply_ports_over_start", 0, if (settled > reply_start) settled - reply_start else 0);
    retire(p);
    conclude(case);
}

// ---- replyAfterCancel --------------------------------------------------------

// A reply that reaches its reply port after cancel's flush has completed the
// call (op-775). The client's target queue is held, so the reply source and
// its cancel handler, which run on the connection's receive queue, wait while
// the server answers. The call completes once, with INVALID, and the reply
// port goes once, with the reply still in it.
const Holder = struct {
    request: O = null,
    peer: O = null,
    sem: c.sem_t = undefined,
};
fn holdPeer(ctx: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const h: *Holder = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) >= INVALID or h.request != null) return;
    h.peer = xpc_retain(peer);
    h.request = xpc_retain(o);
    _ = c.sem_post(&h.sem);
}
fn holdListener(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    if (eventCode(o) != PEER) return;
    setHandler(o, &holdPeer, ctx);
    xpc_connection_resume(o);
}
const Gate = struct { entered: c.sem_t = undefined, release: c.sem_t = undefined };
fn blockQueue(ctx: ?*anyopaque) callconv(.c) void {
    const g: *Gate = @ptrCast(@alignCast(ctx.?));
    _ = c.sem_post(&g.entered);
    _ = c.sem_wait(&g.release);
}
// True once the one marked reply port holds one message, within ms.
fn replyInPort(ms: u64) bool {
    const start = nowMs();
    while (nowMs() - start < ms) {
        var s: Names = undefined;
        names(&s);
        for (s.fds[0..s.n], s.contexts[0..s.n]) |fd, ctx| {
            if (ctx != REPLY_PORT_CONTEXT) continue;
            var st: c.mach_port_status_t = std.mem.zeroes(c.mach_port_status_t);
            var count: c.mach_msg_type_number_t = @sizeOf(c.mach_port_status_t) / @sizeOf(c.natural_t);
            if (c.mach_port_get_attributes(c.mach_task_self(), @intCast(fd), c.MACH_PORT_RECEIVE_STATUS, @ptrCast(&st), &count) == 0 and st.mps_msgcount == 1) return true;
        }
        _ = c.usleep(10_000);
    }
    return false;
}
extern fn dispatch_async_f(O, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn xpc_connection_set_target_queue(O, O) void;
fn replyAfterCancel(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "replyAfterCancel";
    library(case);
    const ports_start = settleReplyPorts(0, 2000);
    var h: Holder = .{};
    _ = c.sem_init(&h.sem, 0, 0);
    const l = xpc_connection_create(null, dispatch_queue_create("op775.hold", null));
    need(l != null, "listener");
    setHandler(l, &holdListener, &h);
    xpc_connection_resume(l);
    const e = xpc_endpoint_create(l);
    need(e != null, "endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "client");
    xpc_release(e);
    const q = dispatch_queue_create("op775.client", null);
    xpc_connection_set_target_queue(conn, q);
    var client: Events = undefined;
    client.init();
    setHandler(conn, &recordInto, &client);
    xpc_connection_resume(conn);
    var replies: Events = undefined;
    replies.init();
    sendWithReply(conn, 1, &replies);
    need(waitMs(&h.sem, 3000), "server holds the request");
    var g: Gate = .{};
    _ = c.sem_init(&g.entered, 0, 0);
    _ = c.sem_init(&g.release, 0, 0);
    dispatch_async_f(q, &g, &blockQueue);
    need(waitMs(&g.entered, 3000), "client queue held");
    // The server answers now. The reply waits in the call's reply port: its
    // source cannot run while the queue is held.
    const r = xpc_dictionary_create_reply(h.request);
    need(r != null, "reply");
    xpc_dictionary_set_uint64(r, "value", 2);
    xpc_connection_send_message(h.peer, r);
    xpc_release(r);
    const in_port = replyInPort(2000);
    // The flush takes the call before the source sees the reply; the call's
    // INVALID waits on the held queue too.
    xpc_connection_cancel(conn);
    _ = c.usleep(100_000);
    const ports_held = replyPorts();
    const early = replies.count();
    _ = c.sem_post(&g.release);
    const done = replies.waitFor(1, 3000);
    // A second completion would arrive here.
    _ = c.usleep(200_000);
    const settled = settleReplyPorts(ports_start, 3000);
    _ = c.printf("xpc_b0 case=%s reply_ports_start=%llu reply_ports_while_held=%llu reply_ports_settled=%llu client_events=%llu client_first=%llu\n", case, ports_start, ports_held, settled, client.count(), client.first());
    fact(case, "reply_waiting_in_port", 1, @intFromBool(in_port));
    fact(case, "completions_while_held", 0, early);
    fact(case, "completion", INVALID, if (done) replies.first() else NONE);
    fact(case, "completions", 1, replies.count());
    fact(case, "reply_port_kept_until_release", 1, @intFromBool(ports_held == ports_start + 1));
    fact(case, "reply_ports_over_start", 0, if (settled > ports_start) settled - ports_start else 0);
    xpc_release(h.request);
    xpc_release(h.peer);
    xpc_release(conn);
    xpc_connection_cancel(l);
    xpc_release(l);
    conclude(case);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "25");
}
var cases: [5]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const ids = [_][*:0]const u8{ "unrepliedRequestInterrupted_released", "unrepliedRequestInterrupted_exit", "unexpectedDescriptorReleased", "replyPortsReleased", "replyAfterCancel" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &unrepliedReleased, &unrepliedExit, &unexpectedDescriptorReleased, &replyPortsReleased, &replyAfterCancel };
    for (&cases, ids, bodies) |*tc, id, body| {
        var err = c.atf_tc_init(tc, id, &head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
