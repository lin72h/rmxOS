// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/user.h");
    @cInclude("sys/proc.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
    @cInclude("atf-c.h");
    @cInclude("launch.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const total = 5000;
const expected_status = 37 << 8;
var procs: [16384]c.struct_kinfo_proc = undefined;
fn need(ok: bool, what: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s (errno=%d)", what, c.__error().*);
}
fn now() i64 {
    var ts: c.struct_timespec = undefined;
    need(c.clock_gettime(c.CLOCK_MONOTONIC, &ts) == 0, "monotonic clock");
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}
fn childZombies(parent: c.pid_t) usize {
    // The independent observer counts every direct zombie, not just our PIDs.
    var size: usize = @sizeOf(@TypeOf(procs));
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PROC };
    need(c.sysctl(&mib, mib.len, &procs, &size, null, 0) == 0, "PID 1 process inventory");
    need(size % @sizeOf(c.struct_kinfo_proc) == 0, "complete process records");
    var n: usize = 0;
    for (procs[0 .. size / @sizeOf(c.struct_kinfo_proc)]) |p| {
        need(p.ki_structsize == @sizeOf(c.struct_kinfo_proc), "process inventory ABI");
        if (p.ki_ppid == parent and p.ki_stat == c.SZOMB) n += 1;
    }
    return n;
}
fn zombies() usize {
    return childZombies(1);
}
fn inventoryCheck() c_int {
    const before = childZombies(c.getpid());
    const child = c.fork();
    if (child == 0) c._exit(0);
    if (child < 0) return 1;
    var status: c_int = 0;
    const peek = c.waitpid(child, &status, c.WNOWAIT);
    const during = childZombies(c.getpid());
    const reaped = c.waitpid(child, &status, 0);
    const after = childZombies(c.getpid());
    _ = c.printf("inventory_check expected_before=0 observed_before=%zu expected_during=1 observed_during=%zu expected_after=0 observed_after=%zu\n", before, during, after);
    return if (peek == child and reaped == child and status == 0 and before == 0 and during == 1 and after == 0) 0 else 1;
}
fn string(dict: c.launch_data_t, key: [*:0]const u8, value: [*:0]const u8) void {
    need(c.launch_data_dict_insert(dict, c.launch_data_new_string(value), key), "job string");
}
fn request(key: [*:0]const u8, value: c.launch_data_t) c.launch_data_t {
    const q = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY);
    need(q != null, "job request allocation");
    defer c.launch_data_free(q);
    need(c.launch_data_dict_insert(q, value, key), "job request insertion");
    const r = c.launch_msg(q);
    need(r != null, "job IPC reply");
    return r;
}
const JobState = extern struct { pid: i64, status: i64 };
fn jobStatus(label: [*:0]const u8) JobState {
    const r = request(c.LAUNCH_KEY_GETJOB, c.launch_data_new_string(label));
    defer c.launch_data_free(r);
    need(c.launch_data_get_type(r) == c.LAUNCH_DATA_DICTIONARY, "ordinary job remains registered");
    const pid = c.launch_data_dict_lookup(r, c.LAUNCH_JOBKEY_PID);
    const status = c.launch_data_dict_lookup(r, c.LAUNCH_JOBKEY_LASTEXITSTATUS);
    need(status != null, "ordinary job reports LastExitStatus");
    return .{ .pid = if (pid == null) 0 else c.launch_data_get_integer(pid), .status = c.launch_data_get_integer(status) };
}
fn submitJob(label: [*:0]const u8, gatepath: [*:0]const u8) JobState {
    const job = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY);
    need(job != null, "ordinary job allocation");
    string(job, c.LAUNCH_JOBKEY_LABEL, label);
    string(job, c.LAUNCH_JOBKEY_PROGRAM, "/usr/tests/lib/launchd/orphan_reap_test");
    const args = c.launch_data_alloc(c.LAUNCH_DATA_ARRAY);
    for ([_][*:0]const u8{ "/usr/tests/lib/launchd/orphan_reap_test", "--job", gatepath }, 0..) |arg, i| {
        need(c.launch_data_array_set_index(args, c.launch_data_new_string(arg), i), "ordinary job arguments");
    }
    need(c.launch_data_dict_insert(job, args, c.LAUNCH_JOBKEY_PROGRAMARGUMENTS), "ordinary job argv");
    need(c.launch_data_dict_insert(job, c.launch_data_new_bool(true), c.LAUNCH_JOBKEY_RUNATLOAD), "ordinary job RunAtLoad");
    const submitted = request(c.LAUNCH_KEY_SUBMITJOB, job);
    need(c.launch_data_get_type(submitted) == c.LAUNCH_DATA_ERRNO and c.launch_data_get_errno(submitted) == 0, "ordinary job accepted");
    c.launch_data_free(submitted);
    const start_deadline = now() + 5000;
    while (jobStatus(label).pid == 0 and now() < start_deadline) _ = c.usleep(10000);
    const running = jobStatus(label);
    need(running.pid > 0, "ordinary job started beside orphans");
    return running;
}

