// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const scope = @import("log_store_scope.zig");
const c = @cImport({
    // Zig 0.16 cannot translate the BSD bintime_shift inline (as in
    // log_store_scope.zig): sys/stat.h and signal.h bring sys/time.h.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("grp.h");
    @cInclude("pwd.h");
    @cInclude("sys/wait.h");
    @cInclude("syslog.h");
    @cInclude("time.h");
    @cInclude("sys/mach/message.h");
    @cInclude("dlfcn.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("sys/stat.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn __sys_task_self_trap() c_uint;
extern fn __sys_mach_reply_port() c_uint;
extern fn __sys_mach_msg_trap(*c.mach_msg_header_t, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint) c_int;
extern fn __sys__kernelrpc_mach_port_deallocate_trap(c_uint, c_uint) c_int;
extern fn __sys__kernelrpc_mach_port_destroy_trap(c_uint, c_uint) c_int;
extern fn __sys__kernelrpc_mach_port_allocate_trap(c_uint, c_uint, *c_uint) c_int;
extern fn __sys__kernelrpc_mach_port_insert_right_trap(c_uint, c_uint, c_uint, c_uint) c_int;
extern fn __sys__kernelrpc_mach_port_mod_refs_trap(c_uint, c_uint, c_uint, c_int) c_int;
extern fn mach_port_get_refs(c_uint, c_uint, c_uint, *c_uint) c_int;
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
    const service = "org.rmxos.logd";
    @memcpy(buffer[32..][0..service.len], service);
    childNeed(__sys_mach_msg_trap(h, c.MACH_SEND_MSG, 188, 0, 0, 0, 0) == 0);
    childNeed(__sys_mach_msg_trap(h, c.MACH_RCV_MSG, 0, buffer.len, reply, 0, 0) == 0);
    const code = std.mem.readInt(i32, buffer[32..36], .little);
    _ = c.printf("op103 uid=%u raw_lookup id=%d bits=0x%x size=%u return=%d expected=1099\n", c.getuid(), h.msgh_id, h.msgh_bits, h.msgh_size, code);
    _ = c.fflush(null);
    childNeed(h.msgh_id == 504 and h.msgh_bits & c.MACH_MSGH_BITS_COMPLEX == 0 and h.msgh_size == 36 and code == 1099);
}
const Kind = enum { logger, syslog, simple, setgid_child, setuid_root_child };
fn libcBinding(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var info: c.Dl_info = undefined;
    for ([_]*const anyopaque{ @ptrCast(&c.syslog), @ptrCast(&c.openlog), @ptrCast(&c.closelog) }) |symbol| {
        need(c.dladdr(symbol, &info) != 0 and info.dli_fname != null, "resolve syslog API provider");
        const path = std.mem.span(info.dli_fname);
        _ = c.printf("op180_syslog_binding object=%s expected=libc.so.7\n", info.dli_fname);
        need(std.mem.endsWith(u8, path, "/libc.so.7"), "syslog API must bind libc, not the private store archive");
    }
}
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
    const template = std.Io.Dir.cwd().readFileAlloc(io, "/usr/tests/lib/liblogstore/username_logging.plist", a, .limited(8192)) catch c.atf_tc_fail("read fixture plist");
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
// op-815: a forked child holds none of its parent's log sender names (Mach
// names are descriptors that fork does not copy), so its first log must not
// close or release what the child itself keeps under those numbers. The
// parent's first syslog opens the names; the child fills each number with a
// pipe or a port of its own, logs once, and reports to the parent through a
// pipe opened before the parent's log. Only the parent asserts.
const Hold = enum { pipes, ports };
const max_fd = 4096;
const max_targets = 8;
const FdSet = std.StaticBitSet(max_fd);
const right_send = 0;
const right_receive = 1;
const make_send = 20;
const ChildReport = extern struct {
    got: u8 = 0,
    logged: u8 = 0,
    made: u32 = 0,
    free: [max_targets]u8 = @splat(0),
    held: [max_targets]u8 = @splat(0),
    open: [max_targets]u8 = @splat(0),
    fifo: [max_targets]u8 = @splat(0),
    trip: [max_targets]u8 = @splat(0),
    receive_kr: [max_targets]i32 = @splat(0),
    receive: [max_targets]u32 = @splat(0),
    send_kr: [max_targets]i32 = @splat(0),
    send: [max_targets]u32 = @splat(0),
};
fn openSet() FdSet {
    var set = FdSet.initEmpty();
    for (0..max_fd) |fd| {
        if (c.fcntl(@as(c_int, @intCast(fd)), c.F_GETFD) != -1) set.set(fd);
    }
    return set;
}
fn indexIn(list: []const c_int, fd: c_int) ?usize {
    for (list, 0..) |x, i| if (x == fd) return i;
    return null;
}
// Pipes take the lowest free number: keep every pipe until each number is one
// of a pipe's ends, then close the pipes that hold none of them.
fn holdPipes(targets: []const c_int, r: *ChildReport, ends: *[max_targets][2]c_int) void {
    var pairs: [512][2]c_int = undefined;
    var kept: [512]bool = undefined;
    var count: usize = 0;
    var covered: usize = 0;
    while (covered < targets.len and count < pairs.len) {
        if (c.pipe2(&pairs[count], c.O_NONBLOCK) != 0) break;
        kept[count] = false;
        for (pairs[count]) |fd| {
            if (indexIn(targets, fd)) |i| {
                ends[i] = pairs[count];
                r.held[i] = 1;
                kept[count] = true;
                covered += 1;
            }
        }
        count += 1;
    }
    r.made = @intCast(count);
    for (pairs[0..count], kept[0..count]) |p, k| {
        if (!k) {
            _ = c.close(p[0]);
            _ = c.close(p[1]);
        }
    }
}
// Ports take the lowest free number from 16. Target 0 is the caller's own
// task for these traps, so no task name is made; no MIG call before the log.
fn holdPorts(targets: []const c_int, r: *ChildReport) void {
    var names: [512]c_uint = undefined;
    var kept: [512]bool = undefined;
    var count: usize = 0;
    var covered: usize = 0;
    while (covered < targets.len and count < names.len) {
        if (__sys__kernelrpc_mach_port_allocate_trap(0, right_receive, &names[count]) != 0) break;
        kept[count] = false;
        if (indexIn(targets, @intCast(names[count]))) |i| {
            const n = names[count];
            r.held[i] = @intFromBool(__sys__kernelrpc_mach_port_insert_right_trap(0, n, n, make_send) == 0 and
                __sys__kernelrpc_mach_port_mod_refs_trap(0, n, right_receive, 0) == 0 and
                __sys__kernelrpc_mach_port_mod_refs_trap(0, n, right_send, 0) == 0);
            kept[count] = true;
            covered += 1;
        }
        count += 1;
    }
    r.made = @intCast(count);
    for (names[0..count], kept[0..count]) |n, k| {
        if (!k) _ = __sys__kernelrpc_mach_port_destroy_trap(0, n);
    }
}
fn checkPipes(targets: []const c_int, r: *ChildReport, ends: *const [max_targets][2]c_int) void {
    for (targets, 0..) |fd, i| {
        r.open[i] = @intFromBool(c.fcntl(fd, c.F_GETFD) != -1);
        var st: c.struct_stat = undefined;
        r.fifo[i] = @intFromBool(c.fstat(fd, &st) == 0 and (@as(c_int, st.st_mode) & c.S_IFMT) == c.S_IFIFO);
        const byte: u8 = 0x40 + @as(u8, @intCast(i));
        var back: u8 = 0;
        r.trip[i] = @intFromBool(c.write(ends[i][1], &byte, 1) == 1 and c.read(ends[i][0], &back, 1) == 1 and back == byte);
    }
}
fn checkPorts(targets: []const c_int, r: *ChildReport) void {
    const task = __sys_task_self_trap();
    for (targets, 0..) |fd, i| {
        const name: c_uint = @intCast(fd);
        r.receive_kr[i] = mach_port_get_refs(task, name, right_receive, &r.receive[i]);
        r.send_kr[i] = mach_port_get_refs(task, name, right_send, &r.send[i]);
    }
}
fn forkedChild(hold: Hold, targets: []const c_int, marker: [:0]const u8, report_fd: c_int) noreturn {
    var r: ChildReport = .{};
    var ends: [max_targets][2]c_int = undefined;
    // On the base a kept pipe can lose its read end: EPIPE, not a signal.
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigaddset(&set, c.SIGPIPE);
    _ = c.sigprocmask(c.SIG_BLOCK, &set, null);
    var all_free = true;
    for (targets, 0..) |fd, i| {
        const free = c.fcntl(fd, c.F_GETFD) == -1 and std.c._errno().* == c.EBADF;
        r.free[i] = @intFromBool(free);
        all_free = all_free and free;
    }
    if (all_free) {
        switch (hold) {
            .pipes => holdPipes(targets, &r, &ends),
            .ports => holdPorts(targets, &r),
        }
        r.got = 1;
        for (r.held[0..targets.len]) |h| {
            if (h != 1) r.got = 0;
        }
    }
    if (r.got == 1) {
        c.syslog(c.LOG_NOTICE, "%s", marker.ptr);
        r.logged = 1;
        switch (hold) {
            .pipes => checkPipes(targets, &r, &ends),
            .ports => checkPorts(targets, &r),
        }
    }
    const bytes = std.mem.asBytes(&r);
    _ = c.write(report_fd, bytes.ptr, bytes.len);
    c._exit(0);
}
fn readAll(fd: c_int, buf: []u8) usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.read(fd, buf[got..].ptr, buf.len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return got;
}
fn fact(case: [*:0]const u8, name: ?c_int, label: [*:0]const u8, expected: i64, observed: i64) void {
    if (name) |n| {
        _ = c.printf("op815 case=%s name=%d fact=%s expected=%lld observed=%lld\n", case, n, label, @as(c_longlong, expected), @as(c_longlong, observed));
    } else {
        _ = c.printf("op815 case=%s fact=%s expected=%lld observed=%lld\n", case, label, @as(c_longlong, expected), @as(c_longlong, observed));
    }
}
fn forkedChildKeeps(hold: Hold) void {
    need(c.geteuid() == 0, "run as root");
    const case: [*:0]const u8 = switch (hold) {
        .pipes => "forkedChildKeepsPipes",
        .ports => "forkedChildKeepsPorts",
    };
    var info: c.Dl_info = undefined;
    need(c.dladdr(@ptrCast(&c.syslog), &info) != 0 and info.dli_fname != null, "resolve syslog provider");
    _ = c.printf("op815 case=%s libc=%s pid=%d\n", case, info.dli_fname, c.getpid());
    var bufs: [3][96]u8 = undefined;
    const first = std.fmt.bufPrintZ(&bufs[0], "op815-{s}-parent1-{d}", .{ @tagName(hold), c.getpid() }) catch unreachable;
    const child = std.fmt.bufPrintZ(&bufs[1], "op815-{s}-child-{d}", .{ @tagName(hold), c.getpid() }) catch unreachable;
    const second = std.fmt.bufPrintZ(&bufs[2], "op815-{s}-parent2-{d}", .{ @tagName(hold), c.getpid() }) catch unreachable;
    var report: [2]c_int = undefined;
    need(c.pipe(&report) == 0, "report pipe");
    scope.begin();
    c.openlog("op103", c.LOG_PID, c.LOG_USER);
    // The sender's names: the numbers this one call opened.
    const before = openSet();
    c.syslog(c.LOG_NOTICE, "%s", first.ptr);
    const after = openSet();
    var list: [max_targets]c_int = undefined;
    var n: usize = 0;
    var over: usize = 0;
    var closed: usize = 0;
    for (0..max_fd) |fd| {
        if (after.isSet(fd) and !before.isSet(fd)) {
            if (n < max_targets) {
                list[n] = @intCast(fd);
                n += 1;
            } else over += 1;
        }
        if (before.isSet(fd) and !after.isSet(fd)) closed += 1;
    }
    _ = c.printf("op815 case=%s opened_by_first_log=%zu closed_by_first_log=%zu over=%zu\n", case, n, closed, over);
    const targets = list[0..n];
    const task = __sys_task_self_trap();
    for (targets) |t| {
        var receive: c_uint = 0;
        var send: c_uint = 0;
        const rk = mach_port_get_refs(task, @intCast(t), right_receive, &receive);
        const sk = mach_port_get_refs(task, @intCast(t), right_send, &send);
        _ = c.printf("op815 case=%s sender_name=%d receive_kr=%d receive=%u send_kr=%d send=%u\n", case, t, rk, receive, sk, send);
    }
    _ = c.fflush(null);
    need(n > 0 and over == 0, "the parent's first syslog opened the sender's names (1 to 8 numbers)");
    const pid = c.fork();
    need(pid >= 0, "fork logging child");
    if (pid == 0) {
        _ = c.close(report[0]);
        forkedChild(hold, targets, child, report[1]);
    }
    _ = c.close(report[1]);
    var r: ChildReport = .{};
    const got = readAll(report[0], std.mem.asBytes(&r));
    _ = c.close(report[0]);
    fact(case, null, "child_report_bytes", @sizeOf(ChildReport), @intCast(got));
    for (targets, 0..) |t, i| fact(case, t, "free_in_child", 1, r.free[i]);
    for (targets, 0..) |t, i| fact(case, t, "child_holds_number", 1, r.held[i]);
    _ = c.printf("op815 case=%s made=%u\n", case, r.made);
    fact(case, null, "child_got_numbers", 1, r.got);
    fact(case, null, "child_logged", 1, r.logged);
    var kept = true;
    var trip = true;
    for (targets, 0..) |t, i| {
        switch (hold) {
            .pipes => {
                fact(case, t, "pipe_open", 1, r.open[i]);
                fact(case, t, "pipe_fifo", 1, r.fifo[i]);
                fact(case, t, "pipe_round_trip", 1, r.trip[i]);
                kept = kept and r.open[i] == 1;
                trip = trip and r.trip[i] == 1;
            },
            .ports => {
                fact(case, t, "receive_kr", 0, r.receive_kr[i]);
                fact(case, t, "receive_refs", 1, r.receive[i]);
                fact(case, t, "send_kr", 0, r.send_kr[i]);
                fact(case, t, "send_refs", 1, r.send[i]);
                kept = kept and r.receive_kr[i] == 0 and r.receive[i] == 1;
                trip = trip and r.send_kr[i] == 0 and r.send[i] == 1;
            },
        }
    }
    _ = c.fflush(null);
    need(got == @sizeOf(ChildReport), "the child's report arrived whole");
    need(r.got == 1, "the child did not get the numbers: each free in it, then held by its own pipe or port");
    need(r.logged == 1, "the child logged");
    switch (hold) {
        .pipes => {
            need(kept, "each of the child's pipes is still open after its log");
            need(trip, "a byte written into each of the child's pipes reads back out");
        },
        .ports => {
            need(kept, "each of the child's ports keeps its receive right after its log");
            need(trip, "each of the child's ports keeps one send reference after its log");
        },
    }
    awaitRecord(child, 0);
    var status: c_int = -1;
    need(c.waitpid(pid, &status, 0) == pid, "wait for the child");
    fact(case, null, "child_wait_status", 0, status);
    need(status == 0, "the child exits 0");
    c.syslog(c.LOG_NOTICE, "%s", second.ptr);
    awaitRecord(second, 0);
    awaitRecord(first, 0);
    c.closelog();
    fact(case, null, "parent_lines_stored", 2, 2);
}
fn forkedChildKeepsPipes(_: [*c]const c.atf_tc_t) callconv(.c) void {
    forkedChildKeeps(.pipes);
}
fn forkedChildKeepsPorts(_: [*c]const c.atf_tc_t) callconv(.c) void {
    forkedChildKeeps(.ports);
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "require.user", "root");
    _ = c.atf_tc_set_md_var(tc, "timeout", "20");
}
var cases: [10]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "libc_binding", "nonroot_logger", "nonroot_syslog", "nonroot_simple", "root_logger", "setgid_child", "setuid_root_child", "username_daemon", "forkedChildKeepsPipes", "forkedChildKeepsPorts" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ libcBinding, nonrootLogger, nonrootSyslog, nonrootSimple, rootLogger, setgidChild, setuidRootChild, usernameDaemon, forkedChildKeepsPipes, forkedChildKeepsPorts };
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
