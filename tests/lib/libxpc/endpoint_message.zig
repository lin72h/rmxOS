// SPDX-License-Identifier: BSD-2-Clause
// op-796: endpoints in messages. An endpoint value in a dictionary, at any
// depth, crosses a connection in an ordinary message, a request and a reply.
// The sender's libxpc sends each endpoint's send right as a port descriptor
// (COPY_SEND), after a request's send-once reply right, and the packed list
// holds the endpoint as its index among those descriptors; the receiver's
// libxpc makes an endpoint object that owns the right it received, and
// xpc_connection_create_from_endpoint works on it as on a local one.
// `container` starts a container this way: its runtime helper answers
// createEndpoint with an endpoint in a reply, and the client connects from it.
//
// The program links libxpc.so.5 by its soname with no run path, so
// LD_LIBRARY_PATH selects the library under test; each case prints the path
// of the libxpc it loaded. A forked child keeps its parent's library.
//
// Port names on rmxOS are file descriptors and mach_port_names is not
// implemented, so the cases count references on one name with
// mach_port_get_refs. In one task a send right to a port shares the name of
// its receive right: an endpoint received for an in-process listener adds a
// reference to the listener's own name. In another task the name of a
// received endpoint is read from its description, "(endpoint) <name>"
// (xpc_copy_description), which endpointInMessage checks against a local
// endpoint whose name is known.
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
const AuditToken = extern struct { val: [8]u32 };
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
extern fn xpc_dictionary_set_value(O, [*:0]const u8, O) void;
extern fn xpc_dictionary_get_value(O, [*:0]const u8) O;
extern fn xpc_dictionary_get_audit_token(O, *AuditToken) void;
extern fn xpc_array_create(O, usize) O;
extern fn xpc_array_append_value(O, O) void;
extern fn xpc_array_get_value(O, usize) O;
extern fn xpc_array_get_count(O) usize;
extern fn xpc_get_type(O) ?*const anyopaque;
extern fn xpc_retain(O) O;
extern fn xpc_release(O) void;
extern fn xpc_copy_description(O) ?[*:0]u8;
extern fn dispatch_queue_create([*:0]const u8, O) O;
// libxpc's own nvlist (lib/libxpc/subr_nvlist.c), whose types include
// NV_TYPE_ENDPOINT (nv.h): the wire records read a captured list with it.
extern fn nvlist_unpack(?*const anyopaque, usize) ?*anyopaque;
extern fn nvlist_destroy(?*anyopaque) void;
extern fn nvlist_exists_type(?*const anyopaque, [*:0]const u8, c_int) bool;
extern fn nvlist_get_nvlist_array(?*const anyopaque, [*:0]const u8) ?*const anyopaque;
extern fn nvlist_get_nvlist_dictionary(?*const anyopaque, [*:0]const u8) ?*const anyopaque;
extern fn nvlist_get_endpoint(?*const anyopaque, [*:0]const u8) c_int;
extern const _xpc_error_connection_invalid: u8;
extern const _xpc_error_connection_interrupted: u8;
extern const _xpc_type_connection: u8;
extern const _xpc_type_dictionary: u8;
extern const _xpc_type_endpoint: u8;
extern var _NSConcreteStackBlock: [32]?*anyopaque;
extern fn _Block_copy(?*const anyopaque) ?*anyopaque;
extern fn _Block_release(?*const anyopaque) void;
const LISTENER: u64 = 1; // XPC_CONNECTION_MACH_SERVICE_LISTENER
const NV_TYPE_ENDPOINT: c_int = 10;
const NV_TYPE_NVLIST_ARRAY: c_int = 14;
const NV_TYPE_NVLIST_DICTIONARY: c_int = 15;
const CAP: u64 = 64; // XPC_MAX_ENDPOINTS (lib/libxpc/xpc_internal.h)
const PORT_SEND: u64 = 17; // MACH_MSG_TYPE_PORT_SEND
const PORT_SEND_ONCE: u64 = 18; // MACH_MSG_TYPE_PORT_SEND_ONCE

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
fn isEndpoint(o: O) bool {
    return o != null and xpc_get_type(o) == @as(?*const anyopaque, @ptrCast(&_xpc_type_endpoint));
}
const LIMIT_MS: u64 = 2000;

fn bump(p: *u64) void {
    _ = @atomicRmw(u64, p, .Add, 1, .seq_cst);
}
fn load(p: *u64) u64 {
    return @atomicLoad(u64, p, .seq_cst);
}
fn put(p: *u64, v: u64) void {
    @atomicStore(u64, p, v, .seq_cst);
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
    _ = c.printf("xpc_b0 case=%s library=%s pid=%d cap=%llu codes=invalid:%llu,interrupted:%llu,peer:%llu,none:%llu\n", case, path, c.getpid(), CAP, INVALID, INTERRUPTED, PEER, NONE);
    _ = c.fflush(null);
}

