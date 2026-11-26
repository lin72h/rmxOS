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
//
// op-813 adds five cases (op-806's review). replyEndpointRefused: a reply
// whose endpoint the kernel refuses at body copyin has lost its send-once
// right, and its sender must not release that name again; the program's own
// mach_msg_send is the hook that puts a sentinel on the freed name.
// fileInEndpointSlot: a file in an endpoint's slot refuses the message and
// is closed once. endpointIndexOutOfRange, endpointIndexTwice and
// endpointsOverCapReceived: the decoder's other refusals, each followed by a
// message that arrives.
//
// op-823 adds fileInSendOnceSlot: a file in a request's send-once slot
// refuses the request and is closed once, and the next request arrives.
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
extern fn xpc_dictionary_set_mach_recv(O, [*:0]const u8, u32) void;
extern fn xpc_connection_send_barrier(O, ?*anyopaque) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
// libxpc's own nvlist (lib/libxpc/subr_nvlist.c), whose types include
// NV_TYPE_ENDPOINT (nv.h): the wire records read a captured list with it.
extern fn nvlist_unpack(?*const anyopaque, usize) ?*anyopaque;
extern fn nvlist_destroy(?*anyopaque) void;
extern fn nvlist_exists_type(?*const anyopaque, [*:0]const u8, c_int) bool;
extern fn nvlist_get_nvlist_array(?*const anyopaque, [*:0]const u8) ?*const anyopaque;
extern fn nvlist_get_nvlist_dictionary(?*const anyopaque, [*:0]const u8) ?*const anyopaque;
extern fn nvlist_get_endpoint(?*const anyopaque, [*:0]const u8) c_int;
// op-813: the raw cases build their lists with the same nvlist.
extern fn nvlist_create_dictionary(c_int) ?*anyopaque;
extern fn nvlist_add_uint64(?*anyopaque, [*:0]const u8, u64) void;
extern fn nvlist_add_endpoint(?*anyopaque, [*:0]const u8, c_int) void;
extern fn nvlist_pack(?*const anyopaque, *usize) ?*anyopaque;
extern fn nvlist_error(?*const anyopaque) c_int;
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
    // op-813: every other descriptor and its kinfo type.
    others: [512]c_int = undefined,
    kinds: [512]c_int = undefined,
    no: usize = 0,
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
        } else {
            need(s.no < s.others.len, "other descriptors fit the snapshot");
            s.others[s.no] = f.kf_fd;
            s.kinds[s.no] = f.kf_type;
            s.no += 1;
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

// ---- Final events (op-805) -------------------------------------------------
//
// xpc_connection_cancel is asynchronous (lib/libxpc/xpc_connection.c): the
// connection's final INVALID comes later, on its receive queue, and its
// rights go separately, from its send queue. Each case runs in its own
// process, and exit() runs at the depth of the case's returned frame, so
// what a handler can reach lives in static storage. Each connection a case
// gives a handler has an End here, carried in its handler's block: what the
// handler received, its INVALIDs, and every event after the first INVALID.
// The case waits for every End's INVALID before it goes on. INVALID is the
// last event a connection's handler receives (connection.h), so an event
// after it is a libxpc defect, never the case's.
const End = struct {
    label: [*:0]const u8 = "",
    events: u64 = 0,
    invalid: u64 = 0,
    after: u64 = 0,
};
const END_SLOTS = 512;
var ends: [END_SLOTS]End = @splat(.{});
var ends_made: u64 = 0;
// Past END_SLOTS: counted as made, never ended, so the case fails.
var end_overflow: End = .{ .label = "overflow" };
fn newEnd(label: [*:0]const u8) *End {
    const i = @atomicRmw(u64, &ends_made, .Add, 1, .seq_cst);
    if (i >= END_SLOTS) return &end_overflow;
    ends[@intCast(i)].label = label;
    return &ends[@intCast(i)];
}
fn endsMade() []End {
    return ends[0..@intCast(@min(load(&ends_made), END_SLOTS))];
}
fn hasInvalid(e: *End) bool {
    return load(&e.invalid) != 0;
}
// Until e has its INVALID, or ms.
fn awaitEnd(e: *End, ms: u64) bool {
    const start = nowMs();
    while (!hasInvalid(e) and nowMs() - start < ms) _ = c.usleep(1_000);
    return hasInvalid(e);
}
// Until every End made so far has its INVALID, or ms: how many have.
fn awaitEnds(ms: u64) u64 {
    const start = nowMs();
    while (true) {
        var n: u64 = 0;
        for (endsMade()) |*e| n += @intFromBool(hasInvalid(e));
        if (n == load(&ends_made) or nowMs() - start >= ms) return n;
        _ = c.usleep(2_000);
    }
}
// After the last INVALID: the time an event after it has to arrive.
const QUIET_MS = 50;
// A case's last step: every End's INVALID, the quiet window, then the facts.
fn finalEvents(case: [*:0]const u8) void {
    const have = awaitEnds(3000);
    _ = c.usleep(QUIET_MS * 1000);
    var after: u64 = load(&end_overflow.after);
    var events: u64 = 0;
    for (endsMade()) |*e| {
        after += load(&e.after);
        events += load(&e.events);
        if (!hasInvalid(e) or load(&e.after) != 0) _ = c.printf("xpc_b0 case=%s end=%s events=%llu invalid=%llu after_invalid=%llu\n", case, e.label, load(&e.events), load(&e.invalid), load(&e.after));
    }
    _ = c.printf("xpc_b0 case=%s final ends=%llu invalid=%llu events=%llu after_invalid=%llu quiet_ms=%u\n", case, load(&ends_made), have, events, after, @as(c_uint, QUIET_MS));
    fact(case, "final_invalids", load(&ends_made), have);
    fact(case, "events_after_invalid", 0, after);
}

// Blocks ABI (BlocksRuntime runtime.c), as in reply_right.zig. A
// connection's handler block carries the connection's End (none in the
// forked server); a reply block carries none.
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
    end: ?*End,
};
fn blockInvoke(b: *Block, o: O) callconv(.c) void {
    if (b.end) |e| if (hasInvalid(e)) bump(&e.after);
    b.f(b.ctx, b.conn, o);
    if (b.end) |e| {
        bump(&e.events);
        if (o == @as(O, @ptrCast(@constCast(&_xpc_error_connection_invalid)))) bump(&e.invalid);
    }
}
const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Block) };
fn block(f: Fn, ctx: ?*anyopaque, conn: O, end: ?*End) ?*anyopaque {
    var literal = Block{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = 0, .reserved = 0, .invoke = &blockInvoke, .descriptor = &descriptor, .f = f, .ctx = ctx, .conn = conn, .end = end };
    return _Block_copy(&literal);
}
fn setHandler(conn: O, f: Fn, ctx: ?*anyopaque, end: ?*End) void {
    const b = block(f, ctx, conn, end);
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
const OP_RECV_REPLY: u64 = 11; // (replyEndpointRefused) reply with a fresh receive right as "p"

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
// A dictionary with n endpoints of listener l in its array "eps", each its
// own object: an array admits an object once (xpc_array_admit), so one
// endpoint appended n times is one slot.
fn manyMessage(value: u64, op: u64, l: O, n: usize) O {
    const d = dict(value, op);
    const eps = xpc_array_create(null, 0);
    need(eps != null, "endpoint array");
    for (0..n) |_| {
        const e = xpc_endpoint_create(l);
        need(e != null, "endpoint for the array");
        xpc_array_append_value(eps, e);
        xpc_release(e);
    }
    need(xpc_array_get_count(eps) == n, "the array holds every endpoint");
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
    const b = block(f, k, null, null);
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
    setHandler(o, &targetPeer, t, newEnd("target_peer"));
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
    // replyEndpointRefused: the peer that answered OP_RECV_REPLY, retained,
    // and the receive right its reply carried.
    peer: O = null,
    recv: u32 = 0,
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
                    setHandler(conn, &ignore, null, newEnd("server_connection"));
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
        // A receive right with no send right, borrowed by the reply
        // (xpc_dictionary_set_mach_recv): its COPY_SEND descriptor is
        // refused at the kernel's body copyin, after the header's.
        OP_RECV_REPLY => {
            var r: u32 = 0;
            if (c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &r) == 0) {
                const rep = xpc_dictionary_create_reply(o);
                if (rep != null) {
                    s.recv = r;
                    s.peer = xpc_retain(peer);
                    xpc_dictionary_set_uint64(rep, "value", code);
                    xpc_dictionary_set_mach_recv(rep, "p", r);
                    xpc_connection_send_message(peer, rep);
                    xpc_release(rep);
                } else _ = c.mach_port_mod_refs(c.mach_task_self(), r, c.MACH_PORT_RIGHT_RECEIVE, -1);
            }
        },
        else => {},
    }
    bump(&s.count[slot]);
}
fn serverListener(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) != PEER) return;
    bump(&s.peers);
    setHandler(o, &serverPeer, s, newEnd("server_peer"));
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
    setHandler(l, f, ctx, newEnd(tag));
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
    setHandler(conn, &recordInto, events, newEnd("client"));
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
// The other connections' events (op-805): one case runs per process.
var named_events: Events = undefined;
var conn_events: Events = undefined;
var quiet_events: Events = undefined;
var capture_events: Events = undefined;
var second_events: [3]Events = undefined;

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
    setHandler(child_anon, &childAnonListener, null, null);
    xpc_connection_resume(child_anon);
    const l = xpc_connection_create_mach_service(name, dispatch_queue_create("op796.child.named", null), LISTENER);
    if (l == null) c._exit(81);
    setHandler(l, &childNamedListener, null, null);
    xpc_connection_resume(l);
    var b: u8 = 'r';
    if (c.write(ready, &b, 1) != 1) c._exit(82);
    while (true) _ = c.pause();
}
fn childAnonListener(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    if (eventCode(o) != PEER) return;
    setHandler(o, &childAnonPeer, null, null);
    xpc_connection_resume(o);
}
fn childNamedListener(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    if (eventCode(o) != PEER) return;
    setHandler(o, &childNamedPeer, null, null);
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
    named_events.init();
    const named = xpc_connection_create_mach_service(name, dispatch_queue_create("op796.reply.named", null), 0);
    need(named != null, "named client");
    const named_end = newEnd("named_client");
    setHandler(named, &recordInto, &named_events, named_end);
    xpc_connection_resume(named);
    const ask = &calls[0];
    ask.init();
    ask.keep = true;
    call(named, dict(1, OP_GIVE), ask, &callDone);
    const asked = waitMs(&ask.sem, LIMIT_MS);
    fact(case, "endpoint_reply_arrived", 1, if (asked) ask.code else NONE);
    fact(case, "endpoint_in_reply", 1, ask.found);
    // Its service port dies with the server: let the named client's rights go
    // first, and its final INVALID come before the case goes on.
    xpc_connection_cancel(named);
    xpc_release(named);
    fact(case, "named_client_invalid", 1, @intFromBool(awaitEnd(named_end, 3000)));
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
    const events = &conn_events;
    events.init();
    setHandler(conn, &recordInto, events, newEnd("endpoint_client"));
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
    finalEvents(case);
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
    finalEvents(case);
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
// A request the case sends itself, as libxpc builds one with an endpoint:
// header to dest with a send right made from reply; two descriptors, a
// send-once right to reply and a copy of the send right carried, ending at
// 52; 4 bytes of padding; size at 56, ID at 64 and the packed list at 72.
fn sendRequest(dest: u32, reply_port: u32, carried: u32, payload: []const u8, id: u64) c_int {
    const total = std.mem.alignForward(usize, 72 + payload.len, 8);
    const buf: [*]align(8) u8 = @ptrCast(@alignCast(c.calloc(1, total) orelse c.atf_tc_fail("setup: request buffer")));
    defer c.free(buf);
    const h: *c.mach_msg_header_t = @ptrCast(buf);
    h.msgh_bits = COMPLEX | c.MACH_MSGH_BITS(c.MACH_MSG_TYPE_COPY_SEND, c.MACH_MSG_TYPE_MAKE_SEND);
    h.msgh_size = @intCast(total);
    h.msgh_remote_port = dest;
    h.msgh_local_port = reply_port;
    h.msgh_id = 0x10000000; // not libxpc's XPC_PIPE_MESSAGE_ID (0x58504300); the decoder reads no ID
    std.mem.writeInt(u32, buf[24..28], 2, .little);
    const d: [*]align(4) PortDescriptor = @ptrCast(@alignCast(buf + 28));
    d[0] = .{ .name = reply_port, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_MAKE_SEND_ONCE, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
    d[1] = .{ .name = carried, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
    std.mem.writeInt(u64, buf[56..64], payload.len, .little);
    std.mem.writeInt(u64, buf[64..72], id, .little);
    @memcpy(buf[72..][0..payload.len], payload);
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
    // Never resumed: a handler sees its INVALID and does not activate it.
    capture_events.init();
    setHandler(cap, &recordInto, &capture_events, newEnd("capture_listener"));
    quiet_events.init();
    const cc = clientOf(cap, &quiet_events);
    // Ordinary.
    send(cc, nestedMessage(22, 0, et));
    fact(case, "ordinary_received", 0, @bitCast(@as(i64, receiveWire(cport, 2000))));
    const o = view();
    printView(case, "ordinary", o);
    fact(case, "ordinary_complex", 1, o.complex);
    fact(case, "ordinary_descriptors", 1, o.count);
    fact(case, "ordinary_d0_disposition", PORT_SEND, o.disp[0]);
    fact(case, "ordinary_d0_names_target", tport, o.name[0]);
    fact(case, "ordinary_list_at_56", 0x6c, if (o.list == 56) o.magic else 0);
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
    fact(case, "request_list_at_72", 0x6c, if (r.list == 72) r.magic else 0);
    fact(case, "request_endpoint_index", 0, @bitCast(r.index));
    const n: usize = if (r.size <= captured.len and r.list == 72) @intCast(r.size) else 0;
    @memcpy(captured[0..n], wire[72..][0..n]);
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
    fact(case, "reply_list_at_56", 0x6c, if (p.list == 56) p.magic else 0);
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
    const events = &conn_events;
    events.init();
    const conn_end = newEnd("endpoint_client");
    setHandler(k.conn, &recordInto, events, conn_end);
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
    _ = awaitEnd(conn_end, 3000);
    fact(case, "send_refs_after_cancel", start, settleRefs(tport, SEND, start, 2000));
    retire(client);
    retire(s);
    retire(t);
    finalEvents(case);
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
    const ev1 = &second_events[0];
    const ev2 = &second_events[1];
    ev1.init();
    ev2.init();
    const c1 = xpc_connection_create_from_endpoint(g1.ep);
    const c2 = xpc_connection_create_from_endpoint(g2.ep);
    need(c1 != null and c2 != null, "two clients");
    setHandler(c1, &recordInto, ev1, newEnd("first_client"));
    setHandler(c2, &recordInto, ev2, newEnd("second_client"));
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
    const ev3 = &second_events[2];
    ev3.init();
    const c3 = xpc_connection_create_from_endpoint(g2.ep);
    need(c3 != null, "third client");
    setHandler(c3, &recordInto, ev3, newEnd("third_client"));
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
    finalEvents(case);
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
    finalEvents(case);
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
    const start = refs(tport, SEND);
    send(client, manyMessage(90, OP_COUNT, t, CAP));
    const cap_arrived = awaitCount(&srv.count[90], 1, LIMIT_MS);
    const interrupted_before = cli.tally(INTERRUPTED);
    send(client, manyMessage(91, OP_COUNT, t, CAP + 1));
    const interrupted = cli.waitCode(INTERRUPTED, LIMIT_MS) and cli.tally(INTERRUPTED) > interrupted_before;
    send(client, dict(92, 0));
    const small = awaitCount(&srv.count[92], 1, LIMIT_MS);
    const k = &calls[0];
    k.init();
    call(client, manyMessage(93, OP_COUNT_REPLY, t, CAP), k, &callDone);
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
    retire(client);
    retire(s);
    retire(t);
    finalEvents(case);
    conclude(case);
}

// ---- op-813: the reply's send-once right, and what an endpoint slot holds ----
//
// The reply-send hook is this program's own mach_msg_send. libxpc.so.5 calls
// mach_msg_send for every pipe message (xpc_pipe_send_msg); an executable's
// definition comes first in the dynamic lookup, so libxpc's reference binds
// to this one, on whichever libxpc LD_LIBRARY_PATH selects. Unarmed it counts
// pipe messages and calls the next definition (dlsym RTLD_NEXT, resolved in
// main). Armed (replyEndpointRefused only), after a refused pipe message
// whose header moves a send-once right, it records the header's destination
// name and allocates ports (traps only: no MIG reply port) until one gets
// that name: the sentinel, given one send right. Names are the lowest free
// descriptor from 16 (sys/compat/mach/ipc/ipc_entry.c, kern_fdalloc), so the
// loop reaches the freed name unless another thread took it first. What this
// adds to every case of the program: one call frame and three counters on
// each mach_msg_send call (libxpc's, and any other library's).
const MOVE_SEND_ONCE: u32 = 18; // MACH_MSG_TYPE_MOVE_SEND_ONCE
const XPC_PIPE_MESSAGE_ID: c_int = 0x58504300; // lib/libxpc/xpc/launchd.h
const SendFn = *const fn (*c.mach_msg_header_t) callconv(.c) c.mach_msg_return_t;
var next_send: ?SendFn = null;
const Hook = struct {
    armed: u64 = 0,
    all: u64 = 0, // every message through this mach_msg_send: 0 means not bound
    sends: u64 = 0, // of those, pipe messages (XPC_PIPE_MESSAGE_ID)
    replies: u64 = 0, // of those, on a send-once right
    fired: u64 = 0,
    recorded: u32 = 0, // the refused reply's header destination
    kr: u32 = 0, // its send's result
    sentinel: u32 = 0,
    fillers: u32 = 0, // ports allocated below the recorded name, then freed
    fillers_freed: u32 = 0,
    past: u32 = 0, // the first name past the recorded one, if the loop overshot
};
var hook: Hook = .{};
fn realSend(h: *c.mach_msg_header_t) c.mach_msg_return_t {
    if (next_send) |f| return f(h);
    return c.mach_msg(h, c.MACH_SEND_MSG, h.msgh_size, 0, 0, c.MACH_MSG_TIMEOUT_NONE, 0);
}
pub export fn mach_msg_send(h: *c.mach_msg_header_t) c.mach_msg_return_t {
    const name: u32 = h.msgh_remote_port;
    const remote: u32 = h.msgh_bits & 0x1f; // MACH_MSGH_BITS_REMOTE_MASK
    const pipe = h.msgh_id == XPC_PIPE_MESSAGE_ID;
    const kr = realSend(h);
    bump(&hook.all);
    if (pipe) {
        bump(&hook.sends);
        if (remote == MOVE_SEND_ONCE) bump(&hook.replies);
    }
    if (pipe and remote == MOVE_SEND_ONCE and kr != 0 and @atomicRmw(u64, &hook.armed, .Xchg, 0, .seq_cst) == 1) {
        hook.recorded = name;
        hook.kr = @bitCast(kr);
        sentinelAt(name);
        put(&hook.fired, 1);
    }
    return kr;
}
fn sentinelAt(want: u32) void {
    const task = c.mach_task_self();
    var fillers: [64]u32 = undefined;
    var n: usize = 0;
    while (n < fillers.len) {
        var p: u32 = 0;
        if (c.mach_port_allocate(task, c.MACH_PORT_RIGHT_RECEIVE, &p) != 0) break;
        if (p == want) {
            if (c.mach_port_insert_right(task, p, p, c.MACH_MSG_TYPE_MAKE_SEND) == 0) {
                hook.sentinel = p;
            } else _ = c.mach_port_mod_refs(task, p, c.MACH_PORT_RIGHT_RECEIVE, -1);
            break;
        }
        fillers[n] = p;
        n += 1;
        if (p > want) {
            hook.past = p;
            break;
        }
    }
    hook.fillers = @intCast(n);
    for (fillers[0..n]) |p| {
        if (c.mach_port_mod_refs(task, p, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0) hook.fillers_freed += 1;
    }
}
fn observer(case: [*:0]const u8) void {
    var info: c.Dl_info = undefined;
    const p: ?*const anyopaque = if (next_send) |f| @ptrCast(f) else null;
    const found = p != null and c.dladdr(p, &info) != 0 and info.dli_fname != null;
    const path: [*c]const u8 = if (found) info.dli_fname else "none (mach_msg)";
    _ = c.printf("xpc_b0 case=%s observer=mach_msg_send next=%s\n", case, path);
    _ = c.fflush(null);
}
// The barrier runs on conn's send queue (xpc_connection_send_barrier is a
// dispatch_sync there): when it returns, every send queued before it,
// xpc_send included, has returned.
const BarrierBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*BarrierBlock) callconv(.c) void,
    descriptor: *const Descriptor,
};
fn barrierInvoke(_: *BarrierBlock) callconv(.c) void {}
const barrier_descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(BarrierBlock) };
fn barrier(conn: O) void {
    var literal = BarrierBlock{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = 0, .reserved = 0, .invoke = &barrierInvoke, .descriptor = &barrier_descriptor };
    const b = _Block_copy(&literal);
    xpc_connection_send_barrier(conn, b);
    _Block_release(b);
}

// Names back to the start. Every right these cases test is to a port whose
// receive right this task holds (the listener's, a client's, the case's own
// ports), so a send reference to it shares the receive right's name: a
// leaked or doubly released one shows in that name's references and type.
// Only a send-once right (never shared) or a dead name is a name of its own.
// Names a thread brings and takes away are not the cases': a thread's MIG
// reply port (mig_get_reply_port: a receive right with no send right and no
// context, kept until its thread exits) and a send right with no receive
// right here (a foreign or kernel port, such as a thread's). Those, new or
// gone, are printed with the task's thread count and not counted; that they
// are worker threads' is an inference. libxpc marks its own call reply ports
// with a context (XPC_REPLY_PORT_CONTEXT), so a lingering one counts.
fn context(name: u32) u64 {
    var v: c.mach_vm_address_t = 0;
    return if (c.mach_port_get_context(c.mach_task_self(), name, &v) == 0) v else 0xffffffffffffffff;
}
fn rights(t: u32) u32 {
    return t & 0x1f0000; // MACH_PORT_TYPE_ALL_RIGHTS
}
fn threadName(t: u32) bool {
    return rights(t) == c.MACH_PORT_TYPE_RECEIVE or rights(t) == c.MACH_PORT_TYPE_SEND;
}
fn newThreadName(name: u32, t: u32) bool {
    return rights(t) == c.MACH_PORT_TYPE_SEND or (rights(t) == c.MACH_PORT_TYPE_RECEIVE and refs(name, SEND) == 0 and context(name) == 0);
}
// The task's threads (kinfo_proc records with KERN_PROC_INC_THREAD).
fn threads() u64 {
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID | c.KERN_PROC_INC_THREAD, c.getpid() };
    var size: usize = 0;
    if (c.sysctl(&mib, mib.len, null, &size, null, 0) != 0) return 0;
    size += 4 * @sizeOf(c.kinfo_proc);
    const buf = c.malloc(size) orelse return 0;
    defer c.free(buf);
    if (c.sysctl(&mib, mib.len, buf, &size, null, 0) != 0) return 0;
    return size / @sizeOf(c.kinfo_proc);
}
var start_threads: u64 = 0;
fn namesBack(case: [*:0]const u8, a: *const Names, b: *const Names, others: bool, show: bool) bool {
    var ok = true;
    var churn: u64 = 0;
    for (a.fds[0..a.n], a.types[0..a.n]) |fd, t| {
        var seen: ?u32 = null;
        for (b.fds[0..b.n], b.types[0..b.n]) |x, u| {
            if (x == fd) seen = u;
        }
        if (seen != null and seen.? == t) continue;
        if (threadName(t)) {
            churn += 1;
            if (show) _ = c.printf("xpc_b0 case=%s thread_name_gone=%d start_type=0x%x end_type=0x%x (not counted)\n", case, fd, t, seen orelse 0);
            continue;
        }
        ok = false;
        if (show) _ = c.printf("xpc_b0 case=%s name=%d start_type=0x%x end_type=0x%x\n", case, fd, t, seen orelse 0);
    }
    for (b.fds[0..b.n], b.types[0..b.n]) |fd, t| {
        var same = false;
        for (a.fds[0..a.n], a.types[0..a.n]) |x, u| same = same or (x == fd and u == t);
        if (same) continue;
        if (newThreadName(@intCast(fd), t)) {
            churn += 1;
            if (show) _ = c.printf("xpc_b0 case=%s thread_name_new=%d type=0x%x send_refs=%llu (not counted)\n", case, fd, t, refs(@intCast(fd), SEND));
            continue;
        }
        ok = false;
        if (show) _ = c.printf("xpc_b0 case=%s new_name=%d type=0x%x send_refs=%llu context=0x%llx\n", case, fd, t, refs(@intCast(fd), SEND), context(@intCast(fd)));
    }
    if (show) _ = c.printf("xpc_b0 case=%s names start=%llu end=%llu thread_names_not_counted=%llu threads start=%llu end=%llu\n", case, @as(u64, a.n), @as(u64, b.n), churn, start_threads, threads());
    if (others) {
        const same_count = a.no == b.no;
        for (a.others[0..a.no], a.kinds[0..a.no], 0..) |fd, k, i| {
            if (!same_count or b.others[i] != fd or b.kinds[i] != k) ok = false;
        }
        if (!same_count or !ok) {
            if (show) {
                for (b.others[0..b.no], b.kinds[0..b.no]) |fd, k| _ = c.printf("xpc_b0 case=%s end_descriptor=%d kind=%d\n", case, fd, k);
                _ = c.printf("xpc_b0 case=%s other_descriptors start=%llu end=%llu\n", case, @as(u64, a.no), @as(u64, b.no));
            }
            if (!same_count) ok = false;
        }
    }
    _ = c.fflush(null);
    return ok;
}
var start_names: Names = .{};
var end_names: Names = .{};
var prev_names: Names = .{};
fn sameNames(a: *const Names, b: *const Names) bool {
    if (a.n != b.n) return false;
    for (a.fds[0..a.n], a.types[0..a.n], b.fds[0..b.n], b.types[0..b.n]) |x, t, y, u| {
        if (x != y or t != u) return false;
    }
    return true;
}
fn unreadable(s: *const Names) u64 {
    var k: u64 = 0;
    for (s.types[0..s.n]) |t| k += @intFromBool(t == 0);
    return k;
}
// The start snapshot once no teardown is still changing it: no name that
// mach_port_type cannot read (one being destroyed between the file table and
// the read, as a finished call's reply port is: libxpc releases it after the
// call completes), and the same twice in a row, 20 ms apart; or 2 s. Then
// the thread count.
fn settledStart(case: [*:0]const u8) void {
    const start = nowMs();
    names(&prev_names);
    while (true) {
        _ = c.usleep(20_000);
        names(&start_names);
        if ((unreadable(&start_names) == 0 and sameNames(&prev_names, &start_names)) or nowMs() - start >= 2000) break;
        prev_names = start_names;
    }
    _ = c.printf("xpc_b0 case=%s start_names=%llu unreadable=%llu settle_ms=%llu\n", case, @as(u64, start_names.n), unreadable(&start_names), nowMs() - start);
    start_threads = threads();
}
fn settleNames(case: [*:0]const u8, others: bool, ms: u64) bool {
    const start = nowMs();
    while (true) {
        names(&end_names);
        const last = nowMs() - start >= ms;
        if (namesBack(case, &start_names, &end_names, others, last)) {
            _ = namesBack(case, &start_names, &end_names, others, true);
            return true;
        }
        if (last) return false;
        _ = c.usleep(20_000);
    }
}
fn pipeDescriptors(s: *const Names) u64 {
    var k: u64 = 0;
    for (s.kinds[0..s.no]) |x| k += @intFromBool(x == c.KF_TYPE_PIPE);
    return k;
}

