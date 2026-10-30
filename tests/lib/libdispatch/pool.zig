// SPDX-License-Identifier: BSD-2-Clause
// The worker pool grows while a worker sleeps, and overcommit gathers 64
// workers (swift-corelibs-libdispatch 6.4.0 dispatch_concur and
// dispatch_readsync shapes); starting a global queue writes no syslog record.
// Each shape runs in its own pool_child process.
const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline
    // (tests/lib/libxpc/bsm_header.zig does the same).
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;

const deadline_ms = 20_000;
fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

const Run = struct { status: c_int = 0, timed_out: bool = false, text: [4096]u8 = undefined, len: usize = 0 };

fn run(helper: [*:0]const u8, mode: [*:0]const u8) Run {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) c.atf_tc_fail("pipe");
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork");
    if (pid == 0) {
        const limit = c.struct_rlimit{ .rlim_cur = 0, .rlim_max = 0 };
        _ = c.setrlimit(c.RLIMIT_CORE, &limit);
        _ = c.dup2(fds[1], 1);
        _ = c.dup2(fds[1], 2);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        const argv = [_:null]?[*:0]const u8{ helper, mode };
        _ = c.execv(helper, @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    var r = Run{};
    const started = now();
    while (true) {
        var status: c_int = 0;
        var w = c.waitpid(pid, &status, c.WNOHANG);
        if (w == 0 and now() - started >= deadline_ms) {
            _ = c.kill(pid, c.SIGKILL);
            w = c.waitpid(pid, &status, 0);
            r.timed_out = true;
        }
        if (w == pid) {
            r.status = status;
            break;
        }
        if (w != 0) c.atf_tc_fail("waitpid");
        _ = c.usleep(10_000);
    }
    while (r.len < r.text.len) {
        const n = c.read(fds[0], &r.text[r.len], r.text.len - r.len);
        if (n <= 0) break;
        r.len += @intCast(n);
    }
    _ = c.close(fds[0]);
    return r;
}

fn shape(tc: [*c]const c.atf_tc_t, modes: []const [*:0]const u8, comptime what: [*:0]const u8) void {
    const srcdir = c.atf_tc_get_config_var(tc, "srcdir");
    var helper: [512]u8 = undefined;
    _ = c.snprintf(&helper, helper.len, "%s/pool_child", srcdir);
    var failed = false;
    for (modes) |mode| {
        const r = run(@ptrCast(&helper), mode);
        var lines = std.mem.splitScalar(u8, r.text[0..r.len], '\n');
        while (lines.next()) |l| {
            if (l.len > 0) _ = c.printf("pool mode=%s %.*s\n", mode, @as(c_int, @intCast(l.len)), l.ptr);
        }
        const ok = !r.timed_out and c.WIFEXITED(r.status) and c.WEXITSTATUS(r.status) == 0 and
            std.mem.indexOf(u8, r.text[0..r.len], "\ndone ok\n") != null;
        _ = c.printf("pool mode=%s status=%d timed_out=%d result=%s\n", mode, r.status, @as(c_int, @intFromBool(r.timed_out)), if (ok) "pass" else "fail");
        if (!ok) failed = true;
    }
    _ = c.fflush(null);
    if (failed) c.atf_tc_fail("%s", what);
}
fn poolGrowsWhileWorkerSleeps(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    shape(tc, &.{ "global", "concurrent" }, "4 queued 1 ms items complete while their submitter sleeps 10 ms");
}
fn overcommitRendezvous(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    shape(tc, &.{"rendezvous"}, "64 overcommit blocks all run at once within 5 s");
}
fn quietRootQueueStart(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    shape(tc, &.{ "quiet", "logged" }, "starting a global queue makes no syslog or ASL call (and dispatch_debug's call is seen)");
}

const names = [_][*:0]const u8{ "poolGrowsWhileWorkerSleeps", "overcommitRendezvous", "quietRootQueueStart" };
const bodies = .{ &poolGrowsWhileWorkerSleeps, &overcommitRendezvous, &quietRootQueueStart };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "60");
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
