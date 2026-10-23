// SPDX-License-Identifier: BSD-2-Clause
// Shared by destructive logging cases and their ATF cleanup processes.
const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("asl.h");
});
const a = std.heap.page_allocator;
pub const plist = "/etc/launchd.d/com.apple.syslogd.plist";
fn z(s: []const u8) [:0]u8 {
    return a.dupeZ(u8, s) catch unreachable;
}
pub fn run(args: []const []const u8) bool {
    const argv = a.allocSentinel(?[*:0]const u8, args.len, null) catch unreachable;
    for (args, 0..) |s, i| argv[i] = z(s).ptr;
    const child = c.fork();
    if (child < 0) return false;
    if (child == 0) {
        _ = c.alarm(4);
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    var status: c_int = 0;
    return c.waitpid(child, &status, 0) == child and status == 0;
}
pub fn pid() i32 {
    const raw = std.fs.cwd().readFileAlloc(a, "/var/run/syslog.pid", 64) catch return 0;
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
    const raw = std.fs.cwd().readFileAlloc(a, "/var/log/messages", 32 * 1024 * 1024) catch return false;
    defer a.free(raw);
    return std.mem.indexOf(u8, raw, message) != null;
}
pub fn health(label: []const u8) bool {
    const message = std.fmt.allocPrintSentinel(a, "op021.health.{s}.{d}.{d}", .{ label, c.getpid(), std.time.nanoTimestamp() }, 0) catch unreachable;
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
    const current = pid();
    if (current > 1) _ = c.kill(current, c.SIGCONT);
    // load is idempotent for an already registered job; do not bypass launchd.
    _ = run(&.{ "/bin/launchctl", "load", plist });
    for (0..100) |_| {
        const current_pid = pid();
        if (current_pid > 1 and c.kill(current_pid, 0) == 0) return health("restore");
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
