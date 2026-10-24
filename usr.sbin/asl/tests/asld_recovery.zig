// SPDX-License-Identifier: BSD-2-Clause
// Shared by destructive logging cases and their ATF cleanup processes.
const std = @import("std");
// ATF callbacks have no process.Init; their file operations are synchronous.
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("asl.h");
    @cInclude("launch.h");
});
const a = std.heap.page_allocator;
pub const plist = "/etc/launchd.d/com.apple.syslogd.plist";
fn z(s: []const u8) [:0]u8 {
    return a.dupeZ(u8, s) catch unreachable;
}
pub fn run(args: []const []const u8) bool {
    return runStatus(args) == 0;
}
pub fn runStatus(args: []const []const u8) i32 {
    const argv = a.allocSentinel(?[*:0]const u8, args.len, null) catch unreachable;
    for (args, 0..) |s, i| argv[i] = z(s).ptr;
    const child = c.fork();
    if (child < 0) return -1;
    if (child == 0) {
        _ = c.alarm(4);
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    var status: c_int = 0;
    if (c.waitpid(child, &status, 0) != child) return -1;
    return status;
}
pub fn pid() i32 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, "/var/run/syslog.pid", a, .limited(64)) catch return 0;
    return std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \r\n"), 10) catch 0;
}
pub fn stored(message: [:0]const u8) bool {
    const store = c.asl_open_path("/var/log/asl", 0) orelse return false;
    defer c.asl_release(store);
    const q = c.asl_new(c.ASL_TYPE_QUERY) orelse return false;
    defer c.asl_release(q);
    if (c.asl_set_query(q, "Message", message, c.ASL_QUERY_OP_EQUAL) != 0) return false;
    const list = c.asl_new(c.ASL_TYPE_LIST) orelse return false;
    defer c.asl_release(list);
    c.asl_append(list, q);
    var last: usize = 0;
    const result = c.asl_match(store, list, &last, std.math.maxInt(usize), 1, 100000, -1);
    defer c.asl_release(result);
    return c.asl_next(result) != null;
}
pub fn fileHas(message: []const u8) bool {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, "/var/log/messages", a, .limited(32 * 1024 * 1024)) catch return false;
    defer a.free(raw);
    return std.mem.indexOf(u8, raw, message) != null;
}
pub fn health(label: []const u8) bool {
    const message = std.fmt.allocPrintSentinel(a, "op021.health.{s}.{d}.{d}", .{ label, c.getpid(), std.Io.Clock.real.now(io).nanoseconds }, 0) catch unreachable;
    if (!run(&.{ "/usr/bin/logger", "-p", "user.notice", message })) return false;
    for (0..100) |_| {
        if (stored(message) and fileHas(message)) {
            _ = c.printf("asld_health marker=%s store=1 messages=1 pid=%d\n", message.ptr, pid());
            _ = c.fflush(null);
            return true;
        }
        _ = c.usleep(20000);
    }
    return false;
}
pub fn restore() bool {
    const plist_ok = restorePlist();
    const current = pid();
    if (current > 1) _ = c.kill(current, c.SIGCONT);
    // load is idempotent for an already registered job; do not bypass launchd.
    const registered = capture(&.{ "/bin/launchctl", "list", "com.apple.syslogd" }) != null;
    _ = c.printf("asld_restore registered=%d\n", @as(c_int, if (registered) 1 else 0));
    _ = c.fflush(null);
    if (!registered) _ = run(&.{ "/bin/launchctl", "load", plist });
    for (0..100) |_| {
        const current_pid = pid();
        if (current_pid > 1 and c.kill(current_pid, 0) == 0) {
            const served = health("restore");
            stopTrace();
            return plist_ok and served;
        }
        _ = c.usleep(20000);
    }
    return false;
}
pub fn descriptors(label: []const u8) bool {
    const current = pid();
    const number = std.fmt.allocPrint(a, "{d}", .{current}) catch unreachable;
    _ = c.printf("asld_descriptors phase=%s pid=%d\n", z(label).ptr, current);
    _ = c.fflush(null);
    return run(&.{ "/usr/bin/procstat", "-f", number });
}
// Cleanup is a separate ATF process; atf_tc_fail has no current test there.
pub fn cleanupResult(ok: bool, label: [*:0]const u8) void {
    _ = c.printf("asld_cleanup label=%s restore=%d\n", label, @as(c_int, if (ok) 1 else 0));
    _ = c.fflush(null);
    if (!ok) c._exit(1);
}
fn capture(args: []const []const u8) ?[]u8 {
    var pipes: [2]c_int = undefined;
    if (c.pipe(&pipes) != 0) return null;
    const argv = a.allocSentinel(?[*:0]const u8, args.len, null) catch return null;
    for (args, 0..) |arg, index| argv[index] = z(arg).ptr;
    const child = c.fork();
    if (child == 0) {
        _ = c.alarm(4);
        _ = c.close(pipes[0]);
        _ = c.dup2(pipes[1], 1);
        _ = c.close(pipes[1]);
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    _ = c.close(pipes[1]);
    defer _ = c.close(pipes[0]);
    if (child < 0) return null;
    const buffer = a.alloc(u8, 65536) catch return null;
    var used: usize = 0;
    while (used < buffer.len) {
        const n = c.read(pipes[0], buffer[used..].ptr, buffer.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    if (used == buffer.len) _ = c.kill(child, c.SIGKILL);
    var status: c_int = 0;
    if (c.waitpid(child, &status, 0) != child or status != 0) return null;
    return buffer[0..used];
}
pub fn serviceAbsent() bool {
    const request = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY) orelse return false;
    defer c.launch_data_free(request);
    const name = c.launch_data_new_string("com.apple.system.logger") orelse return false;
    _ = c.launch_data_dict_insert(request, name, "GetServiceState");
    const reply = c.launch_msg(request) orelse return false;
    defer c.launch_data_free(reply);
    if (c.launch_data_get_type(reply) != c.LAUNCH_DATA_DICTIONARY) return false;
    const registered = c.launch_data_dict_lookup(reply, "Registered") orelse return false;
    const receive = c.launch_data_dict_lookup(reply, "ReceiveRightInLaunchd") orelse return false;
    return c.launch_data_get_type(registered) == c.LAUNCH_DATA_BOOL and c.launch_data_get_type(receive) == c.LAUNCH_DATA_BOOL and !c.launch_data_get_bool(registered) and !c.launch_data_get_bool(receive);
}
fn observed(label: []const u8, args: []const []const u8) i32 {
    _ = c.printf("asld_capture phase=%s argv=", z(label).ptr);
    for (args) |arg| _ = c.printf("%s ", z(arg).ptr);
    _ = c.printf("\n");
    _ = c.fflush(null);
    const status = runStatus(args);
    _ = c.printf("asld_capture phase=%s wait_status=%d\n", z(label).ptr, status);
    _ = c.fflush(null);
    return status;
}
pub fn snapshot(label: []const u8) i32 {
    _ = c.printf("asld_snapshot phase=%s pidfile=%d\n", z(label).ptr, pid());
    _ = c.fflush(null);
    const listed = observed(label, &.{ "/bin/launchctl", "list", "com.apple.syslogd" });
    _ = c.printf("asld_snapshot phase=%s list_status=%d\n", z(label).ptr, listed);
    _ = c.fflush(null);
    _ = observed(label, &.{ "/bin/launchctl", "service-state", "com.apple.system.logger" });
    // Enumerate processes: a missing/stale pidfile must not hide a replacement.
    const raw = capture(&.{ "/bin/ps", "-ax", "-o", "pid=,comm=" });
    if (raw) |processes| {
        var lines = std.mem.splitScalar(u8, processes, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const number = fields.next() orelse continue;
            const comm = fields.next() orelse continue;
            if (!std.mem.eql(u8, comm, "asld")) continue;
            const number_z = z(number);
            _ = c.printf("asld_process phase=%s pid=%s\n", z(label).ptr, number_z.ptr);
            _ = c.fflush(null);
            _ = observed(label, &.{ "/bin/ps", "-p", number, "-o", "pid,ppid,lstart,state,wchan,command" });
            _ = observed(label, &.{ "/usr/bin/procstat", "-f", number });
            _ = observed(label, &.{ "/usr/bin/procstat", "-kk", number });
        }
    } else {
        _ = c.printf("asld_process phase=%s enumeration_failed=1\n", z(label).ptr);
    }
    _ = observed(label, &.{ "/bin/cat", "/var/log/asld.stderr.log" });
    _ = observed(label, &.{ "/bin/cat", "/var/log/asld.restart.debug" });
    _ = c.fflush(null);
    return listed;
}
const saved_plist = "/tmp/op026-syslogd.original.plist";
pub fn traceStartup() bool {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, plist, a, .limited(32768)) catch return false;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = saved_plist, .data = raw }) catch return false;
    const traced = std.mem.replaceOwned(u8, a, raw, "<string>/usr/sbin/asld</string>", "<string>/usr/sbin/asld</string><string>-d</string><string>/var/log/asld.restart.debug</string>") catch return false;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = plist, .data = traced }) catch return false;
    return true;
}
pub fn restorePlist() bool {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, saved_plist, a, .limited(32768)) catch |err| return err == error.FileNotFound;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = plist, .data = raw }) catch return false;
    std.Io.Dir.cwd().deleteFile(io, saved_plist) catch return false;
    return true;
}
pub fn stopTrace() void {
    const message = c.asl_new(c.ASL_TYPE_MSG) orelse return;
    defer c.asl_release(message);
    _ = c.asl_set(message, "Option", "control");
    _ = c.asl_set(message, "Message", "= debug 0");
    _ = c.asl_send(null, message);
}
