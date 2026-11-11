// SPDX-License-Identifier: BSD-2-Clause
// A dictionary whose data value is larger than mach.ool_max_message, sent on
// an in-process connection: an anonymous connection and a client made from
// its endpoint, so nothing goes to launchd. libxpc sends inline, so the size
// is its own to refuse (xpc_pipe_send's EMSGSIZE, xpc_misc.c); the send
// returns nothing, and the refusal reaches the caller as an event on the
// client connection. The case records those events, then requires that a
// small message on the same connection arrives and that mach.ool_bytes is
// unchanged.
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
extern fn xpc_dictionary_create(O, O, usize) O;
extern fn xpc_dictionary_set_uint64(O, [*:0]const u8, u64) void;
extern fn xpc_dictionary_get_uint64(O, [*:0]const u8) u64;
extern fn xpc_dictionary_set_data(O, [*:0]const u8, ?*const anyopaque, usize) void;
extern fn xpc_get_type(O) ?*const anyopaque;
extern fn xpc_release(O) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern fn dispatch_release(O) void;
extern const _xpc_error_connection_invalid: u8;
extern const _xpc_error_connection_interrupted: u8;
extern const _xpc_type_dictionary: u8;
extern var _NSConcreteStackBlock: [32]?*anyopaque;
extern fn _Block_copy(?*const anyopaque) ?*anyopaque;
extern fn _Block_release(?*const anyopaque) void;

const INVALID: u64 = 1 << 32;
const INTERRUPTED: u64 = (1 << 32) + 1;
const OTHER: u64 = (1 << 32) + 2;
fn eventCode(o: O) u64 {
    if (o == @as(O, @ptrCast(@constCast(&_xpc_error_connection_invalid)))) return INVALID;
    if (o == @as(O, @ptrCast(@constCast(&_xpc_error_connection_interrupted)))) return INTERRUPTED;
    if (xpc_get_type(o) == @as(?*const anyopaque, @ptrCast(&_xpc_type_dictionary))) return xpc_dictionary_get_uint64(o, "value");
    return OTHER;
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
    fn record(e: *Events, o: O) void {
        const i = @atomicRmw(u64, &e.n, .Add, 1, .seq_cst);
        if (i < e.log.len) e.log[@intCast(i)] = eventCode(o);
        _ = c.sem_post(&e.sem);
    }
    fn count(e: *Events) u64 {
        return @atomicLoad(u64, &e.n, .seq_cst);
    }
    // Wait until value has been recorded, or ms have passed.
    fn waitValue(e: *Events, value: u64, ms: u64) bool {
        var t: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &t);
        const ns: u64 = @as(u64, @intCast(t.tv_nsec)) + ms * 1_000_000;
        t.tv_sec += @intCast(ns / 1_000_000_000);
        t.tv_nsec = @intCast(ns % 1_000_000_000);
        while (true) {
            const n: usize = @intCast(@min(e.count(), e.log.len));
            for (e.log[0..n]) |v| if (v == value) return true;
            if (c.sem_timedwait(&e.sem, &t) != 0) return false;
        }
    }
    // Wait for a first event, or ms.
    fn waitAny(e: *Events, ms: u32) void {
        var waited: u32 = 0;
        while (e.count() == 0 and waited < ms) : (waited += 10) _ = c.usleep(10_000);
    }
    fn has(e: *Events, value: u64) bool {
        const n: usize = @intCast(@min(e.count(), e.log.len));
        for (e.log[0..n]) |v| if (v == value) return true;
        return false;
    }
    fn show(e: *Events, label: [*:0]const u8) void {
        _ = c.printf("xpc_ool_limit events=%s count=%lu", label, e.count());
        const n: usize = @intCast(@min(e.count(), e.log.len));
        for (e.log[0..n]) |v| _ = c.printf(" 0x%lx", v);
        _ = c.printf("\n");
    }
};

// Blocks ABI (BlocksRuntime runtime.c), as in stage_a.zig: a stack literal
// copied to the heap once; the handler records into ctx.
const Descriptor = extern struct { reserved: c_ulong, size: c_ulong };
const Block = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*Block, O) callconv(.c) void,
    descriptor: *const Descriptor,
    events: *Events,
};
fn blockInvoke(b: *Block, o: O) callconv(.c) void {
    b.events.record(o);
}
const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Block) };
fn setHandler(conn: O, events: *Events) void {
    var literal = Block{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = 0, .reserved = 0, .invoke = &blockInvoke, .descriptor = &descriptor, .events = events };
    const b = _Block_copy(&literal);
    xpc_connection_set_event_handler(conn, b);
    _Block_release(b);
}

