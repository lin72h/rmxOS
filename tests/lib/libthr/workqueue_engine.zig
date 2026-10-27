// SPDX-License-Identifier: BSD-2-Clause
// Direct libthr engine: deliberately no libdispatch dependency.
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("pthread.h");
    @cInclude("pthread/workqueue_private.h");
    @cInclude("pthread/qos_private.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/thr.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("link.h");
    @cInclude("dlfcn.h");
    @cInclude("sched.h");
    @cInclude("thr_workq_idle.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const A = std.atomic.Value;
var entered: A(u32) = .init(0);
var finished: A(u32) = .init(0);
var running: A(u32) = .init(0);
var peak: A(u32) = .init(0);
var gates: [1024]A(bool) = @splat(.init(false));
var tids: [1024]A(c_long) = @splat(.init(0));
var priorities: [1024]u64 = @splat(0);
var qos: [1024]c_uint = @splat(0);
var policies: [1024]c_int = @splat(0);
var narrow: [1024]bool = @splat(false);
fn now() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) c.atf_tc_fail("clock");
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
}
fn read(comptime T: type, name: [*:0]const u8) T {
    var value: T = 0;
    var len: usize = @sizeOf(T);
    if (c.sysctlbyname(name, &value, &len, null, 0) != 0 or len != @sizeOf(T)) c.atf_tc_fail("sysctl %s", name);
    return value;
}
fn snapshot(label: [*:0]const u8) void {
    _ = c.printf("twq_snapshot %s init=%ld enter=%ld return=%ld request=%ld narrow=%ld cap=%u process_cap=%u\n", label, read(c_long, "kern.twq.init_count"), read(c_long, "kern.twq.thread_enter_count"), read(c_long, "kern.twq.thread_return_count"), read(c_long, "kern.twq.reqthreads_count"), read(c_long, "kern.twq.should_narrow_count"), read(u32, "kern.twq.max_lane_threads"), read(u32, "kern.twq.max_proc_threads"));
    _ = c.fflush(null);
}
fn library(info: [*c]c.struct_dl_phdr_info, _: usize, _: ?*anyopaque) callconv(.c) c_int {
    if (info.*.dlpi_name != null and std.mem.indexOf(u8, std.mem.span(info.*.dlpi_name), "libdispatch") != null) return 1;
    return 0;
}
fn begin() void {
    if (c.dl_iterate_phdr(&library, null) != 0) c.atf_tc_fail("libdispatch loaded in direct engine process");
    snapshot("before");
}
fn callback(p: u64) callconv(.c) void {
    const i = entered.fetchAdd(1, .seq_cst);
    if (i >= tids.len) c._exit(90);
    var tid: c_long = 0;
    _ = c.thr_self(&tid);
    priorities[i] = p;
    qos[i] = c.qos_class_self();
    var param: c.struct_sched_param = undefined;
    if (c.pthread_getschedparam(c.pthread_self(), &policies[i], &param) != 0) c._exit(91);
    narrow[i] = c._pthread_workqueue_should_narrow(p);
    const n = running.fetchAdd(1, .seq_cst) + 1;
    _ = peak.fetchMax(n, .seq_cst);
    tids[i].store(tid, .seq_cst);
    while (!gates[i].load(.seq_cst)) _ = c.usleep(1000);
    _ = running.fetchSub(1, .seq_cst);
    _ = finished.fetchAdd(1, .seq_cst);
}
fn config() c.struct_pthread_workqueue_config {
    var cfg = std.mem.zeroes(c.struct_pthread_workqueue_config);
    cfg.version = 2;
    cfg.workq_cb = &callback;
    return cfg;
}
fn setup() void {
    var cfg = config();
    const rc = c.pthread_workqueue_setup(&cfg, @sizeOf(@TypeOf(cfg)));
    if (rc != 0) c.atf_tc_fail("setup expected=0 observed=%d", rc);
}
fn priority(oc: bool) u64 {
    return c._pthread_qos_class_encode(c.QOS_CLASS_DEFAULT, 0, if (oc) c._PTHREAD_PRIORITY_OVERCOMMIT_FLAG else 0);
}
fn request(n: u32, p: u64) void {
    const rc = c._pthread_workqueue_addthreads(@intCast(n), p);
    if (rc != 0) c.atf_tc_fail("request expected=0 observed=%d", rc);
}
fn await(counter: *A(u32), n: u32) bool {
    const end = now() + 12000;
    while (counter.load(.seq_cst) < n and now() < end) _ = c.usleep(1000);
    return counter.load(.seq_cst) == n;
}
fn drain(n: u32) void {
    for (&gates) |*g| g.store(true, .seq_cst);
    if (!await(&finished, n)) c.atf_tc_fail("callback drain expected=%u observed=%u", n, finished.load(.seq_cst));
    _ = c.usleep(100_000);
    snapshot("after");
}
fn registration(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    if (c._pthread_workqueue_addthreads(1, priority(false)) != c.EPERM) c.atf_tc_fail("pre-registration request");
    var cfg = config();
    cfg.version = 99;
    if (c.pthread_workqueue_setup(&cfg, @sizeOf(@TypeOf(cfg))) != c.EINVAL) c.atf_tc_fail("setup version");
    cfg.version = 2;
    cfg.flags = 1;
    if (c.pthread_workqueue_setup(&cfg, @sizeOf(@TypeOf(cfg))) != c.ENOTSUP) c.atf_tc_fail("setup flags");
    cfg.flags = 0;
    if (c.pthread_workqueue_setup(&cfg, 4) != c.EINVAL) c.atf_tc_fail("setup size");
    setup();
    const rc = c.pthread_workqueue_setup(&cfg, @sizeOf(@TypeOf(cfg)));
    _ = c.printf("registration second expected=%d observed=%d\n", @as(c_int, c.EBUSY), rc);
    if (rc != c.EBUSY) c.atf_tc_fail("registration once");
    request(1, priority(false));
    if (!await(&entered, 1)) c.atf_tc_fail("first callback replaced");
    drain(1);
}
fn features(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    const f = c._pthread_workqueue_supported();
    _ = c.printf("features observed=0x%x source_required=0x13 current_macos_27_2=open\n", @as(c_uint, @bitCast(f)));
    if (f & 0x13 != 0x13) c.atf_tc_fail("ordinary workqueue features");
    snapshot("after");
}
fn admission(oc: bool) void {
    begin();
    const cap = read(u32, "kern.twq.max_lane_threads");
    const cpus = read(u32, "hw.ncpu");
    if (cap != @min(@as(u32, 512), @max(@as(u32, 64), cpus * 5))) c.atf_tc_fail("constrained cap formula");
    const target = cap + 8;
    if (target >= 512) c.atf_tc_fail("fixture needs overcommit headroom");
    setup();
    request(target, priority(oc));
    const expected = if (oc) target else cap;
    const ready = await(&entered, expected);
    _ = c.usleep(200_000);
    const held = running.load(.seq_cst);
    _ = c.printf("blocked overcommit=%u cap=%u target=%u expected_peak=%u observed_peak=%u held=%u\n", @as(u32, @intFromBool(oc)), cap, target, expected, peak.load(.seq_cst), held);
    drain(target);
    if (!ready or held != expected or peak.load(.seq_cst) != expected) c.atf_tc_fail("blocked admission cap");
}
fn constrained(_: [*c]const c.atf_tc_t) callconv(.c) void {
    admission(false);
}
fn overcommit(_: [*c]const c.atf_tc_t) callconv(.c) void {
    admission(true);
}
fn workerPriority(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    setup();
    const p = priority(false);
    request(1, p);
    const end = now() + 12000;
    while (tids[0].load(.seq_cst) == 0 and now() < end) _ = c.usleep(1000);
    if (tids[0].load(.seq_cst) == 0) c.atf_tc_fail("worker priority timeout");
    var rel: c_int = 99;
    var flags: c_ulong = 0;
    const decoded = c._pthread_qos_class_decode(priorities[0], &rel, &flags);
    _ = c.printf("worker requested=0x%lx callback=0x%lx qos_self=%u decoded=%u relative=%d scheduler_policy=%d\n", p, priorities[0], qos[0], decoded, rel, policies[0]);
    drain(1);
    if (decoded != c.QOS_CLASS_DEFAULT or qos[0] != c.QOS_CLASS_DEFAULT or rel != 0) c.atf_tc_fail("default worker priority/QoS");
}
fn narrowing(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    setup();
    const nonworker = c._pthread_workqueue_should_narrow(priority(false));
    request(1, priority(true));
    const end = now() + 12000;
    while (tids[0].load(.seq_cst) == 0 and now() < end) _ = c.usleep(1000);
    if (tids[0].load(.seq_cst) == 0) c.atf_tc_fail("narrow timeout");
    _ = c.printf("narrow nonworker expected=0 observed=%u overcommit expected=0 observed=%u\n", @as(c_uint, @intFromBool(nonworker)), @as(c_uint, @intFromBool(narrow[0])));
    drain(1);
    if (nonworker or narrow[0]) c.atf_tc_fail("narrow errors and overcommit collapse to false");
}
fn requestedQos(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    setup();
    const classes = [_]c_uint{ c.QOS_CLASS_MAINTENANCE, c.QOS_CLASS_BACKGROUND, c.QOS_CLASS_UTILITY, c.QOS_CLASS_DEFAULT, c.QOS_CLASS_USER_INITIATED, c.QOS_CLASS_USER_INTERACTIVE };
    var mismatches: u32 = 0;
    for (classes, 0..) |q, i| {
        const p = c._pthread_qos_class_encode(q, -15, c._PTHREAD_PRIORITY_OVERCOMMIT_FLAG);
        request(1, p);
        const end = now() + 12000;
        while (tids[i].load(.seq_cst) == 0 and now() < end) _ = c.usleep(1000);
        if (tids[i].load(.seq_cst) == 0) c.atf_tc_fail("QoS callback timeout");
        var rel: c_int = 99;
        const decoded = c._pthread_qos_class_decode(priorities[i], &rel, null);
        _ = c.printf("qos requested=%u relative_requested=-15 callback_qos=%u callback_relative=%d qos_self=%u scheduler_policy=%d\n", q, decoded, rel, qos[i], policies[i]);
        if (decoded != q or rel != 0 or qos[i] != q) mismatches += 1;
        gates[i].store(true, .seq_cst);
        if (!await(&finished, @intCast(i + 1))) c.atf_tc_fail("QoS drain");
    }
    drain(classes.len);
    // Existing difference, outside op-177's idle-only product authority.
    c.atf_tc_expect_fail("rmxOS preserves requested relative priority and qos_class_self is a default-only stub; op-175 P:2506-2531,2590-2606");
    if (mismatches != 0) c.atf_tc_fail("Apple callback QoS/relative contract mismatches=%u", mismatches);
}
fn codecs(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    const classes = [_]c_uint{ c.QOS_CLASS_MAINTENANCE, c.QOS_CLASS_BACKGROUND, c.QOS_CLASS_UTILITY, c.QOS_CLASS_DEFAULT, c.QOS_CLASS_USER_INITIATED, c.QOS_CLASS_USER_INTERACTIVE };
    var mismatches: u32 = 0;
    for (classes) |q| {
        for ([_]c_int{ -15, 0 }) |rel| {
            const p = c._pthread_qos_class_encode(q, rel, 0);
            var decoded_rel: c_int = 99;
            const decoded = c._pthread_qos_class_decode(p, &decoded_rel, null);
            const low: u8 = @truncate(@as(u32, @bitCast(rel - 1)));
            _ = c.printf("codec qos=%u rel=%d encoded=0x%lx expected_low=%u observed_low=%u\n", q, rel, p, @as(c_uint, low), @as(c_uint, @intCast(p & 255)));
            if (decoded != q or decoded_rel != rel or p & 255 != low) mismatches += 1;
        }
    }
    snapshot("after");
    c.atf_tc_expect_fail("rmxOS encodes relpri, Apple encodes relpri-1; op-175 R:152-180,226-236");
    if (mismatches != 0) c.atf_tc_fail("Apple priority codec mismatches=%u", mismatches);
}
fn symbols(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    const names = [_][*:0]const u8{
        "pthread_workqueue_setup",                       "_pthread_workqueue_init",                             "_pthread_workqueue_init_with_kevent",                     "_pthread_workqueue_init_with_workloop",
        "__pthread_workqueue_setkill",                   "pthread_workqueue_setdispatch_np",                    "pthread_workqueue_setdispatchoffset_np",                  "pthread_workqueue_addthreads_np",
        "_pthread_workqueue_supported",                  "_pthread_workqueue_addthreads",                       "_pthread_workqueue_add_cooperativethreads",               "_pthread_workqueue_should_narrow",
        "_pthread_workqueue_set_event_manager_priority", "_pthread_qos_override_start_direct",                  "_pthread_qos_override_end_direct",                        "_pthread_override_qos_class_start_direct",
        "_pthread_override_qos_class_end_direct",        "_pthread_workqueue_override_start_direct",            "_pthread_workqueue_override_start_direct_check_owner",    "_pthread_workqueue_override_reset",
        "_pthread_workqueue_asynchronous_override_add",  "_pthread_workqueue_asynchronous_override_reset_self", "_pthread_workqueue_asynchronous_override_reset_all_self", "_pthread_workqueue_allow_send_signals",
        "_pthread_workloop_create",                      "_pthread_workloop_destroy",
    };
    var missing: u32 = 0;
    for (names) |name| {
        const present = c.dlsym(c.RTLD_DEFAULT, name) != null;
        _ = c.printf("contract_symbol name=%s expected=present observed=%s\n", name, @as([*:0]const u8, if (present) "present" else "absent"));
        if (!present) missing += 1;
    }
    snapshot("after");
    c.atf_tc_expect_fail("rmxOS lacks cooperative, workloop, async override and signal-preservation SPI; all 26 op-175 H declarations inventoried");
    if (missing != 0) c.atf_tc_fail("Apple contract symbols missing=%u", missing);
}
fn threadCount() u32 {
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID | c.KERN_PROC_INC_THREAD, c.getpid() };
    var bytes: [1024 * 1024]u8 = undefined;
    var len: usize = bytes.len;
    if (c.sysctl(&mib, mib.len, &bytes, &len, null, 0) != 0 or len < 4) c.atf_tc_fail("thread inventory");
    const size = std.mem.readInt(u32, bytes[0..4], .little);
    if (size < 4 or len % size != 0) c.atf_tc_fail("thread inventory size");
    return @intCast(len / size);
}
fn alive(tid: c_long) bool {
    if (c.thr_kill(tid, 0) == 0) return true;
    if (c.__error().* == c.ESRCH) return false;
    c.atf_tc_fail("thread liveness errno=%d", c.__error().*);
}
fn idle(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    setup();
    request(8, priority(true));
    if (!await(&entered, 8)) c.atf_tc_fail("idle setup");
    for (0..8) |i| {
        while (tids[i].load(.seq_cst) == 0) _ = c.usleep(1000);
        gates[i].store(true, .seq_cst);
        if (!await(&finished, @intCast(i + 1))) c.atf_tc_fail("idle ordered release");
        _ = c.usleep(50_000);
    }
    const start = now();
    var gone: usize = 0;
    while (now() - start < 10000 and gone < 7) {
        var new_gone: usize = 0;
        var survivor = false;
        for (0..8) |i| {
            if (alive(tids[i].load(.seq_cst))) {
                survivor = true;
            } else {
                if (survivor) c.atf_tc_fail("retirement is not oldest first index=%zu", i);
                new_gone += 1;
            }
        }
        if (new_gone != gone) _ = c.printf("idle retired=%zu elapsed_ms=%lu\n", new_gone, now() - start);
        gone = new_gone;
        _ = c.usleep(10_000);
    }
    _ = c.usleep(200_000);
    const threads = threadCount();
    _ = c.printf("idle expected_retired=7 observed_retired=%zu expected_process_threads=2 observed_process_threads=%u elapsed_ms=%lu\n", gone, threads, now() - start);
    if (gone != 7 or threads != 2 or !alive(tids[7].load(.seq_cst))) c.atf_tc_fail("one warm worker and no permanent timer thread");
    // Exercise timer restart and reuse after the timer thread has left.
    request(2, priority(true));
    if (!await(&entered, 10)) c.atf_tc_fail("reaper restart lost work");
    drain(10);
}
const Case = struct { name: [*:0]const u8, body: *const fn ([*c]const c.atf_tc_t) callconv(.c) void };
const cases = [_]Case{
    .{ .name = "registration_once", .body = &registration },
    .{ .name = "features", .body = &features },
    .{ .name = "blocked_constrained", .body = &constrained },
    .{ .name = "blocked_overcommit", .body = &overcommit },
    .{ .name = "worker_priority", .body = &workerPriority },
    .{ .name = "should_narrow", .body = &narrowing },
    .{ .name = "idle_retirement", .body = &idle },
    .{ .name = "requested_qos_contract", .body = &requestedQos },
    .{ .name = "priority_codec_contract", .body = &codecs },
    .{ .name = "contract_symbols", .body = &symbols },
};
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "descr", "Direct workqueue engine; op-175 source contract; no libdispatch");
    _ = c.atf_tc_set_md_var(tc, "timeout", "25");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (cases) |item| {
        const tc = std.heap.page_allocator.create(c.atf_tc_t) catch unreachable;
        var err = c.atf_tc_init(tc, item.name, &head, item.body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, &add);
}
comptime {
    if (!@import("builtin").is_test) @export(&main, .{ .name = "main" });
}
test "XNU delay below threshold and linearly above, including saturated decay" {
    try std.testing.expectEqual(@as(u64, 5000), c.twq_idle_delay_msec(3, 2));
    try std.testing.expectEqual(@as(u64, 4921), c.twq_idle_delay_msec(4, 2));
    try std.testing.expectEqual(@as(u64, 2500), c.twq_idle_delay_msec(35, 2));
    try std.testing.expectEqual(@as(u64, 78), c.twq_idle_delay_msec(67, 2));
    try std.testing.expectEqual(@as(u64, 78), c.twq_idle_delay_msec(100, 2));
    try std.testing.expectEqual(@as(u64, 5000), c.twq_idle_delay_msec(6, 16));
    try std.testing.expectEqual(@as(u64, 4937), c.twq_idle_delay_msec(7, 16));
}