// ---- Port names -------------------------------------------------------------

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
const SEND = c.MACH_PORT_RIGHT_SEND;
const DEAD = c.MACH_PORT_RIGHT_DEAD_NAME;
fn portType(name: u32) c.mach_port_type_t {
    var t: c.mach_port_type_t = 0;
    return if (c.mach_port_type(c.mach_task_self(), name, &t) == 0) t else 0;
}
const Names = struct {
    fds: [2048]c_int = undefined,
    types: [2048]u32 = undefined,
    n: usize = 0,
    dead: u64 = 0,
};
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
            need(s.n < s.fds.len, "port names fit the snapshot");
            s.fds[s.n] = f.kf_fd;
            s.types[s.n] = t;
            if ((t & c.MACH_PORT_TYPE_DEAD_NAME) != 0) s.dead += 1;
            s.n += 1;
        }
        offset += @intCast(f.kf_structsize);
    }
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
var before_names: Names = .{};
var after_names: Names = .{};
fn deadNames() u64 {
    var s: Names = undefined;
    names(&s);
    return s.dead;
}
fn settleDead(target: u64, ms: u64) u64 {
    const start = nowMs();
    var n = deadNames();
    while (n != target and nowMs() - start < ms) {
        _ = c.usleep(10_000);
        n = deadNames();
    }
    return n;
}
// The name an endpoint object holds: its description is "(endpoint) <name>".
fn endpointName(o: O) u32 {
    const d = xpc_copy_description(o) orelse return 0;
    defer c.free(d);
    const s = std.mem.span(d);
    var i: usize = 0;
    while (i < s.len and s[i] != '<') : (i += 1) {}
    var v: u64 = 0;
    i += 1;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) v = v * 10 + (s[i] - '0');
    return if (i < s.len and s[i] == '>' and v <= 0xffffffff) @intCast(v) else 0;
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
fn block(f: Fn, ctx: ?*anyopaque, conn: O) ?*anyopaque {
    var literal = Block{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = 0, .reserved = 0, .invoke = &blockInvoke, .descriptor = &descriptor, .f = f, .ctx = ctx, .conn = conn };
    return _Block_copy(&literal);
}
fn setHandler(conn: O, f: Fn, ctx: ?*anyopaque) void {
    const b = block(f, ctx, conn);
    xpc_connection_set_event_handler(conn, b);
    _Block_release(b);
}
fn ignore(_: ?*anyopaque, _: O, _: O) callconv(.c) void {}

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
        if (i < e.log.len) put(&e.log[@intCast(i)], code);
        _ = c.sem_post(&e.sem);
    }
    fn count(e: *Events) u64 {
        return load(&e.n);
    }
    fn logged(e: *Events) usize {
        return @intCast(@min(e.count(), 16));
    }
    fn last(e: *Events) u64 {
        const n = e.logged();
        return if (n == 0) NONE else load(&e.log[n - 1]);
    }
    fn tally(e: *Events, code: u64) u64 {
        var k: u64 = 0;
        for (e.log[0..e.logged()]) |*x| {
            if (load(x) == code) k += 1;
        }
        return k;
    }
    // Until an event of this code has come, or ms.
    fn waitCode(e: *Events, code: u64, ms: u64) bool {
        const start = nowMs();
        while (e.tally(code) == 0 and nowMs() - start < ms) _ = c.usleep(2_000);
        return e.tally(code) != 0;
    }
};
fn recordInto(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const e: *Events = @ptrCast(@alignCast(ctx.?));
    e.record(eventCode(o));
}

// ---- Messages ------------------------------------------------------------------

// What a message asks of the server that gets it (its "op").
const OP_REQUEST: u64 = 1; // reply with value + 1 and the audit token's pid
const OP_CONNECT: u64 = 2; // connect from the endpoint at list[0].ep and send value + 1
const OP_GIVE: u64 = 3; // reply with a new endpoint of the server's target
const OP_REPLY_NESTED: u64 = 4; // reply with the endpoint at list[0].ep as "ep"
const OP_ECHO: u64 = 5; // reply with the message's "ep"
const OP_COUNT: u64 = 6; // count the endpoints of "eps"
const OP_COUNT_REPLY: u64 = 7; // count them and reply with the count as "n"
const OP_HOLD: u64 = 8; // (endpointInReply's server) hold the request unanswered
const OP_RELEASE: u64 = 9; // ... answer the held request
const OP_EXIT: u64 = 10; // ... exit

fn dict(value: u64, op: u64) O {
    const d = xpc_dictionary_create(null, null, 0);
    need(d != null, "dictionary");
    xpc_dictionary_set_uint64(d, "value", value);
    if (op != 0) xpc_dictionary_set_uint64(d, "op", op);
    return d;
}
// A dictionary whose endpoint is two levels down: list[0].ep, a dictionary
// in an array in the dictionary.
fn nestedMessage(value: u64, op: u64, ep: O) O {
    const d = dict(value, op);
    const inner = xpc_dictionary_create(null, null, 0);
    const list = xpc_array_create(null, 0);
    need(inner != null and list != null, "nested containers");
    xpc_dictionary_set_value(inner, "ep", ep);
    xpc_array_append_value(list, inner);
    xpc_dictionary_set_value(d, "list", list);
    xpc_release(inner);
    xpc_release(list);
    return d;
}
fn nested(o: O) O {
    const list = xpc_dictionary_get_value(o, "list");
    if (list == null or xpc_array_get_count(list) < 1) return null;
    const inner = xpc_array_get_value(list, 0);
    return if (inner == null) null else xpc_dictionary_get_value(inner, "ep");
}
// A dictionary with n copies of ep in its array "eps".
fn manyMessage(value: u64, op: u64, ep: O, n: usize) O {
    const d = dict(value, op);
    const eps = xpc_array_create(null, 0);
    need(eps != null, "endpoint array");
    for (0..n) |_| xpc_array_append_value(eps, ep);
    xpc_dictionary_set_value(d, "eps", eps);
    xpc_release(eps);
    return d;
}
fn send(conn: O, m: O) void {
    xpc_connection_send_message(conn, m);
    xpc_release(m);
}
fn tokenPid(o: O) u64 {
    var tok = std.mem.zeroes(AuditToken);
    xpc_dictionary_get_audit_token(o, &tok);
    return tok.val[5]; // audit_token_to_au32's pid (bsm_wrappers.c)
}

// One call's completion: its first event, the reply's fields, how many came,
// and (when keep) the reply's endpoint, retained.
const Call = struct {
    sem: c.sem_t = undefined,
    n: u64 = 0,
    code: u64 = NONE,
    pid: u64 = 0,
    count: u64 = 0,
    found: u64 = 0,
    keep: bool = false,
    ep: O = null,
    conn: O = null, // endpointReleasedBeforeUse: made from the reply's endpoint
    refs_name: u32 = 0, // endpointNames: the name counted while the reply lives
    refs_seen: u64 = 0,
    fn init(k: *Call) void {
        k.* = .{};
        _ = c.sem_init(&k.sem, 0, 0);
    }
};
fn callDone(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const k: *Call = @ptrCast(@alignCast(ctx.?));
    if (@atomicRmw(u64, &k.n, .Add, 1, .seq_cst) == 0) {
        k.code = eventCode(o);
        if (k.code < INVALID) {
            k.pid = xpc_dictionary_get_uint64(o, "pid");
            k.count = xpc_dictionary_get_uint64(o, "n");
            const ep = xpc_dictionary_get_value(o, "ep");
            k.found = @intFromBool(isEndpoint(ep));
            if (k.keep and isEndpoint(ep)) k.ep = xpc_retain(ep);
            if (k.refs_name != 0) k.refs_seen = refs(k.refs_name, SEND);
        }
    }
    _ = c.sem_post(&k.sem);
}
// container's shape: the reply handler connects from the reply's endpoint;
// the endpoint goes right after, and the reply when the handler returns.
fn callConnect(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const k: *Call = @ptrCast(@alignCast(ctx.?));
    if (@atomicRmw(u64, &k.n, .Add, 1, .seq_cst) == 0) {
        k.code = eventCode(o);
        const ep = if (k.code < INVALID) xpc_dictionary_get_value(o, "ep") else null;
        k.found = @intFromBool(isEndpoint(ep));
        if (isEndpoint(ep)) {
            const e = xpc_retain(ep);
            k.conn = xpc_connection_create_from_endpoint(e);
            xpc_release(e);
        }
    }
    _ = c.sem_post(&k.sem);
}
fn call(conn: O, m: O, k: *Call, f: Fn) void {
    const b = block(f, k, null);
    xpc_connection_send_message_with_reply(conn, m, null, b);
    _Block_release(b);
    xpc_release(m);
}

