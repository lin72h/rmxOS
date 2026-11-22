// Exercise the real launchctl stop path against a job with a known SIGTERM policy.
const std = @import("std");
const fixture = @import("job_fixture.zig");
const scope = @import("log_store_scope.zig");
const io = std.Io.Threaded.global_single_threaded.io();
const a = std.heap.page_allocator;
const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/event.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;

const program = "/usr/tests/sys/launchd/stop_fallback_test";
const cases = [_][*:0]const u8{ "stop_kills_after_timeout", "stop_exits_on_term" };
var tests: [cases.len]c.atf_tc_t = undefined;

fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, format, args) catch unreachable;
}

fn write(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn read(path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
}

fn unlink(path: []const u8) void {
    _ = c.unlink(fixture.z(path));
}

// Block SIGTERM before announcing readiness. sigwait records every delivery
// without asynchronous handlers, and exits normally only for the cooperative job.
fn worker(dir: []const u8, stubborn: bool) !void {
    var set: c.sigset_t = undefined;
    if (c.sigemptyset(&set) != 0 or c.sigaddset(&set, c.SIGTERM) != 0 or
        c.sigprocmask(c.SIG_BLOCK, &set, null) != 0) return error.SignalMask;
    const signals = c.open(fixture.z(fmt("{s}/terms", .{dir})), c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o600));
    if (signals < 0) return error.SignalFile;
    defer _ = c.close(signals);
    try write(fmt("{s}/pid", .{dir}), fmt("{d}\n", .{c.getpid()}));
    while (true) {
        var sig: c_int = 0;
        if (c.sigwait(&set, &sig) != 0 or sig != c.SIGTERM) return error.SignalWait;
        if (c.write(signals, "T", 1) != 1) return error.SignalRecord;
        if (!stubborn) return;
    }
}

fn waitPid(dir: []const u8) !c_int {
    for (0..100) |_| {
        if (read(fmt("{s}/pid", .{dir}))) |bytes| {
            defer a.free(bytes);
            const pid = std.fmt.parseInt(c_int, std.mem.trimEnd(u8, bytes, "\n"), 10) catch 0;
            if (pid > 1) return pid;
        } else |_| {}
        _ = c.usleep(50_000);
    }
    return error.JobReadinessTimeout;
}

fn monotonicNs() !u64 {
    var t: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &t) != 0) return error.MonotonicClock;
    return @as(u64, @intCast(t.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(t.tv_nsec));
}

fn exercise(stubborn: bool) !void {
    var directory = "/tmp/rmx-stop-fallback.XXXXXX".*;
    if (c.mkdtemp(&directory) == null) return error.FixtureDirectory;
    const dir = std.mem.sliceTo(&directory, 0);
    defer {
        for ([_][]const u8{ "job.plist", "pid", "terms" }) |name| unlink(fmt("{s}/{s}", .{ dir, name }));
        _ = c.rmdir(&directory);
    }
    const label = fmt("org.rmxos.test.stop-fallback.{s}", .{std.fs.path.extension(dir)[1..]});
    const plist = fmt("{s}/job.plist", .{dir});
    const terms = fmt("{s}/terms", .{dir});
    try write(plist, fmt(
        \\<?xml version="1.0"?>
        \\<plist version="1.0"><dict>
        \\<key>Label</key><string>{s}</string>
        \\<key>ProgramArguments</key><array>
        \\<string>{s}</string><string>--worker</string><string>{s}</string><string>{s}</string>
        \\</array>
        \\<key>ExitTimeOut</key><integer>2</integer>
        \\</dict></plist>
    , .{ label, program, dir, if (stubborn) @as([]const u8, "stubborn") else "cooperative" }));

    scope.begin();
    if (fixture.run(&.{ "/bin/launchctl", "bootstrap", "system", plist }) != 0) return error.JobBootstrap;
    defer _ = fixture.run(&.{ "/bin/launchctl", "remove", label });
    if (fixture.run(&.{ "/bin/launchctl", "start", label }) != 0) return error.JobStart;
    const pid = try waitPid(dir);
    var exited = false;
    defer if (!exited) {
        // The base leaves the stubborn worker alive. Bound cleanup even there.
        _ = c.kill(pid, c.SIGKILL);
    };

    const queue = c.kqueue();
    if (queue < 0) return error.ProcessQueue;
    defer _ = c.close(queue);
    const watch = c.struct_kevent{
        .ident = @intCast(pid),
        .filter = c.EVFILT_PROC,
        .flags = c.EV_ADD | c.EV_ONESHOT,
        .fflags = c.NOTE_EXIT,
        .data = 0,
        .udata = null,
        .ext = .{ 0, 0, 0, 0 },
    };
    if (c.kevent(queue, &watch, 1, null, 0, null) != 0) return error.ExitWatch;
    const start = try monotonicNs();
    if (fixture.run(&.{ "/bin/launchctl", "stop", label }) != 0) return error.JobStop;
    const timeout = c.struct_timespec{ .tv_sec = 6, .tv_nsec = 0 };
    var event: c.struct_kevent = undefined;
    const n = c.kevent(queue, null, 0, &event, 1, &timeout);
    if (n < 0) return error.ExitObservation;
    exited = n == 1 and event.ident == @as(usize, @intCast(pid)) and
        event.flags & c.EV_ERROR == 0 and event.fflags & c.NOTE_EXIT != 0;
    const elapsed_ms = ((try monotonicNs()) - start) / std.time.ns_per_ms;
    const status = if (exited) event.data else -1;
    const deliveries = try read(terms);
    defer a.free(deliveries);

    // A cooperative exit is observed through the whole fallback window.
    if (!stubborn and elapsed_ms < 2_200)
        _ = c.usleep(@intCast((2_200 - elapsed_ms) * 1000));
    const logs = scope.query("RefProc", label, false, false);
    defer a.free(logs);
    const unexpected = std.mem.indexOf(u8, logs, "Job was sent unexpected signal:") != null;
    const timeout_logged = std.mem.indexOf(u8, logs, "Exit timeout elapsed (2 seconds). Killing") != null;
    _ = c.printf("stop_fallback label=%s pid=%d terms=%zu wait_status=%jd elapsed_ms=%ju unexpected=%d timeout_log=%d\n", fixture.z(label).ptr, pid, deliveries.len, status, elapsed_ms, @as(c_int, @intFromBool(unexpected)), @as(c_int, @intFromBool(timeout_logged)));
    _ = c.fflush(null);

    if (!std.mem.eql(u8, deliveries, "T")) return error.ExpectedOneSigterm;
    if (unexpected) return error.UnexpectedSignalLog;
    if (!exited) return error.JobDidNotExit;
    if (stubborn) {
        if (status != c.SIGKILL or elapsed_ms < 2_000) return error.ExpectedTimedSigkill;
    } else if (status != 0 or timeout_logged) {
        return error.ExpectedGracefulExit;
    }
}

fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "25");
}

fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    exercise(std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), std.mem.span(cases[0]))) catch |err|
        c.atf_tc_fail("launchctl stop: %s", @errorName(err).ptr);
}

fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (cases, &tests) |name, *tc| {
        var err = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}

pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--worker")) {
        worker(std.mem.span(argv[2]), std.mem.eql(u8, std.mem.span(argv[3]), "stubborn")) catch return 1;
        return 0;
    }
    return atf_tp_main(argc, argv, add);
}
