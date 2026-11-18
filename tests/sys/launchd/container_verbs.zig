// Container service-manager contract. Each case selects launchctl via -v launchctl=.
const std = @import("std");
const io = std.Io.Threaded.global_single_threaded.io();
const a = std.heap.page_allocator;
const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{ "managernameSystem", "bootstrapSessionArray", "bootstrapDashSUnchanged", "printExitStatus", "bootoutStopsJob" };
var cases: [names.len]c.atf_tc_t = undefined;
const Result = struct { rc: c_int, out: []const u8, err: []const u8 };
fn z(s: []const u8) [:0]const u8 {
    return a.dupeZ(u8, s) catch unreachable;
}
fn fmt(comptime s: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, s, args) catch unreachable;
}
fn check(ok: bool, why: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", why);
}
fn read(file: *c.FILE) []const u8 {
    check(c.fseek(file, 0, c.SEEK_END) == 0, "capture seek");
    const n = c.ftell(file);
    check(n >= 0 and n < 1048576, "capture size");
    check(c.fseek(file, 0, c.SEEK_SET) == 0, "capture rewind");
    const bytes = a.alloc(u8, @intCast(n)) catch unreachable;
    check(c.fread(bytes.ptr, 1, bytes.len, file) == bytes.len, "capture read");
    return bytes;
}
fn run(binary: []const u8, args: []const []const u8, preload: bool) Result {
    const out = c.tmpfile() orelse unreachable;
    const err = c.tmpfile() orelse unreachable;
    defer _ = c.fclose(out);
    defer _ = c.fclose(err);
    const av = a.allocSentinel(?[*:0]const u8, args.len + 1, null) catch unreachable;
    av[0] = z(binary).ptr;
    for (args, 1..) |s, i| av[i] = z(s).ptr;
    const pid = c.fork();
    check(pid >= 0, "fork command");
    if (pid == 0) {
        _ = c.dup2(c.fileno(out), 1);
        _ = c.dup2(c.fileno(err), 2);
        if (preload) _ = c.setenv("LD_PRELOAD", "/usr/tests/sys/launchd/container_dash_s.so", 1);
        _ = c.execv(av[0].?, @ptrCast(av.ptr));
        c._exit(127);
    }
    var status: c_int = 0;
    check(c.waitpid(pid, &status, 0) == pid, "wait command");
    const rc: c_int = if (status & 127 == 0) (status >> 8) & 255 else 128 + (status & 127);
    const result = Result{ .rc = rc, .out = read(out), .err = read(err) };
    _ = c.printf("command=%s", z(binary).ptr);
    for (args) |arg| _ = c.printf(" %s", z(arg).ptr);
    _ = c.printf(" rc=%d stdout=[%.*s] stderr=[%.*s]\n", rc, @as(c_int, @intCast(result.out.len)), result.out.ptr, @as(c_int, @intCast(result.err.len)), result.err.ptr);
    _ = c.fflush(null);
    return result;
}
fn selectedBinary(tc: [*c]const c.atf_tc_t) []const u8 {
    return std.mem.span(c.atf_tc_get_config_var_wd(tc, "launchctl", "/bin/launchctl"));
}
fn label() []const u8 {
    return fmt("com.rmxos.container-verbs.{d}", .{c.getpid()});
}
fn target(l: []const u8) []const u8 {
    return fmt("system/{s}", .{l});
}
fn plist(l: []const u8, system: bool) []const u8 {
    const path = fmt("/tmp/container-verbs-{d}.plist", .{c.getpid()});
    const text = fmt("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>{s}</string><key>LimitLoadToSessionType</key><array><string>Aqua</string><string>Background</string>{s}</array><key>RunAtLoad</key><true/><key>MachServices</key><dict><key>{s}.service</key><true/></dict><key>ProgramArguments</key><array><string>/bin/sleep</string><string>300</string></array></dict></plist>\n", .{ l, if (system) @as([]const u8, "<string>System</string>") else "", l });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch c.atf_tc_fail("write plist");
    return path;
}
fn cleanup(l: []const u8, path: []const u8) void {
    // Cleanup uses the established synchronous unload, including on the base.
    _ = l;
    _ = run("/bin/launchctl", &.{ "unload", path }, false);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
fn load(b: []const u8, l: []const u8, path: []const u8) void {
    _ = l;
    check(run(b, &.{ "bootstrap", "system", path }, false).rc == 0, "bootstrap system must load session array");
}
fn pidFrom(b: []const u8, l: []const u8) c_int {
    for (0..100) |_| {
        const r = run(b, &.{ "print", target(l) }, false);
        check(r.rc == 0, "loaded job print must exit 0");
        if (std.mem.indexOf(u8, r.out, "pid = ")) |at| {
            const text = std.mem.trim(u8, r.out[at + 6 ..], " \r\n");
            const pid = std.fmt.parseInt(c_int, text, 10) catch 0;
            if (pid > 0) return pid;
        }
        _ = c.usleep(50000);
    }
    c.atf_tc_fail("job did not start");
}
fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    const b = selectedBinary(tc);
    if (std.mem.eql(u8, name, "managernameSystem")) {
        const r = run(b, &.{"managername"}, false);
        check(r.rc == 0 and std.mem.eql(u8, r.out, "System\n") and r.err.len == 0, "managername must print System LF");
        return;
    }
    if (std.mem.eql(u8, name, "bootstrapDashSUnchanged")) {
        // Force fork failure inside runcom: exercises -S System without rerunning rc.
        // The same injected boundary and argv[0] basename apply to both binaries.
        const base = run("/usr/tests/sys/launchd/base/launchctl", &.{ "bootstrap", "-S", "System" }, true);
        const r = run(b, &.{ "bootstrap", "-S", "System" }, true);
        check(base.rc == 1 and std.mem.indexOf(u8, base.err, "fork /etc/rc") != null, "base must reach runcom fork boundary");
        check(r.rc == base.rc and std.mem.eql(u8, r.out, base.out) and std.mem.eql(u8, r.err, base.err), "-S System status and output must match base");
        return;
    }
    const l = label();
    const path = plist(l, true);
    defer cleanup(l, path);
    if (std.mem.eql(u8, name, "bootstrapSessionArray")) {
        load(b, l, path);
        check(run(b, &.{ "print", target(l) }, false).rc == 0, "array job loaded");
        check(run(b, &.{ "bootout", target(l) }, false).rc == 0, "remove first array job");
        _ = plist(l, false);
        const r = run(b, &.{ "bootstrap", "system", path }, false);
        check(r.rc != 0 and std.mem.indexOf(u8, r.err, "does not include current manager System") != null, "unmatched array must fail with stderr reason");
        check(run(b, &.{ "print", target(l) }, false).rc == 113, "unmatched array must leave job unloaded");
        for ([_][]const u8{ "user/0", "gui/0" }) |domain| {
            const denied = run(b, &.{ "bootstrap", domain, path }, false);
            check(denied.rc != 0 and denied.err.len > 0, "non-system bootstrap refused");
            for ([_][]const u8{ "print", "bootout" }) |verb| {
                const d = run(b, &.{ verb, fmt("{s}/{s}", .{ domain, l }) }, false);
                check(d.rc != 0 and d.err.len > 0, "non-system service target refused");
            }
        }
        const missing = run(b, &.{ "bootstrap", "system", "/tmp/container-verbs-no-such-file.plist" }, false);
        check(missing.rc != 0 and missing.err.len > 0, "failed load reason on stderr");
        return;
    }
    if (std.mem.eql(u8, name, "printExitStatus")) {
        check(run(b, &.{ "print", target(l) }, false).rc == 113, "never-loaded job must exit 113");
        load(b, l, path);
        const r = run(b, &.{ "print", target(l) }, false);
        check(r.rc == 0 and std.mem.indexOf(u8, r.out, l) != null and (std.mem.indexOf(u8, r.out, "pid =") != null or std.mem.indexOf(u8, r.out, "state =") != null), "print label and pid or state");
        check(run(b, &.{ "bootout", target(l) }, false).rc == 0, "bootout loaded job");
        check(run(b, &.{ "print", target(l) }, false).rc == 113, "removed job must exit 113");
        const absent = run(b, &.{ "bootout", target(l) }, false);
        check(absent.rc == 113 and absent.err.len > 0, "absent bootout code 113 and stderr reason");
        return;
    }
    load(b, l, path);
    const pid = pidFrom(b, l);
    check(c.kill(pid, 0) == 0, "job process must exist");
    check(run(b, &.{ "bootout", target(l) }, false).rc == 0, "bootout running job");
    check(c.kill(pid, 0) == -1 and c.__error().* == c.ESRCH, "bootout must wait for process exit");
    check(run(b, &.{ "print", target(l) }, false).rc == 113, "bootout must remove job");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, null, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        _ = c.atf_tc_set_md_var(&cases[i], "require.user", "root");
        _ = c.atf_tc_set_md_var(&cases[i], "timeout", "30");
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