// ---- In-process servers ----------------------------------------------------------

const SLOTS = 128;
// A target: its peers count each value, keep the sender's pid from the audit
// token, and answer OP_REQUEST with value + 1.
const Target = struct {
    peers: u64 = 0,
    count: [SLOTS]u64 = @splat(0),
    pid: [SLOTS]u64 = @splat(0),
};
fn reply(peer: O, o: O, value: u64, ep: O, n: u64, pid: u64) void {
    const r = xpc_dictionary_create_reply(o);
    if (r == null) return;
    xpc_dictionary_set_uint64(r, "value", value);
    if (pid != 0) xpc_dictionary_set_uint64(r, "pid", pid);
    if (n != 0) xpc_dictionary_set_uint64(r, "n", n);
    if (ep != null) xpc_dictionary_set_value(r, "ep", ep);
    xpc_connection_send_message(peer, r);
    xpc_release(r);
}
fn targetPeer(ctx: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const t: *Target = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    if (code >= SLOTS) return;
    const slot: usize = @intCast(code);
    put(&t.pid[slot], tokenPid(o));
    if (xpc_dictionary_get_uint64(o, "op") == OP_REQUEST) reply(peer, o, code + 1, null, 0, tokenPid(o));
    bump(&t.count[slot]);
}
fn targetListener(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const t: *Target = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) != PEER) return;
    bump(&t.peers);
    setHandler(o, &targetPeer, t);
    xpc_connection_resume(o);
}
// A server: its peers do what each message's op asks.
const Server = struct {
    target: O = null,
    target_port: u32 = 0,
    peers: u64 = 0,
    count: [SLOTS]u64 = @splat(0),
    found: [SLOTS]u64 = @splat(0), // the endpoint read, or the endpoints counted
    named: [SLOTS]u64 = @splat(0), // of those, how many name the target's port
    sent: [SLOTS]u64 = @splat(0),
    conns: [8]O = @splat(null),
    nconns: u64 = 0,
};
fn countEndpoints(s: *Server, o: O, slot: usize) u64 {
    const eps = xpc_dictionary_get_value(o, "eps");
    var n: u64 = 0;
    var named: u64 = 0;
    if (eps != null) {
        for (0..xpc_array_get_count(eps)) |i| {
            const e = xpc_array_get_value(eps, i);
            if (isEndpoint(e)) {
                n += 1;
                if (endpointName(e) == s.target_port) named += 1;
            }
        }
    }
    put(&s.found[slot], n);
    put(&s.named[slot], named);
    return n;
}
fn serverPeer(ctx: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    if (code >= SLOTS) return;
    const slot: usize = @intCast(code);
    switch (xpc_dictionary_get_uint64(o, "op")) {
        OP_CONNECT => {
            const ep = nested(o);
            put(&s.found[slot], @intFromBool(isEndpoint(ep)));
            put(&s.named[slot], @intFromBool(isEndpoint(ep) and endpointName(ep) == s.target_port));
            if (isEndpoint(ep)) {
                const conn = xpc_connection_create_from_endpoint(ep);
                const i = @atomicRmw(u64, &s.nconns, .Add, 1, .seq_cst);
                if (conn != null and i < s.conns.len) {
                    s.conns[@intCast(i)] = conn;
                    setHandler(conn, &ignore, null);
                    xpc_connection_resume(conn);
                    send(conn, dict(code + 1, 0));
                    bump(&s.sent[slot]);
                }
            }
        },
        OP_GIVE => {
            const e = xpc_endpoint_create(s.target);
            reply(peer, o, code, e, 0, 0);
            if (e != null) xpc_release(e);
        },
        OP_REPLY_NESTED => {
            const ep = nested(o);
            put(&s.found[slot], @intFromBool(isEndpoint(ep)));
            reply(peer, o, code, ep, 0, 0);
        },
        OP_ECHO => {
            const ep = xpc_dictionary_get_value(o, "ep");
            put(&s.found[slot], @intFromBool(isEndpoint(ep)));
            reply(peer, o, code, if (isEndpoint(ep)) ep else null, 0, 0);
        },
        OP_COUNT => _ = countEndpoints(s, o, slot),
        OP_COUNT_REPLY => {
            const n = countEndpoints(s, o, slot);
            reply(peer, o, code, null, n, 0);
        },
        else => {},
    }
    bump(&s.count[slot]);
}
fn serverListener(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) != PEER) return;
    bump(&s.peers);
    setHandler(o, &serverPeer, s);
    xpc_connection_resume(o);
}
// An anonymous listener and its port name, by snapshots around its creation.
fn listenerWithPort(tag: [*:0]const u8, port: *u32) O {
    names(&before_names);
    const l = xpc_connection_create(null, dispatch_queue_create(tag, null));
    names(&after_names);
    need(l != null, "listener");
    port.* = onlyNew(&before_names, &after_names) orelse c.atf_tc_fail("setup: one new port for the listener");
    return l;
}
fn listen(tag: [*:0]const u8, f: Fn, ctx: ?*anyopaque, port: *u32) O {
    const l = listenerWithPort(tag, port);
    setHandler(l, f, ctx);
    xpc_connection_resume(l);
    return l;
}
// A client of a listener, from a local endpoint that goes at once.
fn clientOf(l: O, events: *Events) O {
    const e = xpc_endpoint_create(l);
    need(e != null, "local endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "client from the local endpoint");
    xpc_release(e);
    setHandler(conn, &recordInto, events);
    xpc_connection_resume(conn);
    return conn;
}
fn retire(conn: O) void {
    if (conn == null) return;
    xpc_connection_cancel(conn);
    xpc_release(conn);
}
fn retireServer(s: *Server) void {
    for (&s.conns) |*x| {
        retire(x.*);
        x.* = null;
    }
}

// Each case runs in its own process. Its servers, clients and calls live
// here, not in the case's frame: an event that comes after the case ends
// writes here.
var tgt: Target = .{};
var srv: Server = .{};
var cli: Events = undefined;
var calls: [4]Call = undefined;

// ---- endpointInReply -----------------------------------------------------------

// container's shape across two processes. A forked child holds an anonymous
// listener and a named listener, and answers OP_GIVE on the named one with an
// endpoint of the anonymous one. The parent asks, gets the endpoint in the
// reply, lets the reply go, connects from the endpoint, and makes three
// request-and-reply exchanges, the first held while the other two complete.
// The child reads the audit token of each request. Then it exits.
var child_anon: O = null;
var child_held: O = null;
var child_held_peer: O = null;
var child_held_pid: u64 = 0;
fn childServe(name: [*:0]const u8, ready: c_int) noreturn {
    _ = c.alarm(20);
    child_anon = xpc_connection_create(null, dispatch_queue_create("op796.child.anonymous", null));
    if (child_anon == null) c._exit(80);
    setHandler(child_anon, &childAnonListener, null);
    xpc_connection_resume(child_anon);
    const l = xpc_connection_create_mach_service(name, dispatch_queue_create("op796.child.named", null), LISTENER);
    if (l == null) c._exit(81);
    setHandler(l, &childNamedListener, null);
    xpc_connection_resume(l);
    var b: u8 = 'r';
    if (c.write(ready, &b, 1) != 1) c._exit(82);
    while (true) _ = c.pause();
}
fn childAnonListener(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    if (eventCode(o) != PEER) return;
    setHandler(o, &childAnonPeer, null);
    xpc_connection_resume(o);
}
fn childNamedListener(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    if (eventCode(o) != PEER) return;
    setHandler(o, &childNamedPeer, null);
    xpc_connection_resume(o);
}
fn childNamedPeer(_: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const code = eventCode(o);
    if (code >= INVALID or xpc_dictionary_get_uint64(o, "op") != OP_GIVE) return;
    const e = xpc_endpoint_create(child_anon);
    if (e == null) c._exit(83);
    reply(peer, o, code, e, 0, tokenPid(o));
    xpc_release(e);
}
fn childAnonPeer(_: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const code = eventCode(o);
    if (code >= INVALID) return;
    const pid = tokenPid(o);
    switch (xpc_dictionary_get_uint64(o, "op")) {
        OP_HOLD => {
            child_held = xpc_retain(o);
            child_held_peer = peer;
            child_held_pid = pid;
        },
        OP_REQUEST => reply(peer, o, code + 1, null, 0, pid),
        OP_RELEASE => if (child_held != null) {
            reply(child_held_peer, child_held, xpc_dictionary_get_uint64(child_held, "value") + 1, null, 0, child_held_pid);
            xpc_release(child_held);
            child_held = null;
        },
        OP_EXIT => c._exit(0),
        else => {},
    }
}
fn readByte(fd: c_int, want: u8, ms: c_int) bool {
    var ready = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    var b: u8 = 0;
    return c.poll(&ready, 1, ms) == 1 and c.read(fd, &b, 1) == 1 and b == want;
}
fn reap(pid: c.pid_t, ms: u64) ?c_int {
    var status: c_int = -1;
    const start = nowMs();
    while (nowMs() - start < ms) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid) return status;
        _ = c.usleep(10_000);
    }
    return null;
}
fn stopChild(pid: c.pid_t) void {
    _ = c.kill(pid, c.SIGKILL);
    _ = c.waitpid(pid, null, 0);
}
fn endpointInReply(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointInReply";
    library(case);
    var buf: [96]u8 = undefined;
    const len = c.snprintf(&buf, buf.len, "org.rmxos.op796.reply.%d", c.getpid());
    need(len > 0 and len < buf.len, "service name");
    const name: [*:0]const u8 = @ptrCast(&buf);
    var ready: [2]c_int = undefined;
    need(c.pipe(&ready) == 0, "pipe");
    // Fork before this process uses libdispatch or libxpc.
    const pid = c.fork();
    need(pid >= 0, "fork");
    if (pid == 0) {
        _ = c.close(ready[0]);
        childServe(name, ready[1]);
    }
    _ = c.close(ready[1]);
    const served = readByte(ready[0], 'r', 3000);
    _ = c.close(ready[0]);
    fact(case, "server_serving", 1, @intFromBool(served));
    if (!served) {
        stopChild(pid);
        conclude(case);
    }
    const dead_start = deadNames();
    // Ask the named listener for an endpoint.
    var named_events: Events = undefined;
    named_events.init();
    const named = xpc_connection_create_mach_service(name, dispatch_queue_create("op796.reply.named", null), 0);
    need(named != null, "named client");
    setHandler(named, &recordInto, &named_events);
    xpc_connection_resume(named);
    const ask = &calls[0];
    ask.init();
    ask.keep = true;
    call(named, dict(1, OP_GIVE), ask, &callDone);
    const asked = waitMs(&ask.sem, LIMIT_MS);
    fact(case, "endpoint_reply_arrived", 1, if (asked) ask.code else NONE);
    fact(case, "endpoint_in_reply", 1, ask.found);
    // Its service port dies with the server: let the named client's rights go first.
    xpc_connection_cancel(named);
    xpc_release(named);
    if (ask.ep == null) {
        stopChild(pid);
        conclude(case);
    }
    const e = ask.ep;
    const ename = endpointName(e);
    _ = c.printf("xpc_b0 case=%s observed endpoint_name=%u type=0x%x server_pid=%d\n", case, ename, portType(ename), pid);
    fact(case, "endpoint_names_a_send_right", 1, @intFromBool(ename != 0 and (portType(ename) & c.MACH_PORT_TYPE_SEND) != 0));
    // The reply has gone; the endpoint object alone holds the received right.
    fact(case, "send_refs_endpoint", 1, refs(ename, SEND));
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "connection from the endpoint");
    fact(case, "send_refs_with_connection", 2, refs(ename, SEND));
    var events: Events = undefined;
    events.init();
    setHandler(conn, &recordInto, &events);
    xpc_connection_resume(conn);
    // Three exchanges: the first held while the second and third complete.
    const a = &calls[1];
    const b = &calls[2];
    const k = &calls[3];
    a.init();
    b.init();
    k.init();
    call(conn, dict(10, OP_HOLD), a, &callDone);
    call(conn, dict(20, OP_REQUEST), b, &callDone);
    const b_done = waitMs(&b.sem, LIMIT_MS);
    call(conn, dict(30, OP_REQUEST), k, &callDone);
    const c_done = waitMs(&k.sem, LIMIT_MS);
    const a_pending = load(&a.n) == 0;
    send(conn, dict(40, OP_RELEASE));
    const a_done = waitMs(&a.sem, LIMIT_MS);
    _ = c.usleep(100_000);
    const me: u64 = @intCast(c.getpid());
    fact(case, "second_reply", 21, if (b_done) b.code else NONE);
    fact(case, "third_reply", 31, if (c_done) k.code else NONE);
    fact(case, "first_pending_while_two_complete", 1, @intFromBool(a_pending));
    fact(case, "first_reply_after_release", 11, if (a_done) a.code else NONE);
    fact(case, "first_token_pid", me, a.pid);
    fact(case, "second_token_pid", me, b.pid);
    fact(case, "third_token_pid", me, k.pid);
    fact(case, "completions", 3, load(&a.n) + load(&b.n) + load(&k.n));
    fact(case, "send_refs_connected", 2, refs(ename, SEND));
    // The server exits.
    send(conn, dict(50, OP_EXIT));
    const invalid = events.waitCode(INVALID, 3000);
    const status = reap(pid, 3000);
    if (status == null) stopChild(pid);
    _ = c.usleep(200_000);
    _ = c.printf("xpc_b0 case=%s observed events=%llu invalid=%llu interrupted=%llu last=%llu\n", case, events.count(), events.tally(INVALID), events.tally(INTERRUPTED), events.last());
    fact(case, "server_exited_zero", 1, @intFromBool(status != null and status.? == 0));
    fact(case, "connection_invalid", 1, @intFromBool(invalid));
    fact(case, "invalid_events", 1, events.tally(INVALID));
    fact(case, "last_event", INVALID, events.last());
    // The connection gives up its dead name; the endpoint object holds its own.
    fact(case, "dead_refs_after_invalid", 1, settleRefs(ename, DEAD, 1, 3000));
    xpc_release(e);
    fact(case, "dead_refs_after_endpoint_released", 0, settleRefs(ename, DEAD, 0, 2000));
    fact(case, "dead_names_back", dead_start, settleDead(dead_start, 2000));
    xpc_release(conn);
    conclude(case);
}

