// SPDX-License-Identifier: BSD-2-Clause
// op-780: messages up to 1 MiB on a connection. libxpc's cap,
// XPC_MAX_MESSAGE (lib/libxpc/xpc_misc.c), is the largest msgh_size it sends
// or reads: the sender refuses a message over it with EMSGSIZE and logs it;
// the receiver reads a message the 8 KiB stack buffer does not hold into a
// buffer of its own size (MACH_RCV_LARGE), and one over the cap is logged and
// taken off the queue unread, as one message handled.
//
// Wire forms (xpc_misc.c): an ordinary message is the header (24 bytes),
// size (8) and ID (8), then the packed nvlist, so its packed bytes may be
// up to the cap less 40; a request that expects a reply has a body with one
// port descriptor first (16 more bytes), so up to the cap less 56. The case
// learns a dictionary's packed size from the wire: a listener that is never
// resumed keeps what a client sends it queued, and the message's size field
// is the packed size.
//
// The program links libxpc.so.5 by its soname with no run path, so
// LD_LIBRARY_PATH selects the library under test; each case prints the path
// of the libxpc it loaded. Port names on rmxOS are file descriptors
// (kern.proc.filedesc, KF_TYPE_PORT 17).
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
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const O = ?*anyopaque;
extern fn xpc_connection_create(?[*:0]const u8, O) O;
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
extern fn xpc_dictionary_set_data(O, [*:0]const u8, ?*const anyopaque, usize) void;
extern fn xpc_dictionary_get_data(O, [*:0]const u8, *usize) ?*const anyopaque;
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

const CAP: u64 = 1 << 20; // XPC_MAX_MESSAGE
const ORDINARY: u64 = 40; // header, size, ID
const REQUEST: u64 = 56; // header, body, port descriptor, size, ID
const SEQ_KEY = "XPC sequence number"; // XPC_SEQID, which every reply carries
const PIPE_ID: c_int = 0x58504300; // XPC_PIPE_MESSAGE_ID
// The smallest message over the cap the kernel takes: msgh_size is a
// multiple of 4 (ipc_kmsg.c, MACH_SEND_MSG_TOO_SMALL).
const OVER: u64 = CAP + 4;

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

// ---- Data -----------------------------------------------------------------------

