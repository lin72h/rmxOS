// SPDX-License-Identifier: BSD-2-Clause
// __proc_info follows FreeBSD's process-group, lock-order and visibility
// contracts: pgfind under proctree_lock, the process group before the
// process lock, p_cansee for every listed or described process, and
// credentials read under the process lock.
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/param.h");
    @cInclude("sys/jail.h");
    @cInclude("sys/uio.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/wait.h");
    @cInclude("errno.h");
    @cInclude("pthread.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn __error() *c_int;
extern fn proc_listpids(kind: u32, typeinfo: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern fn proc_listpgrppids(pgrpid: c.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
const rounds = 100000;
const hidden_uid: c.uid_t = 52401;
const switch_uid: c.uid_t = 52402;
// sys/proc_info.h; its include chain needs the Mach headers in libproc's
// order, so the few names used here are restated.
const PROC_UID_ONLY: u32 = 4;
const PROC_RUID_ONLY: u32 = 5;
const PROC_PIDTBSDINFO: c_int = 3;
const BsdInfo = extern struct {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: c.uid_t,
    pbi_gid: c.gid_t,
    pbi_ruid: c.uid_t,
    pbi_rgid: c.gid_t,
    pbi_svuid: c.uid_t,
    pbi_svgid: c.gid_t,
    rfu_1: u32,
    pbi_comm: [c.MAXCOMLEN]u8,
    pbi_name: [2 * c.MAXCOMLEN]u8,
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
};
// mach.ko's DWARF: struct proc_bsdinfo is 0x98 bytes, pbi_pgid at 0x70.
comptime {
    if (@sizeOf(BsdInfo) != 0x98 or @offsetOf(BsdInfo, "pbi_pgid") != 0x70) @compileError("proc_bsdinfo layout");
}
var pgrp_tc: c.atf_tc_t = undefined;
var lockorder_tc: c.atf_tc_t = undefined;
var visibility_tc: c.atf_tc_t = undefined;

fn now_ms() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1000000);
}

// A child in its own process group that waits until the gate closes.
const Child = struct { pid: c.pid_t, gate: c_int };
fn grouped_child() Child {
    var ready: [2]c_int = undefined;
    var gate: [2]c_int = undefined;
    if (c.pipe(&ready) != 0 or c.pipe(&gate) != 0) c.atf_tc_fail("pipe setup failed");
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork failed");
    if (pid == 0) {
        _ = c.close(ready[0]);
        _ = c.close(gate[1]);
        const ok: u8 = if (c.setpgid(0, 0) == 0) 1 else 0;
        _ = c.write(ready[1], &ok, 1);
        var byte: u8 = 0;
        _ = c.read(gate[0], &byte, 1);
        c._exit(0);
    }
    _ = c.close(ready[1]);
    _ = c.close(gate[0]);
    var ok: u8 = 0;
    if (c.read(ready[0], &ok, 1) != 1 or ok != 1) c.atf_tc_fail("child setpgid failed");
    _ = c.close(ready[0]);
    return .{ .pid = pid, .gate = gate[1] };
}
fn release(child: Child) void {
    _ = c.close(child.gate);
    var status: c_int = 0;
    _ = c.waitpid(child.pid, &status, 0);
}

fn pgrp_head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "proc_listpgrppids lists exactly the members of a process group");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn pgrp_body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const child = grouped_child();
    defer release(child);
    var pids: [64]c_int = [_]c_int{0} ** 64;
    const n = proc_listpgrppids(child.pid, &pids, @sizeOf(@TypeOf(pids)));
    const err = __error().*;
    _ = c.printf("proc_info_pgrp expected_count=1 observed_count=%d expected_pid=%d observed_pid=%d errno=%d\n", n, child.pid, pids[0], err);
    if (n != 1 or pids[0] != child.pid) c.atf_tc_fail("process group listing count=%d first=%d", n, pids[0]);
}