// ---- endpointInMessage, with the wire records ------------------------------------

// An endpoint of a target listener, two levels down in an ordinary message to
// a server, which connects from it and sends the target one message.
fn endpointInMessage(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointInMessage";
    library(case);
    var tport: u32 = 0;
    const t = listen("op796.nested.target", &targetListener, &tgt, &tport);
    var sport: u32 = 0;
    srv.target = t;
    srv.target_port = tport;
    const s = listen("op796.nested.server", &serverListener, &srv, &sport);
    const et = xpc_endpoint_create(t);
    need(et != null, "target endpoint");
    // The description names the port: a known answer for endpointName.
    fact(case, "description_names_target_port", tport, endpointName(et));
    cli.init();
    const client = clientOf(s, &cli);
    send(client, nestedMessage(20, OP_CONNECT, et));
    const arrived = awaitCount(&srv.count[20], 1, LIMIT_MS);
    fact(case, "message_arrived", 1, @intFromBool(arrived));
    fact(case, "nested_endpoint_read", 1, load(&srv.found[20]));
    if (load(&srv.found[20]) == 0) {
        retire(client);
        xpc_release(et);
        retire(s);
        retire(t);
        conclude(case);
    }
    fact(case, "nested_endpoint_names_target", 1, load(&srv.named[20]));
    const through = awaitCount(&tgt.count[21], 1, LIMIT_MS);
    _ = c.usleep(100_000);
    fact(case, "message_through", 1, @intFromBool(through));
    fact(case, "target_messages", 1, load(&tgt.count[21]));
    fact(case, "target_token_pid", @intCast(c.getpid()), load(&tgt.pid[21]));
    wireRecords(case, et, tport, sport);
    retireServer(&srv);
    retire(client);
    xpc_release(et);
    retire(s);
    retire(t);
    conclude(case);
}

