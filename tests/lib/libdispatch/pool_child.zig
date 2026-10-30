// SPDX-License-Identifier: BSD-2-Clause
// Worker-pool shapes from swift-corelibs-libdispatch 6.4.0's C tests, one
// per process, for pool_test.
//   global, concurrent: dispatch_concur's async shape. One submitter on the
//     queue asyncs 4 items of usleep(1000), then sleeps 10 ms; all 4 must
//     complete during that sleep (the pool grows while its worker sleeps).
//     "global" uses the default global queue, "concurrent" a
//     DISPATCH_QUEUE_CONCURRENT queue.
//   rendezvous: dispatch_readsync's start. 64 blocks on the high-priority
//     overcommit global queue each wait until all 64 are running; all must
//     be running at once within 5 s.
//   quiet: a program that starts a global queue makes no syslog(3) or
//     simple ASL call: this program defines them, so libdispatch's calls
//     bind here and are counted.
//   logged: the control for quiet: dispatch_debug does log, and the call
//     reaches this program's definitions.
// The child prints the libthr and libdispatch it bound, one line per check,
// and exits 0 only when every check holds.
const std = @import("std");
const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const Object = ?*anyopaque;
const Fn = *const fn (Object) callconv(.c) void;
extern fn dispatch_get_global_queue(c_long, c_ulong) Object;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_async_f(Object, Object, Fn) void;
extern fn dispatch_group_create() Object;
extern fn dispatch_group_async_f(Object, Object, Object, Fn) void;
extern fn dispatch_group_wait(Object, u64) c_long;
extern fn dispatch_time(u64, i64) u64;
extern const _dispatch_queue_attr_concurrent: u8;
extern fn dispatch_debug(Object, [*:0]const u8, ...) void;

const ms: i64 = 1_000_000;
const items = 4;
const rendezvous_count = 64;
var failed = false;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = c.write(1, text.ptr, text.len);
}
fn check(ok: bool, comptime name: []const u8) void {
    say("check {s} {s}", .{ name, if (ok) "ok" else "FAIL" });
    if (!ok) failed = true;
}
fn now_us() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1_000_000 + @divTrunc(ts.tv_nsec, 1000);
}
fn bound(comptime symbol: [*:0]const u8, comptime label: []const u8) void {
    const p = c.dlsym(c.RTLD_DEFAULT, symbol) orelse return;
    var info: c.Dl_info = undefined;
    if (c.dladdr(p, &info) != 0 and info.dli_fname != null)
        say(label ++ "={s}", .{std.mem.span(info.dli_fname)});
}

// dispatch_concur's async shape.
var done = std.atomic.Value(u32).init(0);
var during_sleep = std.atomic.Value(u32).init(0);
var group: Object = null;
var target: Object = null;
fn work(_: Object) callconv(.c) void {
    _ = c.usleep(1000);
    _ = done.fetchAdd(1, .seq_cst);
}
fn submit(_: Object) callconv(.c) void {
    for (0..items) |_| dispatch_group_async_f(group, target, null, work);
    const slept = now_us();
    _ = c.usleep(10_000);
    during_sleep.store(done.load(.seq_cst), .seq_cst);
    say("submitter slept_us={d} completed_during_sleep={d}", .{ now_us() - slept, during_sleep.load(.seq_cst) });
}
fn concur(q: Object) void {
    group = dispatch_group_create();
    target = q;
    dispatch_group_async_f(group, q, null, submit);
    check(dispatch_group_wait(group, dispatch_time(0, 5000 * ms)) == 0, "all_items_finish");
    check(during_sleep.load(.seq_cst) == items, "all_4_complete_while_submitter_sleeps");
}

// dispatch_readsync's start.
var running = std.atomic.Value(u32).init(0);
var peak = std.atomic.Value(u32).init(0);
var started_us: i64 = 0;
var reached_us = std.atomic.Value(i64).init(0);
fn meet(_: Object) callconv(.c) void {
    const n = running.fetchAdd(1, .seq_cst) + 1;
    _ = peak.fetchMax(n, .seq_cst);
    if (n == rendezvous_count) reached_us.store(now_us() - started_us, .seq_cst);
    const give_up = now_us() + 5_000_000;
    while (running.load(.seq_cst) < rendezvous_count and now_us() < give_up) _ = c.usleep(10_000);
}
fn rendezvous() void {
    const q = dispatch_get_global_queue(2, 2); // HIGH, OVERCOMMIT
    const g = dispatch_group_create();
    started_us = now_us();
    for (0..rendezvous_count) |_| dispatch_group_async_f(g, q, null, meet);
    check(dispatch_group_wait(g, dispatch_time(0, 10_000 * ms)) == 0, "all_blocks_return");
    const reached = reached_us.load(.seq_cst);
    say("rendezvous peak_running={d} reached_us={d}", .{ peak.load(.seq_cst), reached });
    check(peak.load(.seq_cst) == rendezvous_count and reached > 0 and reached <= 5_000_000, "all_64_running_within_5s");
}

// Calls from libdispatch to the logging entry points bind to these.
var log_calls = std.atomic.Value(u32).init(0);
export fn _simple_asl_log(_: c_int, _: ?[*:0]const u8, _: ?[*:0]const u8) void {
    _ = log_calls.fetchAdd(1, .seq_cst);
}
export fn syslog(_: c_int, _: ?[*:0]const u8, ...) callconv(.c) void {
    _ = log_calls.fetchAdd(1, .seq_cst);
}
export fn vsyslog(_: c_int, _: ?[*:0]const u8, _: ?*anyopaque) void {
    _ = log_calls.fetchAdd(1, .seq_cst);
}
fn nop(_: Object) callconv(.c) void {}
fn quiet() void {
    const g = dispatch_group_create();
    dispatch_group_async_f(g, dispatch_get_global_queue(0, 0), null, nop);
    dispatch_group_async_f(g, dispatch_get_global_queue(2, 2), null, nop);
    check(dispatch_group_wait(g, dispatch_time(0, 5000 * ms)) == 0, "global_queue_work_ran");
    say("quiet log_calls={d}", .{log_calls.load(.seq_cst)});
    check(log_calls.load(.seq_cst) == 0, "no_syslog_or_asl_record");
}

fn logged() void {
    dispatch_debug(dispatch_group_create(), "rmx pool_child control");
    say("logged log_calls={d}", .{log_calls.load(.seq_cst)});
    check(log_calls.load(.seq_cst) >= 1, "interposed_log_seen");
}

pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc != 2) return 2;
    const mode = std.mem.span(argv[1]);
    bound("_pthread_workqueue_addthreads", "libthr");
    bound("dispatch_async_f", "libdispatch");
    if (std.mem.eql(u8, mode, "global")) {
        concur(dispatch_get_global_queue(0, 0));
    } else if (std.mem.eql(u8, mode, "concurrent")) {
        concur(dispatch_queue_create("rmx.pool.concurrent", @ptrCast(@constCast(&_dispatch_queue_attr_concurrent))));
    } else if (std.mem.eql(u8, mode, "rendezvous")) {
        rendezvous();
    } else if (std.mem.eql(u8, mode, "quiet")) {
        quiet();
    } else if (std.mem.eql(u8, mode, "logged")) {
        logged();
    } else return 2;
    say("done {s}", .{if (failed) "FAIL" else "ok"});
    return if (failed) 1 else 0;
}
