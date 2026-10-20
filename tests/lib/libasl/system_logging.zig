// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
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
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const job = "/etc/launchd.d/com.apple.syslogd.plist";
var captured: [262144]u8 = undefined;
const Result = struct { status: c_int, text: []const u8 };
fn need(ok: bool, message: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s errno=%d", message, c.__error().*);
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
    const file = c.fopen(path, "r") orelse return 0;
    defer _ = c.fclose(file);
    var line: [16384]u8 = undefined;
    var result: usize = 0;
    while (c.fgets(&line, line.len, file) != null) result += count(std.mem.span(@as([*:0]const u8, @ptrCast(&line))), token);
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
    return run(&.{ "/usr/bin/aslutil", "-d", "/var/log/asl", "-F", "raw", "-k", "Message", message });
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
    const denied = command(&.{ "/etc/rc.d/syslogd", "onestart" });
    need(denied.status != 0, "rc refuses to start syslogd over live asld");
    need(c.lstat("/var/run/log", &st) == 0 and st.st_ino == inode and ownerIs("asld"), "refusal preserves the live socket and owner");
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
    // Later repetitions rotate the boot text out of messages. Check it before
    // the first fixture load; the store keeps the boot record across rotations.
    if (before_load == 0 and c.access("/tmp/op767-fallback-boot", c.F_OK) != 0) awaitFile("/var/log/messages", boot, 1);
    // The preliminary fixture boots syslogd, which consumes the boot backlog.
    // Whole-plan boots start asld and must also have exactly one store copy.
    if (c.access("/tmp/op767-fallback-boot", c.F_OK) != 0) _ = awaitStore(boot, 1);
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
fn counters(_: [*c]const c.atf_tc_t) callconv(.c) void {
    awaitOwner("asld");
    const status_args = &.{ "/usr/bin/aslutil", "-d", "/var/log/asl", "-F", "raw", "-k", "com.rmxos.asld.record", "status" };
    const before = count(run(status_args), "[com.rmxos.asld.record status]");
    need(c.kill(pidfile(), c.SIGUSR1) == 0, "request system logger status");
    const names = [_][]const u8{ "dropped_wq", "dropped_kern_quota", "dropped_parse", "bsd_in_truncated", "store_failed", "store_fallback_memory", "file_action_failed", "native_malformed", "dup_suppressed", "config_rejected" };
    for (0..100) |i| {
        const raw = run(status_args);
        if (count(raw, "[com.rmxos.asld.record status]") > before) {
            for (names) |name| {
                var pattern: [128]u8 = undefined;
                const match = std.fmt.bufPrint(&pattern, "[{s} 0]", .{name}) catch unreachable;
                need(count(raw, match) == count(raw, "[com.rmxos.asld.record status]"), "all status counters present and zero");
            }
            return;
        }
        if (i % 5 == 4) _ = c.kill(pidfile(), c.SIGUSR1);
        _ = c.usleep(20000);
    }
    need(false, "status written through store");
}
fn restore() void {
    if (ownerIs("syslogd")) _ = run(&.{ "/etc/rc.d/syslogd", "forcestop" });
    _ = run(&.{ "/usr/sbin/sysrc", "syslogd_enable=NO" });
    setDisabled(false);
    if (!ownerIs("asld")) _ = run(&.{ "/bin/launchctl", "load", job });
    awaitOwner("asld");
}
fn setDisabled(disabled: bool) void {
    const input = c.fopen(job, "r");
    need(input != null, "read installed job");
    var bytes: [8192]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, input);
    need(n < bytes.len and c.ferror(input) == 0, "bounded installed job read");
    _ = c.fclose(input);
    const text = bytes[0..n];
    var start: usize = 0;
    var end: usize = 0;
    const key = "<key>Disabled</key>";
    if (std.mem.indexOf(u8, text, key)) |i| {
        start = i;
        var value = i + key.len;
        while (value < n and std.ascii.isWhitespace(text[value])) value += 1;
        if (std.mem.startsWith(u8, text[value..], "<true/>")) {
            end = value + 7;
        } else if (std.mem.startsWith(u8, text[value..], "<false/>")) {
            end = value + 8;
        } else need(false, "known Disabled boolean");
    } else {
        start = (std.mem.indexOf(u8, text, "<dict>") orelse unreachable) + 6;
        end = start;
    }
    const output = c.fopen("/etc/launchd.d/.op767-syslogd.tmp", "w");
    need(output != null, "write job switch");
    const middle: []const u8 = if (disabled) "<key>Disabled</key><true/>" else "";
    need(c.fwrite(text.ptr, 1, start, output) == start and c.fwrite(middle.ptr, 1, middle.len, output) == middle.len and c.fwrite(text[end..].ptr, 1, n - end, output) == n - end, "write complete job with only Disabled changed");
    need(c.fchmod(c.fileno(output), 0o644) == 0 and c.fclose(output) == 0, "close switched job");
    need(c.rename("/etc/launchd.d/.op767-syslogd.tmp", job) == 0, "publish switched job");
}
fn wayBack(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const initially_syslogd = ownerIs("syslogd");
    _ = c.printf("op767_fallback initially_syslogd=%d\n", @as(c_int, if (initially_syslogd) 1 else 0));
    if (initially_syslogd) {
        awaitFile("/var/log/messages", "FreeBSD is a registered trademark of The FreeBSD Foundation.", 1);
        const flag = c.fopen("/tmp/op767-fallback-boot", "w");
        need(flag != null, "record preliminary fallback boot");
        _ = c.fclose(flag);
    }
    setDisabled(true);
    if (ownerIs("asld")) {
        const previous = pidfile();
        _ = run(&.{ "/bin/launchctl", "unload", job });
        var stopped = false;
        for (0..100) |_| {
            if (c.kill(previous, 0) != 0 and c.__error().* == c.ESRCH) {
                stopped = true;
                break;
            }
            _ = c.usleep(50000);
        }
        need(stopped, "asld exited before fallback starts");
    }
    _ = run(&.{ "/usr/sbin/sysrc", "syslogd_enable=YES" });
    _ = run(&.{ "/etc/rc.d/syslogd", "start" });
    awaitOwner("syslogd");
    rotateAndLog();
    const debug = unique("fallback_debug");
    log("user.debug", "op767", &debug);
    awaitFile("/var/log/debug.log", z(&debug), 1);
    const excluded = unique("fallback_devd");
    log("daemon.debug", "devd", &excluded);
    const fence = unique("fallback_fence");
    log("daemon.info", "op767", &fence);
    awaitFile("/var/log/daemon.log", z(&fence), 1);
    need(fileCount("/var/log/debug.log", z(&excluded)) == 0 and fileCount("/var/log/daemon.log", z(&excluded)) == 0, "fallback restores devd filter");
    restore();
    const after = unique("restored_asld");
    log("user.notice", "op767", &after);
    awaitFile("/var/log/messages", z(&after), 1);
    _ = awaitStore(&after, 1);
}
fn retention(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const jobs = run(&.{ "/bin/launchctl", "list" });
    need(std.mem.indexOf(u8, jobs, "com.rmxos.aslmanager.once") != null, "retention job loaded");
    const path = "/tmp/op767-interval.plist";
    const f = c.fopen(path, "w");
    need(f != null, "interval fixture plist");
    _ = c.fputs("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>com.rmxos.op767.interval</string><key>ProgramArguments</key><array><string>/usr/sbin/aslmanager</string><string>-once</string><string>-wait-for-filesystems</string><string>-s</string><string>/var/log/asl</string></array><key>ThrottleInterval</key><integer>0</integer><key>StartInterval</key><integer>2</integer></dict></plist>", f);
    need(c.fclose(f) == 0, "close interval fixture");
    const marker = "[com.rmxos.aslmanager.record summary]";
    const before = count(run(&.{ "/usr/bin/aslutil", "-d", "/var/log/asl", "-F", "raw", "-k", "com.rmxos.aslmanager.record", "summary" }), marker);
    _ = run(&.{ "/bin/launchctl", "load", path });
    var observed = before;
    for (0..140) |_| {
        observed = count(run(&.{ "/usr/bin/aslutil", "-d", "/var/log/asl", "-F", "raw", "-k", "com.rmxos.aslmanager.record", "summary" }), marker);
        if (observed >= before + 2) break;
        _ = c.usleep(50000);
    }
    _ = run(&.{ "/bin/launchctl", "unload", path });
    _ = c.unlink(path);
    need(observed >= before + 2, "launchd StartInterval ran the same retention command twice");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    if (c.access("/tmp/op767-interval.plist", c.F_OK) == 0) {
        _ = command(&.{ "/bin/launchctl", "unload", "/tmp/op767-interval.plist" });
        _ = c.unlink("/tmp/op767-interval.plist");
    }
    restore();
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "90");
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
    _ = c.alarm(85);
}
var cases: [8]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "one_owner", "routes", "native", "kernel", "rotation", "counters", "retention", "way_back" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ oneOwner, routes, native, kernel, rotation, counters, retention, wayBack };
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