const PortDescriptor = extern struct { name: u32, pad1: u32, pad2: u16, disposition: u8, kind: u8 };
const COMPLEX: u32 = 0x80000000;
var wire: [16384]u8 align(8) = undefined;
fn receiveWire(port: u32, ms: u32) c_int {
    @memset(&wire, 0);
    const h: *c.mach_msg_header_t = @ptrCast(&wire);
    return c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, wire.len, port, ms, 0);
}
// One received message as the wire carries it, read from `wire`.
const View = struct {
    complex: u64 = 0,
    count: u64 = 0,
    disp: [3]u64 = @splat(0),
    name: [3]u32 = @splat(0),
    list: u64 = 0, // the offset of the packed list
    size: u64 = 0,
    id: u64 = 0,
    magic: u64 = 0, // the list's first byte: 0x6c for an nvlist header
    index: i64 = -1, // the endpoint's index in the list
    reply_port: u32 = 0,
    bits: u32 = 0,
};
// The index of the endpoint in a packed list, at "ep" or at list[0].ep.
fn listIndex(bytes: []const u8) i64 {
    const nv = nvlist_unpack(bytes.ptr, bytes.len) orelse return -2;
    defer nvlist_destroy(nv);
    if (nvlist_exists_type(nv, "ep", NV_TYPE_ENDPOINT)) return nvlist_get_endpoint(nv, "ep");
    if (!nvlist_exists_type(nv, "list", NV_TYPE_NVLIST_ARRAY)) return -1;
    const a = nvlist_get_nvlist_array(nv, "list");
    if (!nvlist_exists_type(a, "0", NV_TYPE_NVLIST_DICTIONARY)) return -1;
    const d = nvlist_get_nvlist_dictionary(a, "0");
    if (!nvlist_exists_type(d, "ep", NV_TYPE_ENDPOINT)) return -1;
    return nvlist_get_endpoint(d, "ep");
}
fn view() View {
    const h: *c.mach_msg_header_t = @ptrCast(&wire);
    var v = View{ .bits = h.msgh_bits, .reply_port = h.msgh_remote_port };
    v.complex = @intFromBool((h.msgh_bits & COMPLEX) != 0);
    v.count = if (v.complex != 0) std.mem.readInt(u32, wire[24..28], .little) else 0;
    const shown: usize = @intCast(@min(v.count, 3));
    for (0..shown) |i| {
        const d: *align(4) const PortDescriptor = @ptrCast(@alignCast(&wire[28 + 12 * i]));
        v.disp[i] = d.disposition;
        v.name[i] = d.name;
    }
    v.list = if (v.count == 0) 40 else std.mem.alignForward(u64, 28 + 12 * v.count, 8) + 16;
    if (v.list > h.msgh_size) return v;
    v.size = std.mem.readInt(u64, wire[@intCast(v.list - 16)..][0..8], .little);
    v.id = std.mem.readInt(u64, wire[@intCast(v.list - 8)..][0..8], .little);
    v.magic = wire[@intCast(v.list)];
    if (v.size <= h.msgh_size - v.list) v.index = listIndex(wire[@intCast(v.list)..][0..@intCast(v.size)]);
    return v;
}
fn printView(case: [*:0]const u8, form: [*:0]const u8, v: View) void {
    _ = c.printf("xpc_b0 case=%s wire form=%s bits=0x%08x complex=%llu descriptors=%llu d0=%llu:%u d1=%llu:%u list_offset=%llu size=%llu id=%llu magic=0x%llx index=%lld reply_port=%u\n", case, form, v.bits, v.complex, v.count, v.disp[0], v.name[0], v.disp[1], v.name[1], v.list, v.size, v.id, v.magic, v.index, v.reply_port);
    _ = c.fflush(null);
}
// A request the case sends itself: header to dest with a send right made
// from reply, a send-once right to reply, then a copy of the send right
// carried, then size, ID and the packed list.
fn sendRequest(dest: u32, reply_port: u32, carried: u32, payload: []const u8, id: u64) c_int {
    const total = std.mem.alignForward(usize, 56 + payload.len, 8);
    const buf: [*]align(8) u8 = @ptrCast(@alignCast(c.calloc(1, total) orelse c.atf_tc_fail("setup: request buffer")));
    defer c.free(buf);
    const h: *c.mach_msg_header_t = @ptrCast(buf);
    h.msgh_bits = COMPLEX | c.MACH_MSGH_BITS(c.MACH_MSG_TYPE_COPY_SEND, c.MACH_MSG_TYPE_MAKE_SEND);
    h.msgh_size = @intCast(total);
    h.msgh_remote_port = dest;
    h.msgh_local_port = reply_port;
    h.msgh_id = 0x10000000; // XPC_PIPE_MESSAGE_ID
    std.mem.writeInt(u32, buf[24..28], 2, .little);
    const d: [*]align(4) PortDescriptor = @ptrCast(@alignCast(buf + 28));
    d[0] = .{ .name = reply_port, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_MAKE_SEND_ONCE, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
    d[1] = .{ .name = carried, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
    std.mem.writeInt(u64, buf[40..48], payload.len, .little);
    std.mem.writeInt(u64, buf[48..56], id, .little);
    @memcpy(buf[56..][0..payload.len], payload);
    return c.mach_msg(h, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, h.msgh_size, 0, 0, 1000, 0);
}
var captured: [4096]u8 = undefined;
// The three forms as the library builds them: an ordinary message and a
// request from a client to a listener that is never resumed, read from its
// port; and the server's reply to a request the case sends, read from a port
// of the case's own.
fn wireRecords(case: [*:0]const u8, et: O, tport: u32, sport: u32) void {
    var cport: u32 = 0;
    const cap = listenerWithPort("op796.wire.capture", &cport);
    var quiet: Events = undefined;
    quiet.init();
    const cc = clientOf(cap, &quiet);
    // Ordinary.
    send(cc, nestedMessage(22, 0, et));
    fact(case, "ordinary_received", 0, @bitCast(@as(i64, receiveWire(cport, 2000))));
    const o = view();
    printView(case, "ordinary", o);
    fact(case, "ordinary_complex", 1, o.complex);
    fact(case, "ordinary_descriptors", 1, o.count);
    fact(case, "ordinary_d0_disposition", PORT_SEND, o.disp[0]);
    fact(case, "ordinary_d0_names_target", tport, o.name[0]);
    fact(case, "ordinary_list_at_40", 0x6c, if (o.list == 40) o.magic else 0);
    fact(case, "ordinary_endpoint_index", 0, @bitCast(o.index));
    c.mach_msg_destroy(@ptrCast(&wire));
    // Request.
    const kr = &calls[0];
    kr.init();
    call(cc, nestedMessage(23, OP_REPLY_NESTED, et), kr, &callDone);
    fact(case, "request_received", 0, @bitCast(@as(i64, receiveWire(cport, 2000))));
    const r = view();
    printView(case, "request", r);
    fact(case, "request_complex", 1, r.complex);
    fact(case, "request_descriptors", 2, r.count);
    fact(case, "request_d0_disposition", PORT_SEND_ONCE, r.disp[0]);
    fact(case, "request_d1_disposition", PORT_SEND, r.disp[1]);
    fact(case, "request_d1_names_target", tport, r.name[1]);
    fact(case, "request_list_at_56", 0x6c, if (r.list == 56) r.magic else 0);
    fact(case, "request_endpoint_index", 0, @bitCast(r.index));
    const n: usize = if (r.size <= captured.len and r.list == 56) @intCast(r.size) else 0;
    @memcpy(captured[0..n], wire[56..][0..n]);
    // The request's send-once right goes with it: its call completes with an error.
    c.mach_msg_destroy(@ptrCast(&wire));
    _ = waitMs(&kr.sem, LIMIT_MS);
    // Reply: the captured request, sent to the server with a reply right of the case's own.
    var own: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &own) == 0, "reply port");
    need(n != 0, "captured request list");
    fact(case, "raw_request_sent", 0, @bitCast(@as(i64, sendRequest(sport, own, tport, captured[0..n], 796))));
    fact(case, "reply_received", 0, @bitCast(@as(i64, receiveWire(own, 2000))));
    const p = view();
    printView(case, "reply", p);
    fact(case, "reply_complex", 1, p.complex);
    fact(case, "reply_descriptors", 1, p.count);
    fact(case, "reply_d0_disposition", PORT_SEND, p.disp[0]);
    fact(case, "reply_d0_names_target", tport, p.name[0]);
    fact(case, "reply_list_at_40", 0x6c, if (p.list == 40) p.magic else 0);
    fact(case, "reply_endpoint_index", 0, @bitCast(p.index));
    fact(case, "reply_id", 796, p.id);
    fact(case, "reply_has_no_reply_port", 0, p.reply_port);
    c.mach_msg_destroy(@ptrCast(&wire));
    retire(cc);
    retire(cap);
    _ = c.mach_port_mod_refs(c.mach_task_self(), own, c.MACH_PORT_RIGHT_RECEIVE, -1);
}

