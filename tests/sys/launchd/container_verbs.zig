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
const names = [_][*:0]const u8{ "managernameSystem", "bootstrapSessionArray", "bootstrapDashSUnchanged", "printExitStatus", "bootoutStopsJob", "listRunningJob", "listExitedJob" };
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
    return jobPlist(l, system, "<string>/bin/sleep</string><string>300</string>");
}
fn jobPlist(l: []const u8, system: bool, arguments: []const u8) []const u8 {
    const directory = if (c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp";
    const path = fmt("{s}/container-verbs-{d}.plist", .{ directory, c.getpid() });
    const text = fmt("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>{s}</string><key>LimitLoadToSessionType</key><array><string>Aqua</string><string>Background</string>{s}</array><key>RunAtLoad</key><true/><key>MachServices</key><dict><key>{s}.service</key><true/></dict><key>ProgramArguments</key><array>{s}</array></dict></plist>\n", .{ l, if (system) @as([]const u8, "<string>System</string>") else "", l, arguments });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch c.atf_tc_fail("write plist");
    return path;
}
fn cleanup(l: []const u8, path: []const u8) void {
    // Cleanup uses the established synchronous unload, including on the base.
    _ = l;
    cleanupWith("/bin/launchctl", path);
}
fn cleanupWith(b: []const u8, path: []const u8) void {
    _ = run(b, &.{ "unload", path }, false);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
fn load(b: []const u8, l: []const u8, path: []const u8) void {
    _ = l;
    check(run(b, &.{ "bootstrap", "system", path }, false).rc == 0, "bootstrap system must load session array");
}
fn printedPid(out: []const u8) ?c_int {
    const at = std.mem.indexOf(u8, out, "pid = ") orelse return null;
    const text = std.mem.trim(u8, out[at + 6 ..], " \r\n");
    const pid = std.fmt.parseInt(c_int, text, 10) catch return null;
    return if (pid > 0) pid else null;
}
fn pidFrom(b: []const u8, l: []const u8) c_int {
    for (0..100) |_| {
        const r = run(b, &.{ "print", target(l) }, false);
        check(r.rc == 0, "loaded job print must exit 0");
        if (printedPid(r.out)) |pid| return pid;
        _ = c.usleep(50000);
    }
    c.atf_tc_fail("job did not start");
}
const ListRow = struct { pid: []const u8, status: []const u8 };
fn listedRow(out: []const u8, label_name: []const u8) !ListRow {
    if (!std.mem.endsWith(u8, out, "\n")) return error.UnterminatedList;
    var lines = std.mem.splitScalar(u8, out[0 .. out.len - 1], '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "PID\tStatus\tLabel"))
        return error.ListHeaderMismatch;
    var found: ?ListRow = null;
    var container_found = false;
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const pid = fields.next() orelse return error.MissingPidField;
        const status = fields.next() orelse return error.MissingStatusField;
        const name = fields.next() orelse return error.MissingLabelField;
        if (fields.next() != null or pid.len == 0 or status.len == 0 or name.len == 0)
            return error.InvalidListRow;
        if (std.mem.eql(u8, name, label_name)) {
            if (found != null) return error.DuplicateLabel;
            found = .{ .pid = pid, .status = status };
        }

        // ServiceManager splits lines on whitespace and takes the third word.
        var words = std.mem.tokenizeAny(u8, line, " \t\r\n\x0b\x0c");
        _ = words.next();
        _ = words.next();
        if (words.next()) |third|
            container_found = container_found or std.mem.eql(u8, third, label_name);
    }
    if (!container_found) return error.ContainerLabelMissing;
    return found orelse error.ManagedJobMissing;
}
fn listJob(b: []const u8, exits: bool) !void {
    const l = fmt("com.apple.container.op703.{d}", .{c.getpid()});
    const path = if (exits)
        jobPlist(l, true, "<string>/bin/sh</string><string>-c</string><string>exit 3</string>")
    else
        plist(l, true);
    defer cleanupWith(b, path);
    if (run(b, &.{ "bootstrap", "system", path }, false).rc != 0)
        return error.JobBootstrapFailed;
    for (0..100) |_| {
        const result = run(b, &.{"list"}, false);
        if (result.rc != 0 or result.err.len != 0) return error.ListCommandFailed;
        const row = try listedRow(result.out, l);
        if (exits) {
            if (std.mem.eql(u8, row.pid, "-") and std.mem.eql(u8, row.status, "3"))
                return;
        } else if (std.fmt.parseInt(c_int, row.pid, 10)) |pid| {
            const printed = run(b, &.{ "print", target(l) }, false);
            if (pid <= 0 or printed.rc != 0 or printedPid(printed.out) != pid or c.kill(pid, 0) != 0)
                return error.ListPidMismatch;
            if (!std.mem.eql(u8, row.status, "-")) return error.RunningStatusMismatch;
            return;
        } else |_| {}
        _ = c.usleep(50000);
    }
    return error.ListJobStateTimeout;
}
fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    const b = selectedBinary(tc);
    const exits = std.mem.eql(u8, name, "listExitedJob");
    if (exits or std.mem.eql(u8, name, "listRunningJob")) {
        listJob(b, exits) catch |e| c.atf_tc_fail("launchctl list fixture: %s", @errorName(e).ptr);
        return;
    }
    if (std.mem.eql(u8, name, "managernameSystem")) {
        const r = run(b, &.{"managername"}, false);
        check(r.rc == 0 and std.mem.eql(u8, r.out, "System\n") and r.err.len == 0, "managername must print System LF");
        return;
    }
    if (std.mem.eql(u8, name, "bootstrapDashSUnchanged")) {
        // Force fork failure inside runcom: exercises -S System without rerunning rc.
        // op-247 recorded this result for both base and selected launchctl.
        const expected = Result{ .rc = 1, .out = "", .err = "launchctl: fork /etc/rc: Resource temporarily unavailable\n" };
        const r = run(b, &.{ "bootstrap", "-S", "System" }, true);
        check(r.rc == expected.rc and std.mem.eql(u8, r.out, expected.out) and std.mem.eql(u8, r.err, expected.err), "-S System status and output must match recorded result");
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
