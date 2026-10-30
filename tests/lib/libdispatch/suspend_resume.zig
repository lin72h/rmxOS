// SPDX-License-Identifier: BSD-2-Clause
// dispatch_suspend and dispatch_resume act on queues and sources only.
// resumeNonQueue: on a group, a semaphore, a data object and an I/O channel
// both calls return and the object still works. resumeQueueStillChecked: an
// unbalanced resume of a plain queue still stops with "Over-resume". Each
// object runs in its own suspend_resume_child process.
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

const deadline_ms = 15_000;
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

fn child(tc: [*c]const c.atf_tc_t, mode: [*:0]const u8) Run {
    const srcdir = c.atf_tc_get_config_var(tc, "srcdir");
    var helper: [512]u8 = undefined;
    _ = c.snprintf(&helper, helper.len, "%s/suspend_resume_child", srcdir);
    const r = run(@ptrCast(&helper), mode);
    var lines = std.mem.splitScalar(u8, r.text[0..r.len], '\n');
    while (lines.next()) |l| {
        if (l.len > 0) _ = c.printf("suspend_resume mode=%s %.*s\n", mode, @as(c_int, @intCast(l.len)), l.ptr);
    }
    return r;
}
fn resumeNonQueue(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    var failed = false;
    for ([_][*:0]const u8{ "group", "semaphore", "data", "io" }) |mode| {
        const r = child(tc, mode);
        const ok = !r.timed_out and c.WIFEXITED(r.status) and c.WEXITSTATUS(r.status) == 0 and
            std.mem.indexOf(u8, r.text[0..r.len], "\ndone ok\n") != null;
        _ = c.printf("suspend_resume mode=%s status=%d timed_out=%d result=%s\n", mode, r.status, @as(c_int, @intFromBool(r.timed_out)), if (ok) "pass" else "fail");
        if (!ok) failed = true;
    }
    _ = c.fflush(null);
    if (failed) c.atf_tc_fail("suspend and resume return on a group, a semaphore, data and a channel, which still work");
}
fn resumeQueueStillChecked(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const r = child(tc, "queue");
    const stopped = !r.timed_out and c.WIFSIGNALED(r.status) and
        (c.WTERMSIG(r.status) == c.SIGILL or c.WTERMSIG(r.status) == c.SIGTRAP);
    const said = std.mem.indexOf(u8, r.text[0..r.len], "Over-resume of an object") != null;
    _ = c.printf("suspend_resume mode=queue status=%d stopped=%d over_resume=%d result=%s\n", r.status, @as(c_int, @intFromBool(stopped)), @as(c_int, @intFromBool(said)), if (stopped and said) "pass" else "fail");
    _ = c.fflush(null);
    if (!(stopped and said)) c.atf_tc_fail("an unbalanced resume of a queue stops with Over-resume");
}

const names = [_][*:0]const u8{ "resumeNonQueue", "resumeQueueStillChecked" };
const bodies = .{ &resumeNonQueue, &resumeQueueStillChecked };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "70");
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