// ---- endpointReleasedBeforeUse ---------------------------------------------------

// The reply handler connects from the reply's endpoint and lets the endpoint
// go; the reply goes when the handler returns. One exchange follows.
fn endpointReleasedBeforeUse(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointReleasedBeforeUse";
    library(case);
    var tport: u32 = 0;
    const t = listen("op796.released.target", &targetListener, &tgt, &tport);
    var sport: u32 = 0;
    srv.target = t;
    srv.target_port = tport;
    const s = listen("op796.released.server", &serverListener, &srv, &sport);
    cli.init();
    const client = clientOf(s, &cli);
    const start = refs(tport, SEND);
    const k = &calls[0];
    k.init();
    call(client, dict(30, OP_GIVE), k, &callConnect);
    const done = waitMs(&k.sem, LIMIT_MS);
    fact(case, "reply_arrived", 30, if (done) k.code else NONE);
    fact(case, "endpoint_in_reply", 1, k.found);
    if (k.conn == null) {
        retire(client);
        retire(s);
        retire(t);
        conclude(case);
    }
    // The reply and its endpoint are gone: the connection's reference stays.
    fact(case, "send_refs_after_release", start + 1, settleRefs(tport, SEND, start + 1, 1000));
    var events: Events = undefined;
    events.init();
    setHandler(k.conn, &recordInto, &events);
    xpc_connection_resume(k.conn);
    const x = &calls[1];
    x.init();
    call(k.conn, dict(31, OP_REQUEST), x, &callDone);
    const exchanged = waitMs(&x.sem, LIMIT_MS);
    _ = c.usleep(100_000);
    fact(case, "exchange_reply", 32, if (exchanged) x.code else NONE);
    fact(case, "target_messages", 1, load(&tgt.count[31]));
    fact(case, "connection_events", 0, events.count());
    fact(case, "send_refs_connected", start + 1, refs(tport, SEND));
    retire(k.conn);
    fact(case, "send_refs_after_cancel", start, settleRefs(tport, SEND, start, 2000));
    retire(client);
    retire(s);
    retire(t);
    conclude(case);
}

