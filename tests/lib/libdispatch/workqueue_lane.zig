// SPDX-License-Identifier: BSD-2-Clause
// Adapted from Gatekeeper op-679 workload/lane.zig; assertions belong to ATF.
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/thrworkq.h");
    @cInclude("sys/syscall.h");
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn dispatch_get_global_queue(isize, usize) ?*anyopaque;
extern fn dispatch_queue_create([*:0]const u8, ?*anyopaque) ?*anyopaque;
extern fn dispatch_async_f(?*anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_semaphore_create(isize) ?*anyopaque;
extern fn dispatch_semaphore_signal(?*anyopaque) isize;
extern fn dispatch_semaphore_wait(?*anyopaque, u64) isize;
extern fn dispatch_time(u64, i64) u64;
extern fn dispatch_release(?*anyopaque) void;
const forever = std.math.maxInt(u64);
const ten_seconds = 10_000_000_000;
const Context = struct {
    gate: ?*anyopaque,
    entered: ?*anyopaque,
    done: ?*anyopaque,
    marker: ?*anyopaque,
    waiting: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    marker_ns: std.atomic.Value(i64) = .init(0),
};
fn now() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) c.atf_tc_fail("monotonic clock");
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}
fn worker(ptr: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(ptr.?));
    _ = ctx.waiting.fetchAdd(1, .seq_cst);
    _ = dispatch_semaphore_signal(ctx.entered);
    _ = dispatch_semaphore_wait(ctx.gate, forever);
    _ = ctx.waiting.fetchSub(1, .seq_cst);
    _ = ctx.finished.fetchAdd(1, .seq_cst);
    _ = dispatch_semaphore_signal(ctx.done);
}
fn last(ptr: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(ptr.?));
    ctx.marker_ns.store(now(), .seq_cst);
    _ = dispatch_semaphore_signal(ctx.marker);
}
fn readInt(name: [*:0]const u8) u32 {
    var n: u32 = 0;
    var size: usize = @sizeOf(u32);
    if (c.sysctlbyname(name, &n, &size, null, 0) != 0 or size != @sizeOf(u32)) c.atf_tc_fail("sysctl %s", name);
    return n;
}
fn threadCount() u32 {
    // KERN_PROC_INC_THREAD emits one self-sized kinfo_proc per thread.
    // Decode only its leading ki_structsize rather than importing kernel-only
    // PCB types through user.h (packed bitfields are opaque to Zig).
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID | c.KERN_PROC_INC_THREAD, c.getpid() };
    var bytes: [512 * 1024]u8 = undefined;
    var size: usize = bytes.len;
    if (c.sysctl(&mib, mib.len, &bytes, &size, null, 0) != 0 or size < 4) c.atf_tc_fail("process thread inventory");
    const record_size = std.mem.readInt(u32, bytes[0..4], .little);
    if (record_size < 4 or size % record_size != 0) c.atf_tc_fail("process thread record size");
    return @intCast(size / record_size);
}
fn context() Context {
    const ctx: Context = .{ .gate = dispatch_semaphore_create(0), .entered = dispatch_semaphore_create(0), .done = dispatch_semaphore_create(0), .marker = dispatch_semaphore_create(0) };
    if (ctx.gate == null or ctx.entered == null or ctx.done == null or ctx.marker == null) c.atf_tc_fail("semaphore allocation");
    return ctx;
}
fn dispose(ctx: *Context) void {
    for ([_]?*anyopaque{ ctx.gate, ctx.entered, ctx.done, ctx.marker }) |s| dispatch_release(s);
}
fn queues(out: []?*anyopaque, oc: bool) void {
    for (out) |*q| {
        q.* = if (oc) dispatch_queue_create("op681.serial", null) else dispatch_get_global_queue(0, 0);
        if (q.* == null) c.atf_tc_fail("queue allocation");
    }
}
fn drain(ctx: *Context, count: usize) bool {
    for (0..count) |_| _ = dispatch_semaphore_signal(ctx.gate);
    const deadline = dispatch_time(0, ten_seconds);
    for (0..count) |_| if (dispatch_semaphore_wait(ctx.done, deadline) != 0) return false;
    return ctx.finished.load(.seq_cst) == count and ctx.waiting.load(.seq_cst) == 0;
}
fn admission(oc: bool) void {
    const n = readInt("hw.ncpu");
    if (n == 0 or n > 128) c.atf_tc_fail("unsupported CPU count %u", n);
    const target: usize = n * @as(usize, if (oc) 2 else 1);
    if (target >= c.TWQ_MAX_LANE_THREADS) c.atf_tc_fail("CPU-sized setup reaches resource ceiling");
    var ctx = context();
    var qs: [257]?*anyopaque = @splat(null);
    queues(qs[0 .. target + 1], oc);
    for (0..target) |i| dispatch_async_f(qs[i], &ctx, &worker);
    var entered: usize = 0;
    const ready = dispatch_time(0, ten_seconds);
    for (0..target) |_| {
        if (dispatch_semaphore_wait(ctx.entered, ready) != 0) break;
        entered += 1;
    }
    _ = c.usleep(100_000);
    const waiting = ctx.waiting.load(.seq_cst);
    const start = now();
    dispatch_async_f(qs[target], &ctx, &last);
    const marker_rc = dispatch_semaphore_wait(ctx.marker, dispatch_time(0, ten_seconds));
    const stamp = ctx.marker_ns.load(.seq_cst);
    const elapsed = if (stamp > 0) stamp - start else now() - start;
    const before_release = marker_rc == 0 and stamp >= start and elapsed <= ten_seconds and ctx.waiting.load(.seq_cst) == target;
    const drained = drain(&ctx, target);
    const marker_after = if (marker_rc == 0) @as(isize, 0) else dispatch_semaphore_wait(ctx.marker, dispatch_time(0, ten_seconds));
    _ = c.printf("twq_admission overcommit=%u N=%u expected_waiting=%zu observed_waiting=%u entered=%zu expected_marker_ms_max=10000 observed_marker_ms=%lld marker_rc=%ld expected_finished=%zu observed_finished=%u\n", @as(u32, @intFromBool(oc)), n, target, waiting, entered, @as(c_longlong, @divTrunc(elapsed, 1_000_000)), marker_rc, target, ctx.finished.load(.seq_cst));
    if (!drained or marker_after != 0) c.atf_tc_fail("callbacks did not drain after release");
    if (oc) for (qs[0 .. target + 1]) |q| dispatch_release(q);
    dispose(&ctx);
    if (entered != target or waiting != target or !before_release) c.atf_tc_fail("further same-lane callback did not run while all workers waited");
}
fn defaultLane(_: [*c]const c.atf_tc_t) callconv(.c) void {
    admission(false);
}
fn overcommitLane(_: [*c]const c.atf_tc_t) callconv(.c) void {
    admission(true);
}
fn boundedWaiters(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const cap = readInt("kern.twq.max_lane_threads");
    const proc_cap = readInt("kern.twq.max_proc_threads");
    if (cap != c.TWQ_MAX_LANE_THREADS or proc_cap != c.TWQ_MAX_PROC_THREADS) c.atf_tc_fail("pool limit/header mismatch");
    const before = threadCount();
    var ctx = context();
    var qs: [c.TWQ_MAX_LANE_THREADS + 16]?*anyopaque = @splat(null);
    queues(&qs, true);
    // Feed one blocker at a time so each requested replacement has entered
    // before asking for another. Then saturate the pending queue at the cap.
    var entered: usize = 0;
    for (0..cap) |i| {
        dispatch_async_f(qs[i], &ctx, &worker);
        if (dispatch_semaphore_wait(ctx.entered, dispatch_time(0, ten_seconds)) != 0) break;
        entered += 1;
    }
    for (qs[cap..]) |q| dispatch_async_f(q, &ctx, &worker);
    var peak: u32 = 0;
    var max_waiting: u32 = 0;
    for (0..20) |_| {
        peak = @max(peak, threadCount());
        max_waiting = @max(max_waiting, ctx.waiting.load(.seq_cst));
        _ = c.usleep(10_000);
    }
    const drained = drain(&ctx, qs.len);
    _ = c.printf("twq_bound expected_lane_max=%u observed_waiting_max=%u entered=%zu expected_proc_max=%u observed_process_threads=%u baseline_threads=%u expected_finished=%zu observed_finished=%u\n", cap, max_waiting, entered, proc_cap, peak, before, qs.len, ctx.finished.load(.seq_cst));
    if (!drained) c.atf_tc_fail("bounded pending callbacks did not drain");
    for (qs) |q| dispatch_release(q);
    dispose(&ctx);
    // Main and the libthr reaper are not registered pool workers.
    if (entered != cap or max_waiting != cap or peak > cap + before + 2 or peak > proc_cap) c.atf_tc_fail("total worker bound or saturated setup failed");
}
const PoolGate = struct {
    released: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(u32) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),
    attempted: std.atomic.Value(u32) = .init(0),
};
const PoolWorker = struct { gate: *PoolGate, priority: u32 };
fn poolWorker(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const arg: *PoolWorker = @ptrCast(@alignCast(ptr.?));
    _ = arg.gate.attempted.fetchAdd(1, .seq_cst);
    const kr = c.syscall(c.SYS_twq_kernreturn, @as(c_int, c.TWQ_OP_THREAD_ENTER), @as(?*anyopaque, null), @as(c_int, @bitCast(arg.priority)), @as(c_int, 0));
    if (kr != 0) {
        _ = arg.gate.failures.fetchAdd(1, .seq_cst);
        return null;
    }
    _ = arg.gate.entered.fetchAdd(1, .seq_cst);
    const end = now() + 30_000_000_000;
    while (!arg.gate.released.load(.seq_cst) and now() < end) _ = c.usleep(1000);
    return null;
}
fn awaitCount(counter: *std.atomic.Value(u32), value: u32) bool {
    const end = now() + ten_seconds;
    while (counter.load(.seq_cst) < value and now() < end) _ = c.usleep(1000);
    return counter.load(.seq_cst) == value;
}
fn processBound(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var init = std.mem.zeroes(c.struct_twq_init_args);
    init.tqi_version = c.TWQ_SPI_VERSION_CURRENT;
    if (c.syscall(c.SYS_twq_kernreturn, @as(c_int, c.TWQ_OP_INIT), &init, @as(c_int, @sizeOf(@TypeOf(init))), @as(c_int, 0)) < 0) c.atf_tc_fail("TWQ init");
    var gate: PoolGate = .{};
    var threads: [c.TWQ_MAX_PROC_THREADS + 1]c.pthread_t = undefined;
    var args: [c.TWQ_MAX_PROC_THREADS + 1]PoolWorker = undefined;
    const tokens = [_]u32{ c.TWQ_QOS_CLASS_MAINTENANCE, c.TWQ_QOS_CLASS_BACKGROUND, c.TWQ_QOS_CLASS_UTILITY, c.TWQ_QOS_CLASS_DEFAULT, c.TWQ_QOS_CLASS_USER_INITIATED };
    var created: u32 = 0;
    var setup_ok = true;
    for (&threads, &args, 0..) |*thread, *arg, i| {
        arg.* = .{ .gate = &gate, .priority = (tokens[i / c.TWQ_MAX_LANE_THREADS] << 8) | c.TWQ_PRIORITY_OVERCOMMIT_FLAG };
        if (c.pthread_create(thread, null, &poolWorker, arg) != 0) {
            setup_ok = false;
            break;
        }
        created += 1;
        if (i < c.TWQ_MAX_PROC_THREADS and !awaitCount(&gate.entered, created)) {
            setup_ok = false;
            break;
        }
    }
    _ = awaitCount(&gate.attempted, created);
    _ = c.usleep(100_000);
    const held = gate.entered.load(.seq_cst);
    var req = std.mem.zeroes(c.struct_twq_reqthreads_args);
    req.tqr_version = c.TWQ_REQTHREADS_VERSION;
    req.tqr_reqcount = 1;
    req.tqr_priority = (c.TWQ_QOS_CLASS_USER_INTERACTIVE << 8) | @as(u64, c.TWQ_PRIORITY_OVERCOMMIT_FLAG);
    const grant = c.syscall(c.SYS_twq_kernreturn, @as(c_int, c.TWQ_OP_REQTHREADS), &req, @as(c_int, @sizeOf(@TypeOf(req))), @as(c_int, 0));
    const physical = threadCount();
    gate.released.store(true, .seq_cst);
    for (threads[0..created]) |thread| {
        if (c.pthread_join(thread, null) != 0) setup_ok = false;
    }
    _ = c.printf("twq_process_bound expected_registered_max=%u observed_registered=%u expected_full_grant=0 observed_grant=%ld expected_finished=%u observed_finished=%u observed_physical_threads=%u\n", @as(u32, c.TWQ_MAX_PROC_THREADS), held, grant, created, gate.entered.load(.seq_cst), physical);
    if (!setup_ok or created != threads.len or held != c.TWQ_MAX_PROC_THREADS or grant != 0 or gate.entered.load(.seq_cst) != created or gate.failures.load(.seq_cst) != 0) c.atf_tc_fail("process pool bound, waiting entry or release/drain failed");
}
var cases: [4]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "60");
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Waiting TWQ callbacks allow bounded replacement admission");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "default_lane", "overcommit_lane", "bounded_waiters", "process_bound" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &defaultLane, &overcommitLane, &boundedWaiters, &processBound };
    for (names, bodies, 0..) |name, body, i| {
        var e = c.atf_tc_init(&cases[i], name, &head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
