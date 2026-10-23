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
fn flood(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const before = status();
    var tag_buf: [64]u8 = undefined;
    const tag = std.fmt.bufPrintZ(&tag_buf, "op946-{d}", .{c.getpid()}) catch unreachable;
    var pipe: [2]c_int = undefined;
    need(c.pipe(&pipe) == 0, "logger pipe");
    const child = c.fork();
    need(child >= 0, "logger fork");
    if (child == 0) {
        _ = c.close(pipe[1]);
        _ = c.dup2(pipe[0], 0);
        _ = c.close(pipe[0]);
        _ = c.execl("/usr/bin/logger", "logger", "-t", tag.ptr, @as(?*anyopaque, null));
        c._exit(127);
    }
    _ = c.close(pipe[0]);
    const input = c.fdopen(pipe[1], "w") orelse @panic("logger stdin");
    for (0..30) |second| {
        for (0..1000) |i| need(c.fprintf(input, "op946-numbered-%zu\n", second * 1000 + i) > 0, "numbered input");
        need(c.fflush(input) == 0, "flush burst");
        _ = c.sleep(1);
    }
    // Keep this sender alive for a final successful send after the last burst.
    _ = c.sleep(1);
    need(c.fputs("op946-numbered-30000\n", input) >= 0, "flush message");
    need(c.fclose(input) == 0, "close input");
    var waited: c_int = 0;
    need(c.waitpid(child, &waited, 0) == child and waited == 0, "logger exit");
    var stored: u64 = 0;
    var dropped: u64 = 0;
    for (0..50) |_| {
        _ = c.usleep(100000);
        const result = query("Sender", tag, 30002);
        stored = 0;
        while (c.asl_next(result) != null) stored += 1;
        c.asl_release(result);
        dropped = status() - before;
        if (stored + dropped >= 30001) break;
    }
    _ = c.printf("op946_flood sent=30001 stored=%ju sender_dropped=%ju expected_accounted=30001 observed_accounted=%ju\n", stored, dropped, stored + dropped);
    need(stored + dropped == 30001, "stored plus sender_dropped equals sent exactly");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "85");
    _ = c.alarm(80);
}
var cases: [3]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "socket", "report", "flood" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ socketCase, reportCase, flood };
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
