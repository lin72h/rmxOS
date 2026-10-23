const std = @import("std");
const sender = @import("syslog_sender.zig");
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
    return t.tv_sec * 1000000000 + t.tv_nsec;
}
fn phase(name: [*:0]const u8, began: i64) void {
    _ = c.printf("op956_phase name=%s elapsed_ms=%lld\n", name, @as(c_longlong, @divTrunc(now(c.CLOCK_MONOTONIC) - began, 1000000)));
    _ = c.fflush(null);
}
fn flood(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const began = now(c.CLOCK_MONOTONIC);
    phase("status_before", began);
    const before = status();
    phase("generator", began);
    var tag_buf: [64]u8 = undefined;
    const tag = std.fmt.bufPrintZ(&tag_buf, "op956-{d}", .{c.getpid()}) catch unreachable;
    c.openlog(tag, c.LOG_PID, c.LOG_USER);
    defer c.closelog();
    var wall: i64 = 0;
    var cpu: i64 = 0;
    for (0..10) |second| {
        const w = now(c.CLOCK_MONOTONIC);
        const p = now(c.CLOCK_THREAD_CPUTIME_ID);
        for (0..1000) |i| c.syslog(c.LOG_NOTICE, "op956-numbered-%zu", second * 1000 + i);
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
    c.syslog(c.LOG_NOTICE, "op956-numbered-10000");
    wall += now(c.CLOCK_MONOTONIC) - final_wall;
    cpu += now(c.CLOCK_THREAD_CPUTIME_ID) - final_cpu;
    _ = c.printf("op956_sender sent=10001 send_wall_ns=%lld send_cpu_ns=%lld blocked_estimate_ns=%lld\n", @as(c_longlong, wall), @as(c_longlong, cpu), @as(c_longlong, @max(0, wall - cpu)));
    _ = c.fflush(null);
    phase("status_after", began);
    const dropped = status() - before;
    phase("store_query", began);
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
            need(std.mem.eql(u8, std.mem.span(c.asl_get(m, "UID")), "0"), "kernel audit UID");
            need(std.mem.eql(u8, std.mem.span(c.asl_get(m, "GID")), "0"), "kernel audit GID");
            need(c.asl_get(m, "RFC5424.Timestamp") == null and c.asl_get(m, "RFC5424.StructuredData") == null, "Mach records have no RFC parse metadata");
            stored += 1;
        }
        c.asl_release(result);
        if (stored + dropped >= 10001) break;
        _ = c.usleep(100000);
    }
    _ = c.printf("op956_flood sent=10001 stored=%zu sender_dropped=%ju observed_accounted=%ju\n", stored, dropped, stored + dropped);
    phase("complete", began);
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
fn fallback(_: [*c]const c.atf_tc_t) callconv(.c) void {
    c.openlog("op956-fallback", c.LOG_PID, c.LOG_USER);
    c.syslog(c.LOG_NOTICE, "prime service cache");
    var old_pid: c_int = 0;
    const pidfile = c.fopen("/var/run/syslog.pid", "r") orelse @panic("pidfile");
    _ = c.fscanf(pidfile, "%d", &old_pid);
    _ = c.fclose(pidfile);
    command("/bin/launchctl", "unload", "/etc/launchd.d/com.apple.syslogd.plist");
    for (0..100) |_| {
        if (c.kill(old_pid, 0) != 0) break;
        _ = c.usleep(100000);
    }
    need(c.kill(old_pid, 0) != 0, "asld exited before unavailable-service sends");
    for (0..100) |i| c.syslog(c.LOG_NOTICE, "fallback-numbered-%zu", i);
    command("/bin/launchctl", "load", "/etc/launchd.d/com.apple.syslogd.plist");
    command("/usr/sbin/service", "syslogd", "onestart");
    _ = c.sleep(1);
    const before = status();
    c.syslog(c.LOG_NOTICE, "after-restart");
    const after = status();
    _ = c.printf("op956_fallback refused=100 expected_reported=100 observed_reported=%ju\n", after - before);
    need(after - before == 100, "both failed transports are reported after restart");
    c.syslog(c.LOG_NOTICE, "after-report");
    need(status() == after, "loss report counted once");
    c.closelog();
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "120");
    _ = c.alarm(110);
}
var cases: [4]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "socket", "report", "flood", "fallback" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ socketCase, reportCase, flood, fallback };
    for (&cases, names, bodies) |*tc, name, body| {
        var err = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