// ---- secondEndpoint --------------------------------------------------------------

// One target listener, two endpoints of it from two replies, two clients.
// Destroying one endpoint and cancelling its client leaves the listener and
// the other client working.
fn secondEndpoint(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "secondEndpoint";
    library(case);
    var tport: u32 = 0;
    const t = listen("op796.second.target", &targetListener, &tgt, &tport);
    var sport: u32 = 0;
    srv.target = t;
    srv.target_port = tport;
    const s = listen("op796.second.server", &serverListener, &srv, &sport);
    cli.init();
    const client = clientOf(s, &cli);
    const start = refs(tport, SEND);
    const g1 = &calls[0];
    const g2 = &calls[1];
    g1.init();
    g2.init();
    g1.keep = true;
    g2.keep = true;
    call(client, dict(40, OP_GIVE), g1, &callDone);
    call(client, dict(41, OP_GIVE), g2, &callDone);
    _ = waitMs(&g1.sem, LIMIT_MS);
    _ = waitMs(&g2.sem, LIMIT_MS);
    fact(case, "first_endpoint_in_reply", 1, g1.found);
    fact(case, "second_endpoint_in_reply", 1, g2.found);
    if (g1.ep == null or g2.ep == null) {
        if (g1.ep != null) xpc_release(g1.ep);
        if (g2.ep != null) xpc_release(g2.ep);
        retire(client);
        retire(s);
        retire(t);
        conclude(case);
    }
    fact(case, "send_refs_two_endpoints", start + 2, refs(tport, SEND));
    var ev1: Events = undefined;
    var ev2: Events = undefined;
    ev1.init();
    ev2.init();
    const c1 = xpc_connection_create_from_endpoint(g1.ep);
    const c2 = xpc_connection_create_from_endpoint(g2.ep);
    need(c1 != null and c2 != null, "two clients");
    setHandler(c1, &recordInto, &ev1);
    setHandler(c2, &recordInto, &ev2);
    xpc_connection_resume(c1);
    xpc_connection_resume(c2);
    fact(case, "send_refs_two_clients", start + 4, refs(tport, SEND));
    const x1 = &calls[2];
    const x2 = &calls[3];
    x1.init();
    x2.init();
    call(c1, dict(42, OP_REQUEST), x1, &callDone);
    call(c2, dict(44, OP_REQUEST), x2, &callDone);
    const d1 = waitMs(&x1.sem, LIMIT_MS);
    const d2 = waitMs(&x2.sem, LIMIT_MS);
    fact(case, "first_client_reply", 43, if (d1) x1.code else NONE);
    fact(case, "second_client_reply", 45, if (d2) x2.code else NONE);
    fact(case, "target_peers", 2, load(&tgt.peers));
    // Destroy the first endpoint and cancel its client.
    xpc_release(g1.ep);
    xpc_connection_cancel(c1);
    const ended = ev1.waitCode(INVALID, LIMIT_MS);
    fact(case, "first_client_invalid", 1, @intFromBool(ended));
    fact(case, "send_refs_after", start + 2, settleRefs(tport, SEND, start + 2, 2000));
    // The other client, and a new one from the other endpoint, still work.
    x2.init();
    call(c2, dict(46, OP_REQUEST), x2, &callDone);
    const d3 = waitMs(&x2.sem, LIMIT_MS);
    fact(case, "second_client_after", 47, if (d3) x2.code else NONE);
    var ev3: Events = undefined;
    ev3.init();
    const c3 = xpc_connection_create_from_endpoint(g2.ep);
    need(c3 != null, "third client");
    setHandler(c3, &recordInto, &ev3);
    xpc_connection_resume(c3);
    x1.init();
    call(c3, dict(48, OP_REQUEST), x1, &callDone);
    const d4 = waitMs(&x1.sem, LIMIT_MS);
    _ = c.usleep(100_000);
    fact(case, "new_client_from_second_endpoint", 49, if (d4) x1.code else NONE);
    fact(case, "target_peers_after", 3, load(&tgt.peers));
    fact(case, "first_client_events", 1, ev1.count());
    fact(case, "second_client_events", 0, ev2.count());
    retire(c3);
    retire(c2);
    xpc_release(c1);
    xpc_release(g2.ep);
    fact(case, "send_refs_end", start, settleRefs(tport, SEND, start, 2000));
    retire(client);
    retire(s);
    retire(t);
    conclude(case);
}