fn read(name: [*:0]const u8) u64 {
    var value: c_ulong = 0;
    var size: usize = @sizeOf(c_ulong);
    if (c.sysctlbyname(name, &value, &size, null, 0) != 0 or size != @sizeOf(c_ulong)) c.atf_tc_fail("read %s", name);
    return value;
}
// mach.ool_bytes once it equals target, or its last value after 2 s.
fn settle(target: u64) u64 {
    var value = read("mach.ool_bytes");
    var waited: u32 = 0;
    while (value != target and waited < 200) : (waited += 1) {
        _ = c.usleep(10_000);
        value = read("mach.ool_bytes");
    }
    return value;
}
fn pid1(comm: *[c.COMMLEN + 1]u8) bool {
    var kp: c.struct_kinfo_proc = undefined;
    var size: usize = @sizeOf(c.struct_kinfo_proc);
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID, 1 };
    if (c.sysctl(&mib, mib.len, &kp, &size, null, 0) != 0 or size != @sizeOf(c.struct_kinfo_proc)) return false;
    @memcpy(comm, kp.ki_comm[0 .. c.COMMLEN + 1]);
    return true;
}

var server_events: Events = .{};
var client_events: Events = .{};
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.alarm(25);
    server_events.init();
    client_events.init();
    const start = read("mach.ool_bytes");
    const max = read("mach.ool_max_message");
    const len: usize = @intCast(max + 4096);
    const data: [*]u8 = @ptrCast(c.malloc(len) orelse c.atf_tc_fail("data allocation"));
    @memset(data[0..len], 0x5a);

    const server_q = dispatch_queue_create("ool_limit.server", null);
    const server = xpc_connection_create(null, server_q);
    dispatch_release(server_q);
    if (server == null) c.atf_tc_fail("anonymous connection");
    setHandler(server, &server_events);
    xpc_connection_resume(server);
    const endpoint = xpc_endpoint_create(server);
    const client = xpc_connection_create_from_endpoint(endpoint);
    xpc_release(endpoint);
    if (client == null) c.atf_tc_fail("connection from endpoint");
    setHandler(client, &client_events);
    xpc_connection_resume(client);

    const big = xpc_dictionary_create(null, null, 0);
    xpc_dictionary_set_uint64(big, "value", 1);
    xpc_dictionary_set_data(big, "blob", data, len);
    c.free(data);

    // The dictionary on the connection, then a small one.
    xpc_connection_send_message(client, big);
    xpc_release(big);
    const small = xpc_dictionary_create(null, null, 0);
    xpc_dictionary_set_uint64(small, "value", 2);
    xpc_connection_send_message(client, small);
    xpc_release(small);
    const arrived = server_events.waitValue(2, 5000);
    client_events.waitAny(1000);
    const big_arrived = server_events.has(1);
    const after = settle(start);
    var comm: [c.COMMLEN + 1]u8 = @splat(0);
    const have_pid1 = pid1(&comm);
    const launchd = have_pid1 and c.strcmp(&comm, "launchd") == 0;

    _ = c.printf("xpc_ool_limit max=%lu data=%lu invalid=0x%lx interrupted=0x%lx\n", max, @as(c_ulong, len), INVALID, INTERRUPTED);
    client_events.show("client");
    server_events.show("server");
    _ = c.printf("xpc_ool_limit expected_small_arrived=1 observed_small_arrived=%d expected_big_arrived=0 observed_big_arrived=%d expected_bytes=%lu observed_bytes=%lu expected_pid1=launchd observed_pid1=%s\n", @as(c_int, @intFromBool(arrived)), @as(c_int, @intFromBool(big_arrived)), start, after, if (have_pid1) @as([*:0]const u8, @ptrCast(&comm)) else "unread");

    xpc_connection_cancel(client);
    xpc_release(client);
    xpc_connection_cancel(server);
    xpc_release(server);
    if (!arrived) c.atf_tc_fail("small message after the oversized one did not arrive");
    if (big_arrived) c.atf_tc_fail("oversized dictionary arrived");
    if (after != start) c.atf_tc_fail("mach.ool_bytes changed: %lu -> %lu", start, after);
    if (!launchd) c.atf_tc_fail("PID 1 is not launchd");
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "30");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "oversized_data", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    const added = c.atf_tp_add_tc(tp, &tc);
    if (c.atf_is_error(added)) return added;
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