// Keep unbounded launch_msg calls out of the ten-second collection window.
// The forking observer never opens a liblaunch connection; each IPC operation
// runs after exec in a fresh client with both a parent cap and its own alarm.
fn client(kind: [*:0]const u8, label: [*:0]const u8, gatepath: [*:0]const u8) JobState {
    var fds: [2]c_int = undefined;
    need(c.pipe(&fds) == 0, "client result pipe");
    var descriptor: [32:0]u8 = @splat(0);
    _ = c.snprintf(&descriptor, descriptor.len, "%d", fds[1]);
    const pid = c.fork();
    need(pid >= 0, "fork bounded status client");
    if (pid == 0) {
        _ = c.close(fds[0]);
        _ = c.execl("/usr/tests/lib/launchd/orphan_reap_test", "orphan_reap_test", "--client", kind, label, gatepath, &descriptor, @as(?*anyopaque, null));
        c._exit(114);
    }
    _ = c.close(fds[1]);
    const deadline = now() + 7000;
    var status: c_int = 0;
    var waited: c.pid_t = 0;
    while (now() < deadline) {
        waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited == pid) break;
        if (waited < 0 and c.__error().* != c.EINTR) break;
        _ = c.usleep(1000);
    }
    if (waited != pid) {
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, &status, 0);
        _ = c.close(fds[0]);
        c.atf_tc_fail("bounded %s client timed out", kind);
    }
    var state: JobState = undefined;
    const n = c.read(fds[0], &state, @sizeOf(JobState));
    _ = c.close(fds[0]);
    need(status == 0 and n == @sizeOf(JobState), "bounded status client returned complete facts");
    return state;
}