var info_ok: u32 = 0;
var info_bad: u32 = 0;
var info_errno: c_int = 0;
var kill_ok: u32 = 0;
var kill_bad: u32 = 0;
var kill_errno: c_int = 0;
var done = std.atomic.Value(u32).init(0);
var target: c.pid_t = 0;
fn info_loop(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var info: BsdInfo = undefined;
    for (0..rounds) |_| {
        const size = proc_pidinfo(target, PROC_PIDTBSDINFO, 0, &info, @sizeOf(BsdInfo));
        if (size == @sizeOf(BsdInfo) and info.pbi_pgid == @as(u32, @intCast(target))) {
            info_ok += 1;
        } else {
            info_bad += 1;
            info_errno = __error().*;
        }
    }
    _ = done.fetchAdd(1, .seq_cst);
    return null;
}
fn kill_loop(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    for (0..rounds) |_| {
        if (c.killpg(target, 0) == 0) {
            kill_ok += 1;
        } else {
            kill_bad += 1;
            kill_errno = __error().*;
        }
    }
    _ = done.fetchAdd(1, .seq_cst);
    return null;
}
// WITNESS reports each lock order reversal once in the kernel log; count
// those naming both the process lock and the process group.
fn proc_pgrp_reversals() c_int {
    var len: usize = 0;
    if (c.sysctlbyname("kern.msgbuf", null, &len, null, 0) != 0) c.atf_tc_fail("kern.msgbuf size errno=%d", __error().*);
    len += 65536;
    const raw: [*]u8 = @ptrCast(c.malloc(len) orelse c.atf_tc_fail("msgbuf allocation failed"));
    defer c.free(raw);
    if (c.sysctlbyname("kern.msgbuf", raw, &len, null, 0) != 0) c.atf_tc_fail("kern.msgbuf read errno=%d", __error().*);
    const text = raw[0..len];
    var found: c_int = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "lock order reversal")) |i| {
        const window = text[i..@min(text.len, i + 512)];
        if (std.mem.indexOf(u8, window, "process lock") != null and std.mem.indexOf(u8, window, "process group") != null) found += 1;
        at = i + 1;
    }
    return found;
}
fn lockorder_head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "PROC_PIDTBSDINFO and killpg on one process group finish without a process/process-group lock order reversal");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "40");
}
fn lockorder_body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const child = grouped_child();
    defer release(child);
    target = child.pid;
    const before = proc_pgrp_reversals();
    const start = now_ms();
    var a: c.pthread_t = undefined;
    var b: c.pthread_t = undefined;
    if (c.pthread_create(&a, null, &info_loop, null) != 0 or c.pthread_create(&b, null, &kill_loop, null) != 0) c.atf_tc_fail("thread creation failed");
    while (done.load(.seq_cst) < 2 and now_ms() - start < 30000) _ = c.usleep(10000);
    const elapsed = now_ms() - start;
    const finished = done.load(.seq_cst);
    if (finished < 2) c.atf_tc_fail("loops did not finish within 30 s finished=%u", finished);
    _ = c.pthread_join(a, null);
    _ = c.pthread_join(b, null);
    const after = proc_pgrp_reversals();
    _ = c.printf("proc_info_lockorder expected_pidinfo=%d observed_pidinfo=%u pidinfo_errno=%d expected_killpg=%d observed_killpg=%u killpg_errno=%d elapsed_ms=%lld limit_ms=30000 expected_reversals=0 observed_reversals_before=%d observed_reversals_after=%d\n", @as(c_int, rounds), info_ok, info_errno, @as(c_int, rounds), kill_ok, kill_errno, @as(c_longlong, elapsed), before, after);
    if (info_ok != rounds or kill_ok != rounds) c.atf_tc_fail("pidinfo ok=%u killpg ok=%u", info_ok, kill_ok);
    if (after != 0) c.atf_tc_fail("kernel log has %d process/process-group lock order reversals", after);
}

