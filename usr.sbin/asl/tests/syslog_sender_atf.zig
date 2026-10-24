const std = @import("std");
const recovery = @import("asld_recovery.zig");
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
    @cInclude("poll.h");
    @cInclude("sys/mach/message.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/sysctl.h");
    @cInclude("asld_stop_abi.h");
    @cInclude("dirent.h");
    @cInclude("fcntl.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn reportCase(_: [*c]const c.atf_tc_t) callconv(.c) void {
    reports.storedReport() catch |err| c.atf_tc_fail("stored report: %s", @errorName(err).ptr);
    reports.invalidCounts() catch |err| c.atf_tc_fail("invalid counts: %s", @errorName(err).ptr);
}
fn need(ok: bool, message: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", message);
}
fn query(key: [*:0]const u8, value: [*:0]const u8, limit: usize) c.asl_object_t {
    return queryBudget(key, value, limit, 2000000);
}
fn queryBefore(key: [*:0]const u8, value: [*:0]const u8, limit: usize, deadline: i64) ?c.asl_object_t {
    const remaining = deadline - now(c.CLOCK_MONOTONIC);
    if (remaining <= 0) return null;
    const usec: u32 = @intCast(@min(2000000, @max(1, @divTrunc(remaining, 1000))));
    return queryBudget(key, value, limit, usec);
}
fn queryBudget(key: [*:0]const u8, value: [*:0]const u8, limit: usize, usec: u32) c.asl_object_t {
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
    return c.asl_match(store, list, &last, std.math.maxInt(usize), limit, usec, -1);
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
// Unlike status(), this observation shares the reconciliation deadline with
// store reads, so a missing reply cannot add a separate wait to each pass.
fn statusBefore(deadline: i64) ?u64 {
    const pid = recovery.pid();
    need(pid > 1, "status logger pid");
    const old = queryBefore("com.rmxos.asld.record", "status", 1, deadline) orelse return null;
    const old_msg = c.asl_next(old);
    const old_id = if (old_msg != null) numeric(old_msg, "ASLMessageID") else 0;
    c.asl_release(old);
    need(c.kill(pid, c.SIGUSR1) == 0, "fresh reconciliation status signal");
    while (now(c.CLOCK_MONOTONIC) < deadline) {
        const fresh = queryBefore("com.rmxos.asld.record", "status", 1, deadline) orelse return null;
        const m = c.asl_next(fresh);
        if (m != null and numeric(m, "ASLMessageID") > old_id) {
            need(c.asl_get(m, "sender_dropped") != null, "fresh sender count present");
            const count = numeric(m, "sender_dropped");
            c.asl_release(fresh);
            return count;
        }
        c.asl_release(fresh);
        _ = c.usleep(1000);
    }
    return null;
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
    var dropped: u64 = 0;
    phase("store_query", began);
    var identity_ok = true;
    var native_fields_ok = true;
    var stored: usize = 0;
    for (0..50) |pass| {
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
            need(equal(m, "UID", "0") and equal(m, "GID", "0"), "queue-fill record keeps kernel audit identity");
            seen[id] = true;
            if (stored == 0 or !equal(m, "UID", "0") or !equal(m, "GID", "0")) identity("flood", m);
            identity_ok = identity_ok and equal(m, "UID", "0") and equal(m, "GID", "0");

            native_fields_ok = native_fields_ok and c.asl_get(m, "RFC5424.Timestamp") == null and c.asl_get(m, "RFC5424.StructuredData") == null;
            stored += 1;
        }
        c.asl_release(result);
        dropped = status() - before;
        _ = c.printf("op063_flood_reconcile pass=%zu stored=%zu reported=%ju\n", pass + 1, stored, dropped);
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
        const before_flush = transport.totals();
        transport.record(c.LOG_NOTICE, "flush after restart");
        const after_flush = transport.totals();
        const delivered = [3]u64{ @intCast(after_flush[0] - before_flush[0]), @intCast(after_flush[1] - before_flush[1]), @intCast(after_flush[2] - before_flush[2]) };
        _ = c.write(readiness[1], &delivered, @sizeOf(@TypeOf(delivered)));
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
    var delivered: [3]u64 = undefined;
    need(c.read(readiness[0], &delivered, @sizeOf(@TypeOf(delivered))) == @sizeOf(@TypeOf(delivered)), "post-restore transport counts");
    _ = c.printf("op063_fallback_transport expected_mach=2 observed_mach=%ju socket=%ju refused=%ju\n", delivered[0], delivered[1], delivered[2]);
    var pid_buf: [32]u8 = undefined;
    const child_pid = std.fmt.bufPrintZ(&pid_buf, "{d}", .{child}) catch unreachable;
    var dropped: u64 = 0;
    var stored: usize = 0;
    var report_count: usize = 0;
    var report: c.asl_object_t = null;
    defer c.asl_release(report);
    var fresh_samples: usize = 0;
    var pass: usize = 0;
    const began = now(c.CLOCK_MONOTONIC);
    const deadline = began + 10 * std.time.ns_per_s;
    while (now(c.CLOCK_MONOTONIC) < deadline) : (pass += 1) {
        const found = queryBefore("Sender", tag, 110, deadline) orelse break;
        var seen: [100]bool = @splat(false);
        stored = 0;
        while (c.asl_next(found)) |m| {
            const value = c.asl_get(m, "Message");
            if (value == null) continue;
            const text = std.mem.span(value);
            if (!std.mem.startsWith(u8, text, "fallback-numbered-")) continue;
            const id = std.fmt.parseInt(usize, text["fallback-numbered-".len..], 10) catch c.atf_tc_fail("number");
            need(id < 100 and !seen[id], "unique fallback record");
            need(equal(m, "UID", "0") and equal(m, "GID", "0"), "queue-fill record keeps kernel audit identity");
            seen[id] = true;
            identity("fallback", m);
            stored += 1;
        }
        c.asl_release(found);
        dropped = statusBefore(deadline) orelse {
            _ = c.printf("op063_fallback_reconcile pass=%zu stored=%zu reported=%ju fresh=0 report_records=%zu elapsed_ns=%lld\n", pass + 1, stored, dropped, report_count, @as(c_longlong, now(c.CLOCK_MONOTONIC) - began));
            break;
        };
        fresh_samples += 1;
        const records = queryBefore("PID", child_pid, 128, deadline) orelse break;
        report_count = 0;
        c.asl_release(report);
        report = null;
        while (c.asl_next(records)) |m| {
            if (c.asl_get(m, "com.rmxos.syslog.sender_dropped") == null) continue;
            report_count += 1;
            c.asl_release(report);
            report = c.asl_retain(m);
        }
        c.asl_release(records);
        _ = c.printf("op063_fallback_reconcile pass=%zu stored=%zu reported=%ju report_records=%zu elapsed_ns=%lld\n", pass + 1, stored, dropped, report_count, @as(c_longlong, now(c.CLOCK_MONOTONIC) - began));
        _ = c.fflush(null);
        if (stored + dropped == 100 and report_count != 0) break;
        if (stored + dropped > 100) break;
        _ = c.usleep(1000);
    }
    _ = c.printf("op982_fallback sent=100 stored=%zu sender_dropped=%ju accounted=%ju\n", stored, dropped, stored + dropped);
    if (now(c.CLOCK_MONOTONIC) >= deadline and fresh_samples != 0 and report_count == 0) {
        _ = c.printf("op063_product_finding stored=%zu reported=%ju report_records=%zu fresh_samples=%zu elapsed_ns=%lld\n", stored, dropped, report_count, fresh_samples, @as(c_longlong, now(c.CLOCK_MONOTONIC) - began));
        _ = c.fflush(null);
    }
    need(stored + dropped == 100, "fresh stored plus reported equals 100 within ten seconds");
    need(report_count == 1 and report != null, "exactly one native sender drop report");
    need(equal(report, "Sender", "syslog") and equal(report, "PID", child_pid), "report belongs to child syslog sender");
    var uid_buf: [32]u8 = undefined;
    var gid_buf: [32]u8 = undefined;
    const uid = std.fmt.bufPrintZ(&uid_buf, "{d}", .{c.getuid()}) catch unreachable;
    const gid = std.fmt.bufPrintZ(&gid_buf, "{d}", .{c.getgid()}) catch unreachable;
    need(equal(report, "UID", uid) and equal(report, "GID", gid), "report retains child's kernel UID and GID");
    need(equal(report, "com.rmxos.syslog.sender_dropped", "100") and equal(report, "Message", "syslog: could not deliver 100 messages"), "report carries the exact undelivered count");
    need(c.asl_get(report, "RFC5424.Timestamp") == null and c.asl_get(report, "RFC5424.StructuredData") == null, "native Mach report has no socket parse fields");
    need(delivered[0] == 2 and delivered[1] == 0 and delivered[2] == 0, "report and flush sent only over Mach");
    identity("fallback-report", report);
    need(status() == dropped, "fresh status shows no duplicate loss report");
    _ = c.close(readiness[0]);
    _ = c.close(release_pipe[1]);
}
fn fillQueue(port: c_uint, tag: [:0]const u8, first: usize) usize {
    var count: usize = 0;
    while (count < 8192) : (count += 1) {
        var text: [256]u8 = undefined;
        const record = std.fmt.bufPrintZ(&text, "[Sender {s}] [Level 5] [Facility user] [Message prefill-{d}]", .{ tag, first + count }) catch unreachable;
        var request: [56]u8 align(8) = @splat(0);
        const h: *c.mach_msg_header_t = @ptrCast(&request);
        h.msgh_bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND;
        h.msgh_size = request.len;
        h.msgh_remote_port = port;
        h.msgh_id = 118;
        std.mem.writeInt(u32, request[24..28], 1, .little);
        std.mem.writeInt(u64, request[28..36], @intFromPtr(record.ptr), .little);
        request[37] = c.MACH_MSG_VIRTUAL_COPY;
        request[39] = c.MACH_MSG_OOL_DESCRIPTOR;
        std.mem.writeInt(u32, request[40..44], @intCast(record.len + 1), .little);
        request[48] = 1; // NDR little-endian integer representation.
        std.mem.writeInt(u32, request[52..56], @intCast(record.len + 1), .little);
        // Only the test fixture uses a zero-timeout send to observe a full queue.
        const rc = c.mach_msg_trap(h, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, request.len, 0, 0, 0, 0);
        if (rc == c.MACH_SEND_TIMED_OUT) return count;
        need(rc == 0, "fixture queue-fill send");
    }
    c.atf_tc_fail("fixture did not observe a full queue while filling");
}
fn prefillStored(tag: [:0]const u8, expected: usize) void {
    var actual: usize = 0;
    for (0..100) |_| {
        const found = query("Sender", tag, expected + 2);
        var seen: [16384]bool = @splat(false);
        actual = 0;
        while (c.asl_next(found)) |m| {
            const raw = c.asl_get(m, "Message") orelse continue;
            const text = std.mem.span(raw);
            if (!std.mem.startsWith(u8, text, "prefill-")) continue;
            const id = std.fmt.parseInt(usize, text[8..], 10) catch c.atf_tc_fail("prefill number");
            need(id < expected and id < seen.len and !seen[id], "unique queue-fill record");
            need(equal(m, "UID", "0") and equal(m, "GID", "0"), "queue-fill record keeps kernel audit identity");
            seen[id] = true;
            actual += 1;
        }
        c.asl_release(found);
        if (actual == expected) break;
        _ = c.usleep(10000);
    }
    _ = c.printf("op045_prefill expected=%zu observed=%zu\n", expected, actual);
    need(actual == expected, "every successful queue-fill record stored after resume");
}
fn processState(pid: c_int) c_int {
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID, pid };
    var info: [c.ASLD_KINFO_SIZE]u8 = undefined;
    var size: usize = info.len;
    if (c.sysctl(&mib, mib.len, &info, &size, null, 0) != 0 or size != info.len or @as(*align(1) const c.pid_t, @ptrCast(&info[c.ASLD_KINFO_PID])).* != pid) return -1;
    return info[c.ASLD_KINFO_STAT];
}
fn bounded(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(recovery.health("waiting-before"), "initial asld serves");
    const before = status();
    const old = recovery.pid();
    var tag_buf: [64]u8 = undefined;
    const tag = std.fmt.bufPrintZ(&tag_buf, "op045-prefill-{d}", .{c.getpid()}) catch unreachable;
    transport.openlog(tag, c.LOG_PID, c.LOG_USER);
    transport.record(c.LOG_NOTICE, "prime queue-fill port");
    const port = transport.loggerPort();
    need(port != 0, "observed Mach logger port");
    var ready: [2]c_int = undefined;
    var release: [2]c_int = undefined;
    need(c.pipe(&ready) == 0 and c.pipe(&release) == 0, "waiting pipes");
    const child = c.fork();
    need(child >= 0, "waiting child");
    if (child == 0) {
        _ = c.alarm(20);
        _ = c.close(ready[0]);
        _ = c.close(release[1]);
        var name: [64]u8 = undefined;
        const child_tag = std.fmt.bufPrintZ(&name, "op045-waiting-{d}", .{c.getpid()}) catch unreachable;
        transport.openlog(child_tag, c.LOG_PID | c.LOG_NDELAY, c.LOG_USER);
        transport.setQuiet(true);
        var byte: u8 = 1;
        _ = c.write(ready[1], &byte, 1);
        if (c.read(release[0], &byte, 1) != 1) c._exit(75);
        const began = now(c.CLOCK_MONOTONIC);
        _ = c.write(ready[1], &byte, 1); // The one call is about to start.
        transport.record(c.LOG_NOTICE, "one waiting application");
        const elapsed: u64 = @intCast(now(c.CLOCK_MONOTONIC) - began);
        _ = c.write(ready[1], &elapsed, @sizeOf(u64));
        if (c.read(release[0], &byte, 1) != 1) c._exit(75);
        const refused_before = transport.totals()[2];
        const unloaded_began = now(c.CLOCK_MONOTONIC);
        for (0..20) |_| transport.record(c.LOG_NOTICE, "op045 unloaded application");
        const refused_total: u64 = @intCast(transport.totals()[2] - refused_before);
        _ = c.printf("syslog_unloaded sends=20 elapsed_ns=%lld\n", @as(c_longlong, now(c.CLOCK_MONOTONIC) - unloaded_began));
        _ = c.fflush(null);
        _ = c.write(ready[1], &refused_total, @sizeOf(u64));
        if (c.read(release[0], &byte, 1) != 1) c._exit(75);
        _ = c.sleep(1);
        c.syslog(c.LOG_NOTICE, "op045 waiting flush");
        c.closelog();
        c._exit(0);
    }
    _ = c.close(ready[1]);
    _ = c.close(release[0]);
    defer _ = c.close(ready[0]);
    defer _ = c.close(release[1]);
    var byte: u8 = 0;
    need(c.read(ready[0], &byte, 1) == 1, "child cached the service while asld was running");
    need(c.kill(old, c.SIGSTOP) == 0, "stop asld before filling its queue");
    const stop_began = now(c.CLOCK_MONOTONIC);
    var before_fill = processState(old);
    while (before_fill != c.SSTOP and now(c.CLOCK_MONOTONIC) - stop_began < 2 * std.time.ns_per_s) {
        _ = c.usleep(1000);
        before_fill = processState(old);
    }
    if (before_fill != c.SSTOP) {
        _ = c.kill(old, c.SIGCONT);
        c.atf_tc_fail("asld did not report SSTOP within 2 s: pid=%d expected_ki_stat=%d observed_ki_stat=%d", old, c.SSTOP, before_fill);
    }
    const filled = fillQueue(port, tag, 0);
    const before_release = processState(old);
    _ = c.printf("op058_prepared pid=%d expected_ki_stat=%d before_fill=%d before_release=%d fill_count=%zu\n", old, c.SSTOP, before_fill, before_release, filled);
    _ = c.fflush(null);
    if (before_release != c.SSTOP) {
        _ = c.kill(old, c.SIGCONT);
        c.atf_tc_fail("asld left SSTOP before release: expected_ki_stat=%d observed_ki_stat=%d fill_count=%zu", c.SSTOP, before_release, filled);
    }
    _ = c.write(release[1], &byte, 1);
    var poll = c.struct_pollfd{ .fd = ready[0], .events = c.POLLIN, .revents = 0 };
    need(c.poll(&poll, 1, 2500) == 1 and c.read(ready[0], &byte, 1) == 1, "waiting child starts its one call");
    const stopped_result = c.poll(&poll, 1, 250);
    _ = c.kill(old, c.SIGCONT);
    need(c.poll(&poll, 1, 2500) == 1, "waiting syslog completes after resume");
    var wait_ns: u64 = 0;
    need(c.read(ready[0], &wait_ns, @sizeOf(u64)) == @sizeOf(u64), "waiting child elapsed time");
    _ = c.printf("op058_bounded pid=%d expected_ki_stat=%d before_fill=%d before_release=%d fill_count=%zu wait_ns=%ju stopped_poll=%d\n", old, c.SSTOP, before_fill, before_release, filled, wait_ns, stopped_result);
    if (stopped_result == 1 and wait_ns < 250 * std.time.ns_per_ms) {
        _ = c.printf("op058_product_finding before_fill=%d before_release=%d fill_count=%zu wait_ns=%ju\n", before_fill, before_release, filled, wait_ns);
        _ = c.fflush(null);
    }
    need(stopped_result == 0, "full-queue syslog must not return while asld is stopped");
    prefillStored(tag, filled);
    var child_name: [64]u8 = undefined;
    const child_tag = std.fmt.bufPrintZ(&child_name, "op045-waiting-{d}", .{child}) catch unreachable;
    const application = awaitSender(child_tag);
    identity("waiting", application);
    need(equal(application, "Message", "one waiting application"), "blocked application stored after resume");
    need(equal(application, "UID", "0") and equal(application, "GID", "0"), "waiting application keeps kernel audit identity");
    c.asl_release(application);
    const all_applications = query("Sender", child_tag, 2);
    var application_count: usize = 0;
    while (c.asl_next(all_applications) != null) application_count += 1;
    c.asl_release(all_applications);
    need(application_count == 1, "single blocked call stored exactly once");
    need(status() == before, "a full Mach queue is not counted as a loss");
    command("/bin/launchctl", "unload", recovery.plist);
    for (0..100) |_| {
        if (c.kill(old, 0) != 0) break;
        _ = c.usleep(20000);
    }
    need(c.kill(old, 0) != 0, "unloaded receiver exits");
    _ = c.write(release[1], &byte, 1);
    var expected: u64 = 0;
    need(c.poll(&poll, 1, 2500) == 1 and c.read(ready[0], &expected, @sizeOf(u64)) == @sizeOf(u64), "unloaded syslog returns before reload");
    need(expected == 20, "each undelivered unloaded record is counted");
    need(recovery.restore(), "reload serves after unloaded sends");
    _ = c.write(release[1], &byte, 1);
    var result: c_int = 0;
    need(c.waitpid(child, &result, 0) == child and result == 0, "waiting child result");
    var dropped = status();
    for (0..50) |_| {
        if (dropped >= expected) break;
        _ = c.usleep(20000);
        dropped = status();
    }
    _ = c.printf("syslog_mach_loss expected=%ju observed=%ju\n", expected, dropped);
    need(dropped == expected, "every undelivered application counted on next successful report");
    need(status() == dropped, "loss report not duplicated");
}

