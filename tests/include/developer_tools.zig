// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
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
    @cInclude("string.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [5]c.atf_tc_t = undefined;
var executable: [*:0]const u8 = undefined;
fn need(ok: bool, message: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", message);
}
const Result = struct { status: c_int, bytes: [2048]u8, len: usize };
fn run(argv: []const ?[*:0]const u8, developer: ?[*:0]const u8) Result {
    var pipe: [2]c_int = undefined;
    need(c.pipe(&pipe) == 0, "capture pipe");
    const pid = c.fork();
    need(pid >= 0, "fork launcher");
    if (pid == 0) {
        _ = c.close(pipe[0]);
        _ = c.dup2(pipe[1], 1);
        _ = c.dup2(pipe[1], 2);
        _ = c.close(pipe[1]);
        _ = c.alarm(3);
        if (developer) |dir| {
            _ = c.setenv("DEVELOPER_DIR", dir, 1);
        } else _ = c.unsetenv("DEVELOPER_DIR");
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    _ = c.close(pipe[1]);
    var result: Result = .{ .status = -1, .bytes = undefined, .len = 0 };
    while (result.len < result.bytes.len) {
        const n = c.read(pipe[0], result.bytes[result.len..].ptr, result.bytes.len - result.len);
        need(n >= 0, "read launcher output");
        if (n == 0) break;
        result.len += @intCast(n);
    }
    _ = c.close(pipe[0]);
    need(c.waitpid(pid, &result.status, 0) == pid, "wait launcher");
    _ = c.printf("op065_tool program=%s wait_status=%d output=%.*s\n", argv[0].?, result.status, @as(c_int, @intCast(result.len)), result.bytes[0..result.len].ptr);
    return result;
}
fn absentSelection() void {
    var st: c.struct_stat = undefined;
    need(c.lstat("/var/db/xcode_select_link", &st) != 0, "guest has no selection");
    need(c.lstat("/Library/Developer/CommandLineTools", &st) != 0, "guest has no default tools");
}
fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    if (std.mem.eql(u8, name, "sdk")) {
        const r = run(&.{ "/usr/bin/xcrun", "--show-sdk-path", null }, null);
        need(r.status == 0 and std.mem.eql(u8, r.bytes[0..r.len], "/\n"), "SDK path is slash");
    } else if (std.mem.eql(u8, name, "selection")) {
        absentSelection();
        const r = run(&.{ "/usr/bin/xcode-select", "-p", null }, null);
        need(r.status == 256, "absent selection exits one");
    } else if (std.mem.eql(u8, name, "swift")) {
        absentSelection();
        var first: c.struct_stat = undefined;
        need(c.stat("/usr/bin/xcrun", &first) == 0 and first.st_nlink == 8, "xcrun has seven hard links");
        inline for (.{ "swift", "swiftc", "swift-build", "swift-test", "swift-run", "swift-package", "sourcekit-lsp" }) |alias| {
            var st: c.struct_stat = undefined;
            need(c.stat("/usr/bin/" ++ alias, &st) == 0 and st.st_ino == first.st_ino and st.st_dev == first.st_dev, "launcher alias shares xcrun inode");
        }
        const x = run(&.{ "/usr/bin/xcrun", "swift", null }, null);
        const swift = run(&.{ "/usr/bin/swift", null }, null);
        need(x.status == 256 and swift.status == 256 and std.mem.eql(u8, x.bytes[0..x.len], swift.bytes[0..swift.len]), "swift reports the same missing-tools error");
    } else {
        var directory = "/tmp/op065-tools-XXXXXX".* ++ [_]u8{0};
        need(c.mkdtemp(@ptrCast(&directory)) != null, "temporary developer directory");
        defer _ = c.rmdir(@ptrCast(&directory));
        var buffer: [256]u8 = undefined;
        const usr = std.fmt.bufPrintZ(&buffer, "{s}/usr", .{std.mem.sliceTo(&directory, 0)}) catch unreachable;
        need(c.mkdir(usr, 0o700) == 0, "developer usr");
        var bin_buffer: [256]u8 = undefined;
        const bin = std.fmt.bufPrintZ(&bin_buffer, "{s}/usr/bin", .{std.mem.sliceTo(&directory, 0)}) catch unreachable;
        need(c.mkdir(bin, 0o700) == 0, "developer bin");
        defer _ = c.rmdir(usr);
        defer _ = c.rmdir(bin);
        var path_buffer: [256]u8 = undefined;
        const hello = std.fmt.bufPrintZ(&path_buffer, "{s}/hello", .{bin}) catch unreachable;
        need(c.link(executable, hello) == 0, "hello executable fixture");
        defer _ = c.unlink(hello);
        if (std.mem.eql(u8, name, "run")) {
            const r = run(&.{ "/usr/bin/xcrun", "hello", null }, @ptrCast(&directory));
            need(r.status == 0 and std.mem.eql(u8, r.bytes[0..r.len], "op065 hello\n"), "selected hello executes");
        } else {
            const r = run(&.{ "/usr/bin/xcrun", "--find", "hello", null }, @ptrCast(&directory));
            var expected: [257]u8 = undefined;
            const text = std.fmt.bufPrint(&expected, "{s}\n", .{hello}) catch unreachable;
            need(r.status == 0 and std.mem.eql(u8, r.bytes[0..r.len], text), "selected hello path");
        }
    }
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for ([_][*:0]const u8{ "sdk", "selection", "run", "find", "swift" }, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, null, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (std.mem.eql(u8, std.fs.path.basename(std.mem.span(argv[0])), "hello")) {
        _ = c.puts("op065 hello");
        return 0;
    }
    executable = @ptrCast(argv[0]);
    return atf_tp_main(argc, argv, add);
}
