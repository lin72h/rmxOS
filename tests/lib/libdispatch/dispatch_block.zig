// SPDX-License-Identifier: BSD-2-Clause
// dispatch_block_wait, _notify, _cancel/_testcancel and _perform on blocks
// from dispatch_block_create and dispatch_block_create_with_qos_class. Each
// operation runs in its own dispatch_block_child process, once per create
// function, so a stop in one does not hide the rest.
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

fn run(helper: [*:0]const u8, op: [*:0]const u8, kind: [*:0]const u8) Run {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) c.atf_tc_fail("pipe");
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork");
    if (pid == 0) {
        const limit = c.struct_rlimit{ .rlim_cur = 0, .rlim_max = 0 };
        _ = c.setrlimit(c.RLIMIT_CORE, &limit);
        _ = c.dup2(fds[1], 1);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        const argv = [_:null]?[*:0]const u8{ helper, op, kind };
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

fn operation(tc: [*c]const c.atf_tc_t, op: [*:0]const u8) void {
    const srcdir = c.atf_tc_get_config_var(tc, "srcdir");
    var helper: [512]u8 = undefined;
    var lib: [512]u8 = undefined;
    _ = c.snprintf(&helper, helper.len, "%s/dispatch_block_child", srcdir);
    // A base copy beside the program carries op-260's library under its own
    // soname; launchd's LD_LIBRARY_PATH would win over a same-soname copy.
    _ = c.snprintf(&lib, lib.len, "%s/lib/libdispatch_base.so.5", srcdir);
    var st: c.struct_stat = undefined;
    const expected: [*:0]const u8 = if (c.stat(&lib, &st) == 0) @ptrCast(&lib) else "/usr/lib/libdispatch.so.5";
    var want: [600]u8 = undefined;
    const want_len: usize = @intCast(c.snprintf(&want, want.len, "lib=%s\n", expected));
    var failed = false;
    for ([_][*:0]const u8{ "plain", "qos" }) |kind| {
        const r = run(@ptrCast(&helper), op, kind);
        var lines = std.mem.splitScalar(u8, r.text[0..r.len], '\n');
        while (lines.next()) |l| {
            if (l.len > 0) _ = c.printf("dispatch_block op=%s kind=%s %.*s\n", op, kind, @as(c_int, @intCast(l.len)), l.ptr);
        }
        const bound = std.mem.startsWith(u8, r.text[0..r.len], want[0..want_len]);
        const ok = !r.timed_out and c.WIFEXITED(r.status) and c.WEXITSTATUS(r.status) == 0 and bound and
            std.mem.indexOf(u8, r.text[0..r.len], "\ndone ok\n") != null;
        _ = c.printf("dispatch_block op=%s kind=%s status=%d timed_out=%d bound=%d result=%s\n", op, kind, r.status, @as(c_int, @intFromBool(r.timed_out)), @as(c_int, @intFromBool(bound)), if (ok) "pass" else "fail");
        if (!ok) failed = true;
    }
    _ = c.fflush(null);
    if (failed) c.atf_tc_fail("%s: both create functions' children exit 0 with every check, on %s", op, expected);
}

fn blockWait(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    operation(tc, "wait");
}
fn blockNotify(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    operation(tc, "notify");
}
fn blockCancel(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    operation(tc, "cancel");
}
fn blockPerform(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    operation(tc, "perform");
}

const names = [_][*:0]const u8{ "blockWait", "blockNotify", "blockCancel", "blockPerform" };
const bodies = .{ &blockWait, &blockNotify, &blockCancel, &blockPerform };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "40");
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
