const std = @import("std");
const recovery = @import("asld_recovery.zig");
const sender = @import("syslog_sender.zig");
const timing = @import("syslog_timing.zig");
const transport = @import("syslog_transport.zig");
const reports = @import("syslog_reports.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("asl.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("syslog.h");
    @cInclude("time.h");
    @cInclude("errno.h");
    @cInclude("dlfcn.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn socketCase(_: [*c]const c.atf_tc_t) callconv(.c) void {
    sender.fullSocket() catch |err| c.atf_tc_fail("socket accounting: %s", @errorName(err).ptr);
}
fn reportCase(_: [*c]const c.atf_tc_t) callconv(.c) void {
    reports.storedReport() catch |err| c.atf_tc_fail("stored report: %s", @errorName(err).ptr);
    reports.invalidCounts() catch |err| c.atf_tc_fail("invalid counts: %s", @errorName(err).ptr);
}
fn need(ok: bool, message: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", message);
}
fn query(key: [*:0]const u8, value: [*:0]const u8, limit: usize) c.asl_object_t {
    const store = c.asl_open_path("/var/log/asl", 0);
    need(store != null, "open store");
    defer c.asl_release(store);
    const q = c.asl_new(c.ASL_TYPE_QUERY);
    defer c.asl_release(q);
    need(c.asl_set_query(q, key, value, c.ASL_QUERY_OP_EQUAL) == 0, "query");
    const list = c.asl_new(c.ASL_TYPE_LIST);
    defer c.asl_release(list);
    c.asl_append(list, q);
    var last: usize = 0;
    return c.asl_match(store, list, &last, std.math.maxInt(usize), limit, 2000000, -1);
}
fn status() u64 {
    var pid: c_int = 0;
    const f = c.fopen("/var/run/syslog.pid", "r") orelse @panic("pidfile");
    _ = c.fscanf(f, "%d", &pid);
    _ = c.fclose(f);
    const old = query("com.rmxos.asld.record", "status", 1);
    const old_msg = c.asl_next(old);
    const old_id = if (old_msg != null) std.fmt.parseInt(u64, std.mem.span(c.asl_get(old_msg, "ASLMessageID")), 10) catch 0 else 0;
    c.asl_release(old);
    need(c.kill(pid, c.SIGUSR1) == 0, "status signal");
    for (0..100) |_| {
        _ = c.usleep(20000);
        const fresh = query("com.rmxos.asld.record", "status", 1);
        defer c.asl_release(fresh);
        const m = c.asl_next(fresh);
        if (m == null) continue;
        const id = std.fmt.parseInt(u64, std.mem.span(c.asl_get(m, "ASLMessageID")), 10) catch 0;
        if (id > old_id) {
            const counter = c.asl_get(m, "sender_dropped");
            need(counter != null, "sender_dropped status counter present");
            return std.fmt.parseInt(u64, std.mem.span(counter), 10) catch @panic("counter");
        }
    }
    c.atf_tc_fail("fresh status");
}
fn now(clock: c.clockid_t) i64 {
    var t: c.struct_timespec = undefined;
    need(c.clock_gettime(clock, &t) == 0, "clock");
    return timing.nanoseconds(t.tv_sec, t.tv_nsec);
}
fn phase(name: [*:0]const u8, began: i64) void {
    _ = c.printf("op956_phase name=%s elapsed_ms=%lld\n", name, @as(c_longlong, @divTrunc(now(c.CLOCK_MONOTONIC) - began, std.time.ns_per_ms)));
    _ = c.fflush(null);
}
fn flood(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const began = now(c.CLOCK_MONOTONIC);
    phase("status_before", began);
    const before = status();
    phase("generator", began);
    var tag_buf: [64]u8 = undefined;
    const tag = std.fmt.bufPrintZ(&tag_buf, "op956-{d}", .{c.getpid()}) catch unreachable;
    transport.openlog(tag, c.LOG_PID, c.LOG_USER);
    defer transport.closelog();
    var wall: i64 = 0;
    var cpu: i64 = 0;
    transport.setVerbose(false);
    defer transport.setVerbose(true);
    const initial_transports = transport.totals();
    for (0..10) |second| {
        const w = now(c.CLOCK_MONOTONIC);
        const p = now(c.CLOCK_THREAD_CPUTIME_ID);
        for (0..1000) |i| {
            var line: [64]u8 = undefined;
            const text = std.fmt.bufPrintZ(&line, "op956-numbered-{d}", .{second * 1000 + i}) catch unreachable;
            transport.record(c.LOG_NOTICE, text);
        }
        wall += now(c.CLOCK_MONOTONIC) - w;
        cpu += now(c.CLOCK_THREAD_CPUTIME_ID) - p;
        phase("sends", began);
        _ = c.sleep(1);
    }
    const child = c.fork();
    need(child >= 0, "fork cached client");
    if (child == 0) {
        var name: [64]u8 = undefined;
        const child_tag = std.fmt.bufPrintZ(&name, "op956-child-{d}", .{c.getpid()}) catch unreachable;
        c.openlog(child_tag, c.LOG_PID, c.LOG_USER);
        c.syslog(c.LOG_NOTICE, "child reacquired its logger port");
        c._exit(0);
    }
    var child_status: c_int = 0;
    need(c.waitpid(child, &child_status, 0) == child and child_status == 0, "child send completed");
    var child_name: [64]u8 = undefined;
    const child_tag = std.fmt.bufPrintZ(&child_name, "op956-child-{d}", .{child}) catch unreachable;
    var child_count: usize = 0;
    for (0..50) |_| {
        const found = query("Sender", child_tag, 2);
        child_count = 0;
        while (c.asl_next(found) != null) child_count += 1;
        c.asl_release(found);
        if (child_count == 1) break;
        _ = c.usleep(20000);
    }
    need(child_count == 1, "fork child record stored exactly once");
    const final_wall = now(c.CLOCK_MONOTONIC);
    const final_cpu = now(c.CLOCK_THREAD_CPUTIME_ID);
    transport.record(c.LOG_NOTICE, "op956-numbered-10000");
    wall += now(c.CLOCK_MONOTONIC) - final_wall;
    cpu += now(c.CLOCK_THREAD_CPUTIME_ID) - final_cpu;
    _ = c.printf("op956_sender sent=10001 send_wall_ns=%lld send_cpu_ns=%lld blocked_estimate_ns=%lld\n", @as(c_longlong, wall), @as(c_longlong, cpu), @as(c_longlong, @max(0, wall - cpu)));
    _ = c.fflush(null);
    phase("status_after", began);
    const dropped = status() - before;
    phase("store_query", began);
    var identity_ok = true;
    var native_fields_ok = true;
    var stored: usize = 0;
    for (0..50) |_| {
        const result = query("Sender", tag, 10002);
        var seen: [10001]bool = @splat(false);
        stored = 0;
        while (c.asl_next(result)) |m| {
            const text = c.asl_get(m, "Message");
            need(text != null, "message");
            const bytes = std.mem.span(text);
            need(std.mem.startsWith(u8, bytes, "op956-numbered-"), "numbered message");
            const id = std.fmt.parseInt(usize, bytes["op956-numbered-".len..], 10) catch c.atf_tc_fail("number");
            need(id < seen.len and !seen[id], "no duplicate or invented number");
            seen[id] = true;
            if (stored == 0 or !equal(m, "UID", "0") or !equal(m, "GID", "0")) identity("flood", m);
            identity_ok = identity_ok and equal(m, "UID", "0") and equal(m, "GID", "0");

            native_fields_ok = native_fields_ok and c.asl_get(m, "RFC5424.Timestamp") == null and c.asl_get(m, "RFC5424.StructuredData") == null;
            stored += 1;
        }
        c.asl_release(result);
        if (stored + dropped >= 10001) break;
        _ = c.usleep(10000);
    }
    _ = c.printf("op956_flood sent=10001 stored=%zu sender_dropped=%ju observed_accounted=%ju\n", stored, dropped, stored + dropped);
    phase("complete", began);
    const final_transports = transport.totals();
    _ = c.printf("op982_flood_transport expected_mach=10001 observed_mach=%zu socket=%zu refused=%zu\n", final_transports[0] - initial_transports[0], final_transports[1] - initial_transports[1], final_transports[2] - initial_transports[2]);
    need(final_transports[0] - initial_transports[0] == 10001 and final_transports[1] == initial_transports[1] and final_transports[2] == initial_transports[2], "every flood record uses Mach");
    need(wall >= cpu and cpu >= 0, "valid nonnegative send timing");
    need(identity_ok, "kernel audit UID and GID");
    need(native_fields_ok, "Mach records have no RFC parse metadata");
    need(stored == 10001 and dropped == 0, "unbounded Mach send stores every numbered message");
}
fn command(program: [*:0]const u8, verb: [*:0]const u8, path: [*:0]const u8) void {
    const child = c.fork();
    need(child >= 0, "fork command");
    if (child == 0) {
        _ = c.execl(program, program, verb, path, @as(?*anyopaque, null));
        c._exit(127);
    }
    var result: c_int = 0;
    need(c.waitpid(child, &result, 0) == child and result == 0, "command outcome");
}
fn equal(m: c.asl_object_t, key: [*:0]const u8, expected: []const u8) bool {
    const value = c.asl_get(m, key);
    return value != null and std.mem.eql(u8, std.mem.span(value), expected);
}
fn identity(label: [*:0]const u8, m: c.asl_object_t) void {
    _ = c.printf("op982_stored case=%s PID=%s Sender=%s UID=%s GID=%s RFC5424.Timestamp=%s Message=%s\n", label, c.asl_get(m, "PID"), c.asl_get(m, "Sender"), c.asl_get(m, "UID"), c.asl_get(m, "GID"), c.asl_get(m, "RFC5424.Timestamp"), c.asl_get(m, "Message"));
}
fn awaitSender(tag: [*:0]const u8) c.asl_object_t {
    for (0..100) |_| {
        const found = query("Sender", tag, 2);
        if (c.asl_next(found)) |m| {
            _ = c.asl_retain(m);
            c.asl_release(found);
            return m;
        }
        c.asl_release(found);
        _ = c.usleep(20000);
    }
    c.atf_tc_fail("record missing for Sender %s", tag);
}
fn nativeCase(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var library: c.Dl_info = undefined;
    need(c.dladdr(@ptrCast(&c.syslog), &library) != 0, "syslog binding");
    _ = c.printf("op982_binding symbol=syslog object=%s\n", library.dli_fname);
    var name: [64]u8 = undefined;
    const tag = std.fmt.bufPrintZ(&name, "op982-native-{d}", .{c.getpid()}) catch unreachable;
    transport.openlog(tag, c.LOG_PID, c.LOG_USER);
    transport.record(c.LOG_NOTICE, "observed libc source");
    const observed = awaitSender(tag);
    defer c.asl_release(observed);
    identity("observed-libc", observed);
    var other: [64]u8 = undefined;
    const installed = std.fmt.bufPrintZ(&other, "op982-installed-{d}", .{c.getpid()}) catch unreachable;
    c.openlog(installed, c.LOG_PID, c.LOG_USER);
    c.syslog(c.LOG_NOTICE, "installed libc control");
    c.closelog();
    const actual = awaitSender(installed);
    defer c.asl_release(actual);
    identity("installed-libc", actual);
    var control_name: [64]u8 = undefined;
    const control_tag = std.fmt.bufPrintZ(&control_name, "op982-asl-{d}", .{c.getpid()}) catch unreachable;
    const client = c.asl_open(control_tag, "user", 0);
    need(client != null, "asl_log control client");
    transport.controlBegin();
    const rc = c.asl_log(client, null, c.ASL_LEVEL_NOTICE, "asl_log Mach control");
    _ = c.printf("op982_control api=asl_log rc=%d errno=%d\n", rc, c.__error().*);
    transport.controlEnd();
    c.asl_close(client);
    const control = awaitSender(control_tag);
    defer c.asl_release(control);
    identity("asl_log", control);
    _ = c.fflush(null);
    need(equal(control, "UID", "0") and equal(control, "GID", "0"), "asl_log control has kernel audit identity");
    need(equal(observed, "UID", "0") and equal(actual, "UID", "0") and equal(observed, "GID", "0") and equal(actual, "GID", "0"), "both libc paths retain kernel audit identity");
    need(c.asl_get(actual, "RFC5424.Timestamp") == null and c.asl_get(observed, "RFC5424.Timestamp") == null, "native libc records have no RFC parse fields");
    const t = transport.totals();
    need(t[0] == 1 and t[1] == 0 and t[2] == 0, "service-up record takes Mach without socket fallback");
}
fn fallback(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var readiness: [2]c_int = undefined;
    var release_pipe: [2]c_int = undefined;
    need(c.pipe(&readiness) == 0 and c.pipe(&release_pipe) == 0, "fallback pipes");
    const child = c.fork();
    need(child >= 0, "fallback child");
    if (child == 0) {
        _ = c.alarm(20);
        _ = c.close(readiness[0]);
        _ = c.close(release_pipe[1]);
        var name: [64]u8 = undefined;
        const tag = std.fmt.bufPrintZ(&name, "op982-fallback-{d}", .{c.getpid()}) catch unreachable;
        transport.openlog(tag, c.LOG_PID, c.LOG_USER);
        transport.record(c.LOG_NOTICE, "prime service cache");
        var byte: u8 = 1;
        _ = c.write(readiness[1], &byte, 1);
        if (c.read(release_pipe[0], &byte, 1) != 1) c._exit(75);
        const began = now(c.CLOCK_MONOTONIC);
        for (0..100) |i| {
            var line: [64]u8 = undefined;
            const text = std.fmt.bufPrintZ(&line, "fallback-numbered-{d}", .{i}) catch unreachable;
            transport.record(c.LOG_NOTICE, text);
        }
        _ = c.printf("op982_unavailable sends=100 elapsed_ns=%lld\n", @as(c_longlong, now(c.CLOCK_MONOTONIC) - began));
        _ = c.write(readiness[1], &byte, 1);
        if (c.read(release_pipe[0], &byte, 1) != 1) c._exit(75);
        transport.record(c.LOG_NOTICE, "flush after restart");
        _ = c.printf("op982_after_restart flush_completed=1\n");
        _ = c.fflush(null);
        c._exit(0);
    }
    _ = c.close(readiness[1]);
    _ = c.close(release_pipe[0]);
    var byte: u8 = 0;
    need(c.read(readiness[0], &byte, 1) == 1, "child primed cache");
    var old_pid: c_int = 0;
    const pidfile = c.fopen("/var/run/syslog.pid", "r") orelse @panic("pidfile");
    _ = c.fscanf(pidfile, "%d", &old_pid);
    _ = c.fclose(pidfile);
    command("/bin/launchctl", "unload", "/etc/launchd.d/com.apple.syslogd.plist");
    for (0..100) |_| {
        if (c.kill(old_pid, 0) != 0) break;
        _ = c.usleep(100000);
    }
    need(c.kill(old_pid, 0) != 0, "asld exited");
    _ = c.write(release_pipe[1], &byte, 1);
    // Recovery is controlled by the parent; child waits are bounded and EOF
    // terminates the helper if an assertion exits its parent.
    _ = c.sleep(2);
    need(recovery.restore(), "launchctl restart serves after fallback");
    need(c.read(readiness[0], &byte, 1) == 1, "100 sends completed");
    _ = c.write(release_pipe[1], &byte, 1);
    var result: c_int = 0;
    need(c.waitpid(child, &result, 0) == child and result == 0, "fallback child finished");
    var name: [64]u8 = undefined;
    const tag = std.fmt.bufPrintZ(&name, "op982-fallback-{d}", .{child}) catch unreachable;
    const dropped = status(); // Fresh asld; flush/report precede the status snapshot.
    var stored: usize = 0;
    for (0..100) |_| {
        const found = query("Sender", tag, 110);
        var seen: [100]bool = @splat(false);
        stored = 0;
        while (c.asl_next(found)) |m| {
            const value = c.asl_get(m, "Message");
            if (value == null) continue;
            const text = std.mem.span(value);
            if (!std.mem.startsWith(u8, text, "fallback-numbered-")) continue;
            const id = std.fmt.parseInt(usize, text["fallback-numbered-".len..], 10) catch c.atf_tc_fail("number");
            need(id < 100 and !seen[id], "unique fallback record");
            seen[id] = true;
            identity("fallback", m);
            stored += 1;
        }
        c.asl_release(found);
        if (stored + dropped >= 100) break;
        _ = c.usleep(20000);
    }
    _ = c.printf("op982_fallback sent=100 stored=%zu sender_dropped=%ju accounted=%ju\n", stored, dropped, stored + dropped);
    _ = c.fflush(null);
    need(stored + dropped == 100, "fallback stored plus reported equals sent exactly");
    need(status() == dropped, "no second loss report");
    _ = c.close(readiness[0]);
    _ = c.close(release_pipe[1]);
}
extern fn __libc_asl_send([*:0]const u8) c_int;
fn bounded(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(recovery.health("bounded-before"), "initial asld serves");
    const old = recovery.pid();
    var ready: [2]c_int = undefined;
    var release: [2]c_int = undefined;
    need(c.pipe(&ready) == 0 and c.pipe(&release) == 0, "bounded pipes");
    const child = c.fork();
    need(child >= 0, "bounded child");
    if (child == 0) {
        _ = c.alarm(20);
        _ = c.close(ready[0]);
        _ = c.close(release[1]);
        c.openlog("op021-bounded", c.LOG_PID, c.LOG_USER);
        c.syslog(c.LOG_NOTICE, "op021 prime");
        var byte: u8 = 0;
        _ = c.write(ready[1], &byte, 1);
        if (c.read(release[0], &byte, 1) != 1) c._exit(75);
        // Raw protocol sends fill the stopped daemon's queue without changing
        // syslog's application-loss counter. A refused raw fixture is not a log.
        var filled: usize = 0;
        while (filled < 1024 and __libc_asl_send("[Sender op021-prefill] [Message fixture]") == 0) filled += 1;
        if (filled == 1024) c._exit(71);
        const began = now(c.CLOCK_MONOTONIC);
        transport.setVerbose(false);
        transport.setQuiet(true);
        const refused_before = transport.totals()[2];
        for (0..1000) |_| transport.record(c.LOG_NOTICE, "op021 refused application");
        const refused_full = transport.totals()[2] - refused_before;
        if (refused_full == 0) c._exit(74);
        const elapsed = now(c.CLOCK_MONOTONIC) - began;
        _ = c.printf("syslog_mach_full sends=1000 queued_fixture=%zu elapsed_ns=%lld bound_ns=2000000000\n", filled, @as(c_longlong, elapsed));
        _ = c.fflush(null);
        if (elapsed >= 2 * std.time.ns_per_s) c._exit(72);
        _ = c.write(ready[1], &byte, 1);
        if (c.read(release[0], &byte, 1) != 1) c._exit(75);
        const unloaded_began = now(c.CLOCK_MONOTONIC);
        for (0..20) |_| transport.record(c.LOG_NOTICE, "op021 unloaded application");
        const refused_total: u64 = @intCast(transport.totals()[2] - refused_before);
        _ = c.printf("syslog_unloaded sends=20 elapsed_ns=%lld bound_ns=2000000000\n", @as(c_longlong, now(c.CLOCK_MONOTONIC) - unloaded_began));
        _ = c.fflush(null);
        if (now(c.CLOCK_MONOTONIC) - unloaded_began >= 2 * std.time.ns_per_s) c._exit(73);
        _ = c.write(ready[1], &refused_total, @sizeOf(u64));
        if (c.read(release[0], &byte, 1) != 1) c._exit(75);
        _ = c.sleep(1);
        c.syslog(c.LOG_NOTICE, "op021 bounded flush");
        c.closelog();
        c._exit(0);
    }
    _ = c.close(ready[1]);
    _ = c.close(release[0]);
    defer _ = c.close(ready[0]);
    defer _ = c.close(release[1]);
    var byte: u8 = 0;
    need(c.read(ready[0], &byte, 1) == 1, "bounded child primed");
    need(c.kill(old, c.SIGSTOP) == 0, "pause asld receiver");
    _ = c.write(release[1], &byte, 1);
    // Poll proves completion while the receiver is still stopped.
    const Poll = @cImport({
        @cInclude("poll.h");
    });
    var poll = Poll.struct_pollfd{ .fd = ready[0], .events = Poll.POLLIN, .revents = 0 };
    need(Poll.poll(&poll, 1, 2500) == 1 and c.read(ready[0], &byte, 1) == 1, "full-queue syslog returns before receiver resumes");
    // The full-queue measurement is complete. Unload now waits for exit,
    // so resume the receiver before asking launchd to remove it.
    _ = c.kill(old, c.SIGCONT);
    command("/bin/launchctl", "unload", recovery.plist);
    for (0..100) |_| {
        if (c.kill(old, 0) != 0) break;
        _ = c.usleep(20000);
    }
    need(c.kill(old, 0) != 0, "unloaded receiver exits");
    _ = c.write(release[1], &byte, 1);
    var expected: u64 = 0;
    need(Poll.poll(&poll, 1, 2500) == 1 and c.read(ready[0], &expected, @sizeOf(u64)) == @sizeOf(u64), "unloaded syslog returns before reload");
    need(expected >= 20, "unloaded transports refuse and count messages");
    need(recovery.restore(), "reload serves after bounded sends");
    _ = c.write(release[1], &byte, 1);
    var result: c_int = 0;
    need(c.waitpid(child, &result, 0) == child and result == 0, "bounded child result");
    const dropped = status();
    _ = c.printf("syslog_mach_loss expected=%ju observed=%ju\n", expected, dropped);
    need(dropped == expected, "every refused application counted on next successful report");
    need(status() == dropped, "loss report not duplicated");
}

fn bounds(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(recovery.run(&.{"/usr/tests/sys/launchd/unload_completion_unit"}), "unload completion RPC");
    need(recovery.run(&.{"/usr/tests/usr.sbin/asl/cleanup_status_unit"}), "cleanup exit status");
    need(recovery.run(&.{"/usr/tests/usr.sbin/asl/mach_bound_unit"}), "Mach timeout controls");
    need(recovery.run(&.{"/usr/tests/usr.sbin/asl/filesystems_unit"}), "filesystem boot identity controls");
}
fn timingCase(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(timing.nanoseconds(9, 50000000) - timing.nanoseconds(8, 950000000) == 100000000, "nanoseconds across second boundary");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    recovery.cleanupResult(recovery.restore(), "sender");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "120");
    _ = c.alarm(110);
}
var cases: [8]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "timing", "socket", "report", "transport", "flood", "fallback", "bounded", "bounds" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ timingCase, socketCase, reportCase, nativeCase, flood, fallback, bounded, bounds };
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