// Byte i of a value's data: compared byte for byte where it arrives.
fn patternByte(i: usize, seed: u64) u8 {
    return @truncate(i *% 131 +% seed *% 7 +% 1);
}
fn fill(p: [*]u8, n: usize, seed: u64) void {
    for (0..n) |i| p[i] = patternByte(i, seed);
}
fn matches(p: ?*const anyopaque, n: usize, seed: u64) bool {
    const b: [*]const u8 = @ptrCast(p orelse return n == 0);
    for (0..n) |i| if (b[i] != patternByte(i, seed)) return false;
    return true;
}
fn setBlob(d: O, n: usize, seed: u64) void {
    const p: [*]u8 = @ptrCast(c.malloc(@max(n, 1)) orelse c.atf_tc_fail("setup: data buffer"));
    fill(p, n, seed);
    xpc_dictionary_set_data(d, "blob", p, n);
    c.free(p);
}
// A dictionary: "value", then "op" and "n" when not 0, then data of blob
// bytes; with seq, the key every reply carries, so its packed size is a
// reply's.
fn dict(value: u64, op: u64, n: u64, blob: usize, seq: bool) O {
    const d = xpc_dictionary_create(null, null, 0);
    need(d != null, "dictionary");
    if (seq) xpc_dictionary_set_uint64(d, SEQ_KEY, 1);
    xpc_dictionary_set_uint64(d, "value", value);
    if (op != 0) xpc_dictionary_set_uint64(d, "op", op);
    if (n != 0) xpc_dictionary_set_uint64(d, "n", n);
    setBlob(d, blob, value);
    return d;
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

// ---- An in-process server --------------------------------------------------------

// What the server's peer saw for each value: count, data length, whether
// the data matched. op 2: reply with "n" bytes of data; op 3: reply with
// whether the request's data matched.
const SLOTS = 64;
const Slot = struct { count: u64 = 0, len: u64 = 0, match: u64 = 0 };
const Server = struct {
    slots: [SLOTS]Slot = @splat(.{}),
    peers: u64 = 0,
    other: u64 = 0,
};
fn peerEvent(ctx: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    if (code >= SLOTS) {
        bump(&s.other);
        return;
    }
    var len: usize = 0;
    const p = xpc_dictionary_get_data(o, "blob", &len);
    const slot = &s.slots[@intCast(code)];
    @atomicStore(u64, &slot.len, len, .seq_cst);
    @atomicStore(u64, &slot.match, @intFromBool(matches(p, len, code)), .seq_cst);
    const op = xpc_dictionary_get_uint64(o, "op");
    if (op == 2 or op == 3) {
        const r = xpc_dictionary_create_reply(o);
        if (r != null) {
            xpc_dictionary_set_uint64(r, "value", code);
            if (op == 2) setBlob(r, @intCast(xpc_dictionary_get_uint64(o, "n")), code);
            if (op == 3) xpc_dictionary_set_uint64(r, "ok", @intFromBool(matches(p, len, code)));
            xpc_connection_send_message(peer, r);
            xpc_release(r);
        }
    }
    bump(&slot.count);
}
fn listenerEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) != PEER) return;
    bump(&s.peers);
    setHandler(o, &peerEvent, s);
    xpc_connection_resume(o);
}
// The client's own events.
const Client = struct { interrupted: u64 = 0, invalid: u64 = 0, other: u64 = 0 };
fn clientEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const k: *Client = @ptrCast(@alignCast(ctx.?));
    switch (eventCode(o)) {
        INTERRUPTED => bump(&k.interrupted),
        INVALID => bump(&k.invalid),
        else => bump(&k.other),
    }
}
const Pair = struct { listener: O, client: O };
fn pair(s: *Server, k: *Client, tag: [*:0]const u8) Pair {
    const l = xpc_connection_create(null, dispatch_queue_create(tag, null));
    need(l != null, "listener");
    setHandler(l, &listenerEvent, s);
    xpc_connection_resume(l);
    const e = xpc_endpoint_create(l);
    need(e != null, "listener's endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "connection from the endpoint");
    xpc_release(e);
    setHandler(conn, &clientEvent, k);
    xpc_connection_resume(conn);
    return .{ .listener = l, .client = conn };
}
fn retire(p: Pair) void {
    xpc_connection_cancel(p.client);
    xpc_release(p.client);
    xpc_connection_cancel(p.listener);
    xpc_release(p.listener);
}

// One call's completion: the first event, its data, and how many came.
const Call = struct {
    sem: c.sem_t = undefined,
    n: u64 = 0,
    code: u64 = NONE,
    len: u64 = 0,
    match: u64 = 0,
    ok: u64 = 0,
    start: u64 = 0,
    ms: u64 = 0,
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
            var len: usize = 0;
            const p = xpc_dictionary_get_data(o, "blob", &len);
            k.len = len;
            k.match = @intFromBool(matches(p, len, k.code));
            k.ok = xpc_dictionary_get_uint64(o, "ok");
        }
        k.ms = nowMs() - k.start;
    }
    _ = c.sem_post(&k.sem);
}
fn call(conn: O, m: O, k: *Call) void {
    k.start = nowMs();
    const b = block(&callDone, k, null);
    xpc_connection_send_message_with_reply(conn, m, null, b);
    _Block_release(b);
}

// ---- The task's port names -----------------------------------------------------