const private_pidfile = "/tmp/op045-private-child";
fn cleanupPrivate() void {
    const f = c.fopen(private_pidfile, "r") orelse return;
    var pid: c_int = 0;
    var root: [256:0]u8 = @splat(0);
    _ = c.fscanf(f, "%d %255s", &pid, &root);
    _ = c.fclose(f);
    if (pid > 1) {
        _ = c.kill(pid, c.SIGCONT);
        _ = c.kill(pid, c.SIGTERM);
        var status_value: c_int = 0;
        _ = c.waitpid(pid, &status_value, 0);
        for (0..100) |_| {
            if (c.kill(pid, 0) != 0) break;
            _ = c.usleep(10000);
        }
    }
    if (std.mem.startsWith(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&root))), "/tmp/op045-shed.")) std.fs.cwd().deleteTree(std.mem.span(@as([*:0]const u8, @ptrCast(&root)))) catch {};
    _ = c.unlink(private_pidfile);
}
fn numeric(m: c.asl_object_t, key: [*:0]const u8) u64 {
    const value = c.asl_get(m, key) orelse return 0;
    return std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0;
}
fn shedding(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var root = "/tmp/op045-shed.XXXXXX".* ++ [_]u8{0};
    need(c.mkdtemp(@ptrCast(&root)) != null, "private shedding directory");
    var path: [512]u8 = undefined;
    const kernel = std.fmt.bufPrintZ(&path, "{s}/kernel", .{std.mem.sliceTo(&root, 0)}) catch unreachable;
    need(c.mkfifo(kernel, 0o600) == 0, "private kernel fixture");
    for ([_][]const u8{ "asl.conf", "syslog.conf" }) |name| {
        const p = std.fmt.bufPrintZ(&path, "{s}/{s}", .{ std.mem.sliceTo(&root, 0), name }) catch unreachable;
        const file = c.fopen(p, "w") orelse c.atf_tc_fail("private config");
        need(c.fclose(file) == 0, "private config close");
    }
    const child = c.fork();
    need(child >= 0, "private asld fork");
    if (child == 0) {
        const log = std.fmt.bufPrintZ(&path, "{s}/daemon.log", .{std.mem.sliceTo(&root, 0)}) catch unreachable;
        const fd = c.open(log, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
        if (fd < 0) c._exit(127);
        _ = c.dup2(fd, 1);
        _ = c.dup2(fd, 2);
        _ = c.close(fd);
        _ = c.execl("/usr/sbin/asld", "asld", "-private", &root, "-wq_max_bytes", "1", "-mps_limit", "500", "-dup_delay", "0", "-d", log.ptr, @as(?*anyopaque, null));
        c._exit(127);
    }
    const file = c.fopen(private_pidfile, "w") orelse c.atf_tc_fail("private cleanup record");
    _ = c.fprintf(file, "%d %s\n", child, &root);
    _ = c.fclose(file);
    defer cleanupPrivate();
    var ready = false;
    for (0..400) |_| {
        const p = std.fmt.bufPrintZ(&path, "{s}/daemon.log", .{std.mem.sliceTo(&root, 0)}) catch unreachable;
        if (c.fopen(p, "r")) |log| {
            var line: [4096]u8 = undefined;
            while (c.fgets(&line, line.len, log) != null) {
                if (std.mem.indexOf(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&line))), "asld_ready pid=") != null) ready = true;
            }
            _ = c.fclose(log);
        }
        if (ready) break;
        var wait_status: c_int = 0;
        need(c.waitpid(child, &wait_status, c.WNOHANG) == 0, "private asld alive");
        _ = c.usleep(10000);
    }
    need(ready, "private shedding asld ready");
    const fd = c.socket(c.AF_UNIX, c.SOCK_DGRAM, 0);
    need(fd >= 0, "private fixture socket");
    defer _ = c.close(fd);
    var address = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    address.sun_len = @sizeOf(c.struct_sockaddr_un);
    _ = c.snprintf(&address.sun_path, address.sun_path.len, "%s/syslog", &root);
    for (0..100) |_| {
        const payload = "<14>payload op045 shedding";
        need(c.sendto(fd, payload.ptr, payload.len, 0, @ptrCast(&address), address.sun_len) == payload.len, "private shedding datagram");
    }
    // Let the one input burst complete before a requested flush can end it.
    _ = c.usleep(250000);
    var notices: usize = 0;
    var drops: u64 = 0;
    var drained: u64 = 0;
    var data: usize = 0;
    for (0..100) |_| {
        need(c.kill(child, c.SIGUSR1) == 0, "private status request");
        _ = c.usleep(20000);
        const store_path = std.fmt.bufPrintZ(&path, "{s}/store", .{std.mem.sliceTo(&root, 0)}) catch unreachable;
        const store = c.asl_open_path(store_path, 0) orelse continue;
        var last: usize = 0;
        const result = c.asl_match(store, null, &last, std.math.maxInt(usize), 1024, 100000, -1);
        notices = 0;
        drops = 0;
        drained = 0;
        data = 0;
        while (c.asl_next(result)) |m| {
            if (equal(m, "Message", "Internal work queue size limit exceeded - dropping messages")) {
                need(equal(m, "Sender", "syslogd") and equal(m, "Level", "2"), "Apple shedding notice identity and severity");
                notices += 1;
            }
            if (equal(m, "com.rmxos.asld.record", "status")) drops = @max(drops, numeric(m, "dropped_wq"));
            if (equal(m, "com.rmxos.asld.record", "work queue drained")) drained += numeric(m, "dropped_wq");
            if (equal(m, "Message", "payload op045 shedding")) data += 1;
        }
        c.asl_release(result);
        c.asl_release(store);
        if (drops == 100 and drained == 100) break;
    }
    _ = c.printf("op045_shedding expected_notice=1 observed_notice=%zu expected_drops=100 observed_drops=%ju drain_count=%ju stored_input=%zu\n", notices, drops, drained, data);
    need(notices == 1 and drops == 100 and drained == 100 and data == 0, "one Level 2 notice and exact drain drop count");
}
fn loggerCase(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrintZ(&buffer, "op045.logger.{d}.{d}", .{ c.getpid(), now(c.CLOCK_MONOTONIC) }) catch unreachable;
    need(recovery.run(&.{ "/usr/bin/logger", "-p", "user.notice", message }), "logger command");
    var found: usize = 0;
    for (0..100) |_| {
        const result = query("Message", message, 2);
        found = 0;
        while (c.asl_next(result)) |_| found += 1;
        c.asl_release(result);
        if (found != 0) break;
        _ = c.usleep(20000);
    }
    need(found == 1, "logger stores exactly one token line");
}

