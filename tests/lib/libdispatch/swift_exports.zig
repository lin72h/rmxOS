// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("dlfcn.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/mman.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("pthread.h");
});
const Object = ?*anyopaque;
const Fn = *const fn (Object) callconv(.c) void;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_queue_attr_make_with_qos_class(Object, c_uint, c_int) Object;
extern fn dispatch_queue_attr_make_with_overcommit(Object, bool) Object;
extern fn dispatch_queue_attr_make_initially_inactive(Object) Object;
extern fn dispatch_queue_get_qos_class(Object, *c_int) c_uint;
extern fn dispatch_activate(Object) void;
extern fn dispatch_async_f(Object, Object, Fn) void;
extern fn dispatch_sync_f(Object, Object, Fn) void;
extern fn dispatch_barrier_async_f(Object, Object, Fn) void;
extern fn dispatch_barrier_sync_f(Object, Object, Fn) void;
extern fn dispatch_retain(Object) void;
extern fn dispatch_release(Object) void;
extern fn dispatch_suspend(Object) void;
extern fn dispatch_resume(Object) void;
extern fn dispatch_set_context(Object, Object) void;
extern fn dispatch_source_create(*const anyopaque, usize, usize, Object) Object;
extern fn dispatch_source_set_event_handler_f(Object, Fn) void;
extern fn dispatch_source_set_cancel_handler_f(Object, Fn) void;
extern fn dispatch_source_get_data(Object) usize;
extern fn dispatch_source_merge_data(Object, usize) void;
extern fn dispatch_source_cancel(Object) void;
extern fn dispatch_data_create(?*const anyopaque, usize, Object, Object) Object;
extern fn dispatch_data_get_size(Object) usize;
extern const _dispatch_queue_attr_concurrent: u8;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn symbol(name: [*:0]const u8) *anyopaque {
    return c.dlsym(c.RTLD_DEFAULT, name) orelse c.atf_tc_fail("missing API: %s", name);
}
const State = struct {
    count: std.atomic.Value(u32) = .init(0),
    value: std.atomic.Value(usize) = .init(0),
    cancelled: std.atomic.Value(u32) = .init(0),
    source: Object = null,
};
fn increment(p: Object) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(p.?));
    _ = s.count.fetchAdd(1, .seq_cst);
}
fn held(p: Object) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(p.?));
    _ = s.count.fetchAdd(1, .seq_cst);
    while (s.value.load(.seq_cst) == 0) _ = c.usleep(1000);
}
fn barrier(_: Object) callconv(.c) void {}
fn wait(s: *State, count: u32) void {
    for (0..2000) |_| {
        if (s.count.load(.seq_cst) == count) return;
        _ = c.usleep(1000);
    }
    c.atf_tc_fail("callback count expected=%u observed=%u", count, s.count.load(.seq_cst));
}
fn autorelease(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const make: *const fn (Object, c_ulong) callconv(.c) Object = @ptrCast(symbol("dispatch_queue_attr_make_with_autorelease_frequency"));
    const concurrent: Object = @ptrCast(@constCast(&_dispatch_queue_attr_concurrent));
    for (0..3) |frequency| {
        for (0..2) |order| {
            var attr = if (order == 0) make(concurrent, @intCast(frequency)) else concurrent;
            if (attr == null) c.atf_tc_fail("valid frequency rejected");
            attr = dispatch_queue_attr_make_with_qos_class(attr, 0x15, -3);
            attr = dispatch_queue_attr_make_with_overcommit(attr, true);
            attr = dispatch_queue_attr_make_initially_inactive(attr);
            if (order == 1) attr = make(attr, @intCast(frequency));
            if (attr == null) c.atf_tc_fail("composed attribute rejected");
            const q = dispatch_queue_create("rmx.autorelease", attr);
            if (q == null) c.atf_tc_fail("queue allocation");
            var priority: c_int = 0;
            if (dispatch_queue_get_qos_class(q, &priority) != 0x15 or priority != -3) c.atf_tc_fail("frequency lost QoS/priority");
            var state = State{};
            dispatch_async_f(q, &state, increment);
            _ = c.usleep(10000);
            if (state.count.load(.seq_cst) != 0) c.atf_tc_fail("frequency lost inactive attribute");
            dispatch_activate(q);
            dispatch_barrier_sync_f(q, null, barrier);
            if (state.count.load(.seq_cst) != 1) c.atf_tc_fail("queue work did not run once");
            dispatch_async_f(q, &state, held);
            dispatch_async_f(q, &state, held);
            wait(&state, 3); // two overlapping items prove concurrent composition
            state.value.store(1, .seq_cst);
            dispatch_barrier_sync_f(q, null, barrier);
            dispatch_release(q);
        }
        const serial = make(null, @intCast(frequency));
        if (serial == null) c.atf_tc_fail("default serial attribute rejected");
        const q = dispatch_queue_create("rmx.autorelease.serial", serial);
        var serial_state = State{};
        dispatch_async_f(q, &serial_state, held);
        dispatch_async_f(q, &serial_state, held);
        wait(&serial_state, 1);
        _ = c.usleep(10000);
        if (serial_state.count.load(.seq_cst) != 1) c.atf_tc_fail("frequency lost serial default");
        serial_state.value.store(1, .seq_cst);
        dispatch_sync_f(q, null, barrier);
        if (serial_state.count.load(.seq_cst) != 2) c.atf_tc_fail("serial work count");
        dispatch_release(q);
    }
    if (make(null, 3) != null or make(null, std.math.maxInt(c_ulong)) != null) c.atf_tc_fail("invalid frequency accepted");
}
var assert_barrier: *const fn (Object) callconv(.c) void = undefined;
fn assertInside(p: Object) callconv(.c) void {
    assert_barrier(p);
}
fn childAssertion(mode: u8) void {
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork");
    if (pid == 0) {
        const limit = c.struct_rlimit{ .rlim_cur = 0, .rlim_max = 0 };
        _ = c.setrlimit(c.RLIMIT_CORE, &limit);
        const attr: Object = if (mode != 0) @ptrCast(@constCast(&_dispatch_queue_attr_concurrent)) else null;
        const q = dispatch_queue_create("rmx.assert.child", attr);
        if (q == null) c._exit(23);
        if (mode == 0) {
            assert_barrier(q);
        } else if (mode == 1) {
            dispatch_sync_f(q, q, assertInside);
        } else {
            dispatch_async_f(q, q, assertInside);
            _ = c.usleep(2_000_000);
        }
        c._exit(24); // returning from a failed assertion is a failure
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) c.atf_tc_fail("waitpid");
    if (!c.WIFSIGNALED(status) or (c.WTERMSIG(status) != c.SIGILL and c.WTERMSIG(status) != c.SIGTRAP)) c.atf_tc_fail("assertion child expected=SIGILL/SIGTRAP observed_status=%d", status);
}
fn resumeLater(q: Object) callconv(.c) Object {
    _ = c.usleep(20000);
    dispatch_resume(q);
    return null;
}
fn assertAsync(p: Object) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(p.?));
    assert_barrier(s.source);
    _ = s.count.fetchAdd(1, .seq_cst);
}
fn queueBarrier(_: [*c]const c.atf_tc_t) callconv(.c) void {
    assert_barrier = @ptrCast(symbol("dispatch_assert_queue_barrier"));
    // Fork before this parent starts any queue work.
    childAssertion(0);
    childAssertion(1);
    childAssertion(2);
    const serial = dispatch_queue_create("rmx.assert.serial", null);
    dispatch_sync_f(serial, serial, assertInside);
    dispatch_release(serial);
    const q = dispatch_queue_create("rmx.assert.concurrent", @ptrCast(@constCast(&_dispatch_queue_attr_concurrent)));
    dispatch_barrier_sync_f(q, q, assertInside);
    var state = State{ .source = q };
    dispatch_barrier_async_f(q, &state, assertAsync);
    wait(&state, 1);
    dispatch_suspend(q);
    var thread: c.pthread_t = undefined;
    if (c.pthread_create(&thread, null, resumeLater, q) != 0) c.atf_tc_fail("pthread_create");
    dispatch_barrier_sync_f(q, q, assertInside); // forced suspended/slow handoff
    if (c.pthread_join(thread, null) != 0) c.atf_tc_fail("pthread_join");
    dispatch_release(q);
}
fn replaced(p: Object) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(p.?));
    s.value.store(dispatch_source_get_data(s.source), .seq_cst);
    _ = s.count.fetchAdd(1, .seq_cst);
}
fn cancelled(p: Object) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(p.?));
    s.cancelled.store(1, .seq_cst);
}
fn replace(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const kind = symbol("_dispatch_source_type_data_replace");
    const q = dispatch_queue_create("rmx.replace", null);
    var s = State{};
    s.source = dispatch_source_create(kind, 0, 0, q);
    if (s.source == null) c.atf_tc_fail("source allocation");
    if (dispatch_source_create(kind, 1, 0, q) != null or dispatch_source_create(kind, 0, 1, q) != null) c.atf_tc_fail("replace accepted nonzero handle/mask");
    dispatch_set_context(s.source, &s);
    dispatch_source_set_event_handler_f(s.source, replaced);
    dispatch_source_set_cancel_handler_f(s.source, cancelled);
    dispatch_source_merge_data(s.source, 3);
    dispatch_source_merge_data(s.source, 0);
    dispatch_activate(s.source);
    _ = c.usleep(20000);
    if (s.count.load(.seq_cst) != 0) c.atf_tc_fail("zero replacement must suppress pending delivery");
    dispatch_suspend(s.source);
    dispatch_source_merge_data(s.source, 2);
    dispatch_source_merge_data(s.source, 4);
    const latest: usize = 0x100000009;
    dispatch_source_merge_data(s.source, latest);
    dispatch_resume(s.source);
    wait(&s, 1);
    if (s.value.load(.seq_cst) != latest) c.atf_tc_fail("replace expected=%lu observed=%lu", latest, s.value.load(.seq_cst));
    dispatch_source_merge_data(s.source, 7);
    wait(&s, 2);
    if (s.value.load(.seq_cst) != 7) c.atf_tc_fail("replacement after delivery");
    dispatch_source_cancel(s.source);
    for (0..2000) |_| {
        if (s.cancelled.load(.seq_cst) != 0) break;
        _ = c.usleep(1000);
    }
    if (s.cancelled.load(.seq_cst) != 1) c.atf_tc_fail("source cancel completion");
    dispatch_sync_f(q, null, barrier);
    if (s.count.load(.seq_cst) != 2) c.atf_tc_fail("unexpected duplicate delivery");
    dispatch_release(s.source);
    dispatch_release(q);
}
fn mapped(p: *anyopaque, size: usize) bool {
    var residency: u8 = 0;
    if (c.mincore(p, size, &residency) == 0) return true;
    if (c.__error().* != c.ENOMEM) c.atf_tc_fail("mincore unexpected errno=%d", c.__error().*);
    return false;
}
fn munmapData(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const global: *const Object = @ptrCast(@alignCast(symbol("_dispatch_data_destructor_munmap")));
    const page: usize = @intCast(c.getpagesize());
    const memory = c.mmap(null, 2 * page, c.PROT_READ | c.PROT_WRITE, c.MAP_ANON | c.MAP_PRIVATE, -1, 0);
    if (memory == c.MAP_FAILED or memory == null) c.atf_tc_fail("mmap");
    const second: *anyopaque = @ptrFromInt(@intFromPtr(memory.?) + page);
    if (!mapped(memory.?, page) or !mapped(second, page)) c.atf_tc_fail("initial mapping missing");
    const data = dispatch_data_create(memory, 2 * page, null, global.*);
    if (data == null or dispatch_data_get_size(data) != 2 * page) c.atf_tc_fail("dispatch data creation");
    dispatch_retain(data);
    dispatch_release(data);
    if (!mapped(memory.?, page) or !mapped(second, page)) c.atf_tc_fail("mapping released before final data release");
    dispatch_release(data);
    for (0..2000) |_| {
        if (!mapped(memory.?, page) and !mapped(second, page)) return;
        _ = c.usleep(1000);
    }
    c.atf_tc_fail("MUNMAP destructor did not unmap both pages");
}
const names = [_][*:0]const u8{ "autorelease_frequency", "assert_queue_barrier", "data_replace", "data_munmap" };
const bodies = .{ &autorelease, &queueBarrier, &replace, &munmapData };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "10");
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
