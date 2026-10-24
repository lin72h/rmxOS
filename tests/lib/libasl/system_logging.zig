// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const observations = @import("logging_observations.zig");
const scope = @import("log_store_scope.zig");
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
    @cInclude("asl.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
});
extern fn asl_startup_report([*:0]const u8, [*:0]const u8, c_int) c_int;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cleaning = false;
var captured: [262144]u8 = undefined;
const Result = struct { status: c_int, text: []const u8 };
fn need(ok: bool, message: [*:0]const u8) void {
    if (!ok) {
        if (cleaning) {
            _ = c.printf("cleanup failed: %s errno=%d\n", message, c.__error().*);
            _ = c.fflush(null);
            c._exit(1);
        }
        c.atf_tc_fail("%s errno=%d", message, c.__error().*);
    }
}
fn command(args: []const [*:0]const u8) Result {
    need(args.len < 32, "command argument bound");
    const file = c.tmpfile();
    need(file != null, "command capture");
    defer _ = c.fclose(file);
    const pid = c.fork();
    need(pid >= 0, "fork observation command");
    if (pid == 0) {
        _ = c.dup2(c.fileno(file), 1);
        _ = c.dup2(c.fileno(file), 2);
        var argv: [32][*c]u8 = @splat(null);
        for (args, 0..) |arg, i| argv[i] = @constCast(arg);
        _ = c.execv(args[0], &argv);
        c._exit(127);
    }
    var status: c_int = 0;
    need(c.waitpid(pid, &status, 0) == pid, "reap command");
    _ = c.rewind(file);
    const n = c.fread(&captured, 1, captured.len, file);
    need(n < captured.len and c.ferror(file) == 0, "bounded complete capture");
    return .{ .status = status, .text = captured[0..n] };
}
fn run(args: []const [*:0]const u8) []const u8 {
    const r = command(args);
    if (r.status != 0) {
        _ = c.printf("COMMAND_FAILURE %s status=%d output=%.*s\n", args[0], r.status, @as(c_int, @intCast(r.text.len)), r.text.ptr);
        need(false, "command returned success");
    }
    return r.text;
}
fn z(p: [*:0]const u8) []const u8 {
    return std.mem.span(p);
}
fn count(text: []const u8, token: []const u8) usize {
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, token)) |i| {
        n += 1;
        pos = i + token.len;
    }
    return n;
}
fn fileCount(path: [*:0]const u8, token: []const u8) usize {
    return fileCountChannel(path, token, false);
}
fn fileCountChannel(path: [*:0]const u8, token: []const u8, direct: bool) usize {
    const file = c.fopen(path, "r") orelse return 0;
    defer _ = c.fclose(file);
    var line: [16384]u8 = undefined;
    var result: usize = 0;
    while (c.fgets(&line, line.len, file) != null) {
        const bytes = std.mem.span(@as([*:0]const u8, @ptrCast(&line)));
        result += if (direct) observations.directCount(bytes, token) else count(bytes, token);
    }
    need(c.ferror(file) == 0, "read text log");
    return result;
}
fn pidfile() c.pid_t {
    const f = c.fopen("/var/run/syslog.pid", "r") orelse return -1;
    defer _ = c.fclose(f);
    var pid: c.pid_t = -1;
    if (c.fscanf(f, "%d", &pid) != 1) return -1;
    return pid;
}
fn ownerIs(name: []const u8) bool {
    const pid = pidfile();
    if (pid <= 1) return false;
    var text: [32:0]u8 = @splat(0);
    _ = c.snprintf(&text, text.len, "%d", pid);
    const r = command(&.{ "/bin/ps", "-p", &text, "-o", "comm=" });
    return r.status == 0 and std.mem.eql(u8, std.mem.trim(u8, r.text, " \r\n\t"), name);
}
fn awaitOwner(name: []const u8) void {
    for (0..100) |_| {
        if (ownerIs(name)) {
            var signal_ready = true;
            if (std.mem.eql(u8, name, "asld")) {
                var pid: [32:0]u8 = @splat(0);
                _ = c.snprintf(&pid, pid.len, "%d", pidfile());
                const observed = run(&.{ "/usr/bin/procstat", "-i", &pid });
                signal_ready = false;
                var lines = std.mem.tokenizeAny(u8, observed, "\r\n");
                while (lines.next()) |line| {
                    if (std.mem.indexOf(u8, line, "USR1") != null) {
                        const flags = std.mem.trimEnd(u8, line, " \t");
                        signal_ready = flags.len >= 3 and flags[flags.len - 2] == 'I';
                    }
                }
            }
            const fd = c.socket(c.AF_UNIX, c.SOCK_DGRAM, 0);
            if (fd >= 0) {
                var address = std.mem.zeroes(c.struct_sockaddr_un);
                address.sun_family = c.AF_UNIX;
                address.sun_len = @sizeOf(c.struct_sockaddr_un);
                @memcpy(address.sun_path[0..12], "/var/run/log");
                const connected = c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un));
                _ = c.close(fd);
                if (connected == 0 and signal_ready) return;
            }
        }
        _ = c.usleep(50000);
    }
    need(false, "bounded logger ownership transition");
}
fn unique(comptime name: []const u8) [96:0]u8 {
    var text: [96:0]u8 = @splat(0);
    _ = c.snprintf(&text, text.len, "op767_%s_%d", name.ptr, c.getpid());
    return text;
}
fn log(priority: [*:0]const u8, sender: [*:0]const u8, message: [*:0]const u8) void {
    _ = run(&.{ "/usr/bin/logger", "-p", priority, "-t", sender, message });
}
fn awaitFile(path: [*:0]const u8, text: []const u8, expected: usize) void {
    for (0..200) |_| {
        if (fileCount(path, text) == expected) return;
        _ = c.usleep(20000);
    }
    _ = c.printf("LOG_COUNT path=%s expected=%zu observed=%zu\n", path, expected, fileCount(path, text));
    need(false, "text record exact count");
}
fn store(message: [*:0]const u8) []const u8 {
    return scope.query("Message", std.mem.span(message), false, false);
}
fn awaitStore(message: [*:0]const u8, expected: usize) []const u8 {
    const text = std.mem.span(message);
    for (0..100) |_| {
        const records = store(message);
        if (count(records, text) == expected) return records;
        _ = c.usleep(20000);
    }
    _ = c.printf("STORE_COUNT message=%s expected=%zu output=%.*s\n", message, expected, @as(c_int, @intCast(store(message).len)), captured[0..].ptr);
    need(false, "store record exact count through aslutil");
    return "";
}
fn assertConsole() void {
    const fd = c.open("/dev/console", c.O_RDONLY | c.O_NONBLOCK | c.O_NOCTTY);
    need(fd >= 0, "open console without carrier wait");
    defer _ = c.close(fd);
    var term: c.struct_termios = undefined;
    need(c.tcgetattr(fd, &term) == 0 and term.c_cflag & c.CLOCAL != 0, "console has clocal after getty");
    const observed = run(&.{ "/bin/stty", "-f", "/dev/console", "-a" });
    need(std.mem.indexOf(u8, observed, "-clocal") == null and std.mem.indexOf(u8, observed, "clocal") != null, "stty reports clocal");
}
fn bootReady(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const f = c.fopen("/var/run/asld.boot-service.log", "r");
    need(f != null, "compatibility service preserves its boot readiness result");
    defer _ = c.fclose(f);
    var text: [65536]u8 = undefined;
    const n = c.fread(&text, 1, text.len, f);
    need(n < text.len and c.ferror(f) == 0, "read complete boot readiness log");
    const ok = @import("boot_ready_check.zig").ready(text[0..n]);
    if (!ok) _ = c.printf("BOOT_READINESS %.*s\n", @as(c_int, @intCast(n)), &text);
    need(ok, "asld served before dependent rc services with no readiness warning");
}
fn oneOwner(_: [*c]const c.atf_tc_t) callconv(.c) void {
    awaitOwner("asld");
    const list = run(&.{ "/bin/ps", "-axo", "comm=" });
    var processes = std.mem.tokenizeAny(u8, list, "\r\n");
    var owners: usize = 0;
    while (processes.next()) |name| {
        need(!std.mem.eql(u8, name, "syslogd"), "no syslogd process while asld owns logging");
        if (std.mem.eql(u8, name, "asld")) owners += 1;
    }
    need(owners == 1, "exactly one system asld");
    var st: c.struct_stat = undefined;
    need(c.lstat("/var/run/log", &st) == 0 and st.st_mode & c.S_IFMT == c.S_IFSOCK and st.st_mode & 0o777 == 0o666, "BSD datagram socket mode 0666");
    const inode = st.st_ino;
    const ready = command(&.{ "/etc/rc.d/syslogd", "onestart" });
    if (ready.status != 0) {
        _ = c.printf("ONE_OWNER_RC status=%d output=%.*s\n", ready.status, @as(c_int, @intCast(ready.text.len)), ready.text.ptr);
        var owner: [32:0]u8 = @splat(0);
        _ = c.snprintf(&owner, owner.len, "%d", pidfile());
        const observed = command(&.{ "/bin/ps", "-p", &owner, "-o", "pid,args" });
        _ = c.printf("ONE_OWNER_PS status=%d output=%.*s\n", observed.status, @as(c_int, @intCast(observed.text.len)), observed.text.ptr);
        _ = c.fflush(null);
    }
    need(ready.status == 0, "compatibility service accepts the running asld owner");
    need(c.lstat("/var/run/log", &st) == 0 and st.st_ino == inode and ownerIs("asld"), "compatibility readiness preserves the live socket and owner");
    var target: [256]u8 = undefined;
    const n = c.readlink("/dev/log", &target, target.len);
    need(n == 12 and std.mem.eql(u8, target[0..12], "/var/run/log"), "dev log symlink");
    const fd = c.open("/dev/klog", c.O_RDONLY | c.O_NONBLOCK);
    if (fd >= 0) _ = c.close(fd);
    need(fd < 0 and c.__error().* == c.EBUSY, "kernel log has one reader");
    var pid: [32:0]u8 = @splat(0);
    _ = c.snprintf(&pid, pid.len, "%d", pidfile());
    const files = run(&.{ "/usr/bin/procstat", "-f", &pid });
    need(std.mem.indexOf(u8, files, "/dev/klog") != null, "asld owns the kernel descriptor");
    assertConsole();
}
fn routes(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const priorities = [_][*:0]const u8{ "user.notice", "security.info", "auth.info", "mail.info", "cron.info", "user.debug", "daemon.info", "lpr.info" };
    const paths = [_][*:0]const u8{ "/var/log/messages", "/var/log/security", "/var/log/auth.log", "/var/log/maillog", "/var/log/cron", "/var/log/debug.log", "/var/log/daemon.log", "/var/log/lpd-errs" };
    for (priorities, paths, 0..) |priority, path, i| {
        var message: [128:0]u8 = @splat(0);
        _ = c.snprintf(&message, message.len, "op767_route_%d_%zu", c.getpid(), i);
        log(priority, "op767", &message);
        awaitFile(path, z(&message), 1);
        const raw = awaitStore(&message, 1);
        need(std.mem.indexOf(u8, raw, "Sender op767") != null and std.mem.indexOf(u8, raw, "Facility ") != null and std.mem.indexOf(u8, raw, "Level ") != null, "logger fields stored");
    }
    const excluded = unique("devd");
    log("daemon.debug", "devd", &excluded);
    _ = awaitStore(&excluded, 1);
    need(fileCount("/var/log/debug.log", z(&excluded)) == 0 and fileCount("/var/log/daemon.log", z(&excluded)) == 0, "devd excluded only from debug and daemon text files");
    const ppp = unique("ppp");
    log("daemon.info", "ppp", &ppp);
    awaitFile("/var/log/ppp.log", z(&ppp), 1);
    _ = awaitStore(&ppp, 1);
    const other = unique("not_ppp");
    log("daemon.info", "op767", &other);
    _ = awaitStore(&other, 1);
    need(fileCount("/var/log/ppp.log", z(&other)) == 0, "included program filter does not leak other senders");
}
fn native(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const message = unique("native");
    const client = c.asl_open("op767_native", "daemon", 0);
    need(client != null, "native ASL client");
    const msg = c.asl_new(c.ASL_TYPE_MSG);
    need(msg != null, "native message");
    need(c.asl_set(msg, "Telemetry.Kind", "op767") == 0 and c.asl_set(msg, "Telemetry.Value", "intact structured value") == 0, "native structured keys");
    need(c.asl_log(client, msg, c.ASL_LEVEL_NOTICE, "%s", &message) == 0, "native asl_log send");
    c.asl_free(msg);
    c.asl_close(client);
    const raw = awaitStore(&message, 1);
    need(std.mem.indexOf(u8, raw, "Telemetry.Kind op767") != null and std.mem.indexOf(u8, raw, "Telemetry.Value intact structured value") != null, "aslutil reads every native key intact");
}
fn kernel(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const boot = "FreeBSD is a registered trademark of The FreeBSD Foundation.";
    const load = "op767 kernel fixture loaded";
    const unload = "op767 kernel fixture unloaded";
    const before_load = count(store(load), load);
    const before_unload = count(store(unload), unload);
    // Rotation can precede even the first fixture load. The persistent store
    // must still contain the boot banner exactly once.
    const boot_records = scope.query("Message", boot, false, true);
    const boot_stored = count(boot_records, boot);
    const boot_current = fileCount("/var/log/messages", boot);
    _ = c.printf("kernel_boot current_text=%zu stored=%zu expected_stored=1\n", boot_current, boot_stored);
    need(observations.kernelBoot(boot_current, boot_stored), "boot banner retained exactly once in ASL across text rotations");
    const text_load = fileCount("/var/log/messages", load);
    const text_unload = fileCount("/var/log/messages", unload);
    _ = run(&.{ "/sbin/kldload", "/usr/tests/lib/launchd/op767_logger.ko" });
    _ = run(&.{ "/sbin/kldunload", "op767_logger" });
    awaitFile("/var/log/messages", load, text_load + 1);
    awaitFile("/var/log/messages", unload, text_unload + 1);
    _ = awaitStore(load, before_load + 1);
    _ = awaitStore(unload, before_unload + 1);
}
fn rotateAndLog() void {
    assertConsole();
    const before = unique("before_rotation");
    log("user.notice", "op767", &before);
    awaitFile("/var/log/messages", z(&before), 1);
    var old: c.struct_stat = undefined;
    need(c.stat("/var/log/messages", &old) == 0, "old log inode");
    _ = run(&.{ "/usr/sbin/newsyslog", "-F", "/var/log/messages" });
    var fresh: c.struct_stat = undefined;
    need(c.stat("/var/log/messages", &fresh) == 0 and old.st_ino != fresh.st_ino, "newsyslog installed a new messages inode");
    const after = unique("after_rotation");
    log("user.notice", "op767", &after);
    awaitFile("/var/log/messages", z(&after), 1);
    need(fileCount("/var/log/messages", z(&before)) == 0, "new file does not contain pre-rotation record");
}
fn rotation(_: [*c]const c.atf_tc_t) callconv(.c) void {
    awaitOwner("asld");
    rotateAndLog();
}
fn freshStatus() []const u8 {
    const before = count(scope.query("com.rmxos.asld.record", "status", false, false), "[com.rmxos.asld.record status]");
    need(c.kill(pidfile(), c.SIGUSR1) == 0, "request system logger status");
    for (0..100) |i| {
        const raw = scope.query("com.rmxos.asld.record", "status", false, false);
        if (count(raw, "[com.rmxos.asld.record status]") > before) {
            const fresh = observations.newestStatus(raw) orelse unreachable;
            return std.heap.page_allocator.dupe(u8, fresh) catch c.atf_tc_fail("status snapshot allocation");
        }
        if (i % 5 == 4) _ = c.kill(pidfile(), c.SIGUSR1);
        _ = c.usleep(20000);
    }
    need(false, "status written through store");
    unreachable;
}
fn counters(_: [*c]const c.atf_tc_t) callconv(.c) void {
    awaitOwner("asld");
    const pid = pidfile();
    const baseline = freshStatus();
    const fresh = freshStatus();
    need(pidfile() == pid, "status snapshots belong to the same logger process");
    _ = c.printf("asld_baseline_status %.*s\nasld_fresh_status %.*s\n", @as(c_int, @intCast(baseline.len)), baseline.ptr, @as(c_int, @intCast(fresh.len)), fresh.ptr);
    need(observations.statusMatches(fresh, baseline), "idle snapshot changes no counter: exact baseline values and zero deltas");
}
fn compatibilityService(_: [*c]const c.atf_tc_t) callconv(.c) void {
    awaitOwner("asld");
    need(c.access("/usr/sbin/syslogd", c.F_OK) != 0 and c.__error().* == c.ENOENT, "FreeBSD syslogd binary is not installed");
    const defaults = run(&.{ "/bin/cat", "/etc/defaults/rc.conf" });
    need(std.mem.indexOf(u8, defaults, "syslogd_enable") == null, "no syslogd_enable setting installed");
    const ready = c.fopen("/var/run/asld.service-ready", "r");
    need(ready != null, "rc dependency observed the socket and running asld");
    var ready_pid: c.pid_t = -1;
    need(c.fscanf(ready, "%d", &ready_pid) == 1 and ready_pid == pidfile(), "rc readiness belongs to the running logger");
    _ = c.fclose(ready);
    _ = run(&.{ "/usr/sbin/service", "syslogd", "status" });
    // Fixed dependency inventory: rcorder enforces every installed REQUIRE edge.
    const observed = run(&.{ "/bin/sh", "-c", "/sbin/rcorder /etc/rc.d/*" });
    const own = std.mem.indexOf(u8, observed, "/etc/rc.d/syslogd\n") orelse {
        need(false, "compatibility service in rc order");
        unreachable;
    };
    for ([_][]const u8{ "auditd", "bsnmpd", "power_profile", "watchdogd", "bgfsck", "savecore", "pwcheck", "hastd", "ntpdate", "rpcbind" }) |name| {
        var full: [128:0]u8 = @splat(0);
        _ = c.snprintf(&full, full.len, "/etc/rc.d/%.*s\n", @as(c_int, @intCast(name.len)), name.ptr);
        const position = std.mem.indexOf(u8, observed, z(&full)) orelse {
            need(false, "logging dependent service installed");
            unreachable;
        };
        need(position > own, "REQUIRE syslogd service ordered after socket readiness");
    }
    const before = unique("service_before");
    log("user.notice", "op767", &before);
    awaitFile("/var/log/messages", z(&before), 1);
    _ = c.unlink("/var/log/op767-service-messages");
    need(c.rename("/var/log/messages", "/var/log/op767-service-messages") == 0, "rotate file before compatibility reload");
    const fd = c.open("/var/log/messages", c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o644));
    need(fd >= 0, "create replacement messages file");
    _ = c.close(fd);
    _ = run(&.{ "/usr/sbin/service", "syslogd", "reload" });
    const after = unique("service_after");
    log("user.notice", "op767", &after);
    awaitFile("/var/log/messages", z(&after), 1);
    need(fileCount("/var/log/op767-service-messages", z(&after)) == 0, "service reload reopens the destination");
    const startup = unique("startup_failure_fixture");
    const startup_before = fileCountChannel("/var/log/messages", z(&startup), true);
    need(asl_startup_report(&startup, "filesystem readiness timeout fixture", c.ETIMEDOUT) == 0, "startup failure reaches nonblocking console and boot log");
    need(fileCountChannel("/var/log/messages", z(&startup), true) == startup_before + 1, "one direct startup failure appended to boot log");
}
fn retention(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const jobs = run(&.{ "/bin/launchctl", "list" });
    need(std.mem.indexOf(u8, jobs, "com.rmxos.aslmanager.once") != null, "retention job loaded");
    _ = c.unlink("/tmp/op040-retention-times");
    const path = "/tmp/op767-interval.plist";
    const f = c.fopen(path, "w");
    need(f != null, "interval fixture plist");
    _ = c.fputs("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>com.rmxos.op767.interval</string><key>ProgramArguments</key><array><string>/usr/tests/lib/libasl/retention_observer</string></array><key>ThrottleInterval</key><integer>0</integer><key>StartInterval</key><integer>2</integer></dict></plist>", f);
    need(c.fclose(f) == 0, "close interval fixture");
    const marker = "[com.rmxos.aslmanager.record summary]";
    const before = count(scope.query("com.rmxos.aslmanager.record", "summary", false, false), marker);
    _ = run(&.{ "/bin/launchctl", "load", path });
    var observed = before;
    for (0..140) |_| {
        observed = count(scope.query("com.rmxos.aslmanager.record", "summary", false, false), marker);
        if (observed >= before + 2) break;
        _ = c.usleep(50000);
    }
    _ = run(&.{ "/bin/launchctl", "unload", path });
    _ = c.unlink(path);
    _ = c.printf("op040_retention summary_before=%zu summary_after=%zu delta=%zu\n", before, observed, observed - before);
    const times = command(&.{ "/bin/cat", "/tmp/op040-retention-times" });
    _ = c.printf("%.*s", @as(c_int, @intCast(times.text.len)), times.text.ptr);
    need(observed >= before + 2, "launchd StartInterval ran the same retention command twice");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    cleaning = true;
    if (c.access("/tmp/op767-interval.plist", c.F_OK) == 0) {
        _ = command(&.{ "/bin/launchctl", "unload", "/tmp/op767-interval.plist" });
        _ = c.unlink("/tmp/op767-interval.plist");
    }
}
fn retentionUnavailable(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const result = command(&.{ "/usr/bin/env", "ASL_DISABLE=1", "/usr/sbin/aslmanager", "-once", "-s", "/var/log/asl", "-asldb" });
    _ = c.printf("aslmanager_unavailable wait_status=%d output=%.*s\n", result.status, @as(c_int, @intCast(result.text.len)), result.text.ptr);
    need(result.status == 256, "undelivered summary exits one");
    need(count(result.text, "aslmanager: summary write failed") == 1, "undelivered summary reports failure once");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "90");
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
    _ = c.alarm(85);
    scope.begin();
}
var cases: [10]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "boot_ready", "one_owner", "routes", "native", "kernel", "rotation", "counters", "retention", "compat_service", "retention_unavailable" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ bootReady, oneOwner, routes, native, kernel, rotation, counters, retention, compatibilityService, retentionUnavailable };
    for (&cases, names, bodies) |*tc, name, body| {
        var err = c.atf_tc_init(tc, name, head, body, cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
