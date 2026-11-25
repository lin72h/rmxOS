// SPDX-License-Identifier: BSD-2-Clause
// op-780: a send keeps no nvlist. xpc_pipe_send_msg packs a dictionary with
// xpc_pack (lib/libxpc/xpc_misc.c), which builds an nvlist with xpc2nv; a
// list that is never destroyed keeps a copy of every value it holds, and a
// descriptor's duplicate when packing refuses it (nvlist_pack_buffer refuses
// any descriptor). A nested dictionary or array is a list of its own inside
// its parent's.
//
// heapAfterSends: 1,000 sends of one dictionary (data, a nested dictionary
// and an array) on an in-process connection, all received, leave the live
// heap (jemalloc stats.allocated after an epoch refresh) within a bound far
// below one copy of the message per send.
//
// descriptorsAfterRefusedSends: 100 sends of a dictionary holding an
// xpc_fd_create value, each refused at its pack, leave the process's open
// descriptors other than port names as they were. A small message on the
// same connection still arrives afterwards.
//
// The program links libxpc.so.5 by its soname with no run path, so
// LD_LIBRARY_PATH selects the library under test; each case prints the path
// of the libxpc it loaded. Port names on rmxOS are file descriptors
// (kern.proc.filedesc, KF_TYPE_PORT 17), so the descriptor count leaves them
// out: libdispatch's worker threads make and drop them.
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
    @cInclude("fcntl.h");
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
extern fn xpc_connection_send_barrier(O, ?*anyopaque) void;
extern fn xpc_dictionary_create(O, O, usize) O;
extern fn xpc_dictionary_set_uint64(O, [*:0]const u8, u64) void;
extern fn xpc_dictionary_get_uint64(O, [*:0]const u8) u64;
extern fn xpc_dictionary_set_data(O, [*:0]const u8, ?*const anyopaque, usize) void;
extern fn xpc_dictionary_set_string(O, [*:0]const u8, [*:0]const u8) void;
extern fn xpc_dictionary_set_value(O, [*:0]const u8, O) void;
extern fn xpc_array_create(O, usize) O;
extern fn xpc_array_append_value(O, O) void;
extern fn xpc_uint64_create(u64) O;
extern fn xpc_string_create([*:0]const u8) O;
extern fn xpc_fd_create(c_int) O;
extern fn xpc_get_type(O) ?*const anyopaque;
extern fn xpc_release(O) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern fn mallctl([*:0]const u8, ?*anyopaque, ?*usize, ?*anyopaque, usize) c_int;
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
// True once p.* reaches n, within ms.
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
    _ = c.printf("xpc_b0 case=%s library=%s codes=invalid:%llu,interrupted:%llu,peer:%llu,none:%llu\n", case, path, INVALID, INTERRUPTED, PEER, NONE);
    _ = c.fflush(null);
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
// connection's handler block carries the connection's End.
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
fn setHandler(conn: O, f: Fn, ctx: ?*anyopaque, end: *End) void {
    const b = block(f, ctx, conn, end);
    xpc_connection_set_event_handler(conn, b);
    _Block_release(b);
}
// A dispatch_block_t for xpc_connection_send_barrier: the queue is empty
// behind it once it runs.
const Barrier = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*Barrier) callconv(.c) void,
    descriptor: *const Descriptor,
};
fn barrierInvoke(_: *Barrier) callconv(.c) void {}
const barrier_descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Barrier) };
fn sendBarrier(conn: O) void {
    var literal = Barrier{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = 0, .reserved = 0, .invoke = &barrierInvoke, .descriptor = &barrier_descriptor };
    const b = _Block_copy(&literal);
    xpc_connection_send_barrier(conn, b);
    _Block_release(b);
}

// ---- An in-process server ------------------------------------------------------

