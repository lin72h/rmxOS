// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const scope = @import("log_store_scope.zig");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("atf-c.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("grp.h");
    @cInclude("pwd.h");
    @cInclude("sys/wait.h");
    @cInclude("syslog.h");
    @cInclude("time.h");
    @cInclude("sys/mach/message.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn __sys_task_self_trap() c_uint;
extern fn __sys_mach_reply_port() c_uint;
extern fn __sys_mach_msg_trap(*c.mach_msg_header_t, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint) c_int;
extern fn __sys__kernelrpc_mach_port_deallocate_trap(c_uint, c_uint) c_int;
extern fn __sys__kernelrpc_mach_port_destroy_trap(c_uint, c_uint) c_int;
extern fn _simple_asl_log_prog(c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8) void;
fn need(ok: bool, text: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", text);
}
fn childNeed(ok: bool) void {
    if (!ok) c._exit(90);
}
// Exact libc wire request, before using the public logging entry points.
fn firstLookup() void {
    var buffer: [512]u8 align(8) = @splat(0);
    const h: *c.mach_msg_header_t = @ptrCast(&buffer);
    const task = __sys_task_self_trap();
    const reply = __sys_mach_reply_port();
    childNeed(reply != 0);
    defer _ = __sys__kernelrpc_mach_port_destroy_trap(task, reply);
    const ndr = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0 };
    h.msgh_bits = 19 | (21 << 8);
    h.msgh_size = 36;
    h.msgh_remote_port = task;
    h.msgh_local_port = reply;
    h.msgh_id = 3409;
    @memcpy(buffer[24..32], &ndr);
    std.mem.writeInt(u32, buffer[32..36], 4, .little); // TASK_BOOTSTRAP_PORT
    childNeed(__sys_mach_msg_trap(h, c.MACH_SEND_MSG, 36, 0, 0, 0, 0) == 0);
    childNeed(__sys_mach_msg_trap(h, c.MACH_RCV_MSG, 0, buffer.len, reply, 0, 0) == 0);
    childNeed(h.msgh_id == 3509 and h.msgh_bits & c.MACH_MSGH_BITS_COMPLEX != 0 and h.msgh_size == 40);
    const bootstrap = std.mem.readInt(u32, buffer[28..32], .little);
    defer _ = __sys__kernelrpc_mach_port_deallocate_trap(task, bootstrap);
    @memset(&buffer, 0);
    h.msgh_bits = 19 | (21 << 8);
    h.msgh_size = 188;
    h.msgh_remote_port = bootstrap;
    h.msgh_local_port = reply;
    h.msgh_id = 404;
    @memcpy(buffer[24..32], &ndr);
    const service = "com.apple.system.logger";
    @memcpy(buffer[32..][0..service.len], service);
    childNeed(__sys_mach_msg_trap(h, c.MACH_SEND_MSG, 188, 0, 0, 0, 0) == 0);
    childNeed(__sys_mach_msg_trap(h, c.MACH_RCV_MSG, 0, buffer.len, reply, 0, 0) == 0);
    const code = std.mem.readInt(i32, buffer[32..36], .little);
    _ = c.printf("op103 uid=%u raw_lookup id=%d bits=0x%x size=%u return=%d expected=1099\n", c.getuid(), h.msgh_id, h.msgh_bits, h.msgh_size, code);
    _ = c.fflush(null);
    childNeed(h.msgh_id == 504 and h.msgh_bits & c.MACH_MSGH_BITS_COMPLEX == 0 and h.msgh_size == 36 and code == 1099);
}
const Kind = enum { logger, syslog, simple, setgid_child, setuid_root_child };
fn ensureUser() void {
    if (c.getpwuid(501) == null) {
        const p = c.fork();
        need(p >= 0, "fork account setup");
        if (p == 0) {
            _ = c.execl("/usr/sbin/pw", "pw", "useradd", "op103", "-u", "501", "-g", "nogroup", "-d", "/nonexistent", "-s", "/usr/sbin/nologin", @as(?[*:0]const u8, null));
            c._exit(91);
        }
        var status: c_int = 0;
        need(c.waitpid(p, &status, 0) == p and status == 0, "create uid 501");
    }
}
fn run(kind: Kind, uid: c.uid_t) void {
    need(c.geteuid() == 0, "run as root");
    ensureUser();
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrintZ(&marker_buf, "op103-{s}-{d}-{d}", .{ @tagName(kind), uid, c.getpid() }) catch unreachable;
    scope.begin();
    const pid = c.fork();
    need(pid >= 0, "fork logging child");
    if (pid == 0) {
        if (kind == .setgid_child) {
            childNeed(c.setgroups(0, null) == 0 and c.setresgid(501, 65533, 65533) == 0 and c.setuid(501) == 0);
            childNeed(c.getuid() == 501 and c.geteuid() == 501 and c.getgid() == 501 and c.getegid() == 65533);
        } else if (kind == .setuid_root_child) {
            childNeed(c.setgroups(0, null) == 0 and c.setgid(65533) == 0 and c.setresuid(501, 0, 0) == 0);
            childNeed(c.getuid() == 501 and c.geteuid() == 0);
        } else if (uid != 0) {
            childNeed(c.setgroups(0, null) == 0 and c.setgid(65533) == 0 and c.setuid(uid) == 0);
            firstLookup();
        }
        _ = c.printf("op118 kind=%s uid=%u euid=%u gid=%u egid=%u\n", @tagName(kind).ptr, c.getuid(), c.geteuid(), c.getgid(), c.getegid());
        _ = c.fflush(null);
        switch (kind) {
            .logger => {
                _ = c.execl("/usr/bin/logger", "logger", "-t", "op103", "-p", "user.notice", marker.ptr, @as(?[*:0]const u8, null));
                c._exit(92);
            },
            .syslog, .setgid_child, .setuid_root_child => {
                c.openlog("op103", c.LOG_PID, c.LOG_USER);
                c.syslog(c.LOG_NOTICE, "%s", marker.ptr);
                c.closelog();
            },
            .simple => _simple_asl_log_prog(c.LOG_NOTICE, "user", marker.ptr, "op103"),
        }
        c._exit(0);
    }
    var status: c_int = 0;
    need(c.waitpid(pid, &status, 0) == pid and status == 0, "logging child exited successfully");
    awaitRecord(marker, if (kind == .setuid_root_child) 0 else uid);
}
fn awaitRecord(marker: [:0]const u8, uid: c.uid_t) void {
    var start: c.struct_timespec = undefined;
    need(c.clock_gettime(c.CLOCK_MONOTONIC, &start) == 0, "monotonic start");
    while (true) {
        const raw = scope.query("Message", marker, false, false);
        defer std.heap.page_allocator.free(raw);
        const count = std.mem.count(u8, raw, "[Message ");
        need(count <= 1, "no duplicate record");
        if (count == 1) {
            need(std.mem.indexOf(u8, raw, "[Sender op103]") != null, "record sender");
            var uid_buf: [32]u8 = undefined;
            const field = std.fmt.bufPrint(&uid_buf, "[UID {d}]", .{uid}) catch unreachable;
            need(std.mem.indexOf(u8, raw, field) != null, "record uid");
            // Allow delayed duplicate delivery to become visible too.
            _ = c.usleep(200000);
            const final = scope.query("Message", marker, false, false);
            defer std.heap.page_allocator.free(final);
            need(std.mem.count(u8, final, "[Message ") == 1, "exactly once after delivery settles");
            _ = c.printf("op103 kind=%s uid=%u stored=1 expected=1\n", "observed", uid);
            return;
        }
        var now: c.struct_timespec = undefined;
        need(c.clock_gettime(c.CLOCK_MONOTONIC, &now) == 0, "monotonic poll");
        need((now.tv_sec - start.tv_sec) * std.time.ns_per_s + now.tv_nsec - start.tv_nsec < 10 * std.time.ns_per_s, "stored within 10 seconds");
        _ = c.usleep(20000);
    }
}
fn nonrootLogger(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(.logger, 501);
}
fn nonrootSyslog(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(.syslog, 501);
}
fn nonrootSimple(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(.simple, 501);
}
fn rootLogger(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(.logger, 0);
}
fn setgidChild(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(.setgid_child, 501);
}
fn setuidRootChild(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(.setuid_root_child, 501);
}
const daemon_plist = "/tmp/op118-username.plist";
fn launchctl(verb: [*:0]const u8) bool {
    const pid = c.fork();
    need(pid >= 0, "fork launchctl");
    if (pid == 0) {
        _ = c.execl("/bin/launchctl", "launchctl", verb, daemon_plist, @as(?[*:0]const u8, null));
        c._exit(93);
    }
    var status: c_int = 0;
    return c.waitpid(pid, &status, 0) == pid and status == 0;
}
fn usernameDaemon(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(c.geteuid() == 0, "run as root");
    ensureUser();
    const user = c.getpwuid(501) orelse unreachable;
    const a = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const template = std.Io.Dir.cwd().readFileAlloc(io, "/usr/tests/lib/libasl/username_logging.plist", a, .limited(8192)) catch c.atf_tc_fail("read fixture plist");
    defer a.free(template);
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrintZ(&marker_buf, "op118-username-{d}", .{c.getpid()}) catch unreachable;
    const named = std.mem.replaceOwned(u8, a, template, "@USER@", std.mem.span(user.*.pw_name)) catch unreachable;
    defer a.free(named);
    const plist = std.mem.replaceOwned(u8, a, named, "@MARKER@", marker) catch unreachable;
    defer a.free(plist);
    const fp = c.fopen(daemon_plist, "w") orelse c.atf_tc_fail("write fixture plist");
    const written = c.fwrite(plist.ptr, 1, plist.len, fp);
    const closed = c.fclose(fp);
    need(written == plist.len and closed == 0, "complete fixture plist");
    scope.begin();
    need(launchctl("load"), "load UserName daemon");
    defer need(launchctl("unload"), "unload UserName daemon");
    var expected_buf: [192]u8 = undefined;
    const expected = std.fmt.bufPrintZ(&expected_buf, "{s} uid=501 euid=501", .{marker}) catch unreachable;
    awaitRecord(expected, 501);
    // These fields were formatted by the daemon from getuid/geteuid and
    // checked in the one stored record, independent of launchd stdout setup.
    _ = c.printf("op118 kind=username_daemon stored_identity=%s\n", expected.ptr);
}
fn cleanup(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), "username_daemon")) {
        _ = launchctl("unload");
        _ = c.unlink(daemon_plist);
    }
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "require.user", "root");
    _ = c.atf_tc_set_md_var(tc, "timeout", "20");
}
var cases: [7]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "nonroot_logger", "nonroot_syslog", "nonroot_simple", "root_logger", "setgid_child", "setuid_root_child", "username_daemon" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ nonrootLogger, nonrootSyslog, nonrootSimple, rootLogger, setgidChild, setuidRootChild, usernameDaemon };
    for (&cases, names, bodies) |*tc, name, body| {
        var err = c.atf_tc_init(tc, name, head, body, cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc == 3 and std.mem.eql(u8, std.mem.span(argv[1]), "--username-daemon")) {
        childNeed(c.getuid() == 501 and c.geteuid() == 501);
        var record_buf: [192]u8 = undefined;
        const record = std.fmt.bufPrintZ(&record_buf, "{s} uid={d} euid={d}", .{ std.mem.span(argv[2]), c.getuid(), c.geteuid() }) catch unreachable;
        c.openlog("op103", c.LOG_PID, c.LOG_USER);
        c.syslog(c.LOG_NOTICE, "%s", record.ptr);
        c.closelog();
        return 0;
    }
    return atf_tp_main(argc, argv, add);
}
