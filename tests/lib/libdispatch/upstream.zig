// SPDX-License-Identifier: BSD-2-Clause
// ATF adapter for the unmodified assertions in the id-151 upstream fixture.
const std = @import("std");
const catalog = @import("upstream_cases.zig");
const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const marker = "/var/tmp/rmx-upstream-io-mounted";
const capacity = 4 * 1024 * 1024;
const Facts = struct { pid: usize = 0, terminal: usize = 0, failures: usize = 0, vm_skip: bool = false };
fn facts(raw: []const u8) Facts {
    var f = Facts{};
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "[PID] ")) f.pid += 1;
        if (std.mem.eql(u8, line, "[PASS] Process exited")) f.terminal += 1;
        if (std.mem.startsWith(u8, line, "[FAIL]")) f.failures += 1;
        if (std.mem.startsWith(u8, line, "[SKIP] ") or std.mem.indexOf(u8, line, " - No DISPATCH_SOURCE_TYPE_VM") != null) f.vm_skip = true;
    }
    return f;
}
fn success(f: Facts, status: c_int, truncated: bool) bool {
    return !truncated and c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0 and f.pid == 1 and f.terminal == 1 and f.failures == 0;
}
fn command(argv: []const ?[*:0]const u8) c_int {
    const pid = c.fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) return -1;
    return status;
}
fn tmpfs() bool {
    var fs: c.struct_statfs = undefined;
    return c.statfs("/tmp", &fs) == 0 and std.mem.eql(u8, std.mem.sliceTo(&fs.f_fstypename, 0), "tmpfs");
}
fn mountTmp() bool {
    if (tmpfs()) return true;
    const fd = c.open(marker, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o600));
    if (fd < 0) return false;
    _ = c.close(fd);
    const argv = [_]?[*:0]const u8{ "/sbin/mount", "-t", "tmpfs", "-o", "mode=1777", "tmpfs", "/tmp", null };
    const status = command(&argv);
    _ = c.printf("UPSTREAM_TMPFS mount_status=%d observed_tmpfs=%d\n", status, @as(c_int, @intFromBool(tmpfs())));
    if (status != 0 or !tmpfs()) {
        _ = c.unlink(marker);
        return false;
    }
    return true;
}
fn unmountTmp() bool {
    if (c.access(marker, c.F_OK) != 0) return true;
    const argv = [_]?[*:0]const u8{ "/sbin/umount", "/tmp", null };
    if (!tmpfs() or command(&argv) != 0) return false;
    return c.unlink(marker) == 0;
}
fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = c.atf_tc_get_ident(tc);
    const label = std.mem.span(name);
    const io = std.mem.eql(u8, label, "dispatch_io");
    if (io and c.geteuid() != 0) c.atf_tc_skip("dispatch_io requires root to mount tmpfs on /tmp");
    if (io and !mountTmp()) c.atf_tc_fail("dispatch_io requires /tmp on tmpfs");
    const fixture: [*c]const u8 = if (c.atf_tc_has_config_var(tc, "fixture_dir")) c.atf_tc_get_config_var(tc, "fixture_dir") else "/usr/tests/upstream";
    var helper: [1024]u8 = undefined;
    var harness: [1024]u8 = undefined;
    const hn = c.snprintf(&harness, harness.len, "%s/bsdtestharness", fixture);
    const pn = c.snprintf(&helper, helper.len, "%s/%s", fixture, name);
    if (hn < 0 or hn >= harness.len or pn < 0 or pn >= helper.len) c.atf_tc_fail("fixture path too long");
    const storage: [*]u8 = @ptrCast(c.malloc(capacity) orelse c.atf_tc_fail("capture allocation"));
    defer c.free(storage);
    var accepted = false;
    var skipped = false;
    const attempts: usize = if (catalog.retries(label)) 2 else 1;
    for (0..attempts) |attempt| {
        _ = c.printf("UPSTREAM_BEGIN name=%s attempt=%zu limit_s=120\n", name, attempt + 1);
        _ = c.fflush(null);
        var pipe: [2]c_int = undefined;
        if (c.pipe(&pipe) != 0) c.atf_tc_fail("pipe");
        const pid = c.fork();
        if (pid < 0) c.atf_tc_fail("fork");
        if (pid == 0) {
            const limit = c.struct_rlimit{ .rlim_cur = 0, .rlim_max = 0 };
            _ = c.setrlimit(c.RLIMIT_CORE, &limit);
            _ = c.dup2(pipe[1], 1);
            _ = c.dup2(pipe[1], 2);
            _ = c.close(pipe[0]);
            _ = c.close(pipe[1]);
            _ = c.setenv("NOLEAKS", "1", 1);
            const argv = [_:null]?[*:0]const u8{ "/bin/timeout", "-k", "2", "120", @ptrCast(&harness), @ptrCast(&helper) };
            _ = c.execv(argv[0].?, @ptrCast(&argv));
            c._exit(127);
        }
        _ = c.close(pipe[1]);
        var length: usize = 0;
        var truncated = false;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = c.read(pipe[0], &buf, buf.len);
            if (n < 0) truncated = true;
            if (n <= 0) break;
            const size: usize = @intCast(n);
            _ = c.fwrite(&buf, 1, size, c.stdout());
            const keep = @min(size, capacity - length);
            @memcpy(storage[length..][0..keep], buf[0..keep]);
            length += keep;
            if (keep != size) truncated = true;
        }
        _ = c.close(pipe[0]);
        var status: c_int = -1;
        if (c.waitpid(pid, &status, 0) != pid) status = -1;
        const observed = facts(storage[0..length]);
        _ = c.printf("UPSTREAM_ATTEMPT name=%s attempt=%zu wait_status=%d pid_count=%zu terminal_count=%zu fail_count=%zu bytes=%zu truncated=%d observed_vm_skip=%d\n", name, attempt + 1, status, observed.pid, observed.terminal, observed.failures, length, @as(c_int, @intFromBool(truncated)), @as(c_int, @intFromBool(observed.vm_skip)));
        _ = c.fflush(null);
        if (success(observed, status, truncated)) {
            accepted = true;
            skipped = std.mem.eql(u8, label, "dispatch_vm") and observed.vm_skip;
            break;
        }
    }
    if (io and !unmountTmp()) c.atf_tc_fail("tmpfs cleanup");
    if (!accepted) c.atf_tc_fail("upstream assertions or process/terminal status failed; see every attempt above");
    if (skipped) c.atf_tc_skip("upstream VM test has no supported VM source");
    if (std.mem.eql(u8, label, "dispatch_vm")) c.atf_tc_fail("expected upstream VM test to skip itself");
}
fn cleanup(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), "dispatch_io") and !unmountTmp()) c.atf_tc_fail("tmpfs cleanup after interruption");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "250");
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    const description: [*:0]const u8 = if (std.mem.eql(u8, name, "dispatch_concur")) "id-151 upstream; id-149 occasional, one retry" else if (catalog.retries(name)) "id-151 upstream occasional, one retry" else "id-151 upstream swift-6.4.0-RELEASE";
    _ = c.atf_tc_set_md_var(tc, "descr", "%s", description);
    if (std.mem.eql(u8, name, "dispatch_io")) _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
}
var cases: [catalog.names.len]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (catalog.names, 0..) |name, i| {
        const err = c.atf_tc_init(&cases[i], name, &head, &body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, &add);
}
comptime {
    if (!@import("builtin").is_test) @export(&main, .{ .name = "main" });
}
test "terminal and status, full capture, unique child and no failed assertion required" {
    const good = facts("[PID] 7\n[PASS] Process exited\n");
    try std.testing.expect(success(good, 0, false));
    try std.testing.expect(!success(good, 256, false));
    try std.testing.expect(!success(good, 0, true));
    try std.testing.expect(!success(facts("[PASS] Process exited\n"), 0, false));
    try std.testing.expect(!success(facts("[PID] 7\n[PID] 8\n[PASS] Process exited\n"), 0, false));
    try std.testing.expect(!success(facts("[PID] 7\n[FAIL] assertion\n[PASS] Process exited\n"), 0, false));
    try std.testing.expect(!success(facts("[PID] 7\n"), 0, false));
    try std.testing.expect(!success(good, 11, false));
}
