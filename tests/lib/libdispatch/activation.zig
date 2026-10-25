// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("dlfcn.h");
    @cInclude("sys/wait.h");
    @cInclude("errno.h");
});
const Object = ?*anyopaque;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_async_f(Object, Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_sync_f(Object, Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_suspend(Object) void;
extern fn dispatch_resume(Object) void;
extern fn dispatch_queue_attr_make_with_qos_class(Object, c_uint, c_int) Object;
extern fn dispatch_queue_get_qos_class(Object, *c_int) c_uint;
extern fn dispatch_queue_create_with_target([*:0]const u8, Object, Object) Object;
extern fn dispatch_set_target_queue(Object, Object) void;
extern fn dispatch_release(Object) void;
extern fn dispatch_set_context(Object, Object) void;
extern fn dispatch_source_create(*const anyopaque, usize, usize, Object) Object;
extern fn dispatch_source_set_event_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_set_cancel_handler_f(Object, *const fn (Object) callconv(.c) void) void;
extern fn dispatch_source_merge_data(Object, usize) void;
extern fn dispatch_source_cancel(Object) void;
extern const _dispatch_source_type_data_add: u8;
extern const _dispatch_main_q: u8;
extern fn dispatch_debug(Object, [*:0]const u8, ...) void;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var activate: *const fn (Object) callconv(.c) void = undefined;
var inactive: *const fn (Object) callconv(.c) Object = undefined;
fn setup() void {
    activate = @ptrCast(c.dlsym(c.RTLD_DEFAULT, "dispatch_activate") orelse c.atf_tc_fail("dispatch_activate is missing"));
    inactive = @ptrCast(c.dlsym(c.RTLD_DEFAULT, "dispatch_queue_attr_make_initially_inactive") orelse c.atf_tc_fail("inactive queue attribute is missing"));
}
const State = struct {
    count: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(u32) = .init(0),
    order: [64]u32 = @splat(0),
};
const Item = struct { state: *State, index: u32 };
fn item(ptr: Object) callconv(.c) void {
    const it: *Item = @ptrCast(@alignCast(ptr.?));
    const n = it.state.count.load(.seq_cst);
    if (n < 64) it.state.order[n] = it.index;
    _ = it.state.count.fetchAdd(1, .seq_cst);
}
fn event(ptr: Object) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(ptr.?));
    _ = s.count.fetchAdd(1, .seq_cst);
}
fn cancelled(ptr: Object) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(ptr.?));
    s.cancelled.store(1, .seq_cst);
}
fn barrier(_: Object) callconv(.c) void {}
fn quiet(s: *State) void {
    _ = c.usleep(50000);
    if (s.count.load(.seq_cst) != 0) c.atf_tc_fail("work ran while inactive or suspended");
}
fn wait(s: *State, n: u32) void {
    for (0..5000) |_| {
        if (s.count.load(.seq_cst) == n) return;
        _ = c.usleep(1000);
    }
    c.atf_tc_fail("activated work did not complete");
}
fn queue(inactive_queue: bool) Object {
    return dispatch_queue_create("rmx.activation", if (inactive_queue) inactive(null) else null) orelse c.atf_tc_fail("queue allocation");
}
fn queueInactive(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    const q = queue(true);
    var s = State{};
    dispatch_async_f(q, &s, event);
    quiet(&s);
    activate(q);
    dispatch_sync_f(q, null, barrier);
    if (s.count.load(.seq_cst) != 1) c.atf_tc_fail("queue work count");
    dispatch_release(q);
}
fn fifo(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    const q = queue(true);
    var s = State{};
    var items: [64]Item = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .state = &s, .index = @intCast(i) };
        dispatch_async_f(q, it, item);
    }
    quiet(&s);
    activate(q);
    dispatch_sync_f(q, null, barrier);
    if (s.count.load(.seq_cst) != 64) c.atf_tc_fail("all preactivation blocks run exactly once");
    for (s.order, 0..) |actual, expected| if (actual != expected) c.atf_tc_fail("preactivation FIFO order");
    dispatch_release(q);
}
fn source(s: *State, q: Object) Object {
    const src = dispatch_source_create(&_dispatch_source_type_data_add, 0, 0, q) orelse c.atf_tc_fail("source allocation");
    dispatch_set_context(src, s);
    dispatch_source_set_event_handler_f(src, event);
    dispatch_source_set_cancel_handler_f(src, cancelled);
    dispatch_source_merge_data(src, 1);
    return src;
}
fn finishSource(s: *State, src: Object, q: Object) void {
    dispatch_source_cancel(src);
    for (0..5000) |_| {
        if (s.cancelled.load(.seq_cst) != 0) break;
        _ = c.usleep(1000);
    }
    dispatch_sync_f(q, null, barrier);
    if (s.cancelled.load(.seq_cst) != 1) c.atf_tc_fail("source cancellation");
    dispatch_release(src);
    dispatch_release(q);
}
fn sourceInactive(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    var s = State{};
    const q = queue(false);
    const src = source(&s, q);
    quiet(&s);
    activate(src);
    wait(&s, 1);
    finishSource(&s, src, q);
}
fn attributes(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    // Both composition orders must preserve QoS and initial inactivity.
    const attrs = [_]Object{
        inactive(dispatch_queue_attr_make_with_qos_class(null, 0x11, -1)),
        dispatch_queue_attr_make_with_qos_class(inactive(null), 0x11, -1),
    };
    for (attrs) |attr| {
        const q = dispatch_queue_create("rmx.attributes", attr);
        var priority: c_int = 0;
        if (dispatch_queue_get_qos_class(q, &priority) != 0x11 or priority != -1) c.atf_tc_fail("QoS lost during attribute composition");
        var s = State{};
        dispatch_async_f(q, &s, event);
        quiet(&s);
        activate(q);
        dispatch_sync_f(q, null, barrier);
        if (s.count.load(.seq_cst) != 1) c.atf_tc_fail("attribute composition lost initial inactivity");
        dispatch_release(q);
    }
}
fn targetBeforeActivation(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    const first = queue(false);
    const target = queue(false);
    dispatch_suspend(target);
    const q = dispatch_queue_create_with_target("rmx.target", inactive(null), first);
    var s = State{};
    dispatch_async_f(q, &s, event);
    // Setting the target after submission must still affect pending work.
    dispatch_set_target_queue(q, target);
    activate(q);
    quiet(&s);
    dispatch_resume(target);
    dispatch_sync_f(q, null, barrier);
    if (s.count.load(.seq_cst) != 1) c.atf_tc_fail("target configured before activation was lost");
    dispatch_release(q);
    dispatch_release(target);
    dispatch_release(first);
}
fn noop(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    const q = queue(false);
    var s = State{};
    dispatch_suspend(q);
    dispatch_async_f(q, &s, event);
    activate(q);
    activate(q);
    quiet(&s);
    dispatch_resume(q);
    dispatch_sync_f(q, null, barrier);
    if (s.count.load(.seq_cst) != 1) c.atf_tc_fail("activate consumed an explicit suspension");
    dispatch_release(q);
    const sq = queue(false);
    var ss = State{};
    const src = source(&ss, sq);
    activate(src);
    wait(&ss, 1);
    dispatch_suspend(src);
    ss.count.store(0, .seq_cst);
    dispatch_source_merge_data(src, 1);
    activate(src);
    quiet(&ss);
    dispatch_resume(src);
    wait(&ss, 1);
    finishSource(&ss, src, sq);
}
fn suspensions(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    const q = queue(true);
    var s = State{};
    dispatch_suspend(q);
    dispatch_suspend(q);
    dispatch_async_f(q, &s, event);
    activate(q);
    quiet(&s);
    dispatch_resume(q);
    quiet(&s);
    dispatch_resume(q);
    dispatch_sync_f(q, null, barrier);
    if (s.count.load(.seq_cst) != 1) c.atf_tc_fail("suspension count changed by activation");
    dispatch_release(q);
}
fn resumeActivation(_: [*c]const c.atf_tc_t) callconv(.c) void {
    setup();
    const q = queue(false);
    var s = State{};
    const src = source(&s, q);
    dispatch_suspend(src);
    dispatch_resume(src);
    quiet(&s);
    dispatch_resume(src);
    wait(&s, 1);
    activate(src);
    finishSource(&s, src, q);
}
fn logging(want_file: bool) void {
    var gate: [2]c_int = undefined;
    if (c.pipe(&gate) != 0) c.atf_tc_fail("logging pipe");
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(gate[0]);
        _ = c.close(gate[1]);
        c.atf_tc_fail("fork");
    }
    if (pid == 0) {
        _ = c.close(gate[1]);
        var token: u8 = 0;
        var received = c.read(gate[0], &token, 1);
        while (received < 0 and c.__error().* == c.EINTR) received = c.read(gate[0], &token, 1);
        _ = c.close(gate[0]);
        if (received != 1 or token != 1) c._exit(2);
        if (want_file) {
            _ = c.setenv("LIBDISPATCH_LOG", "file", 1);
        } else {
            _ = c.unsetenv("LIBDISPATCH_LOG");
        }
        const q: Object = @ptrCast(@constCast(&_dispatch_main_q));
        dispatch_debug(q, "%s", @as([*:0]const u8, "release logging fixture"));
        c._exit(0);
    }
    _ = c.close(gate[0]);
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "/var/tmp/libdispatch.{d}.log", .{pid}) catch unreachable;
    // PID reuse must not make either logging mode depend on an earlier run.
    const removed = c.unlink(path.ptr) == 0 or c.__error().* == c.ENOENT;
    const token: u8 = 1;
    var released = if (removed) c.write(gate[1], &token, 1) else -1;
    while (released < 0 and removed and c.__error().* == c.EINTR) released = c.write(gate[1], &token, 1);
    _ = c.close(gate[1]);
    var status: c_int = 0;
    const waited = c.waitpid(pid, &status, 0);
    if (!removed) c.atf_tc_fail("remove stale logging file");
    if (released != 1) c.atf_tc_fail("release logging child");
    if (waited != pid or status != 0) c.atf_tc_fail("logging child failed");
    const exists = c.access(path.ptr, c.F_OK) == 0;
    _ = c.unlink(path.ptr);
    if (exists != want_file) c.atf_tc_fail("default logging must be off; explicit file logging must work");
}
fn logDefault(_: [*c]const c.atf_tc_t) callconv(.c) void {
    logging(false);
}
fn logFile(_: [*c]const c.atf_tc_t) callconv(.c) void {
    logging(true);
}
const names = [_][*:0]const u8{ "queue_inactive", "queue_fifo", "source_inactive", "active_noop", "suspend_counts", "resume_activation", "attributes", "target_before_activation", "logging_default", "logging_file" };
const bodies = .{ &queueInactive, &fifo, &sourceInactive, &noop, &suspensions, &resumeActivation, &attributes, &targetBeforeActivation, &logDefault, &logFile };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "20");
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