// The server counts what its peer receives by value; the client counts its
// own events.
const Counts = struct {
    peers: u64 = 0,
    by_value: [8]u64 = @splat(0),
    other: u64 = 0,
    client_interrupted: u64 = 0,
    client_invalid: u64 = 0,
    client_other: u64 = 0,
};
fn peerEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const k: *Counts = @ptrCast(@alignCast(ctx.?));
    const code = eventCode(o);
    if (code < k.by_value.len) bump(&k.by_value[@intCast(code)]) else bump(&k.other);
}
fn listenerEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const k: *Counts = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) != PEER) return;
    bump(&k.peers);
    setHandler(o, &peerEvent, k, newEnd("peer"));
    xpc_connection_resume(o);
}
fn clientEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const k: *Counts = @ptrCast(@alignCast(ctx.?));
    switch (eventCode(o)) {
        INTERRUPTED => bump(&k.client_interrupted),
        INVALID => bump(&k.client_invalid),
        else => bump(&k.client_other),
    }
}
// An anonymous listener, resumed, and a client made from its endpoint.
const Pair = struct { listener: O, client: O };
fn pair(k: *Counts, tag: [*:0]const u8) Pair {
    const l = xpc_connection_create(null, dispatch_queue_create(tag, null));
    need(l != null, "listener");
    setHandler(l, &listenerEvent, k, newEnd("listener"));
    xpc_connection_resume(l);
    const e = xpc_endpoint_create(l);
    need(e != null, "listener's endpoint");
    const conn = xpc_connection_create_from_endpoint(e);
    need(conn != null, "connection from the endpoint");
    xpc_release(e);
    setHandler(conn, &clientEvent, k, newEnd("client"));
    xpc_connection_resume(conn);
    return .{ .listener = l, .client = conn };
}
fn retire(p: Pair) void {
    xpc_connection_cancel(p.client);
    xpc_release(p.client);
    xpc_connection_cancel(p.listener);
    xpc_release(p.listener);
}
fn sendValue(conn: O, value: u64) void {
    const m = xpc_dictionary_create(null, null, 0);
    need(m != null, "message dictionary");
    xpc_dictionary_set_uint64(m, "value", value);
    xpc_connection_send_message(conn, m);
    xpc_release(m);
}

// ---- heapAfterSends --------------------------------------------------------------

// Live bytes as jemalloc counts them: this thread's cache flushed, then an
// epoch refresh (as decode_lifetime.zig reads them).
fn allocated() u64 {
    _ = mallctl("thread.tcache.flush", null, null, null, 0);
    var epoch: u64 = 1;
    var size: usize = @sizeOf(u64);
    need(mallctl("epoch", &epoch, &size, &epoch, @sizeOf(u64)) == 0, "allocator epoch");
    var bytes: usize = 0;
    size = @sizeOf(usize);
    need(mallctl("stats.allocated", &bytes, &size, null, 0) == 0, "allocator live bytes");
    return bytes;
}
const SENDS = 1000;
const WARM = 100;
const BLOB = 4096;
const NESTED_BLOB = 2048;
// The allowed growth over 1,000 sends: one list per send would be about
// 1000 * (BLOB + NESTED_BLOB) bytes, six times this.
const BOUND: u64 = 1 << 20;
// One dictionary: value 1, a data value, a nested dictionary with data of its
// own and a string, and an array with a number, a string and a dictionary.
fn heapMessage() O {
    const m = xpc_dictionary_create(null, null, 0);
    need(m != null, "message");
    xpc_dictionary_set_uint64(m, "value", 1);
    var blob: [BLOB]u8 = @splat(0x5a);
    xpc_dictionary_set_data(m, "blob", &blob, blob.len);
    const nested = xpc_dictionary_create(null, null, 0);
    need(nested != null, "nested dictionary");
    var inner: [NESTED_BLOB]u8 = @splat(0x6b);
    xpc_dictionary_set_data(nested, "blob", &inner, inner.len);
    xpc_dictionary_set_string(nested, "text", "nested");
    xpc_dictionary_set_value(m, "nested", nested);
    xpc_release(nested);
    const list = xpc_array_create(null, 0);
    need(list != null, "array");
    const n = xpc_uint64_create(7);
    const s = xpc_string_create("item");
    const d = xpc_dictionary_create(null, null, 0);
    need(n != null and s != null and d != null, "array items");
    xpc_dictionary_set_uint64(d, "k", 3);
    xpc_array_append_value(list, n);
    xpc_array_append_value(list, s);
    xpc_array_append_value(list, d);
    xpc_release(n);
    xpc_release(s);
    xpc_release(d);
    xpc_dictionary_set_value(m, "list", list);
    xpc_release(list);
    return m;
}
// What the case's handlers reach (op-805).
var heap_counts: Counts = .{};
fn heapAfterSends(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "heapAfterSends";
    library(case);
    const k = &heap_counts;
    k.* = .{};
    const p = pair(k, "op780.heap");
    const m = heapMessage();
    // A first round of the same sends lets libdispatch and libxpc make their
    // threads, caches and size classes.
    for (0..WARM) |_| xpc_connection_send_message(p.client, m);
    const warm = awaitCount(&k.by_value[1], WARM, 10_000);
    sendBarrier(p.client);
    _ = c.usleep(200_000);
    const before = allocated();
    for (0..SENDS) |_| xpc_connection_send_message(p.client, m);
    const all = awaitCount(&k.by_value[1], WARM + SENDS, 20_000);
    // Each send releases its message after mach_msg returns; the barrier
    // runs after the last of them, and the peer's deliveries finish.
    sendBarrier(p.client);
    _ = c.usleep(300_000);
    const after = allocated();
    const growth: u64 = if (after > before) after - before else 0;
    _ = c.printf("xpc_b0 case=%s heap before=%llu after=%llu growth=%llu shrink=%llu bound=%llu sends=%u blob=%u nested_blob=%u received=%llu peers=%llu client_interrupted=%llu\n", case, before, after, growth, if (before > after) before - after else 0, BOUND, @as(c_uint, SENDS), @as(c_uint, BLOB), @as(c_uint, NESTED_BLOB), load(&k.by_value[1]), load(&k.peers), load(&k.client_interrupted));
    fact(case, "warm_sends_received", 1, @intFromBool(warm));
    fact(case, "all_sends_received", 1, @intFromBool(all));
    fact(case, "heap_growth_within_bound", 1, @intFromBool(growth <= BOUND));
    xpc_release(m);
    retire(p);
    finalEvents(case);
    conclude(case);
}