// What a child in a restricted context sees, reported to the parent.
const Seen = extern struct { setup: c_int, listed: c_int, only_self: c_int, info_rc: c_int, info_errno: c_int };
fn observe(fd: c_int) noreturn {
    var seen: Seen = .{ .setup = 0, .listed = 0, .only_self = 1, .info_rc = 0, .info_errno = 0 };
    var pids: [4096]c_int = undefined;
    seen.listed = proc_listallpids(&pids, @sizeOf(@TypeOf(pids)));
    if (seen.listed <= 0) seen.only_self = 0;
    for (0..@intCast(@max(seen.listed, 0))) |i| {
        if (pids[i] != c.getpid()) seen.only_self = 0;
    }
    var info: BsdInfo = undefined;
    seen.info_rc = proc_pidinfo(1, PROC_PIDTBSDINFO, 0, &info, @sizeOf(BsdInfo));
    seen.info_errno = __error().*;
    _ = c.write(fd, &seen, @sizeOf(Seen));
    c._exit(0);
}
fn restricted(comptime setup: fn () c_int) Seen {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) c.atf_tc_fail("pipe setup failed");
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork failed");
    if (pid == 0) {
        _ = c.close(fds[0]);
        const rc = setup();
        if (rc != 0) {
            const failed: Seen = .{ .setup = rc, .listed = -1, .only_self = 0, .info_rc = -1, .info_errno = 0 };
            _ = c.write(fds[1], &failed, @sizeOf(Seen));
            c._exit(1);
        }
        observe(fds[1]);
    }
    _ = c.close(fds[1]);
    var seen: Seen = undefined;
    const got = c.read(fds[0], &seen, @sizeOf(Seen));
    _ = c.close(fds[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    if (got != @sizeOf(Seen)) c.atf_tc_fail("restricted child reported nothing");
    return seen;
}
fn enter_jail() c_int {
    var iov = [_]c.struct_iovec{
        .{ .iov_base = @constCast("path"), .iov_len = 5 },
        .{ .iov_base = @constCast("/"), .iov_len = 2 },
    };
    if (c.jail_set(&iov, iov.len, c.JAIL_CREATE | c.JAIL_ATTACH) < 0) return __error().*;
    return 0;
}
fn become_unprivileged() c_int {
    var groups = [_]c.gid_t{hidden_uid};
    if (c.setgroups(1, &groups) != 0 or c.setgid(hidden_uid) != 0 or c.setuid(hidden_uid) != 0) return __error().*;
    return 0;
}
fn see_other_uids(value: c_int) c_int {
    var old: c_int = -1;
    var size: usize = @sizeOf(c_int);
    if (c.sysctlbyname("security.bsd.see_other_uids", &old, &size, &value, @sizeOf(c_int)) != 0) c.atf_tc_fail("security.bsd.see_other_uids write errno=%d", __error().*);
    return old;
}
fn report(label: [*:0]const u8, seen: Seen, only_self: c_int, errno_value: c_int) void {
    _ = c.printf("proc_info_visibility %s expected_setup=0 observed_setup=%d observed_listed=%d expected_only_self=%d observed_only_self=%d expected_pidinfo_errno=%d observed_pidinfo_rc=%d observed_pidinfo_errno=%d\n", label, seen.setup, seen.listed, only_self, seen.only_self, errno_value, seen.info_rc, seen.info_errno);
    if (seen.setup != 0) c.atf_tc_fail("%s setup errno=%d", label, seen.setup);
    if (seen.only_self != only_self) c.atf_tc_fail("%s listing only_self=%d", label, seen.only_self);
    if (errno_value != 0 and (seen.info_rc != 0 or seen.info_errno != errno_value)) c.atf_tc_fail("%s pid 1 info rc=%d errno=%d", label, seen.info_rc, seen.info_errno);
    if (errno_value == 0 and seen.info_rc != @sizeOf(BsdInfo)) c.atf_tc_fail("%s pid 1 info rc=%d errno=%d", label, seen.info_rc, seen.info_errno);
}
fn visibility_head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "proc_info lists and describes only processes the caller may see");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "30");
}
fn visibility_body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    report("jail", restricted(enter_jail), 1, c.ESRCH);
    // Control: the same unprivileged user sees other uids by default.
    const old = see_other_uids(1);
    report("other_uids_1", restricted(become_unprivileged), 0, 0);
    _ = see_other_uids(0);
    const hidden = restricted(become_unprivileged);
    _ = see_other_uids(old);
    report("other_uids_0", hidden, 1, c.ESRCH);

    // A uid listing while a child's credential changes between two uids.
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork failed");
    if (pid == 0) {
        while (true) {
            if (c.setresuid(switch_uid, switch_uid, 0) != 0 or c.setresuid(0, 0, 0) != 0) c._exit(2);
        }
    }
    var pids: [4096]c_int = undefined;
    var listings: u32 = 0;
    var hits: u32 = 0;
    var foreign: u32 = 0;
    var missing: u32 = 0;
    for (0..20000) |i| {
        const kind: u32 = if (i % 2 == 0) PROC_UID_ONLY else PROC_RUID_ONLY;
        const bytes = proc_listpids(kind, switch_uid, &pids, @sizeOf(@TypeOf(pids)));
        listings += 1;
        for (0..@intCast(@divTrunc(@max(bytes, 0), @sizeOf(c_int)))) |j| {
            if (pids[j] == pid) hits += 1 else foreign += 1;
            if (c.kill(pids[j], 0) != 0) missing += 1;
        }
    }
    _ = c.kill(pid, c.SIGKILL);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    // wait(2) status: the low seven bits hold the terminating signal.
    const switching = (status & 0x7f) == c.SIGKILL;
    _ = c.printf("proc_info_visibility uid_switch listings=%u observed_hits=%u expected_foreign=0 observed_foreign=%u expected_missing=0 observed_missing=%u child_switching=%d\n", listings, hits, foreign, missing, @as(c_int, @intFromBool(switching)));
    if (!switching) c.atf_tc_fail("uid-switching child stopped status=%d", status);
    if (foreign != 0 or missing != 0) c.atf_tc_fail("uid listing returned foreign=%u missing=%u pids", foreign, missing);
    if (hits == 0) c.atf_tc_fail("uid listing never matched the switching child");
}
// The body restores the previous value; this repairs a 0 an interrupted
// body left behind (the image default is 1).
fn visibility_cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var value: c_int = 0;
    var size: usize = @sizeOf(c_int);
    var one: c_int = 1;
    if (c.sysctlbyname("security.bsd.see_other_uids", &value, &size, null, 0) == 0 and value == 0)
        _ = c.sysctlbyname("security.bsd.see_other_uids", null, null, &one, @sizeOf(c_int));
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (.{
        .{ &pgrp_tc, "proc_info_pgrp", &pgrp_head, &pgrp_body, null },
        .{ &lockorder_tc, "proc_info_lockorder", &lockorder_head, &lockorder_body, null },
        .{ &visibility_tc, "proc_info_visibility", &visibility_head, &visibility_body, &visibility_cleanup },
    }) |t| {
        const e = c.atf_tc_init(t[0], t[1], t[2], t[3], t[4], c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        const added = c.atf_tp_add_tc(tp, t[0]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
