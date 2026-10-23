// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const Object = ?*anyopaque;
const mono: u64 = 1 << 63;
const wall_now: u64 = ~@as(u64, 1);
const forever = std.math.maxInt(u64);
extern fn dispatch_after_f(u64, Object, Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_time(u64, i64) u64;
extern fn dispatch_walltime(?*const c.struct_timespec, i64) u64;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_source_create(*const anyopaque, usize, usize, Object) Object;
extern fn dispatch_set_context(Object, Object) void;
extern fn dispatch_source_set_event_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_set_cancel_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_set_timer(Object, u64, u64, u64) void;
extern fn dispatch_resume(Object) void;
extern fn dispatch_source_cancel(Object) void;
extern fn dispatch_sync_f(Object, Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_release(Object) void;
extern fn dispatch_semaphore_create(isize) Object;
extern fn dispatch_semaphore_wait(Object, u64) isize;
extern const _dispatch_source_type_timer: u8;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn now(clock: c.clockid_t) u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(clock, &ts) != 0) c.atf_tc_fail("clock_gettime");
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}
fn equal(actual: u64, expected: u64) void {
    if (actual != expected) c.atf_tc_fail("expected=%llu observed=%llu", expected, actual);
}
fn conversions(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const before = now(c.CLOCK_MONOTONIC);
    const deadline = dispatch_time(mono, 200_000_000);
    const after = now(c.CLOCK_MONOTONIC);
    if (deadline < (mono | (before + 200_000_000)) or deadline > (mono | (after + 200_000_000))) c.atf_tc_fail("monotonic NOW does not use CLOCK_MONOTONIC");
    equal(dispatch_time(mono | 1000, 500), mono | 1500);
    equal(dispatch_time(mono | 1000, -500), mono | 500);
    equal(dispatch_time(mono | 1000, -2000), mono | 1);
    equal(dispatch_time(mono | 1000, std.math.minInt(i64)), mono | 1);
    equal(dispatch_time(mono | ((1 << 62) - 2), 2), forever);
    equal(dispatch_time(forever, -100), forever);
}
fn legacy(_: [*c]const c.atf_tc_t) callconv(.c) void {
    equal(dispatch_time(1000, 500), 1500);
    equal(dispatch_time(1000, -2000), 1);
    equal(dispatch_time(1000, std.math.minInt(i64)), 1);
    equal(dispatch_time((1 << 62) - 2, 2), forever);
    const up_before = dispatch_time(0, 0);
    const up = dispatch_time(0, 200_000_000);
    const up_after = dispatch_time(0, 0);
    if (up < up_before + 200_000_000 or up > up_after + 200_000_000) c.atf_tc_fail("uptime NOW conversion");
    const ts = c.struct_timespec{ .tv_sec = 100, .tv_nsec = 123 };
    const w = dispatch_walltime(&ts, 0);
    equal(w, 0 -% @as(u64, 100 * std.time.ns_per_s + 123));
    equal(dispatch_time(w, 500), w - 500);
    equal(dispatch_time(w, -500), w + 500);
    equal(dispatch_time(0 -% @as(u64, 1000), -999), wall_now);
    equal(dispatch_time(w, std.math.minInt(i64)), wall_now);
    const b = dispatch_walltime(null, 200_000_000);
    const n = dispatch_time(wall_now, 200_000_000);
    const a = dispatch_walltime(null, 200_000_000);
    if (n > b or n < a) c.atf_tc_fail("wall NOW must equal dispatch_walltime(NULL, delta)");
}
fn expired(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const sem = dispatch_semaphore_create(0);
    defer dispatch_release(sem);
    const b = now(c.CLOCK_MONOTONIC);
    if (dispatch_semaphore_wait(sem, mono | 1) == 0) c.atf_tc_fail("empty semaphore succeeded");
    if (now(c.CLOCK_MONOTONIC) - b > 100_000_000) c.atf_tc_fail("expired monotonic deadline blocked");
}
const State = struct { fired: std.atomic.Value(u64) = .init(0), cancelled: std.atomic.Value(u32) = .init(0) };
fn cancelled(p: Object) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(p.?));
    state.cancelled.store(1, .seq_cst);
}
fn event(p: Object) callconv(.c) void {
    const value: *State = @ptrCast(@alignCast(p.?));
    value.fired.store(now(c.CLOCK_MONOTONIC), .seq_cst);
}
fn barrier(_: Object) callconv(.c) void {}
fn timer(kind: u8, step: bool) void {
    var state = State{};
    const q = dispatch_queue_create("rmx.time", null);
    const src = dispatch_source_create(&_dispatch_source_type_timer, 0, 0, q);
    if (src == null or q == null) c.atf_tc_fail("timer allocation");
    dispatch_set_context(src, &state);
    dispatch_source_set_cancel_handler_f(src, cancelled);
    dispatch_source_set_event_handler_f(src, event);
    const b = now(c.CLOCK_MONOTONIC);
    const start = switch (kind) {
        0 => dispatch_time(0, 400_000_000),
        1 => mono | (b + 400_000_000), // Swift's literal encoding, independent of dispatch_time
        else => dispatch_walltime(null, 400_000_000),
    };
    dispatch_source_set_timer(src, start, forever, 0);
    dispatch_resume(src);
    var wall_stamp: u64 = 0;
    var stamp: u64 = 0;
    if (step) {
        _ = c.usleep(100_000); // let the manager arm the kernel timer
        wall_stamp = now(c.CLOCK_REALTIME);
        stamp = now(c.CLOCK_MONOTONIC);
        var ts = c.struct_timespec{ .tv_sec = @intCast(wall_stamp / std.time.ns_per_s - 5), .tv_nsec = @intCast(wall_stamp % std.time.ns_per_s) };
        if (c.clock_settime(c.CLOCK_REALTIME, &ts) != 0) c.atf_tc_fail("clock_settime requires disposable guest root");
    }
    while (state.fired.load(.seq_cst) == 0 and now(c.CLOCK_MONOTONIC) - b < std.time.ns_per_s) _ = c.usleep(1000);
    const observed = state.fired.load(.seq_cst);
    // Restore before any assertion, including a missed deadline.
    if (step) {
        const restore = wall_stamp + now(c.CLOCK_MONOTONIC) - stamp;
        var ts = c.struct_timespec{ .tv_sec = @intCast(restore / std.time.ns_per_s), .tv_nsec = @intCast(restore % std.time.ns_per_s) };
        if (c.clock_settime(c.CLOCK_REALTIME, &ts) != 0) c.atf_tc_fail("restore wall clock");
    }
    dispatch_source_cancel(src);
    while (state.cancelled.load(.seq_cst) == 0) _ = c.usleep(1000);
    dispatch_sync_f(q, null, barrier);
    dispatch_release(src);
    dispatch_release(q);
    if (observed == 0) c.atf_tc_fail("timer failed to wake within 1 second");
    const elapsed = observed - b;
    if (elapsed < 350_000_000 or elapsed > 900_000_000) c.atf_tc_fail("deadline expected=400000000ns observed=%lluns", elapsed);
}
fn uptime(_: [*c]const c.atf_tc_t) callconv(.c) void {
    timer(0, false);
}
fn monotonic(_: [*c]const c.atf_tc_t) callconv(.c) void {
    timer(1, false);
}
fn wall(_: [*c]const c.atf_tc_t) callconv(.c) void {
    timer(2, false);
}
fn uptimeStep(_: [*c]const c.atf_tc_t) callconv(.c) void {
    timer(0, true);
}
fn monoStep(_: [*c]const c.atf_tc_t) callconv(.c) void {
    timer(1, true);
}
fn futureWait(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const sem = dispatch_semaphore_create(0);
    defer dispatch_release(sem);
    const b = now(c.CLOCK_MONOTONIC);
    if (dispatch_semaphore_wait(sem, mono | (b + 100_000_000)) == 0) c.atf_tc_fail("empty semaphore succeeded");
    const elapsed = now(c.CLOCK_MONOTONIC) - b;
    if (elapsed < 90_000_000 or elapsed > 900_000_000) c.atf_tc_fail("monotonic wait expected=100000000ns observed=%lluns", elapsed);
}
fn afterWake(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var state = State{};
    const q = dispatch_queue_create("rmx.after", null);
    if (q == null) c.atf_tc_fail("queue allocation");
    const b = now(c.CLOCK_MONOTONIC);
    dispatch_after_f(mono | (b + 200_000_000), q, &state, event);
    while (state.fired.load(.seq_cst) == 0 and now(c.CLOCK_MONOTONIC) - b < std.time.ns_per_s) _ = c.usleep(1000);
    const observed = state.fired.load(.seq_cst);
    if (observed == 0) c.atf_tc_fail("dispatch_after did not wake");
    dispatch_sync_f(q, null, barrier);
    dispatch_release(q);
    if (observed - b < 180_000_000 or observed - b > 900_000_000) c.atf_tc_fail("dispatch_after wake time");
}
const names =
    [_][*:0]const u8{ "monotonic_conversion", "legacy_conversion", "expired_monotonic", "uptime_wake", "monotonic_wake", "wall_wake", "uptime_wall_step", "monotonic_wall_step", "monotonic_wait", "monotonic_after" };
const bodies = .{ &conversions, &legacy, &expired, &uptime, &monotonic, &wall, &uptimeStep, &monoStep, &futureWait, &afterWake };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "5");
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (names, 0..) |name, i| {
        const err = c.atf_tc_init(&cases[i], name, &head, bodies[i], null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
