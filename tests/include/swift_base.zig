// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const a = std.heap.page_allocator;
var tc: c.atf_tc_t = undefined;
const library = "/usr/lib/swift/libop170_swift.so.1";
fn need(ok: bool, message: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", message);
}
fn command(args: []const ?[*:0]const u8) []const u8 {
    var p: [2]c_int = undefined;
    need(c.pipe(&p) == 0, "capture pipe");
    const pid = c.fork();
    need(pid >= 0, "fork");
    if (pid == 0) {
        _ = c.close(p[0]);
        _ = c.dup2(p[1], 1);
        _ = c.dup2(p[1], 2);
        _ = c.close(p[1]);
        _ = c.unsetenv("LD_LIBRARY_PATH");
        _ = c.unsetenv("LD_PRELOAD");
        _ = c.alarm(15);
        _ = c.execv(args[0].?, @ptrCast(args.ptr));
        c._exit(127);
    }
    _ = c.close(p[1]);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(p[0], &buf, buf.len);
        need(n >= 0, "read command");
        if (n == 0) break;
        out.appendSlice(a, buf[0..@intCast(n)]) catch c.abort();
    }
    _ = c.close(p[0]);
    var status: c_int = -1;
    need(c.waitpid(pid, &status, 0) == pid, "wait command");
    _ = c.printf("op170 program=%s wait_status=%d output=%.*s\n", args[0].?, status, @as(c_int, @intCast(out.items.len)), out.items.ptr);
    _ = c.fflush(null);
    need(status == 0, "command exited successfully");
    return out.toOwnedSlice(a) catch c.abort();
}
fn searchOrder(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const marker = "search directories: ";
        if (std.mem.indexOf(u8, line, marker)) |i| {
            const dirs = line[i + marker.len ..];
            return std.mem.eql(u8, dirs, "/lib:/usr/lib:/usr/lib/swift:/usr/lib/compat") or
                std.mem.startsWith(u8, dirs, "/lib:/usr/lib:/usr/lib/swift:/usr/lib/compat:");
        }
    }
    return false;
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.unlink(library);
    const out = command(&.{ "/usr/sbin/service", "ldconfig", "start", null });
    a.free(out);
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    var st: c.struct_stat = undefined;
    need(c.stat("/usr/lib/swift", &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFDIR, "base Swift directory exists");
    const before = command(&.{ "/sbin/ldconfig", "-r", null });
    defer a.free(before);
    need(searchOrder(before), "defaults then Swift then compat in boot hints");
    need(c.lstat(library, &st) != 0, "fixture library initially absent");
    const srcdir = std.mem.span(c.atf_tc_get_config_var(t, "srcdir"));
    const src = std.fmt.allocPrint(a, "{s}/libop170_swift.so.1", .{srcdir}) catch c.abort();
    defer a.free(src);
    std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), library, io, .{}) catch c.atf_tc_fail("copy fixture library");
    _ = c.chmod(library, 0o555);
    const refresh = command(&.{ "/usr/sbin/service", "ldconfig", "start", null });
    defer a.free(refresh);
    const executable = std.fmt.allocPrintSentinel(a, "{s}/swift_lookup", .{srcdir}, 0) catch c.abort();
    defer a.free(executable);
    const result = command(&.{ executable, null });
    defer a.free(result);
    need(std.mem.eql(u8, result, "op170_swift_runtime observed=170 expected=170\n"), "runtime resolved without RUNPATH or LD_LIBRARY_PATH");
    cleanup(t);
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const e = c.atf_tc_init(&tc, "runtime_search", null, body, cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(e)) return e;
    return c.atf_tp_add_tc(tp, &tc);
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, add);
}
comptime {
    if (!@import("builtin").is_test) @export(&main, .{ .name = "main" });
}
test "search path has exact loader defaults and Swift before compat" {
    try std.testing.expect(searchOrder("/var/run/ld-elf.so.hints:\n\tsearch directories: /lib:/usr/lib:/usr/lib/swift:/usr/lib/compat:/usr/local/lib\n"));
    try std.testing.expect(!searchOrder("search directories: /lib:/usr/lib:/usr/lib/compat:/usr/lib/swift\n"));
    try std.testing.expect(!searchOrder("search directories: /lib:/usr/lib:/usr/lib/swiftly:/usr/lib/compat\n"));
    try std.testing.expect(!searchOrder("unrelated /lib:/usr/lib:/usr/lib/swift:/usr/lib/compat\n"));
}
