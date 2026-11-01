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
    inline for (.{ "depress_restores", "wait_priority", "switch_invalid" }) |name| {
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
            _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
            _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
        }
        fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
            if (comptime std.mem.eql(u8, name, "switch_invalid")) {
                for ([_]c_int{ -1, 3, 4, 5, 99 }) |option| {
                    c.__error().* = 0;
                    const rc = c.syscall(c.SYS_thread_switch, @as(c_uint, 0), option, @as(c_uint, 0));
                    if (rc != 4 or c.__error().* != 0) c.atf_tc_fail("invalid option=%d expected Mach 4 observed=%d errno=%d", option, rc, c.__error().*);
                }
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
