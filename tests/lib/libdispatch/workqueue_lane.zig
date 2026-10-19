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
    @cInclude("signal.h");
    @cInclude("errno.h");
    @cInclude("sched.h");
    @cInclude("sys/cpuset.h");
    @cInclude("pthread_np.h");
    @cInclude("pthread_workqueue.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/thr.h");
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
fn storage(comptime T: type, n: usize) []T {
    return std.heap.page_allocator.alloc(T, n) catch c.atf_tc_fail("test storage allocation");
}
fn laneCap() u32 {
    return readInt("kern.twq.max_lane_threads");
}
fn procCap() u32 {
    return readInt("kern.twq.max_proc_threads");
}
fn threadCount() u32 {

    // KERN_PROC_INC_THREAD emits one self-sized kinfo_proc per thread.
    // Decode only its leading ki_structsize rather than importing kernel-only
    // PCB types through user.h (packed bitfields are opaque to Zig).
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID | c.KERN_PROC_INC_THREAD, c.getpid() };
    var bytes: [1024 * 1024]u8 = undefined;
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
    const lane_cap = laneCap();
    const proc_cap = procCap();
    if (proc_cap != 512 or lane_cap != @min(proc_cap, @max(@as(u32, 64), n * 5))) c.atf_tc_fail("CPU-scaled workqueue ceiling differs");
    _ = c.printf("twq_limits N=%u constrained_lane=%u overcommit_lane=%u process=%u\n", n, lane_cap, proc_cap, proc_cap);
    const target: usize = n * @as(usize, if (oc) 2 else 1);
    if (target >= @min(if (oc) procCap() else laneCap(), procCap())) c.atf_tc_fail("CPU-sized setup reaches resource ceiling");
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
    const proc_cap = procCap();
    const cap = proc_cap; // Overcommit is exempt from the constrained lane ceiling.
    const before = threadCount();
    var ctx = context();
    const qs = storage(?*anyopaque, cap + 16);
    defer std.heap.page_allocator.free(qs);
    queues(qs, true);
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
    if (entered != cap or max_waiting != cap or peak > cap + before + 2 or peak > proc_cap + before + 2) c.atf_tc_fail("total worker bound or saturated setup failed");
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
fn awaitCount(counter: *std.atomic.Value(u32), value: usize) bool {
    const end = now() + ten_seconds;
    while (counter.load(.seq_cst) < value and now() < end) _ = c.usleep(1000);
    return counter.load(.seq_cst) == value;
}
fn processBound(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var init = std.mem.zeroes(c.struct_twq_init_args);
    init.tqi_version = c.TWQ_SPI_VERSION_CURRENT;
    if (c.syscall(c.SYS_twq_kernreturn, @as(c_int, c.TWQ_OP_INIT), &init, @as(c_int, @sizeOf(@TypeOf(init))), @as(c_int, 0)) < 0) c.atf_tc_fail("TWQ init");
    var gate: PoolGate = .{};
    const cap = procCap();
    const threads = storage(c.pthread_t, cap + 1);
    defer std.heap.page_allocator.free(threads);
    const args = storage(PoolWorker, threads.len);
    defer std.heap.page_allocator.free(args);
    const tokens = [_]u32{ c.TWQ_QOS_CLASS_MAINTENANCE, c.TWQ_QOS_CLASS_BACKGROUND, c.TWQ_QOS_CLASS_UTILITY, c.TWQ_QOS_CLASS_DEFAULT, c.TWQ_QOS_CLASS_USER_INITIATED };
    var created: u32 = 0;
    var setup_ok = true;
    for (threads, args, 0..) |*thread, *arg, i| {
        arg.* = .{ .gate = &gate, .priority = (tokens[i % tokens.len] << 8) | c.TWQ_PRIORITY_OVERCOMMIT_FLAG };
        if (c.pthread_create(thread, null, &poolWorker, arg) != 0) {
            setup_ok = false;
            break;
        }
        created += 1;
        if (i < cap and !awaitCount(&gate.entered, created)) {
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
    _ = c.printf("twq_process_bound expected_registered_max=%u observed_registered=%u expected_full_grant=0 observed_grant=%ld expected_finished=%u observed_finished=%u observed_physical_threads=%u\n", cap, held, grant, created, gate.entered.load(.seq_cst), physical);
    if (!setup_ok or created != threads.len or held != cap or grant != 0 or gate.entered.load(.seq_cst) != created or gate.failures.load(.seq_cst) != 0) c.atf_tc_fail("process pool bound, waiting entry or release/drain failed");
}
fn initKernel() void {
    var init = std.mem.zeroes(c.struct_twq_init_args);
    init.tqi_version = c.TWQ_SPI_VERSION_CURRENT;
    if (c.syscall(c.SYS_twq_kernreturn, @as(c_int, c.TWQ_OP_INIT), &init, @as(c_int, @sizeOf(@TypeOf(init))), @as(c_int, 0)) < 0) c.atf_tc_fail("TWQ init");
}
fn kernelOp(op: c_int, priority: u32) c_long {
    return c.syscall(c.SYS_twq_kernreturn, op, @as(?*anyopaque, null), @as(c_int, @bitCast(priority)), @as(c_int, 0));
}
const default_priority: u32 = c.TWQ_QOS_CLASS_DEFAULT << 8;
var native_entered: std.atomic.Value(u32) = .init(0);
var native_finished: std.atomic.Value(u32) = .init(0);
var native_running: std.atomic.Value(u32) = .init(0);
var native_peak: std.atomic.Value(u32) = .init(0);
var native_release: std.atomic.Value(bool) = .init(false);
var native_fifo: bool = false;
var native_sched_errors: std.atomic.Value(u32) = .init(0);
fn nativeCallback(_: u64) callconv(.c) void {
    const running = native_running.fetchAdd(1, .seq_cst) + 1;
    _ = native_peak.fetchMax(running, .seq_cst);
    _ = native_entered.fetchAdd(1, .seq_cst);
    if (native_fifo) {
        // Cold workers inherit the FIFO requester's policy. Return them to
        // ordinary scheduling so the observing main thread can run afterward.
        var param = std.mem.zeroes(c.struct_sched_param);
        if (c.pthread_setschedparam(c.pthread_self(), c.SCHED_OTHER, &param) != 0)
            _ = native_sched_errors.fetchAdd(1, .seq_cst);
    }
    // Remain runnable: sleeping here would legitimately admit replacements.
    while (!native_release.load(.seq_cst)) std.atomic.spinLoopHint();
    _ = native_running.fetchSub(1, .seq_cst);
    _ = native_finished.fetchAdd(1, .seq_cst);
}
fn setupNative() void {
    if (c._pthread_workqueue_init(&nativeCallback, 0, 0) != 0) c.atf_tc_fail("native workqueue init");
}
fn requestNative(n: u32) void {
    if (c._pthread_workqueue_addthreads(@intCast(n), default_priority) != 0) c.atf_tc_fail("native workqueue request");
}
fn warmBatch(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const n = readInt("hw.ncpu");
    if (n == 0 or n > 16) c.atf_tc_fail("CPU count");
    setupNative();
    requestNative(n);
    if (!awaitCount(&native_entered, n)) c.atf_tc_fail("warm pool did not enter");
    native_release.store(true, .seq_cst);
    if (!awaitCount(&native_finished, n)) c.atf_tc_fail("warm pool did not finish");
    // Let all N workers return to the kernel/userland idle lists.
    _ = c.usleep(100_000);
    native_release.store(false, .seq_cst);
    native_entered.store(0, .seq_cst);
    native_finished.store(0, .seq_cst);
    native_peak.store(0, .seq_cst);
    requestNative(2 * n);
    const entered = awaitCount(&native_entered, n);
    _ = c.usleep(150_000);
    const held = native_entered.load(.seq_cst);
    const peak = native_peak.load(.seq_cst);
    native_release.store(true, .seq_cst);
    const drained = awaitCount(&native_finished, 2 * n);
    _ = c.printf("twq_warm N=%u expected_held=%u observed_held=%u expected_peak_max=%u observed_peak=%u expected_finished=%u observed_finished=%u\n", n, n, held, n, peak, 2 * n, native_finished.load(.seq_cst));
    if (!entered or held != n or peak > n or !drained) c.atf_tc_fail("idle reuse exceeded constrained allowance or lost work");
}
fn queuedBatches(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const n = readInt("hw.ncpu");
    if (n == 0 or n > 16) c.atf_tc_fail("CPU count");
    // Pin this process to one CPU, then run the requester FIFO while enqueueing.
    // New ordinary workers cannot register until both requests have returned.
    var set: c.cpuset_t = std.mem.zeroes(c.cpuset_t);
    var original: c.cpuset_t = undefined;
    if (c.cpuset_getaffinity(c.CPU_LEVEL_WHICH, c.CPU_WHICH_PID, -1, @sizeOf(c.cpuset_t), &original) != 0) c.atf_tc_fail("get affinity");
    const bytes = std.mem.asBytes(&original);
    var chosen: ?usize = null;
    for (bytes, 0..) |b, i| {
        if (b != 0) {
            chosen = i * 8 + @ctz(b);
            break;
        }
    }
    const cpu = chosen orelse c.atf_tc_fail("empty CPU set");
    std.mem.asBytes(&set)[cpu / 8] |= @as(u8, 1) << @intCast(cpu % 8);
    if (c.cpuset_setaffinity(c.CPU_LEVEL_WHICH, c.CPU_WHICH_PID, -1, @sizeOf(c.cpuset_t), &set) != 0) c.atf_tc_fail("set affinity");
    setupNative();
    native_fifo = true;
    var param = std.mem.zeroes(c.struct_sched_param);
    param.sched_priority = c.sched_get_priority_min(c.SCHED_FIFO);
    if (c.pthread_setschedparam(c.pthread_self(), c.SCHED_FIFO, &param) != 0) c.atf_tc_fail("FIFO requester");
    requestNative(n);
    requestNative(n);
    const before = native_entered.load(.seq_cst);
    param.sched_priority = 0;
    if (c.pthread_setschedparam(c.pthread_self(), c.SCHED_OTHER, &param) != 0) c.atf_tc_fail("restore scheduling");
    const entered = awaitCount(&native_entered, n);
    _ = c.usleep(150_000);
    const held = native_entered.load(.seq_cst);
    const peak = native_peak.load(.seq_cst);
    native_release.store(true, .seq_cst);
    const drained = awaitCount(&native_finished, 2 * n);
    _ = c.cpuset_setaffinity(c.CPU_LEVEL_WHICH, c.CPU_WHICH_PID, -1, @sizeOf(c.cpuset_t), &original);
    _ = c.printf("twq_queued N=%u expected_registered_before=0 observed_callbacks_before=%u expected_held=%u observed_held=%u expected_peak_max=%u observed_peak=%u observed_finished=%u\n", n, before, n, held, n, peak, native_finished.load(.seq_cst));
    if (before != 0 or !entered or held != n or peak > n or !drained or native_sched_errors.load(.seq_cst) != 0) c.atf_tc_fail("outstanding requests reused allowance");
}
const MoveGate = struct {
    registered: std.atomic.Value(u32) = .init(0),
    start: std.atomic.Value(bool) = .init(false),
    moved: std.atomic.Value(u32) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
};
const MoveArg = struct { gate: *MoveGate, from: u32, to: u32, op: c_int };
fn moveWorker(p: ?*anyopaque) callconv(.c) ?*anyopaque {
    const a: *MoveArg = @ptrCast(@alignCast(p.?));
    if (kernelOp(c.TWQ_OP_THREAD_ENTER, a.from) != 0) {
        _ = a.gate.failures.fetchAdd(1, .seq_cst);
        return null;
    }
    _ = a.gate.registered.fetchAdd(1, .seq_cst);
    while (!a.gate.start.load(.seq_cst)) _ = c.usleep(1000);
    var rc: c_long = undefined;
    if (a.op == c.TWQ_OP_THREAD_TRANSFER) {
        var transfer = std.mem.zeroes(c.struct_twq_thread_transfer_args);
        transfer.tqt_version = c.TWQ_THREAD_TRANSFER_VERSION;
        transfer.tqt_from_priority = a.from;
        transfer.tqt_to_priority = a.to;
        rc = c.syscall(c.SYS_twq_kernreturn, a.op, &transfer, @as(c_int, @sizeOf(@TypeOf(transfer))), @as(c_int, 0));
    } else rc = kernelOp(a.op, a.to);
    if (rc == 0) {
        _ = a.gate.moved.fetchAdd(1, .seq_cst);
    } else {
        _ = a.gate.failures.fetchAdd(1, .seq_cst);
    }
    while (!a.gate.release.load(.seq_cst)) _ = c.usleep(1000);
    return null;
}
fn laneMoves(_: [*c]const c.atf_tc_t) callconv(.c) void {
    initKernel();
    for ([_]c_int{ c.TWQ_OP_THREAD_ENTER, c.TWQ_OP_THREAD_RETURN, c.TWQ_OP_THREAD_TRANSFER }) |op| {
        var gate: MoveGate = .{};
        const cap = @min(laneCap(), procCap() / 2);
        const oc: u32 = if (cap < laneCap()) c.TWQ_PRIORITY_OVERCOMMIT_FLAG else 0;
        const threads = storage(c.pthread_t, 2 * cap);
        defer std.heap.page_allocator.free(threads);
        const args = storage(MoveArg, threads.len);
        defer std.heap.page_allocator.free(args);
        const lanes = [_]u32{ default_priority | oc, (c.TWQ_QOS_CLASS_UTILITY << 8) | oc };

        for (threads, args, 0..) |*thread, *arg, i| {
            const lane = i / cap;
            arg.* = .{ .gate = &gate, .from = lanes[lane], .to = lanes[1 - lane], .op = op };
            if (c.pthread_create(thread, null, &moveWorker, arg) != 0) c.atf_tc_fail("move worker create");
        }
        if (!awaitCount(&gate.registered, threads.len)) c.atf_tc_fail("saturated move setup");
        gate.start.store(true, .seq_cst);
        // No thread exits/releases its destination registration until all move.
        const completed = awaitCount(&gate.moved, threads.len);
        gate.release.store(true, .seq_cst);
        if (!completed) c.atf_tc_fail("saturated lane moves did not complete");
        for (threads) |thread| if (c.pthread_join(thread, null) != 0) c.atf_tc_fail("move join");
        _ = c.printf("twq_moves op=%d expected_registered=%zu observed_registered=%u expected_moved=%zu observed_moved=%u failures=%u\n", op, threads.len, gate.registered.load(.seq_cst), threads.len, gate.moved.load(.seq_cst), gate.failures.load(.seq_cst));
        if (gate.failures.load(.seq_cst) != 0) c.atf_tc_fail("move syscall failed");
    }
}
var cap_threads: []c.pthread_t = &.{};
var main_thread: c.pthread_t = undefined;
var signal_seen: std.atomic.Value(u32) = .init(0);
var cap_gate: PoolGate = .{};
fn signalHandler(_: c_int) callconv(.c) void {
    const self = c.pthread_self();
    if (self == main_thread) return;
    for (cap_threads) |t| if (self == t) return;
    _ = signal_seen.fetchAdd(1, .seq_cst);
}
fn idleHolder(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (kernelOp(c.TWQ_OP_THREAD_ENTER, default_priority) != 0 or kernelOp(c.TWQ_OP_THREAD_RETURN, default_priority) != 0) {
        _ = cap_gate.failures.fetchAdd(1, .seq_cst);
        return null;
    }
    _ = cap_gate.entered.fetchAdd(1, .seq_cst);
    while (!cap_gate.released.load(.seq_cst)) _ = c.usleep(1000);
    return null;
}
fn signalCapacity(_: [*c]const c.atf_tc_t) callconv(.c) void {
    initKernel();
    main_thread = c.pthread_self();
    var action = std.mem.zeroes(c.struct_sigaction);
    action.__sigaction_u.__sa_handler = &signalHandler;
    _ = c.sigemptyset(&action.sa_mask);
    if (c.sigaction(c.SIGUSR1, &action, null) != 0) c.atf_tc_fail("sigaction");
    cap_threads = storage(c.pthread_t, laneCap());
    defer std.heap.page_allocator.free(cap_threads);
    for (cap_threads) |*t| if (c.pthread_create(t, null, &idleHolder, null) != 0) c.atf_tc_fail("idle holder create");
    if (!awaitCount(&cap_gate.entered, cap_threads.len)) c.atf_tc_fail("idle capacity setup");
    var mask: c.sigset_t = undefined;
    _ = c.sigemptyset(&mask);
    _ = c.sigaddset(&mask, c.SIGUSR1);
    // Only the reaper inherits the blocked mask. The future claimed worker
    // inherits the unblocked mask, so its handler can be identified uniquely.
    if (c.pthread_sigmask(c.SIG_BLOCK, &mask, null) != 0) c.atf_tc_fail("block reaper signal");
    setupNative();
    if (c.pthread_sigmask(c.SIG_UNBLOCK, &mask, null) != 0) c.atf_tc_fail("unblock worker signal");
    requestNative(1);
    _ = c.usleep(100_000);
    if (native_entered.load(.seq_cst) != 0) c.atf_tc_fail("callback bypassed held capacity");
    if (c.thr_kill(-1, c.SIGUSR1) != 0) c.atf_tc_fail("directed signal broadcast");
    const handled = awaitCount(&signal_seen, 1);
    const before = native_entered.load(.seq_cst);
    cap_gate.released.store(true, .seq_cst);
    for (cap_threads) |t| if (c.pthread_join(t, null) != 0) c.atf_tc_fail("holder join");
    native_release.store(true, .seq_cst);
    const drained = awaitCount(&native_finished, 1);
    _ = c.usleep(100_000);
    _ = c.printf("twq_signal expected_handler=1 observed_handler=%u expected_before_release=0 observed_before_release=%u expected_finished=1 observed_finished=%u\n", signal_seen.load(.seq_cst), before, native_finished.load(.seq_cst));
    if (!handled or before != 0 or !drained or native_entered.load(.seq_cst) != 1 or cap_gate.failures.load(.seq_cst) != 0) c.atf_tc_fail("capacity signal or claimed callback recovery");
}
fn exitCapacity(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork");
    if (pid == 0) {
        initKernel();
        var gate: PoolGate = .{};
        const cap = laneCap();
        const threads = storage(c.pthread_t, cap + 8);
        const args = storage(PoolWorker, threads.len);
        for (threads, args, 0..) |*t, *a, i| {
            a.* = .{ .gate = &gate, .priority = default_priority };
            if (c.pthread_create(t, null, &poolWorker, a) != 0) c._exit(2);
            if (i < cap and !awaitCount(&gate.entered, @intCast(i + 1))) c._exit(3);
        }
        if (!awaitCount(&gate.attempted, threads.len)) c._exit(4);
        _ = c.usleep(100_000);
        if (gate.entered.load(.seq_cst) != cap) c._exit(5);
        c._exit(0);
    }
    var status: c_int = 0;
    const start = now();
    var rc: c_int = 0;
    while (now() - start < ten_seconds) {
        rc = c.waitpid(pid, &status, c.WNOHANG);
        if (rc != 0) break;
        _ = c.usleep(1000);
    }
    const elapsed = now() - start;
    if (rc == 0) {
        _ = c.kill(pid, c.SIGKILL);
        c.atf_tc_fail("capacity child exit timed out");
    }
    _ = c.printf("twq_exit expected_reaped=%d observed_reaped=%d expected_status=0 observed_status=%d expected_ms_max=10000 observed_ms=%lld\n", pid, rc, status, @as(c_longlong, @divTrunc(elapsed, 1_000_000)));
    if (rc != pid or status != 0) c.atf_tc_fail("capacity child exit failed");
}
var cases: [9]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "60");
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "TWQ admission, bounded migration and interruptible capacity waits");
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(t)), "queued_batches"))
        _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "default_lane", "overcommit_lane", "bounded_waiters", "process_bound", "warm_batch", "queued_batches", "lane_moves", "signal_capacity", "exit_capacity" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &defaultLane, &overcommitLane, &boundedWaiters, &processBound, &warmBatch, &queuedBatches, &laneMoves, &signalCapacity, &exitCapacity };
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