// A list the case packs itself, as libxpc packs a dictionary: "value", then
// each of eps as an endpoint entry "e<i>" holding that index.
var packed_list: [8192]u8 = undefined;
fn rawList(value: u64, eps: []const c_int) []const u8 {
    const nv = nvlist_create_dictionary(0) orelse c.atf_tc_fail("setup: payload list");
    defer nvlist_destroy(nv);
    nvlist_add_uint64(nv, "value", value);
    var key: [16]u8 = undefined;
    for (eps, 0..) |e, i| {
        const k = std.fmt.bufPrintZ(&key, "e{d}", .{i}) catch unreachable;
        nvlist_add_endpoint(nv, k.ptr, e);
    }
    need(nvlist_error(nv) == 0, "payload list entries");
    var size: usize = 0;
    const p = nvlist_pack(nv, &size) orelse c.atf_tc_fail("setup: payload pack");
    defer c.free(p);
    need(size <= packed_list.len, "payload fits");
    @memcpy(packed_list[0..size], @as([*]const u8, @ptrCast(p))[0..size]);
    return packed_list[0..size];
}
// A message the case sends itself to a listener's port from a reply port of
// its own (MAKE_SEND in the header: the listener's peer for that port gets
// it), laid out as xpc_pipe_send_msg lays one out (XPC_WIRE_DATA): with
// once, a send-once right made from the reply port first, as a request
// carries; then each of carried as an endpoint's descriptor (COPY_SEND, which
// takes a descriptor's file as well as a send right); then size, ID and the
// list. No descriptor: a simple message, the list at 40.
fn sendRaw(dest: u32, reply_port: u32, once: bool, carried: []const u32, bytes: []const u8, id: u64) c_int {
    return sendRawSlot(dest, reply_port, if (once) reply_port else null, carried, bytes, id);
}
// The same, with the first descriptor's name given: once_name, made a
// send-once right (MAKE_SEND_ONCE) as a request's reply right is, or none.
fn sendRawSlot(dest: u32, reply_port: u32, once_name: ?u32, carried: []const u32, bytes: []const u8, id: u64) c_int {
    const once = once_name != null;
    const n = carried.len + @intFromBool(once);
    const list: usize = if (n == 0) 40 else std.mem.alignForward(usize, 28 + 12 * n, 8) + 16;
    const total = std.mem.alignForward(usize, list + bytes.len, 8);
    const buf: [*]align(8) u8 = @ptrCast(@alignCast(c.calloc(1, total) orelse c.atf_tc_fail("setup: raw buffer")));
    defer c.free(buf);
    const h: *c.mach_msg_header_t = @ptrCast(buf);
    h.msgh_bits = (if (n != 0) COMPLEX else 0) | c.MACH_MSGH_BITS(c.MACH_MSG_TYPE_COPY_SEND, c.MACH_MSG_TYPE_MAKE_SEND);
    h.msgh_size = @intCast(total);
    h.msgh_remote_port = dest;
    h.msgh_local_port = reply_port;
    h.msgh_id = XPC_PIPE_MESSAGE_ID;
    if (n != 0) {
        std.mem.writeInt(u32, buf[24..28], @intCast(n), .little);
        const d: [*]align(4) PortDescriptor = @ptrCast(@alignCast(buf + 28));
        var i: usize = 0;
        if (once_name) |name| {
            d[0] = .{ .name = name, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_MAKE_SEND_ONCE, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
            i = 1;
        }
        for (carried) |name| {
            d[i] = .{ .name = name, .pad1 = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
            i += 1;
        }
    }
    std.mem.writeInt(u64, buf[list - 16 ..][0..8], bytes.len, .little);
    std.mem.writeInt(u64, buf[list - 8 ..][0..8], id, .little);
    @memcpy(buf[list..][0..bytes.len], bytes);
    return c.mach_msg(h, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, h.msgh_size, 0, 0, 1000, 0);
}

// ---- replyEndpointRefused ----------------------------------------------------
//
// The server answers a request with a reply that borrows a receive right
// with no send right (xpc_dictionary_set_mach_recv). The kernel takes the
// reply's send-once right at header copyin, refuses the endpoint's COPY_SEND
// at body copyin (MACH_SEND_INVALID_RIGHT) and destroys the send-once right
// then (ipc_kmsg_clean_partial), so the client's call completes with an
// error, and the right's name is free again. The hook puts the sentinel on
// that name before the sender returns: a sender that releases the name again
// takes the sentinel's only send right.
fn replyEndpointRefused(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "replyEndpointRefused";
    library(case);
    observer(case);
    var sport: u32 = 0;
    const s = listen("op813.refused.server", &serverListener, &srv, &sport);
    cli.init();
    const client = clientOf(s, &cli);
    // Warm-up: one request and its reply through the unarmed hook.
    const w = &calls[0];
    w.init();
    call(client, dict(100, OP_ECHO), w, &callDone);
    const warm = waitMs(&w.sem, LIMIT_MS) and w.code == 100;
    const all = load(&hook.all);
    const sends = load(&hook.sends);
    const replies = load(&hook.replies);
    settledStart(case);
    put(&hook.armed, 1);
    const k = &calls[1];
    k.init();
    call(client, dict(101, OP_RECV_REPLY), k, &callDone);
    const done = waitMs(&k.sem, LIMIT_MS);
    const fired = awaitCount(&hook.fired, 1, LIMIT_MS);
    put(&hook.armed, 0);
    const peer = srv.peer;
    if (peer != null) barrier(peer);
    const sentinel = hook.sentinel;
    const sentinel_refs = if (sentinel != 0) refs(sentinel, SEND) else 0;
    _ = c.usleep(100_000);
    const exercised = fired and sentinel != 0 and sentinel == hook.recorded;
    _ = c.printf("xpc_b0 case=%s observed warmup=%u all_before=%llu sends_before=%llu replies_before=%llu fired=%u recorded=%u kr=0x%x sentinel=%u fillers=%u past=%u sentinel_send_refs=%llu completions=%llu code=%llu peer=%u recv=%u\n", case, @as(c_uint, @intFromBool(warm)), all, sends, replies, @as(c_uint, @intFromBool(fired)), hook.recorded, hook.kr, sentinel, hook.fillers, hook.past, sentinel_refs, load(&k.n), k.code, @as(c_uint, @intFromBool(peer != null)), srv.recv);
    if (!exercised) _ = c.printf("xpc_b0 case=%s exercised=0: the sentinel did not take the refused reply's name, so a second release of it is not tested\n", case);
    _ = c.fflush(null);
    fact(case, "interposer_bound", 1, @intFromBool(all >= 2));
    fact(case, "interposer_saw_libxpc_sends", 1, @intFromBool(sends >= 2 and replies >= 1));
    fact(case, "warmup_reply", 100, if (warm) w.code else NONE);
    fact(case, "reply_send_refused", 1, @intFromBool(fired));
    fact(case, "sentinel_takes_reply_name", 1, @intFromBool(exercised));
    fact(case, "sentinel_send_refs_after_send", 1, sentinel_refs);
    fact(case, "call_completions", 1, load(&k.n));
    fact(case, "call_error", 1, @intFromBool(done and (k.code == INVALID or k.code == INTERRUPTED)));
    // The case's own ports: the sentinel and the borrowed receive right.
    var freed = hook.fillers_freed == hook.fillers;
    if (sentinel != 0) {
        if (refs(sentinel, SEND) > 0) freed = freed and c.mach_port_deallocate(c.mach_task_self(), sentinel) == 0;
        freed = freed and c.mach_port_mod_refs(c.mach_task_self(), sentinel, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0;
    }
    if (srv.recv != 0) freed = freed and c.mach_port_mod_refs(c.mach_task_self(), srv.recv, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0;
    fact(case, "own_ports_freed", 1, @intFromBool(freed));
    fact(case, "server_names_back", 1, @intFromBool(settleNames(case, false, 2000)));
    if (peer != null) xpc_release(peer);
    retire(client);
    retire(s);
    finalEvents(case);
    conclude(case);
}

// ---- Raw messages to a listener ---------------------------------------------
//
// Each raw case sends from a reply port R of its own to a server listener;
// its first message, a valid one, makes the listener's peer for R. The
// carried port P is the case's, with one send right: an endpoint descriptor
// of P adds a send reference to P's own name in this task, and releasing it
// takes it off again.
const Raw = struct { s: O = null, sport: u32 = 0, r: u32 = 0, p: u32 = 0, start_refs: u64 = 0, r_refs: u64 = 0 };
var raw: Raw = .{};
fn rawSetup(case: [*:0]const u8, tag: [*:0]const u8, warm: u64) void {
    raw.s = listen(tag, &serverListener, &srv, &raw.sport);
    const task = c.mach_task_self();
    need(c.mach_port_allocate(task, c.MACH_PORT_RIGHT_RECEIVE, &raw.r) == 0, "reply port");
    need(c.mach_port_allocate(task, c.MACH_PORT_RIGHT_RECEIVE, &raw.p) == 0, "carried port");
    need(c.mach_port_insert_right(task, raw.p, raw.p, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "carried send right");
    fact(case, "warmup_sent", 0, @bitCast(@as(i64, sendRaw(raw.sport, raw.r, false, &.{}, rawList(warm, &.{}), warm))));
    fact(case, "warmup_arrived", 1, @intFromBool(awaitCount(&srv.count[@intCast(warm)], 1, LIMIT_MS)));
    raw.start_refs = refs(raw.p, SEND);
    // R's send references once the warm-up's header right is gone: the
    // peer's own (xpc_port_add_ref), 1 unless it holds more.
    raw.r_refs = settleRefs(raw.r, SEND, 1, 1000);
    settledStart(case);
}
const Refusal = struct { sent: i64 = 0, sent_next: i64 = 0, arrived: u64 = 0, next: bool = false, notified: u64 = 0 };
// One message to be refused (already packed in bytes), then a valid one
// from the same reply port: its value arrives when the peer read on.
fn refusedThenNext(once: bool, carried: []const u32, bytes: []const u8, refused: u64, next: u64) Refusal {
    var v = Refusal{};
    v.sent = sendRaw(raw.sport, raw.r, once, carried, bytes, refused);
    v.sent_next = sendRaw(raw.sport, raw.r, false, &.{}, rawList(next, &.{}), next);
    v.next = awaitCount(&srv.count[@intCast(next)], 1, LIMIT_MS);
    _ = c.usleep(50_000);
    v.arrived = load(&srv.count[@intCast(refused)]);
    // A refused request's send-once right goes back to R as a notification.
    if (once) {
        while (receiveWire(raw.r, 500) == 0) {
            const h: *c.mach_msg_header_t = @ptrCast(&wire);
            if (h.msgh_id == c.MACH_NOTIFY_SEND_ONCE) v.notified += 1;
            c.mach_msg_destroy(h);
        }
    }
    return v;
}
// The peer for R ends only when R dies: its send source on R
// (xpc_connection_send_source, DISPATCH_MACH_SEND_DEAD) cancels it
// (xpc_connection_remote_dead). Cancelling the listener does not.
fn rawFinish(case: [*:0]const u8, others: bool) void {
    fact(case, "carried_send_refs_back", raw.start_refs, settleRefs(raw.p, SEND, raw.start_refs, 2000));
    // Each raw message's header right is a send right to R.
    fact(case, "reply_port_send_refs_back", raw.r_refs, settleRefs(raw.r, SEND, raw.r_refs, 2000));
    fact(case, "names_back", 1, @intFromBool(settleNames(case, others, 2000)));
    retire(raw.s);
    const task = c.mach_task_self();
    var freed = c.mach_port_mod_refs(task, raw.r, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0;
    finalEvents(case);
    freed = freed and c.mach_port_deallocate(task, raw.p) == 0;
    freed = freed and c.mach_port_mod_refs(task, raw.p, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0;
    fact(case, "own_ports_freed", 1, @intFromBool(freed));
    conclude(case);
}
fn printRefusal(case: [*:0]const u8, form: [*:0]const u8, v: Refusal) void {
    _ = c.printf("xpc_b0 case=%s observed form=%s sent=%lld sent_next=%lld refused_arrived=%llu next_arrived=%u send_once_notified=%llu carried_send_refs=%llu start=%llu\n", case, form, v.sent, v.sent_next, v.arrived, @as(c_uint, @intFromBool(v.next)), v.notified, refs(raw.p, SEND), raw.start_refs);
    _ = c.fflush(null);
}

// ---- fileInEndpointSlot ------------------------------------------------------
//
// An endpoint's slot that holds a pipe's descriptor. rmxOS's kernel carries
// a passable file in a port descriptor (ipc_object_copyin,
// ipc_entry_file_to_port) and the receiver gets it as a new descriptor with
// no Mach entry. The receiver refuses the message and closes it; its
// descriptor table is back where it started, and the next message arrives.
fn fileInEndpointSlot(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "fileInEndpointSlot";
    library(case);
    rawSetup(case, "op813.file.server", 110);
    const start_pipes = pipeDescriptors(&start_names);
    var fds: [2]c_int = undefined;
    need(c.pipe(&fds) == 0, "pipe");
    const carried = [_]u32{@intCast(fds[0])};
    const v = refusedThenNext(false, &carried, rawList(111, &.{0}), 111, 112);
    printRefusal(case, "file", v);
    _ = c.close(fds[0]);
    _ = c.close(fds[1]);
    fact(case, "file_message_sent", 0, @bitCast(v.sent));
    fact(case, "file_message_arrived", 0, v.arrived);
    fact(case, "next_message_arrived", 1, @intFromBool(v.next));
    var now: Names = undefined;
    names(&now);
    _ = c.printf("xpc_b0 case=%s observed pipe_descriptors start=%llu after_close=%llu\n", case, start_pipes, pipeDescriptors(&now));
    fact(case, "pipe_descriptors_after_close", start_pipes, pipeDescriptors(&now));
    rawFinish(case, true);
}

// ---- fileInSendOnceSlot (op-823) ---------------------------------------------
//
// A request's send-once slot that holds a pipe's descriptor: the first
// descriptor names the pipe with MAKE_SEND_ONCE. The kernel carries the file
// as it does in an endpoint's slot (ipc_object_copyin takes the send-once
// copyin types too), and the receiver gets a new descriptor that keeps the
// PORT_SEND_ONCE disposition. The receiver refuses the request and closes the
// descriptor once. The next request, with R's own send-once right, arrives,
// and the server's pipe count is back where it started. On a decoder that
// takes the file as the request's reply right, the request arrives and its
// releases (mach_port_deallocate: KERN_INVALID_NAME) leave the file open.
fn fileInSendOnceSlot(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "fileInSendOnceSlot";
    library(case);
    rawSetup(case, "op823.sonce.server", 124);
    const start_pipes = pipeDescriptors(&start_names);
    var fds: [2]c_int = undefined;
    need(c.pipe(&fds) == 0, "pipe");
    var v = Refusal{};
    v.sent = sendRawSlot(raw.sport, raw.r, @intCast(fds[0]), &.{}, rawList(125, &.{}), 125);
    v.sent_next = sendRaw(raw.sport, raw.r, true, &.{}, rawList(126, &.{}), 126);
    v.next = awaitCount(&srv.count[126], 1, LIMIT_MS);
    _ = c.usleep(50_000);
    v.arrived = load(&srv.count[125]);
    // The next request goes unanswered: its send-once right comes back to R
    // as a notification when the server releases it. Drained before the
    // names are compared.
    while (receiveWire(raw.r, 500) == 0) {
        const h: *c.mach_msg_header_t = @ptrCast(&wire);
        if (h.msgh_id == c.MACH_NOTIFY_SEND_ONCE) v.notified += 1;
        c.mach_msg_destroy(h);
    }
    printRefusal(case, "send_once_file", v);
    _ = c.close(fds[0]);
    _ = c.close(fds[1]);
    fact(case, "file_request_sent", 0, @bitCast(v.sent));
    fact(case, "file_request_arrived", 0, v.arrived);
    fact(case, "next_request_sent", 0, @bitCast(v.sent_next));
    fact(case, "next_request_arrived", 1, @intFromBool(v.next));
    var now: Names = undefined;
    names(&now);
    _ = c.printf("xpc_b0 case=%s observed pipe_descriptors start=%llu after_close=%llu\n", case, start_pipes, pipeDescriptors(&now));
    fact(case, "pipe_descriptors_after_close", start_pipes, pipeDescriptors(&now));
    rawFinish(case, true);
}

// ---- The decoder's other refusals (op-796's untested ones) -------------------

// One endpoint descriptor; the list names index 1.
fn endpointIndexOutOfRange(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointIndexOutOfRange";
    library(case);
    rawSetup(case, "op813.range.server", 113);
    const carried = [_]u32{raw.p};
    const v = refusedThenNext(false, &carried, rawList(114, &.{1}), 114, 115);
    printRefusal(case, "range", v);
    fact(case, "refused_sent", 0, @bitCast(v.sent));
    fact(case, "refused_message_arrived", 0, v.arrived);
    fact(case, "next_message_arrived", 1, @intFromBool(v.next));
    rawFinish(case, false);
}
// Two endpoint descriptors; the list names index 0 twice (as many entries as
// descriptors, one index repeated).
fn endpointIndexTwice(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointIndexTwice";
    library(case);
    rawSetup(case, "op813.twice.server", 116);
    const carried = [_]u32{ raw.p, raw.p };
    const v = refusedThenNext(false, &carried, rawList(117, &.{ 0, 0 }), 117, 118);
    printRefusal(case, "twice", v);
    fact(case, "refused_sent", 0, @bitCast(v.sent));
    fact(case, "refused_message_arrived", 0, v.arrived);
    fact(case, "next_message_arrived", 1, @intFromBool(v.next));
    rawFinish(case, false);
}
// 65 endpoint descriptors, the list naming each once: in a message (65
// descriptors), and after a request's send-once right (66).
fn endpointsOverCapReceived(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "endpointsOverCapReceived";
    library(case);
    rawSetup(case, "op813.over.server", 119);
    var carried: [CAP + 1]u32 = undefined;
    var eps: [CAP + 1]c_int = undefined;
    for (&carried, &eps, 0..) |*n, *e, i| {
        n.* = raw.p;
        e.* = @intCast(i);
    }
    const a = refusedThenNext(false, &carried, rawList(120, &eps), 120, 121);
    printRefusal(case, "message", a);
    fact(case, "message_sent", 0, @bitCast(a.sent));
    fact(case, "message_arrived", 0, a.arrived);
    fact(case, "next_after_message_arrived", 1, @intFromBool(a.next));
    fact(case, "send_refs_after_message", raw.start_refs, settleRefs(raw.p, SEND, raw.start_refs, 2000));
    const b = refusedThenNext(true, &carried, rawList(122, &eps), 122, 123);
    printRefusal(case, "request", b);
    fact(case, "request_sent", 0, @bitCast(b.sent));
    fact(case, "request_arrived", 0, b.arrived);
    fact(case, "next_after_request_arrived", 1, @intFromBool(b.next));
    fact(case, "request_send_once_released", 1, b.notified);
    rawFinish(case, false);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
// The first case may take 30 s (a forked child), each other 15 s.
fn longHead(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "30");
}
fn shortHead(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "15");
}
var cases: [12]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const ids = [_][*:0]const u8{ "endpointInReply", "endpointInMessage", "endpointReleasedBeforeUse", "secondEndpoint", "endpointNames", "endpointCapRefused", "replyEndpointRefused", "fileInEndpointSlot", "endpointIndexOutOfRange", "endpointIndexTwice", "endpointsOverCapReceived", "fileInSendOnceSlot" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &endpointInReply, &endpointInMessage, &endpointReleasedBeforeUse, &secondEndpoint, &endpointNames, &endpointCapRefused, &replyEndpointRefused, &fileInEndpointSlot, &endpointIndexOutOfRange, &endpointIndexTwice, &endpointsOverCapReceived, &fileInSendOnceSlot };
    for (&cases, ids, bodies, 0..) |*tc, id, body, i| {
        var err = c.atf_tc_init(tc, id, if (i == 0) &longHead else &shortHead, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    // The definition the hook calls: the one libxpc would bind without it.
    const rtld_next: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize)); // RTLD_NEXT
    if (c.dlsym(rtld_next, "mach_msg_send")) |f| next_send = @ptrCast(@alignCast(f));
    return atf_tp_main(argc, argv, &add);
}