const Names = struct {
    fds: [2048]c_int = undefined,
    types: [2048]u32 = undefined,
    n: usize = 0,
    reply_ports: u64 = 0, // receive rights that carry libxpc's reply-port mark
};
// libxpc's mark on each call's reply port (XPC_REPLY_PORT_CONTEXT,
// lib/libxpc/xpc_internal.h): "xpc.rply".
const REPLY_PORT_CONTEXT: u64 = 0x7870632e72706c79;
fn portType(name: u32) c.mach_port_type_t {
    var t: c.mach_port_type_t = 0;
    return if (c.mach_port_type(c.mach_task_self(), name, &t) == 0) t else 0;
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
            need(s.n < s.fds.len, "port names fit the snapshot");
            s.fds[s.n] = f.kf_fd;
            s.types[s.n] = t;
            if ((t & c.MACH_PORT_TYPE_RECEIVE) != 0) {
                var v: c.mach_vm_address_t = 0;
                if (c.mach_port_get_context(c.mach_task_self(), @intCast(f.kf_fd), &v) == 0 and v == REPLY_PORT_CONTEXT) s.reply_ports += 1;
            }
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
// An anonymous listener, never resumed unless the case does so, and its port.
fn listenerWithPort(tag: [*:0]const u8, port: *u32) O {
    names(&before_names);
    const l = xpc_connection_create(null, dispatch_queue_create(tag, null));
    names(&after_names);
    need(l != null, "listener");
    port.* = onlyNew(&before_names, &after_names) orelse c.atf_tc_fail("setup: one new port for the listener");
    return l;
}
fn replyPorts() u64 {
    var s: Names = undefined;
    names(&s);
    return s.reply_ports;
}
fn settleReplyPorts(target: u64, ms: u64) u64 {
    const start = nowMs();
    var n = replyPorts();
    while (n > target and nowMs() - start < ms) {
        _ = c.usleep(10_000);
        n = replyPorts();
    }
    return n;
}
fn queued(port: u32) u64 {
    var st: c.mach_port_status_t = std.mem.zeroes(c.mach_port_status_t);
    var count: c.mach_msg_type_number_t = @sizeOf(c.mach_port_status_t) / @sizeOf(c.natural_t);
    if (c.mach_port_get_attributes(c.mach_task_self(), port, c.MACH_PORT_RECEIVE_STATUS, @ptrCast(&st), &count) != 0) return 1 << 40;
    return st.mps_msgcount;
}

// ---- Packed sizes from the wire ----------------------------------------------------

// A listener never resumed, and a client from its endpoint: what the client
// sends stays queued on the listener's port, where the case reads it.
var wire: [CAP + 8192]u8 align(8) = undefined;
const Capture = struct { listener: O, client: O, port: u32 };
fn captureOpen() Capture {
    var port: u32 = 0;
    const l = listenerWithPort("op780.capture", &port);
    const e = xpc_endpoint_create(l);
    need(e != null, "capture endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "capture connection");
    xpc_release(e);
    setHandler(conn, &ignore, null);
    xpc_connection_resume(conn);
    return .{ .listener = l, .client = conn, .port = port };
}
fn captureClose(k: Capture) void {
    xpc_connection_cancel(k.client);
    xpc_release(k.client);
    xpc_connection_cancel(k.listener);
    xpc_release(k.listener);
}
// The packed size of d as an ordinary message carries it, or 0 when nothing
// arrives within 2 s (a sender that refuses it).
fn packedSize(k: Capture, d: O) u64 {
    xpc_connection_send_message(k.client, d);
    const h: *c.mach_msg_header_t = @ptrCast(&wire);
    if (c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, wire.len, k.port, 2000, 0) != 0) return 0;
    const complex = (h.msgh_bits & c.MACH_MSGH_BITS_COMPLEX) != 0;
    const size = std.mem.readInt(u64, wire[@intCast(if (complex) REQUEST - 16 else ORDINARY - 16)..][0..8], .little);
    c.mach_msg_destroy(h);
    return size;
}
// The packed bytes of a dictionary of this shape, less its data: data adds
// its own length and nothing else (two lengths give the same answer).
fn overhead(k: Capture, case: [*:0]const u8, value: u64, op: u64, n: u64, seq: bool) u64 {
    const a = dict(value, op, n, 16, seq);
    const b = dict(value, op, n, 1000, seq);
    const pa = packedSize(k, a);
    const pb = packedSize(k, b);
    xpc_release(a);
    xpc_release(b);
    fact(case, "packed_overhead_linear", 1, @intFromBool(pa > 16 and pb > 1000 and pa - 16 == pb - 1000));
    return if (pa > 16) pa - 16 else 0;
}

// Each case runs in its own process. Its server, client and calls live here,
// not in the case's frame: an event that comes after retire() writes here.
var srv: Server = .{};
var cli: Client = .{};
var calls: [3]Call = undefined;

// ---- sizeThreshold ---------------------------------------------------------------

fn sizeThreshold(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "sizeThreshold";
    library(case);
    const k = captureOpen();
    // A reply here: the sequence key, "value", data.
    const reply_overhead = overhead(k, case, 10, 0, 0, true);
    const targets = [_]u64{ 8000, 8100, 8200 };
    const packed_labels = [_][*:0]const u8{ "reply_8000_packed", "reply_8100_packed", "reply_8200_packed" };
    const reply_labels = [_][*:0]const u8{ "reply_8000_arrived", "reply_8100_arrived", "reply_8200_arrived" };
    const len_labels = [_][*:0]const u8{ "reply_8000_data_length", "reply_8100_data_length", "reply_8200_data_length" };
    const byte_labels = [_][*:0]const u8{ "reply_8000_bytes", "reply_8100_bytes", "reply_8200_bytes" };
    var data: [3]u64 = undefined;
    for (targets, 0..) |t, i| {
        data[i] = t - reply_overhead;
        const d = dict(10 + i, 0, 0, @intCast(data[i]), true);
        fact(case, packed_labels[i], t, packedSize(k, d));
        xpc_release(d);
    }
    captureClose(k);
    const p = pair(&srv, &cli, "op780.threshold");
    for (&calls, 0..) |*kc, i| {
        kc.init();
        const m = dict(10 + i, 2, data[i], 0, false);
        call(p.client, m, kc);
        xpc_release(m);
    }
    for (&calls, 0..) |*kc, i| {
        const done = waitMs(&kc.sem, 3000);
        _ = c.printf("xpc_b0 case=%s reply packed=%llu data=%llu overhead=%llu done=%u code=%llu length=%llu ms=%llu\n", case, targets[i], data[i], reply_overhead, @as(c_uint, @intFromBool(done)), kc.code, kc.len, kc.ms);
        fact(case, reply_labels[i], 10 + i, kc.code);
        fact(case, len_labels[i], data[i], kc.len);
        fact(case, byte_labels[i], 1, kc.match);
    }
    retire(p);
    conclude(case);
}

// ---- largeReply and largeRequest ---------------------------------------------------

const LARGE = 64 * 1024;
fn largeReply(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "largeReply";
    library(case);
    const p = pair(&srv, &cli, "op780.reply");
    const kc = &calls[0];
    kc.init();
    const m = dict(15, 2, LARGE, 0, false);
    call(p.client, m, kc);
    xpc_release(m);
    const done = waitMs(&kc.sem, 3000);
    _ = c.usleep(100_000);
    _ = c.printf("xpc_b0 case=%s observed done=%u code=%llu length=%llu ms=%llu completions=%llu\n", case, @as(c_uint, @intFromBool(done)), kc.code, kc.len, kc.ms, load(&kc.n));
    fact(case, "reply_arrived", 15, kc.code);
    fact(case, "reply_data_length", LARGE, kc.len);
    fact(case, "reply_bytes", 1, kc.match);
    fact(case, "completions", 1, load(&kc.n));
    retire(p);
    conclude(case);
}
fn largeRequest(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "largeRequest";
    library(case);
    const s = &srv;
    const p = pair(&srv, &cli, "op780.request");
    const kc = &calls[0];
    kc.init();
    const m = dict(16, 3, 0, LARGE, false);
    call(p.client, m, kc);
    xpc_release(m);
    const done = waitMs(&kc.sem, 3000);
    _ = c.usleep(100_000);
    _ = c.printf("xpc_b0 case=%s observed done=%u code=%llu ok=%llu ms=%llu server_count=%llu server_length=%llu\n", case, @as(c_uint, @intFromBool(done)), kc.code, kc.ok, kc.ms, load(&s.slots[16].count), load(&s.slots[16].len));
    fact(case, "request_arrived", 1, load(&s.slots[16].count));
    fact(case, "request_data_length", LARGE, load(&s.slots[16].len));
    fact(case, "request_bytes", 1, load(&s.slots[16].match));
    fact(case, "reply_arrived", 16, kc.code);
    fact(case, "reply_says_bytes_matched", 1, kc.ok);
    retire(p);
    conclude(case);
}

// ---- capBoundary -----------------------------------------------------------------

fn capBoundary(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "capBoundary";
    library(case);
    const trailer: u64 = @sizeOf(c.mach_msg_audit_trailer_t);
    const k = captureOpen();
    // The largest ordinary message: packed bytes up to the cap less 40.
    const plain = overhead(k, case, 20, 0, 0, false);
    const max_data = CAP - ORDINARY - plain;
    const max = dict(20, 0, 0, @intCast(max_data), false);
    fact(case, "max_packed", CAP - ORDINARY, packedSize(k, max));
    // The largest request: up to the cap less 56.
    const req_overhead = overhead(k, case, 21, 3, 0, false);
    const req_data = CAP - REQUEST - req_overhead;
    const req = dict(21, 3, 0, @intCast(req_data), false);
    fact(case, "max_request_packed", CAP - REQUEST, packedSize(k, req));
    captureClose(k);
    const over = dict(22, 0, 0, @intCast(max_data + 1), false);
    _ = c.printf("xpc_b0 case=%s arithmetic cap=%llu ordinary_offset=%llu request_offset=%llu max_ordinary_packed=%llu max_ordinary_message=%llu max_request_packed=%llu max_request_message=%llu audit_trailer=%llu receiver_buffer=%llu over_packed=%llu over_message=%llu\n", case, CAP, ORDINARY, REQUEST, CAP - ORDINARY, CAP, CAP - REQUEST, CAP, trailer, CAP + trailer, CAP - ORDINARY + 1, CAP + 1);

    const s = &srv;
    const cl = &cli;
    const p = pair(&srv, &cli, "op780.cap");
    xpc_connection_send_message(p.client, max);
    const max_arrived = awaitCount(&s.slots[20].count, 1, 3000);
    const kc = &calls[0];
    kc.init();
    call(p.client, req, kc);
    const req_done = waitMs(&kc.sem, 3000);
    // One byte more: refused at the sender, which interrupts the client.
    const interrupted_before = load(&cl.interrupted);
    xpc_connection_send_message(p.client, over);
    const interrupted = awaitCount(&cl.interrupted, interrupted_before + 1, 2000);
    const small = dict(23, 0, 0, 0, false);
    xpc_connection_send_message(p.client, small);
    const small_arrived = awaitCount(&s.slots[23].count, 1, 3000);
    _ = c.usleep(200_000);
    _ = c.printf("xpc_b0 case=%s observed max_count=%llu max_length=%llu request_code=%llu request_ok=%llu over_count=%llu small_count=%llu client_interrupted=%llu client_invalid=%llu log_expected=send_refused_size_%llu_cap_%llu\n", case, load(&s.slots[20].count), load(&s.slots[20].len), kc.code, kc.ok, load(&s.slots[22].count), load(&s.slots[23].count), load(&cl.interrupted), load(&cl.invalid), CAP + 1, CAP);
    fact(case, "max_arrived", 1, @intFromBool(max_arrived));
    fact(case, "max_data_length", max_data, load(&s.slots[20].len));
    fact(case, "max_bytes", 1, load(&s.slots[20].match));
    fact(case, "max_request_reply", 21, if (req_done) kc.code else NONE);
    fact(case, "max_request_bytes", 1, kc.ok);
    fact(case, "over_interrupts_client", 1, @intFromBool(interrupted));
    fact(case, "over_arrived", 0, load(&s.slots[22].count));
    fact(case, "small_after", 1, @intFromBool(small_arrived));
    xpc_release(max);
    xpc_release(req);
    xpc_release(over);
    xpc_release(small);
    retire(p);
    conclude(case);
}

// ---- oversizeDropped ---------------------------------------------------------------

// A message of OVER bytes built with mach_msg: a header and zeros.
fn sendOver(dest: u32, disposition: c_uint) c_int {
    const total: usize = @intCast(OVER);
    const buf: [*]align(8) u8 = @ptrCast(@alignCast(c.calloc(1, total) orelse c.atf_tc_fail("setup: over-cap buffer")));
    defer c.free(buf);
    const h: *c.mach_msg_header_t = @ptrCast(buf);
    h.msgh_bits = c.MACH_MSGH_BITS(disposition, 0);
    h.msgh_size = @intCast(total);
    h.msgh_remote_port = dest;
    h.msgh_local_port = 0;
    h.msgh_id = PIPE_ID;
    return c.mach_msg(h, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, @intCast(total), 0, 0, 1000, 0);
}
fn oversizeDropped(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "oversizeDropped";
    library(case);
    const s = &srv;
    var port: u32 = 0;
    const l = listenerWithPort("op780.oversize", &port);
    setHandler(l, &listenerEvent, s);
    // Before the resume: the over-cap message, then an ordinary one.
    fact(case, "over_sent", 0, @bitCast(@as(i64, sendOver(port, c.MACH_MSG_TYPE_COPY_SEND))));
    const e = xpc_endpoint_create(l);
    need(e != null, "endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "client");
    xpc_release(e);
    setHandler(conn, &ignore, null);
    xpc_connection_resume(conn);
    const m = dict(31, 0, 0, 0, false);
    xpc_connection_send_message(conn, m);
    xpc_release(m);
    const start = nowMs();
    while (queued(port) < 2 and nowMs() - start < 2000) _ = c.usleep(2_000);
    fact(case, "queued_before_resume", 2, queued(port));
    // Nothing further is sent from here.
    const t0 = nowMs();
    xpc_connection_resume(l);
    const arrived = awaitCount(&s.slots[31].count, 1, 1000);
    const ms = nowMs() - t0;
    _ = c.usleep(200_000);
    _ = c.printf("xpc_b0 case=%s observed arrived=%u arrival_ms=%llu peers=%llu other=%llu queued_after=%llu over_message=%llu log_expected=not_read_size_%llu_cap_%llu\n", case, @as(c_uint, @intFromBool(arrived)), ms, load(&s.peers), load(&s.other), queued(port), OVER, OVER, CAP);
    fact(case, "ordinary_within_1s", 1, @intFromBool(arrived));
    fact(case, "ordinary_count", 1, load(&s.slots[31].count));
    fact(case, "queued_after", 0, queued(port));
    xpc_connection_cancel(conn);
    xpc_release(conn);
    xpc_connection_cancel(l);
    xpc_release(l);
    conclude(case);
}

// ---- oversizeReplyDropped --------------------------------------------------------

// The server is the case itself: the listener is never resumed, and the case
// reads the request from its port and answers on the request's send-once
// right with a message over the cap.
const PortDescriptor = extern struct { name: u32, pad1: u32, pad2: u16, disposition: u8, kind: u8 };
fn oversizeReplyDropped(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "oversizeReplyDropped";
    library(case);
    const ports_start = settleReplyPorts(0, 2000);
    var port: u32 = 0;
    const l = listenerWithPort("op780.raw", &port);
    const e = xpc_endpoint_create(l);
    need(e != null, "endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "client");
    xpc_release(e);
    const cl = &cli;
    setHandler(conn, &clientEvent, cl);
    xpc_connection_resume(conn);
    const kc = &calls[0];
    kc.init();
    const m = dict(41, 0, 0, 0, false);
    call(conn, m, kc);
    xpc_release(m);
    var bytes: [8192]u8 align(8) = @splat(0);
    const h: *c.mach_msg_header_t = @ptrCast(&bytes);
    const got = c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, port, 3000, 0);
    const complex = got == 0 and (h.msgh_bits & c.MACH_MSGH_BITS_COMPLEX) != 0;
    const count = if (complex) std.mem.readInt(u32, bytes[24..28], .little) else 0;
    const d: *align(4) const PortDescriptor = @ptrCast(@alignCast(&bytes[28]));
    const sonce: u32 = if (complex and count == 1 and d.disposition == c.MACH_MSG_TYPE_PORT_SEND_ONCE) d.name else 0;
    const ports_pending = replyPorts();
    const t0 = nowMs();
    const sent = if (sonce != 0) sendOver(sonce, c.MACH_MSG_TYPE_MOVE_SEND_ONCE) else -1;
    // The request's header right; its send-once right went with the reply.
    if (got == 0 and h.msgh_remote_port != 0) _ = c.mach_port_deallocate(c.mach_task_self(), h.msgh_remote_port);
    const done = waitMs(&kc.sem, 1000);
    const ms = nowMs() - t0;
    // A second completion would come here.
    _ = c.usleep(300_000);
    const settled = settleReplyPorts(ports_start, 2000);
    _ = c.printf("xpc_b0 case=%s observed received=%d complex=%u descriptors=%u sonce=%u done=%u code=%llu ms=%llu completions=%llu reply_ports_start=%llu reply_ports_pending=%llu reply_ports_settled=%llu client_interrupted=%llu client_invalid=%llu log_expected=not_read_size_%llu_cap_%llu\n", case, got, @as(c_uint, @intFromBool(complex)), count, sonce, @as(c_uint, @intFromBool(done)), kc.code, ms, load(&kc.n), ports_start, ports_pending, settled, load(&cl.interrupted), load(&cl.invalid), OVER, CAP);
    fact(case, "request_received", 0, @bitCast(@as(i64, got)));
    fact(case, "request_has_send_once", 1, @intFromBool(sonce != 0));
    fact(case, "reply_port_while_pending", ports_start + 1, ports_pending);
    fact(case, "over_reply_sent", 0, @bitCast(@as(i64, sent)));
    fact(case, "completed_within_1s", 1, @intFromBool(done));
    fact(case, "completion_is_error", 1, @intFromBool(kc.code == INVALID or kc.code == INTERRUPTED));
    fact(case, "completions", 1, load(&kc.n));
    fact(case, "reply_ports_over_start", 0, if (settled > ports_start) settled - ports_start else 0);
    xpc_connection_cancel(conn);
    xpc_release(conn);
    xpc_connection_cancel(l);
    xpc_release(l);
    conclude(case);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "40");
}
var cases: [6]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const ids = [_][*:0]const u8{ "sizeThreshold", "largeReply", "largeRequest", "capBoundary", "oversizeDropped", "oversizeReplyDropped" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &sizeThreshold, &largeReply, &largeRequest, &capBoundary, &oversizeDropped, &oversizeReplyDropped };
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