fn clockStep(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var real: c.struct_timespec = undefined;
    var monotonic: c.struct_timespec = undefined;
    var after: c.struct_timespec = undefined;
    need(c.clock_gettime(c.CLOCK_REALTIME, &real) == 0 and c.clock_gettime(c.CLOCK_MONOTONIC, &monotonic) == 0, "save clocks");
    var stepped = real;
    stepped.tv_sec -= 1;
    need(c.clock_settime(c.CLOCK_REALTIME, &stepped) == 0, "step guest wall clock back one second");
    const sampled = c.clock_gettime(c.CLOCK_MONOTONIC, &after) == 0;
    const delta = if (sampled) timing.nanoseconds(after.tv_sec - monotonic.tv_sec, after.tv_nsec - monotonic.tv_nsec) else 0;
    const restore_ns = timing.nanoseconds(real.tv_sec, real.tv_nsec) + delta;
    const restored = c.struct_timespec{ .tv_sec = @divFloor(restore_ns, std.time.ns_per_s), .tv_nsec = @mod(restore_ns, std.time.ns_per_s) };
    need(c.clock_settime(c.CLOCK_REALTIME, &restored) == 0 and sampled, "restore guest wall clock");
    const began = now(c.CLOCK_MONOTONIC);
    const child = c.fork();
    need(child >= 0, "clock-step manager child");
    if (child == 0) {
        _ = c.execl("/usr/sbin/aslmanager", "aslmanager", "-once", "-wait-for-filesystems", "-s", "/var/log/asl", @as(?*anyopaque, null));
        c._exit(127);
    }
    var status_value: c_int = 0;
    while (now(c.CLOCK_MONOTONIC) - began < 2 * std.time.ns_per_s) {
        const result = c.waitpid(child, &status_value, c.WNOHANG);
        if (result == child) {
            const elapsed = now(c.CLOCK_MONOTONIC) - began;
            _ = c.printf("op045_clock_step expected_status=0 observed_status=%d elapsed_ns=%lld bound_ns=2000000000\n", status_value, @as(c_longlong, elapsed));
            need(status_value == 0 and elapsed < 2 * std.time.ns_per_s, "manager returns zero within two seconds after a restored wall-clock step");
            return;
        }
        need(result == 0, "clock-step manager wait");
        _ = c.usleep(1000);
    }
    _ = c.kill(child, c.SIGKILL);
    _ = c.waitpid(child, &status_value, 0);
    c.atf_tc_fail("manager did not return within two seconds after clock restore");
}

fn bounds(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(recovery.run(&.{"/usr/tests/sys/launchd/unload_completion_unit"}), "unload completion RPC");
    need(recovery.run(&.{"/usr/tests/usr.sbin/asl/cleanup_status_unit"}), "cleanup exit status");
    need(recovery.run(&.{"/usr/tests/usr.sbin/asl/mach_bound_unit"}), "Mach waiting and retry controls");
    need(recovery.run(&.{"/usr/tests/usr.sbin/asl/filesystems_unit"}), "filesystem boot identity controls");
}
fn timingCase(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(timing.nanoseconds(9, 50000000) - timing.nanoseconds(8, 950000000) == 100000000, "nanoseconds across second boundary");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    cleanupPrivate();
    recovery.cleanupResult(recovery.restore(), "sender");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "120");
    _ = c.alarm(110);
}
var cases: [10]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "timing", "report", "transport", "flood", "fallback", "bounded", "bounds", "shedding", "logger", "clock_step" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ timingCase, reportCase, nativeCase, flood, fallback, bounded, bounds, shedding, loggerCase, clockStep };
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
