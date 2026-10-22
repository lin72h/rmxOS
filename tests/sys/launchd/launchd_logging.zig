// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const f = @import("job_fixture.zig");
const retained_records = @import("stopped_records.zig");
extern fn _vproc_log(c_int, [*:0]const u8, ...) void;
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("sys/time.h");
    @cInclude("sys/wait.h");
    @cInclude("launch.h");
    @cInclude("vproc.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
// Stable integer-key ABI from vproc_priv.h; compile-time values appended there.
extern fn vproc_swap_integer(?*anyopaque, c_uint, ?*i64, *i64) ?*anyopaque;
const queue_count: c_uint = 27;
const queue_bytes: c_uint = 28;
const queue_dropped: c_uint = 29;
const a = std.heap.page_allocator;
const names = [_][*:0]const u8{ "drain", "early_boot", "stopped", "pid1_boot", "churn", "report_identity", "mid_batch_exit" };
var cases: [names.len]c.atf_tc_t = undefined;
fn need(ok: bool, msg: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", msg);
}
fn text(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch unreachable;
}
fn stat(key: c_uint) u64 {
    var value: i64 = 0;
    need(vproc_swap_integer(null, key, null, &value) == null, "launchd queue statistic RPC");
    need(value >= 0, "nonnegative queue statistic");
    return @intCast(value);
}
fn store(key: []const u8, value: []const u8) []const u8 {
    return f.capture(&.{ "/usr/bin/aslutil", "-d", "/var/log/asl", "-F", "raw", "-k", key, value });
}
fn occurrences(bytes: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, bytes, needle);
}
fn awaitRecord(key: []const u8, value: []const u8, needle: []const u8) []const u8 {
    for (0..300) |_| {
        const bytes = store(key, value);
        if (occurrences(bytes, needle) > 0) return bytes;
        _ = c.usleep(100000);
    }
    c.atf_tc_fail("store record absent: %s", f.z(needle).ptr);
}
fn submit(label: []const u8) void {
    const job = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY) orelse unreachable;
    defer c.launch_data_free(job);
    need(c.launch_data_dict_insert(job, c.launch_data_new_string(f.z(label).ptr), "Label"), "job label");
    const args = c.launch_data_alloc(c.LAUNCH_DATA_ARRAY) orelse unreachable;
    for ([_][:0]const u8{ "/bin/sh", "-c", "exit 73" }, 0..) |arg, i| need(c.launch_data_array_set_index(args, c.launch_data_new_string(arg.ptr), i), "job argument");
    need(c.launch_data_dict_insert(job, args, "ProgramArguments"), "job arguments");
    need(c.launch_data_dict_insert(job, c.launch_data_new_bool(true), "RunAtLoad"), "job runatload");
    const request = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY) orelse unreachable;
    defer c.launch_data_free(request);
    need(c.launch_data_dict_insert(request, c.launch_data_copy(job), "SubmitJob"), "submit dictionary");
    const reply = c.launch_msg(request) orelse c.atf_tc_fail("submit reply");
    defer c.launch_data_free(reply);
    need(c.launch_data_get_type(reply) == c.LAUNCH_DATA_ERRNO and c.launch_data_get_errno(reply) == 0, "submit status");
    // Wait for the exit to be reaped before removal: each iteration produces
    // the real launchd job exit record, not a probe-generated log message.
    for (0..300) |_| {
        const get = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY) orelse unreachable;
        _ = c.launch_data_dict_insert(get, c.launch_data_new_string(f.z(label).ptr), "GetJob");
        const result = c.launch_msg(get) orelse c.atf_tc_fail("get job");
        c.launch_data_free(get);
        const pid = c.launch_data_dict_lookup(result, "PID");
        const status = c.launch_data_dict_lookup(result, "LastExitStatus");
        const exited = pid == null and status != null and c.launch_data_get_integer(status) == 73 * 256;
        c.launch_data_free(result);
        if (exited) return;
        _ = c.usleep(1000);
    }
    c.atf_tc_fail("job exit wait");
}
fn remove(label: []const u8) void {
    const request = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY) orelse unreachable;
    defer c.launch_data_free(request);
    _ = c.launch_data_dict_insert(request, c.launch_data_new_string(f.z(label).ptr), "RemoveJob");
    if (c.launch_msg(request)) |reply| c.launch_data_free(reply) else c.atf_tc_fail("remove reply");
}
fn waitEmpty() void {
    for (0..300) |_| {
        if (stat(queue_count) == 0 and stat(queue_dropped) == 0) return;
        _ = c.usleep(100000);
    }
    c.atf_tc_fail("launchd queue did not drain");
}
fn early() void {
    const first = "*** launchd[1] has started up. ***";
    const second = "*** Shutdown logging is enabled. ***";
    const bytes = awaitRecord("Sender", "com.apple.launchd", second);
    const x = std.mem.indexOf(u8, bytes, first) orelse c.atf_tc_fail("early startup record absent");
    const y = std.mem.indexOf(u8, bytes, second) orelse unreachable;
    need(x < y, "early launchd messages preserve order");
    need(occurrences(bytes, first) == 1 and occurrences(bytes, second) == 1, "early records stored once");
    need(std.mem.indexOf(u8, bytes, "[PID 1]") != null, "launchd sender pid");
}
fn drain() void {
    waitEmpty();
    const label = text("com.rmxos.op789.exit.{d}", .{c.getpid()});
    defer remove(label);
    submit(label);
    const bytes = awaitRecord("RefProc", label, "[Message Exited with code: 73]");
    need(occurrences(bytes, "[Message Exited with code: 73]") == 1, "live launchd message once");
    need(std.mem.indexOf(u8, bytes, "[Sender com.apple.launchd]") != null and std.mem.indexOf(u8, bytes, "[PID 1]") != null, "launchd sender fields survive drain");
    waitEmpty();
}
fn lastCounter(bytes: []const u8, key: []const u8) u64 {
    const prefix = text("[{s} ", .{key});
    const start = (std.mem.lastIndexOf(u8, bytes, prefix) orelse return 0) + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, ']') orelse c.atf_tc_fail("counter format");
    return std.fmt.parseInt(u64, bytes[start..end], 10) catch c.atf_tc_fail("counter number");
}
fn rss() u64 {
    const bytes = f.capture(&.{ "/bin/ps", "-p", "1", "-o", "rss=" });
    return std.fmt.parseInt(u64, std.mem.trim(u8, bytes, " \r\n"), 10) catch c.atf_tc_fail("PID1 RSS");
}
fn statusCounter(pid: i32) u64 {
    const before = occurrences(store("com.rmxos.asld.record", "status"), "[com.rmxos.asld.record status]");
    need(c.kill(pid, c.SIGUSR1) == 0, "request asld status");
    for (0..300) |_| {
        const bytes = store("com.rmxos.asld.record", "status");
        if (occurrences(bytes, "[com.rmxos.asld.record status]") == before + 1) return lastCounter(bytes, "launchd_dropped");
        _ = c.usleep(100000);
    }
    c.atf_tc_fail("fresh asld status absent");
}
fn reportIdentity() void {
    waitEmpty();
    const raw = f.capture(&.{ "/bin/cat", "/var/run/syslog.pid" });
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \r\n"), 10) catch c.atf_tc_fail("asld pid");
    const before = statusCounter(pid);
    const reports = occurrences(store("com.rmxos.launchd.record", "drops"), "[com.rmxos.launchd.record drops]");
    const message = "launchd log queue dropped 7 records";
    _vproc_log(3, "%s", @as([*:0]const u8, message));
    _ = awaitRecord("RefPID", text("{d}", .{c.getpid()}), message);
    waitEmpty();
    const after = statusCounter(pid);
    _ = c.printf("launchd_report_identity before=%ju after=%ju\n", before, after);
    need(after == before, "job report text must not count drops");
    need(occurrences(store("com.rmxos.launchd.record", "drops"), "[com.rmxos.launchd.record drops]") == reports, "job report text must not create loss report");
}
extern fn _vprocmgr_log_drain(?*anyopaque, ?*anyopaque, *const fn (*c.struct_timeval, c.pid_t, c.pid_t, c.uid_t, c.gid_t, c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) void) ?*anyopaque;
var exit_prefix: []const u8 = "";
var exit_callbacks: u8 = 0;
var exit_pipe: c_int = -1;
fn exitCallback(_: *c.struct_timeval, _: c.pid_t, _: c.pid_t, _: c.uid_t, _: c.gid_t, _: c_int, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, message: [*:0]const u8) callconv(.c) void {
    if (!std.mem.startsWith(u8, std.mem.span(message), exit_prefix)) return;
    exit_callbacks += 1;
    // Deliberately observe callbacks without storing their records. Counting
    // the whole held batch is conservative even if a real drainer stored a prefix.
    if (exit_callbacks == 3) {
        if (c.write(exit_pipe, &exit_callbacks, 1) != 1) c._exit(92);
        c._exit(0);
    }
}
fn midBatchExit() void {
    waitEmpty();
    // Give the sequential asld loop time to acknowledge its last sent batch.
    _ = c.sleep(2);
    const raw = f.capture(&.{ "/bin/cat", "/var/run/syslog.pid" });
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \r\n"), 10) catch c.atf_tc_fail("asld pid");
    need(f.run(&.{ "/bin/launchctl", "unload", "/etc/launchd.d/com.apple.syslogd.plist" }) == 0, "stop asld for helper");
    for (0..100) |_| {
        if (c.kill(pid, 0) != 0) break;
        _ = c.usleep(100000);
    }
    need(c.kill(pid, 0) != 0, "asld exited before helper workload");
    // Stop/reap records and any conservative prior batch are not ours.
    const prior = stat(queue_count) + stat(queue_dropped);
    const produced: u64 = 16;
    exit_prefix = text("op871.midbatch.{d}.", .{c.getpid()});
    for (0..produced) |i| _vproc_log(3, "%s%zu", f.z(exit_prefix).ptr, i);
    need(stat(queue_count) + stat(queue_dropped) == prior + produced, "all helper workload enqueued");
    var pipes: [2]c_int = undefined;
    need(c.pipe(&pipes) == 0, "helper callback pipe");
    const helper = c.fork();
    need(helper >= 0, "fork root drainer");
    if (helper == 0) {
        _ = c.close(pipes[0]);
        exit_pipe = pipes[1];
        exit_callbacks = 0;
        _ = _vprocmgr_log_drain(null, null, exitCallback);
        c._exit(91);
    }
    _ = c.close(pipes[1]);
    defer _ = c.close(pipes[0]);
    var callbacks: u8 = 0;
    need(c.read(pipes[0], &callbacks, 1) == 1 and callbacks == 3, "helper exited in its third callback");
    var status: c_int = 0;
    need(c.waitpid(helper, &status, 0) == helper and status == 0, "mid-batch helper exit status");
    var lost: u64 = 0;
    for (0..100) |_| {
        lost = stat(queue_dropped);
        if (lost == prior + produced) break;
        _ = c.usleep(100000);
    }
    need(stat(queue_count) == 0 and lost == prior + produced, "process exit counted the entire held batch");
    need(f.run(&.{ "/bin/launchctl", "load", "/etc/launchd.d/com.apple.syslogd.plist" }) == 0, "restart asld after helper");
    _ = awaitRecord("com.rmxos.launchd.record", "drops", text("[launchd_dropped {d}]", .{lost}));
    waitEmpty();
    const stored = f.capture(&.{ "/usr/bin/aslutil", "-d", "/var/log/asl", "-F", "raw", "-k", "Message", "Aeq", exit_prefix });
    const stored_count = occurrences(stored, "[Message ");
    _ = c.printf("launchd_mid_batch_exit produced=%ju callbacks=%u stored=%zu counted=%ju prior=%ju helper_pid=%d\n", produced, @as(c_uint, callbacks), stored_count, lost - prior, prior, helper);
    need(stored_count + lost - prior == produced, "stored plus counted drops equals produced");
    need(stored_count == 0, "held batch was never resent");
}
fn stopped() void {
    waitEmpty();
    const rss_before = rss();
    const reports_before = occurrences(store("com.rmxos.launchd.record", "drops"), "[com.rmxos.launchd.record drops]");
    const pid_text = f.capture(&.{ "/bin/cat", "/var/run/syslog.pid" });
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, pid_text, " \n\r"), 10) catch c.atf_tc_fail("asld pidfile");
    need(f.run(&.{ "/bin/launchctl", "unload", "/etc/launchd.d/com.apple.syslogd.plist" }) == 0, "stop asld candidate job");
    for (0..100) |_| {
        if (c.kill(pid, 0) != 0) break;
        _ = c.usleep(100000);
    }
    need(c.kill(pid, 0) != 0, "old asld process exited before queue workload");
    const prior_records = stat(queue_count) + stat(queue_dropped);
    const limits = f.stoppedLimits();
    const count = limits.jobs;
    _ = c.printf("launchd_stopped_budget jobs=%u queue_records=%u job_ms=%u worker_s=%u parent_s=%u atf_s=%u runner_s=%u\n", count, limits.queue_records, limits.job_ms, limits.worker_seconds, limits.parent_seconds, limits.atf_seconds, limits.runner_seconds);
    _ = c.fflush(null);
    const prefix = text("com.rmxos.op789.full.{d}.", .{c.getpid()});
    var newest: []const u8 = "";
    for (0..count) |i| {
        const label = text("com.rmxos.op789.full.{d}.{d}", .{ c.getpid(), i });
        submit(label);
        remove(label);
        newest = label;
        if (i % 200 == 199) {
            _ = c.printf("launchd_stopped_progress jobs=%zu\n", i + 1);
            _ = c.fflush(null);
        }
    }
    const retained = stat(queue_count);
    const bytes = stat(queue_bytes);
    const lost = stat(queue_dropped);
    need(retained + lost == count + prior_records and lost >= prior_records, "workload records and prior stop records all accounted before restart");
    _ = c.printf("launchd_stopped produced_jobs=%u queued=%ju bytes=%ju dropped=%ju\n", count, retained, bytes, lost);
    need(count > limits.queue_records and retained <= limits.queue_records and bytes <= 256 * 1024 and lost > 0, "stopped queue bounded and all losses counted");
    const rss_peak = rss();
    need(rss_peak <= rss_before + 8192, "stopped logger RSS remains within queue/allocation bound");
    need(f.run(&.{ "/bin/launchctl", "load", "/etc/launchd.d/com.apple.syslogd.plist" }) == 0, "start asld candidate job");
    var restarted: i32 = 0;
    for (0..100) |_| {
        const raw = std.fs.cwd().readFileAlloc(a, "/var/run/syslog.pid", 64) catch "";
        restarted = std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \r\n"), 10) catch 0;
        if (restarted > 1 and restarted != pid and c.kill(restarted, 0) == 0) break;
        _ = c.usleep(100000);
    }
    need(restarted > 1 and restarted != pid and c.kill(restarted, 0) == 0, "asld resumed with a new process");
    _ = c.printf("launchd_drainer_restart old_pid=%d new_pid=%d\n", pid, restarted);
    const newest_record = awaitRecord("RefProc", newest, "[Message Exited with code: 73]");
    need(occurrences(newest_record, "[Message Exited with code: 73]") == 1, "newest record delivered once");
    const report = text("[launchd_dropped {d}]", .{lost});
    const drop_records = awaitRecord("com.rmxos.launchd.record", "drops", report);
    need(occurrences(drop_records, "[com.rmxos.launchd.record drops]") == reports_before + 1, "one new loss report per stopped interval");
    waitEmpty();
    const own_records = f.capture(&.{ "/usr/bin/aslutil", "-d", "/var/log/asl", "-F", "raw", "-k", "RefProc", "Aeq", prefix });
    const stored = retained_records.check(own_records, prefix, count, lost - prior_records) catch c.atf_tc_fail("every retained job exit stored exactly once; stored plus own drops equals jobs");
    need(stored == retained, "every retained record belongs to this workload");
    _ = c.printf("launchd_stopped_accounting jobs=%u stored=%ju own_drops=%ju prior_records=%ju\n", count, stored, lost - prior_records, prior_records);
    const status_count = occurrences(store("com.rmxos.asld.record", "status"), "[com.rmxos.asld.record status]");
    need(c.kill(restarted, c.SIGUSR1) == 0, "request asld status");
    var fresh = false;
    for (0..300) |_| {
        const status = store("com.rmxos.asld.record", "status");
        if (occurrences(status, "[com.rmxos.asld.record status]") > status_count and lastCounter(status, "launchd_dropped") == lost) {
            fresh = true;
            break;
        }
        _ = c.usleep(100000);
    }
    need(fresh, "fresh asld status reports exact launchd losses");
    const rss_after = rss();
    _ = c.printf("launchd_rss before_kib=%ju peak_kib=%ju after_kib=%ju reported_drops=%ju\n", rss_before, rss_peak, rss_after, lost);
    need(rss_after <= rss_before + 8192, "RSS stays bounded after draining");
}
fn boot() void {
    const comm = f.capture(&.{ "/bin/ps", "-p", "1", "-o", "comm=" });
    need(std.mem.indexOf(u8, comm, "launchd") != null, "launchd is PID1 by default");
    const path = text("/op789-root-rw-{d}", .{c.getpid()});
    const fd = c.open(f.z(path).ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o600));
    need(fd >= 0, "root is read-write");
    _ = c.close(fd);
    _ = c.unlink(f.z(path).ptr);
    need(f.run(&.{ "/usr/sbin/service", "cron", "onestatus" }) == 0, "base cron running");
    need(f.run(&.{ "/usr/sbin/service", "devd", "onestatus" }) == 0, "base devd running");
    need(f.run(&.{ "/usr/sbin/service", "syslogd", "status" }) == 0, "asld compatibility service ready");
    const jobs = f.capture(&.{ "/bin/launchctl", "list" });
    for ([_][]const u8{ "com.rmxos.console-getty", "com.apple.notifyd", "com.apple.syslogd", "com.rmxos.aslmanager.once" }) |name| need(std.mem.indexOf(u8, jobs, name) != null, "default service job loaded");
    var marker: c.struct_stat = undefined;
    var ready: c.struct_stat = undefined;
    need(c.stat("/var/run/asld.filesystems-ready", &marker) == 0 and c.stat("/var/run/asld.service-ready", &ready) == 0, "boot handshake timestamps");
    const ms = (ready.st_mtim.tv_sec - marker.st_mtim.tv_sec) * 1000 + @divTrunc(ready.st_mtim.tv_nsec - marker.st_mtim.tv_nsec, 1000000);
    _ = c.printf("pid1_boot marker_to_ready_ms=%lld pid1=launchd root_rw=1 base_services=1\n", @as(c_longlong, ms));
    need(ms >= 0 and ms < 1000, "marker to compatibility ready under one second");
}
fn milliseconds() i64 {
    var t: c.struct_timespec = undefined;
    need(c.clock_gettime(c.CLOCK_MONOTONIC, &t) == 0, "monotonic time");
    return t.tv_sec * 1000 + @divTrunc(t.tv_nsec, 1000000);
}
fn churn() void {
    _ = c.alarm(1100);
    const start = milliseconds();
    var next: i64 = 0;
    var cycles: u64 = 0;
    var baseline: u64 = 0;
    var newest: []const u8 = "";
    while (milliseconds() - start < 900000) {
        const elapsed = milliseconds() - start;
        if (elapsed >= next) {
            const resident = rss();
            if (next == 30000) baseline = resident;
            _ = c.printf("pid1_churn elapsed_ms=%lld rss_kib=%ju cycles=%ju queued=%ju drops=%ju\n", @as(c_longlong, elapsed), resident, cycles, stat(queue_count), stat(queue_dropped));
            _ = c.fflush(null);
            if (next >= 30000) need(resident <= baseline + 8192, "PID1 RSS flat within allocator bound during churn");
            next += 30000;
        }
        newest = text("com.rmxos.op789.churn.{d}.{d}", .{ c.getpid(), cycles });
        submit(newest);
        remove(newest);
        cycles += 1;
        _ = c.usleep(100000);
    }
    _ = awaitRecord("RefProc", newest, "[Message Exited with code: 73]");
    waitEmpty();
    _ = c.printf("pid1_churn elapsed_ms=%lld rss_kib=%ju cycles=%ju queued=%ju drops=%ju\n", @as(c_longlong, milliseconds() - start), rss(), cycles, stat(queue_count), stat(queue_dropped));
    _ = c.sleep(60);
    const idle = rss();
    _ = c.printf("pid1_churn_idle elapsed_ms=%lld rss_kib=%ju cycles=%ju\n", @as(c_longlong, milliseconds() - start), idle, cycles);
    need(cycles > 1000 and idle <= baseline + 8192, "churn completed and idle RSS bounded");
}
fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    if (!f.enter("/usr/tests/sys/launchd/launchd_logging_test", name)) return;
    _ = c.alarm(if (std.mem.eql(u8, name, "stopped")) f.stoppedLimits().worker_seconds else 150);
    if (std.mem.eql(u8, name, "early_boot")) early() else if (std.mem.eql(u8, name, "drain")) drain() else if (std.mem.eql(u8, name, "stopped")) stopped() else if (std.mem.eql(u8, name, "pid1_boot")) boot() else if (std.mem.eql(u8, name, "report_identity")) reportIdentity() else if (std.mem.eql(u8, name, "mid_batch_exit")) midBatchExit() else churn();
}
fn cleanup(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    if (std.mem.eql(u8, name, "stopped") or std.mem.eql(u8, name, "mid_batch_exit")) {
        const bytes = std.fs.cwd().readFileAlloc(a, "/var/run/syslog.pid", 64) catch "";
        const pid = std.fmt.parseInt(i32, std.mem.trim(u8, bytes, " \r\n"), 10) catch 0;
        if (pid > 1) _ = c.kill(pid, c.SIGCONT);
        _ = f.run(&.{ "/bin/launchctl", "load", "/etc/launchd.d/com.apple.syslogd.plist" });
    }
    f.cleanup(name);
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    var timeout_buffer: [32]u8 = undefined;
    const timeout: [*:0]const u8 = if (std.mem.eql(u8, name, "churn")) "1100" else if (std.mem.eql(u8, name, "stopped")) (std.fmt.bufPrintZ(&timeout_buffer, "{d}", .{f.stoppedLimits().atf_seconds}) catch unreachable).ptr else "60";
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", timeout);
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, head, body, cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
