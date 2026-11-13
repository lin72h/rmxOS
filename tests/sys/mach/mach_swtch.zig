// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/rtprio.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("pthread.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn Case(comptime number: c_int, comptime name: [:0]const u8) type {
    return struct {
        var tc: c.atf_tc_t = undefined;
        fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
            _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach yield returns with the scheduler thread lock released");
            _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
        }
        fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
            const observed = c.syscall(number, @as(c_int, 0));
            const err = c.__error().*;
            _ = c.printf("operation=%s expected=0 observed=%d errno=%d\n", name.ptr, observed, err);
            if (observed != 0) c.atf_tc_fail("yield expected=0 observed=%d errno=%d", observed, err);
        }
    };
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const config = c.atf_tp_get_config(tp);
    inline for (.{ Case(c.SYS_swtch_pri, "swtch_pri"), Case(c.SYS_swtch, "swtch") }, .{ "swtch_pri", "swtch" }) |T, name| {
        const err = c.atf_tc_init(&T.tc, name, &T.head, &T.body, null, config);
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &T.tc);
        if (c.atf_is_error(added)) return added;
    }
    inline for (.{ "depress_restores", "wait_priority", "switch_invalid", "depress_contended" }) |name| {
        const T = SwitchCase(name);
        const err = c.atf_tc_init(&T.tc, name, &T.head, &T.body, null, config);
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &T.tc);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
const std = @import("std");
extern const mach_kinfo_size: usize;
extern const mach_kinfo_priority: usize;
fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) c.atf_tc_fail("monotonic clock");
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}
fn priority(pid: c.pid_t) u8 {
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID, pid };
    var data: [4096]u8 = undefined;
    var size: usize = data.len;
    if (c.sysctl(&mib, mib.len, &data, &size, null, 0) != 0 or size != mach_kinfo_size or mach_kinfo_priority >= size)
        c.atf_tc_fail("kinfo_proc priority pid=%d size=%zu", pid, size);
    return data[mach_kinfo_priority];
}
fn realtime() void {
    var rp = c.struct_rtprio{ .type = c.RTP_PRIO_REALTIME, .prio = 20 };
    if (c.rtprio_thread(c.RTP_SET, 0, &rp) != 0) c.atf_tc_fail("set stable realtime priority errno=%d", c.__error().*);
}
fn SwitchCase(comptime name: [:0]const u8) type {
    return struct {
        var tc: c.atf_tc_t = undefined;
        fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
            _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach thread_switch restores priority and WAIT backs off without depression");
            _ = c.atf_tc_set_md_var(t, "timeout", "%s", if (comptime std.mem.eql(u8, name, "depress_contended")) "60" else "10");
            _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
        }
        fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
            if (comptime std.mem.eql(u8, name, "switch_invalid")) {
                for ([_]c_int{ -1, 3, 4, 5, 99 }) |option| {
                    c.__error().* = 0;
                    const rc = c.syscall(c.SYS_thread_switch, @as(c_uint, 0), option, @as(c_uint, 0));
                    if (rc != 4 or c.__error().* != 0) c.atf_tc_fail("invalid option=%d expected Mach 4 observed=%d errno=%d", option, rc, c.__error().*);
                }
            } else if (comptime std.mem.eql(u8, name, "depress_contended")) {
                contended();
            } else if (comptime std.mem.eql(u8, name, "depress_restores")) {
                realtime();
                const before = priority(c.getpid());
                for ([_]u32{ 0, 1, 1000 }) |ms| {
                    const start = nowMs();
                    const rc = c.syscall(c.SYS_thread_switch, @as(c_uint, 0), @as(c_int, 1), ms);
                    const elapsed = nowMs() - start;
                    const after = priority(c.getpid());
                    _ = c.printf("depress ms=%u elapsed_ms=%lld expected_priority=%u observed_priority=%u\n", ms, elapsed, @as(c_uint, before), @as(c_uint, after));
                    if (rc != 0 or before != after or elapsed > 750) c.atf_tc_fail("depression not restored on resumption rc=%d", rc);
                }
            } else {
                var pipe: [2]c_int = undefined;
                if (c.pipe(&pipe) != 0) c.atf_tc_fail("pipe");
                const pid = c.fork();
                if (pid < 0) c.atf_tc_fail("fork");
                if (pid == 0) {
                    _ = c.close(pipe[0]);
                    realtime();
                    const before = priority(c.getpid());
                    if (c.write(pipe[1], &before, 1) != 1) c._exit(1);
                    const start = nowMs();
                    const rc = c.syscall(c.SYS_thread_switch, @as(c_uint, 0), @as(c_int, 2), @as(c_uint, 120));
                    const elapsed = nowMs() - start;
                    const after = priority(c.getpid());
                    _ = c.dprintf(1, "wait option_ms=120 elapsed_ms=%lld expected_priority=%u observed_priority=%u\n", elapsed, @as(c_uint, before), @as(c_uint, after));
                    c._exit(if (rc == 0 and elapsed >= 110 and elapsed < 2000 and before == after) 0 else 2);
                }
                _ = c.close(pipe[1]);
                var before: u8 = 0;
                if (c.read(pipe[0], &before, 1) != 1) c.atf_tc_fail("child ready");
                _ = c.close(pipe[0]);
                _ = c.usleep(30_000);
                const during = priority(pid);
                var status: c_int = 0;
                if (c.waitpid(pid, &status, 0) != pid or status != 0) c.atf_tc_fail("WAIT duration/priority child_status=%d", status);
                _ = c.printf("wait during expected_priority=%u observed_priority=%u\n", @as(c_uint, before), @as(c_uint, during));
                if (before != during) c.atf_tc_fail("WAIT depressed sleeping priority");
            }
        }
    };
}
// Contended depressed yields with the softclock thread kept waking: a progress
// check for thread_switch's timer arming; its lock assertion is the guard.
const contended_windows = 10;
const contended_window_s = 2;
var contended_stop: std.atomic.Value(bool) = .init(false);
var contended_errors: std.atomic.Value(u32) = .init(0);
var contended_counts: [256]std.atomic.Value(u64) = @splat(.init(0));
fn counter(arg: ?*anyopaque) *std.atomic.Value(u64) {
    return @ptrCast(@alignCast(arg.?));
}
fn yielder(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const count = counter(arg);
    while (!contended_stop.load(.seq_cst)) {
        if (c.syscall(c.SYS_thread_switch, @as(c_uint, 0), @as(c_int, 1), @as(c_uint, 1)) != 0) _ = contended_errors.fetchAdd(1, .seq_cst);
        _ = count.fetchAdd(1, .seq_cst);
    }
    return null;
}
fn sleeper(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const count = counter(arg);
    const ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 1_000_000 };
    while (!contended_stop.load(.seq_cst)) {
        if (c.nanosleep(&ts, null) != 0) _ = contended_errors.fetchAdd(1, .seq_cst);
        _ = count.fetchAdd(1, .seq_cst);
    }
    return null;
}
fn contended() void {
    var ncpu: c_int = 0;
    var len: usize = @sizeOf(c_int);
    if (c.sysctlbyname("hw.ncpu", &ncpu, &len, null, 0) != 0 or ncpu < 1) c.atf_tc_fail("hw.ncpu");
    const per: usize = 2 * @as(usize, @intCast(ncpu));
    const total = 2 * per;
    if (total > contended_counts.len) c.atf_tc_fail("ncpu=%d exceeds the fixture", ncpu);
    var threads: [256]c.pthread_t = undefined;
    for (0..total) |i| {
        const body = if (i < per) &yielder else &sleeper;
        if (c.pthread_create(&threads[i], null, body, &contended_counts[i]) != 0) c.atf_tc_fail("pthread_create %zu", i);
    }
    var start: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &start) != 0) c.atf_tc_fail("monotonic clock");
    var last: [256]u64 = @splat(0);
    var stalled_window: u32 = 0;
    var stalled_thread: usize = 0;
    for (1..contended_windows + 1) |w| {
        var deadline = start;
        deadline.tv_sec += @intCast(w * contended_window_s);
        while (true) {
            const rc = c.clock_nanosleep(c.CLOCK_MONOTONIC, c.TIMER_ABSTIME, &deadline, null);
            if (rc == 0) break;
            if (rc != c.EINTR) c.atf_tc_fail("clock_nanosleep %d", rc);
        }
        var least: u64 = std.math.maxInt(u64);
        var least_thread: usize = 0;
        for (0..total) |i| {
            const now = contended_counts[i].load(.seq_cst);
            if (now - last[i] < least) {
                least = now - last[i];
                least_thread = i;
            }
            last[i] = now;
        }
        _ = c.printf("depress_contended window=%zu yielders=%zu sleepers=%zu least_advance=%lu least_thread=%zu\n", w, per, per, least, least_thread);
        if (least == 0 and stalled_window == 0) {
            stalled_window = @intCast(w);
            stalled_thread = least_thread;
        }
    }
    contended_stop.store(true, .seq_cst);
    for (0..total) |i| {
        if (c.pthread_join(threads[i], null) != 0) c.atf_tc_fail("pthread_join %zu", i);
    }
    var yields: u64 = 0;
    var sleeps: u64 = 0;
    for (0..total) |i| {
        if (i < per) yields += contended_counts[i].load(.seq_cst) else sleeps += contended_counts[i].load(.seq_cst);
    }
    const errors = contended_errors.load(.seq_cst);
    _ = c.printf("depress_contended seconds=%u yields=%lu sleeps=%lu errors=%u stalled_window=%u stalled_thread=%zu\n", @as(c_uint, contended_windows * contended_window_s), yields, sleeps, errors, stalled_window, stalled_thread);
    if (stalled_window != 0) c.atf_tc_fail("thread %zu made no progress in window %u", stalled_thread, stalled_window);
    if (errors != 0) c.atf_tc_fail("thread_switch or nanosleep failed %u times", errors);
}