// ---- endpointNames ---------------------------------------------------------------

// N round trips, each carrying an endpoint of the target out in a request and
// back in its reply: the send rights on the target's name come back to where
// they started. On a library that sends no endpoint this holds without
// testing anything; the rounds print how many replies carried one.
const ROUNDS = 20;
fn endpointNames(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointNames";
    library(case);
    var tport: u32 = 0;
    const t = listen("op796.names.target", &targetListener, &tgt, &tport);
    var sport: u32 = 0;
    srv.target = t;
    srv.target_port = tport;
    const s = listen("op796.names.server", &serverListener, &srv, &sport);
    cli.init();
    const client = clientOf(s, &cli);
    const et = xpc_endpoint_create(t);
    need(et != null, "target endpoint");
    const start = refs(tport, SEND);
    var completed: u64 = 0;
    var carried: u64 = 0;
    var peak: u64 = start;
    for (0..ROUNDS) |i| {
        const k = &calls[0];
        k.init();
        k.refs_name = tport;
        const m = dict(60 + i, OP_ECHO);
        xpc_dictionary_set_value(m, "ep", et);
        call(client, m, k, &callDone);
        if (waitMs(&k.sem, LIMIT_MS) and k.code == 60 + i) completed += 1;
        carried += k.found;
        peak = @max(peak, k.refs_seen);
    }
    const back = settleRefs(tport, SEND, start, 2000);
    _ = c.printf("xpc_b0 case=%s observed rounds=%u replies_with_endpoint=%llu server_read_endpoint=%llu start=%llu peak_in_reply_handler=%llu back=%llu\n", case, @as(c_uint, ROUNDS), carried, sumFound(60, ROUNDS), start, peak, back);
    fact(case, "rounds_completed", ROUNDS, completed);
    fact(case, "send_refs_back", start, back);
    xpc_release(et);
    retire(client);
    retire(s);
    retire(t);
    conclude(case);
}
fn sumFound(first: usize, n: usize) u64 {
    var k: u64 = 0;
    for (first..first + n) |i| k += load(&srv.found[i]);
    return k;
}

// ---- endpointCapRefused ----------------------------------------------------------

// 64 endpoints (the cap) arrive; one more is refused at the sender, logged,
// and the connection stays usable. A request at the cap (64 endpoints and
// its reply right) is answered.
fn endpointCapRefused(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointCapRefused";
    library(case);
    var tport: u32 = 0;
    const t = listen("op796.cap.target", &targetListener, &tgt, &tport);
    var sport: u32 = 0;
    srv.target = t;
    srv.target_port = tport;
    const s = listen("op796.cap.server", &serverListener, &srv, &sport);
    cli.init();
    const client = clientOf(s, &cli);
    const et = xpc_endpoint_create(t);
    need(et != null, "target endpoint");
    const start = refs(tport, SEND);
    send(client, manyMessage(90, OP_COUNT, et, CAP));
    const cap_arrived = awaitCount(&srv.count[90], 1, LIMIT_MS);
    const interrupted_before = cli.tally(INTERRUPTED);
    send(client, manyMessage(91, OP_COUNT, et, CAP + 1));
    const interrupted = cli.waitCode(INTERRUPTED, LIMIT_MS) and cli.tally(INTERRUPTED) > interrupted_before;
    send(client, dict(92, 0));
    const small = awaitCount(&srv.count[92], 1, LIMIT_MS);
    const k = &calls[0];
    k.init();
    call(client, manyMessage(93, OP_COUNT_REPLY, et, CAP), k, &callDone);
    const answered = waitMs(&k.sem, LIMIT_MS);
    _ = c.usleep(200_000);
    _ = c.printf("xpc_b0 case=%s observed cap_count=%llu cap_named=%llu over_count=%llu small_count=%llu request_code=%llu request_n=%llu client_interrupted=%llu client_invalid=%llu log_expected=send_refused_endpoints_%llu_cap_%llu\n", case, load(&srv.found[90]), load(&srv.named[90]), load(&srv.count[91]), load(&srv.count[92]), k.code, k.count, cli.tally(INTERRUPTED), cli.tally(INVALID), CAP + 1, CAP);
    fact(case, "cap_arrived", 1, @intFromBool(cap_arrived));
    fact(case, "cap_endpoints", CAP, load(&srv.found[90]));
    fact(case, "cap_endpoints_name_target", CAP, load(&srv.named[90]));
    fact(case, "over_interrupts_client", 1, @intFromBool(interrupted));
    fact(case, "over_arrived", 0, load(&srv.count[91]));
    fact(case, "small_after", 1, @intFromBool(small));
    fact(case, "request_at_cap_reply", 93, if (answered) k.code else NONE);
    fact(case, "request_at_cap_endpoints", CAP, k.count);
    fact(case, "send_refs_back", start, settleRefs(tport, SEND, start, 2000));
    xpc_release(et);
    retire(client);
    retire(s);
    retire(t);
    conclude(case);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
// A console command runs the six in one batch under a 120 s cap: 30 + 5 x 15.
fn longHead(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "30");
}
fn shortHead(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "15");
}
var cases: [6]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const ids = [_][*:0]const u8{ "endpointInReply", "endpointInMessage", "endpointReleasedBeforeUse", "secondEndpoint", "endpointNames", "endpointCapRefused" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &endpointInReply, &endpointInMessage, &endpointReleasedBeforeUse, &secondEndpoint, &endpointNames, &endpointCapRefused };
    for (&cases, ids, bodies, 0..) |*tc, id, body, i| {
        var err = c.atf_tc_init(tc, id, if (i == 0) &longHead else &shortHead, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
