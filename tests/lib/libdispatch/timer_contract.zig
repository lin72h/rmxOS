// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("dlfcn.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern const _dispatch_source_type_timer: u8;
extern fn dispatch_queue_create([*:0]const u8, ?*anyopaque) ?*anyopaque;
extern fn dispatch_source_create(*const anyopaque, usize, usize, ?*anyopaque) ?*anyopaque;
extern fn dispatch_set_context(?*anyopaque, ?*anyopaque) void;
extern fn dispatch_source_set_event_handler_f(?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_source_set_cancel_handler_f(?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_source_set_timer(?*anyopaque, u64, u64, u64) void;
extern fn dispatch_time(u64, i64) u64;
extern fn dispatch_resume(?*anyopaque) void;
extern fn dispatch_source_cancel(?*anyopaque) void;
extern fn dispatch_release(?*anyopaque) void;
const Context = struct {
    source: ?*anyopaque = null,
    fired: std.atomic.Value(i64) = .init(0),
    canceled: std.atomic.Value(bool) = .init(false),
};
fn now() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) c.atf_tc_fail("clock");
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}
fn fire(p: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(p.?));
    ctx.fired.store(now(), .seq_cst);
    dispatch_source_cancel(ctx.source);
}
fn cancel(p: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(p.?));
    ctx.canceled.store(true, .seq_cst);
}
fn timers(flags: []const usize) void {
    var contexts: [4]Context = .{ .{}, .{}, .{}, .{} };
    var targets: [4]i64 = undefined;
    const queue = dispatch_queue_create("rmx.timer.contract", null) orelse c.atf_tc_fail("queue");
    const origin = now();
    // 50ms allows five 10ms kernel ticks and queue handoff; it is below
    // the base normal-class batching displacement of 160ms in this fixture.
    const tolerance = 50_000_000;
    for (flags, 0..) |flag, i| {
        const delta: i64 = 400_000_000 + @as(i64, @intCast(i)) * 80_000_000;
        targets[i] = origin + delta;
        const ctx = &contexts[i];
        ctx.source = dispatch_source_create(@ptrCast(&_dispatch_source_type_timer), 0, flag, queue) orelse c.atf_tc_fail("timer flag=%zu rejected", flag);
        dispatch_set_context(ctx.source, ctx);
        dispatch_source_set_event_handler_f(ctx.source, &fire);
        dispatch_source_set_cancel_handler_f(ctx.source, &cancel);
        const remaining = targets[i] - now();
        if (remaining <= 0) c.atf_tc_fail("fixture setup missed target");
        dispatch_source_set_timer(ctx.source, dispatch_time(0, remaining), std.math.maxInt(u64), 2_000_000_000);
        dispatch_resume(ctx.source);
    }
    const stop = now() + 5_000_000_000;
    for (contexts[0..flags.len]) |*ctx| {
        while (!ctx.canceled.load(.seq_cst) and now() < stop) _ = c.usleep(1000);
        if (!ctx.canceled.load(.seq_cst)) c.atf_tc_fail("timer did not fire/cancel");
    }
    var failures: usize = 0;
    for (contexts[0..flags.len], 0..) |*ctx, i| {
        const lateness = ctx.fired.load(.seq_cst) - targets[i];
        _ = c.printf("timer flag=%zu target_ns=%lld observed_ns=%lld tolerance_ns=%lld lateness_ns=%lld\n", flags[i], targets[i], ctx.fired.load(.seq_cst), @as(i64, tolerance), lateness);
        if (lateness < -1_000_000 or lateness > tolerance) failures += 1;
        dispatch_release(ctx.source);
    }
    dispatch_release(queue);
    if (failures != 0) c.atf_tc_fail("%zu timers moved from target beyond 50ms tolerance", failures);
}
fn targetDeadlines(_: [*c]const c.atf_tc_t) callconv(.c) void {
    timers(&.{ 0, 0, 0 });
}
fn acceptedFlags(_: [*c]const c.atf_tc_t) callconv(.c) void {
    timers(&.{ 0, 1, 2, 3 });
}
fn symbols(_: [*c]const c.atf_tc_t) callconv(.c) void {
    if (c.dlsym(c.RTLD_DEFAULT, "_dispatch_source_type_sock") != null) c.atf_tc_fail("empty socket source exported");
}
const names = .{ "target_deadlines", "accepted_flags", "absent_socket" };
const bodies = .{ &targetDeadlines, &acceptedFlags, &symbols };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (names, bodies, 0..) |name, body, i| {
        var err = c.atf_tc_init(&cases[i], name, &head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
