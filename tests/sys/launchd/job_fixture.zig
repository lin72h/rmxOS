// Run a test under launchd when the interactive shell has no bootstrap port.
const std = @import("std");
pub const budget = @import("logging_budget.zig");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("atf-c.h");
});
const a = std.heap.page_allocator;
pub fn stoppedLimits() budget.Limits {
    return budget.limits(budget.running() catch c.atf_tc_fail("query kern.features.kasan"));
}
pub fn z(s: []const u8) [:0]const u8 {
    return a.dupeZ(u8, s) catch c.atf_tc_fail("fixture allocation");
}
pub fn run(args: []const []const u8) i32 {
    const argv = a.allocSentinel(?[*:0]const u8, args.len, null) catch c.atf_tc_fail("argv allocation");
    for (args, 0..) |s, i| argv[i] = z(s).ptr;
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fixture fork");
    if (pid == 0) {
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) c.atf_tc_fail("fixture wait");
    return status;
}
pub fn enter(binary: []const u8, case_name: []const u8) bool {
    if (c.getenv("OP789_LAUNCHD_CHILD") != null) return true;
    const dir = std.fmt.allocPrint(a, "/tmp/op789-test-{d}", .{c.getpid()}) catch unreachable;
    std.fs.cwd().makePath(dir) catch c.atf_tc_fail("fixture directory");
    const label = std.fmt.allocPrint(a, "com.rmxos.op789.runner.{d}", .{c.getpid()}) catch unreachable;
    const plist = std.fmt.allocPrint(a, "{s}/job.plist", .{dir}) catch unreachable;
    const result = std.fmt.allocPrint(a, "{s}/result", .{dir}) catch unreachable;
    const output = std.fmt.allocPrint(a, "{s}/stdout", .{dir}) catch unreachable;
    const text = std.fmt.allocPrint(a, "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>{s}</string><key>ProgramArguments</key><array><string>{s}</string><string>-r</string><string>{s}</string><string>{s}</string></array><key>WorkingDirectory</key><string>{s}</string><key>StandardOutPath</key><string>{s}</string><key>StandardErrorPath</key><string>{s}/stderr</string><key>EnvironmentVariables</key><dict><key>OP789_LAUNCHD_CHILD</key><string>1</string></dict><key>RunAtLoad</key><true/></dict></plist>", .{ label, binary, result, case_name, dir, output, dir }) catch unreachable;
    std.fs.cwd().writeFile(.{ .sub_path = plist, .data = text }) catch c.atf_tc_fail("fixture plist");
    const state = std.fmt.allocPrint(a, "/tmp/op789-runner-{s}", .{case_name}) catch unreachable;
    std.fs.cwd().writeFile(.{ .sub_path = state, .data = std.fmt.allocPrint(a, "{s}\n{s}\n", .{ label, dir }) catch unreachable }) catch c.atf_tc_fail("fixture state");
    if (run(&.{ "/bin/launchctl", "load", plist }) != 0) c.atf_tc_fail("fixture load");
    defer {
        _ = run(&.{ "/bin/launchctl", "remove", label });
        std.fs.cwd().deleteTree(dir) catch {};
        std.fs.cwd().deleteFile(state) catch {};
    }
    var printed: usize = 0;
    const polls: usize = if (std.mem.eql(u8, case_name, "stopped")) @as(usize, stoppedLimits().parent_seconds) * 10 else if (std.mem.eql(u8, case_name, "churn")) 11500 else 2000;
    for (0..polls) |_| {
        const progress = std.fs.cwd().readFileAlloc(a, output, 1048576) catch "";
        if (progress.len > printed) {
            _ = c.printf("%.*s", @as(c_int, @intCast(progress.len - printed)), progress[printed..].ptr);
            _ = c.fflush(null);
            printed = progress.len;
        }
        const bytes = std.fs.cwd().readFileAlloc(a, result, 4096) catch {
            _ = c.usleep(100000);
            continue;
        };
        if (bytes.len == 0) {
            _ = c.usleep(100000);
            continue;
        }
        const observed = std.fs.cwd().readFileAlloc(a, output, 1048576) catch "";
        if (observed.len > printed) _ = c.printf("%.*s", @as(c_int, @intCast(observed.len - printed)), observed[printed..].ptr);
        const stderr_path = std.fmt.allocPrint(a, "{s}/stderr", .{dir}) catch unreachable;
        const diagnostic = std.fs.cwd().readFileAlloc(a, stderr_path, 1048576) catch "";
        if (diagnostic.len > 0) _ = c.printf("launchd_fixture_stderr %.*s\n", @as(c_int, @intCast(diagnostic.len)), diagnostic.ptr);
        _ = c.printf("launchd_fixture case=%s result=%.*s", z(case_name).ptr, @as(c_int, @intCast(bytes.len)), bytes.ptr);
        if (!std.mem.eql(u8, bytes, "passed\n")) c.atf_tc_fail("launchd child case failed");
        return false;
    }
    c.atf_tc_fail("launchd child case timed out");
}

pub fn capture(args: []const []const u8) []const u8 {
    const file = c.tmpfile() orelse c.atf_tc_fail("capture file");
    defer _ = c.fclose(file);
    const argv = a.allocSentinel(?[*:0]const u8, args.len, null) catch unreachable;
    for (args, 0..) |s, i| argv[i] = z(s).ptr;
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("capture fork");
    if (pid == 0) {
        _ = c.dup2(c.fileno(file), 1);
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid or status != 0) c.atf_tc_fail("capture child status");
    _ = c.fseek(file, 0, c.SEEK_END);
    const n = c.ftell(file);
    if (n < 0 or n > 16777216) c.atf_tc_fail("capture length");
    _ = c.fseek(file, 0, c.SEEK_SET);
    const bytes = a.alloc(u8, @intCast(n)) catch unreachable;
    if (c.fread(bytes.ptr, 1, bytes.len, file) != bytes.len) c.atf_tc_fail("capture read");
    return bytes;
}

pub fn cleanup(case_name: []const u8) void {
    const state = std.fmt.allocPrint(a, "/tmp/op789-runner-{s}", .{case_name}) catch unreachable;
    const bytes = std.fs.cwd().readFileAlloc(a, state, 4096) catch return;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const label = lines.next() orelse return;
    const dir = lines.next() orelse return;
    if (!std.mem.startsWith(u8, label, "com.rmxos.op789.runner.") or !std.mem.startsWith(u8, dir, "/tmp/op789-test-")) c.atf_tc_fail("fixture cleanup state");
    _ = run(&.{ "/bin/launchctl", "remove", label });
    std.fs.cwd().deleteTree(dir) catch {};
    std.fs.cwd().deleteFile(state) catch {};
}