// ---- descriptorsAfterRefusedSends ---------------------------------------------

const Descriptors = struct { other_than_ports: u64 = 0, vnodes: u64 = 0, ports: u64 = 0 };
fn descriptors() Descriptors {
    var d: Descriptors = .{};
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
        // Negative numbers are the cwd, root, jail and text vnodes.
        if (f.kf_fd >= 0) {
            if (f.kf_type == 17) d.ports += 1 else d.other_than_ports += 1;
            if (f.kf_type == c.KF_TYPE_VNODE) d.vnodes += 1;
        }
        offset += @intCast(f.kf_structsize);
    }
    return d;
}
const REFUSED = 100;
var fd_counts: Counts = .{};
fn descriptorsAfterRefusedSends(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const case = "descriptorsAfterRefusedSends";
    library(case);
    const k = &fd_counts;
    k.* = .{};
    const p = pair(k, "op780.fd");
    sendValue(p.client, 2);
    const warm = awaitCount(&k.by_value[2], 1, 5000);
    // The dictionary holds the fd object's own duplicate from here on.
    const fd = c.open("/dev/null", c.O_RDONLY);
    need(fd >= 0, "open /dev/null");
    const fdo = xpc_fd_create(fd);
    need(fdo != null, "fd object");
    _ = c.close(fd);
    const m = xpc_dictionary_create(null, null, 0);
    need(m != null, "message");
    xpc_dictionary_set_uint64(m, "value", 3);
    xpc_dictionary_set_value(m, "fd", fdo);
    xpc_release(fdo);
    sendBarrier(p.client);
    const before = descriptors();
    for (0..REFUSED) |_| xpc_connection_send_message(p.client, m);
    sendBarrier(p.client);
    const after = descriptors();
    // The connection still sends: a small message arrives after the refusals.
    sendValue(p.client, 4);
    const small = awaitCount(&k.by_value[4], 1, 5000);
    _ = c.usleep(100_000);
    _ = c.printf("xpc_b0 case=%s descriptors before_other=%llu after_other=%llu before_vnodes=%llu after_vnodes=%llu before_ports=%llu after_ports=%llu refused=%u fd_arrived=%llu client_interrupted=%llu client_invalid=%llu client_other=%llu\n", case, before.other_than_ports, after.other_than_ports, before.vnodes, after.vnodes, before.ports, after.ports, @as(c_uint, REFUSED), load(&k.by_value[3]), load(&k.client_interrupted), load(&k.client_invalid), load(&k.client_other));
    fact(case, "warm_message_received", 1, @intFromBool(warm));
    fact(case, "descriptors_added", 0, if (after.other_than_ports > before.other_than_ports) after.other_than_ports - before.other_than_ports else 0);
    fact(case, "descriptors_removed", 0, if (before.other_than_ports > after.other_than_ports) before.other_than_ports - after.other_than_ports else 0);
    fact(case, "refused_dictionaries_received", 0, load(&k.by_value[3]));
    fact(case, "small_message_after", 1, @intFromBool(small));
    xpc_release(m);
    retire(p);
    finalEvents(case);
    conclude(case);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "40");
}
var cases: [2]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const ids = [_][*:0]const u8{ "heapAfterSends", "descriptorsAfterRefusedSends" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &heapAfterSends, &descriptorsAfterRefusedSends };
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