fn orphanReap(_: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.alarm(180);
    _ = c.setvbuf(c.stdout(), null, c._IOLBF, 0);
    const setup_start = now();
    const initial = zombies();
    _ = c.printf("orphan_reap before_zombies=%zu requested=%d\n", initial, @as(c_int, total));
    need(initial == 0, "PID 1 starts with no zombies");
    var label: [96:0]u8 = @splat(0);
    var gatepath: [128:0]u8 = @splat(0);
    _ = c.snprintf(&label, label.len, "org.rmxos.orphan-reap.%d", c.getpid());
    _ = c.snprintf(&gatepath, gatepath.len, "/tmp/orphan-reap-%d.gate", c.getpid());
    _ = c.unlink(&gatepath);
    const running = client("submit", &label, &gatepath);

    var gate: [2]c_int = undefined;
    var ready: [2]c_int = undefined;
    need(c.pipe(&gate) == 0 and c.pipe(&ready) == 0, "orphan barriers");
    // Each intermediate parent exits immediately. The adopted child reports
    // readiness only after observing getppid()==1, then waits for gate EOF.
    for (0..total) |_| {
        const parent = c.fork();
        need(parent >= 0, "fork intermediate parent");
        if (parent == 0) {
            _ = c.close(gate[1]);
            _ = c.close(ready[0]);
            const child = c.fork();
            if (child < 0) c._exit(111);
            if (child > 0) c._exit(0);
            while (c.getppid() != 1) _ = c.usleep(1000);
            var pid = c.getpid();
            if (c.write(ready[1], &pid, @sizeOf(c.pid_t)) != @sizeOf(c.pid_t)) c._exit(112);
            _ = c.close(ready[1]);
            var byte: u8 = 0;
            while (c.read(gate[0], &byte, 1) < 0 and c.__error().* == c.EINTR) {}
            c._exit(0);
        }
        var status: c_int = 0;
        var waited: c.pid_t = 0;
        while (true) {
            waited = c.waitpid(parent, &status, 0);
            if (waited >= 0 or c.__error().* != c.EINTR) break;
        }
        need(waited == parent and status == 0, "intermediate parent exited normally");
    }
    _ = c.close(gate[0]);
    _ = c.close(ready[1]);
    var pids: [total]c.pid_t = undefined;
    var bytes: usize = 0;
    while (bytes < @sizeOf(@TypeOf(pids))) {
        const n = c.read(ready[0], @as([*]u8, @ptrCast(&pids)) + bytes, @sizeOf(@TypeOf(pids)) - bytes);
        if (n < 0 and c.__error().* == c.EINTR) continue;
        need(n > 0, "all 5000 adopted children reported readiness");
        bytes += @intCast(n);
    }
    _ = c.close(ready[0]);
    _ = c.printf("orphan_reap adopted=%d ordinary_pid=%lld setup_ms=%lld\n", @as(c_int, total), running.pid, now() - setup_start);
    const start = now();
    // Ordinary job and all strangers can exit beside one another.
    const fd = c.open(&gatepath, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o600));
    need(fd >= 0, "release ordinary job");
    _ = c.close(fd);
    _ = c.close(gate[1]);
    var remaining: usize = total;
    while (now() - start < 10000) {
        remaining = zombies();
        // All adopted PIDs must disappear: an initial zero zombie count
        // before the scheduled children exit must never pass the test.
        var alive: usize = 0;
        for (pids) |pid| {
            if (c.kill(pid, 0) == 0 or c.__error().* != c.ESRCH) alive += 1;
        }
        if (remaining == 0 and alive == 0) break;
        _ = c.usleep(10000);
    }
    remaining = zombies();
    var alive: usize = 0;
    for (pids) |pid| {
        if (c.kill(pid, 0) == 0 or c.__error().* != c.ESRCH) alive += 1;
    }
    const elapsed = now() - start;
    _ = c.printf("orphan_reap collection_elapsed_ms=%lld observed_zombies=%zu observed_remaining=%zu\n", elapsed, remaining, alive);
    var observed = client("query", &label, &gatepath);
    const job_deadline = now() + 5000;
    while (observed.pid != 0 and now() < job_deadline) {
        _ = c.usleep(10000);
        observed = client("query", &label, &gatepath);
    }
    _ = c.printf("orphan_reap adopted=%d elapsed_ms=%lld expected_zombies=0 observed_zombies=%zu expected_remaining=0 observed_remaining=%zu expected_job_status=%d observed_job_status=%lld observed_job_pid=%lld\n", @as(c_int, total), elapsed, remaining, alive, @as(c_int, expected_status), observed.status, observed.pid);
    _ = client("remove", &label, &gatepath);
    _ = c.unlink(&gatepath);
    _ = c.alarm(0);
    need(observed.pid == 0 and observed.status == expected_status, "EVFILT_PROC retains the ordinary job exit status");
    need(remaining == 0 and alive == 0 and elapsed <= 10000, "PID 1 collected every adopted child within ten seconds");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "190");
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
}
var case_tc: c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    var err = c.atf_tc_init(&case_tc, "orphan_reap", &head, &orphanReap, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    err = c.atf_tp_add_tc(tp, &case_tc);
    return err;
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc == 6 and std.mem.eql(u8, std.mem.span(argv[1]), "--client")) {
        _ = c.alarm(6);
        const kind = std.mem.span(argv[2]);
        var state = if (std.mem.eql(u8, kind, "submit")) submitJob(@ptrCast(argv[3]), @ptrCast(argv[4])) else if (std.mem.eql(u8, kind, "query")) jobStatus(@ptrCast(argv[3])) else blk: {
            const r = request(c.LAUNCH_KEY_REMOVEJOB, c.launch_data_new_string(argv[3]));
            need(c.launch_data_get_type(r) == c.LAUNCH_DATA_ERRNO and c.launch_data_get_errno(r) == 0, "ordinary job removed");
            c.launch_data_free(r);
            break :blk JobState{ .pid = 0, .status = 0 };
        };
        const fd = std.fmt.parseInt(c_int, std.mem.span(argv[5]), 10) catch return 115;
        return if (c.write(fd, &state, @sizeOf(JobState)) == @sizeOf(JobState)) 0 else 116;
    }
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--inventory-check")) return inventoryCheck();
    if (argc == 3 and std.mem.eql(u8, std.mem.span(argv[1]), "--job")) {
        for (0..18000) |_| {
            if (c.access(argv[2], c.F_OK) == 0) return 37;
            _ = c.usleep(10000);
        }
        return 113;
    }
    return atf_tp_main(argc, argv, &add);
}
