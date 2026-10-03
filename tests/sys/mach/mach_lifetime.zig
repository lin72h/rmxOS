// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/param.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/module.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("pthread.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Observation = extern struct { result: c_int = 0, owned: c_int = 0 };
var cases: [9]c.atf_tc_t = undefined;
fn observe(command_value: u32) Observation {
    var command = command_value;
    var result: Observation = .{};
    var size: usize = @sizeOf(Observation);
    if (c.sysctlbyname("debug.rmx_lifetime_observe", &result, &size, &command, @sizeOf(u32)) != 0 or size != @sizeOf(Observation)) c.atf_tc_fail("lifetime fixture observation failed");
    return result;
}
fn load(t: [*c]const c.atf_tc_t) void {
    var path: [4096]u8 = undefined;
    const length = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (length < 0 or length >= path.len or c.kldload(&path) < 0) c.atf_tc_fail("fixture load failed");
}
fn wait(child: c.pid_t) void {
    var status: c_int = 0;
    if (child < 0 or c.waitpid(child, &status, 0) != child or status != 0) c.atf_tc_fail("child observation failed");
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "15");
}
fn inherited(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    if (observe(1).result != 0) c.atf_tc_fail("bootstrap setup failed");
    const before = observe(2).owned;
    const child = c.fork();
    if (child == 0) c._exit(0);
    wait(child);
    const after = observe(2).owned;
    _ = c.printf("special_rights expected=%d observed=%d\n", before, after);
    if (after != before) c.atf_tc_fail("child exit retained its inherited bootstrap send right");
}
fn taskDeath(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    const child = c.fork();
    if (child == 0) {
        if (observe(3).owned != 1) c._exit(1);
        c._exit(0);
    }
    wait(child);
    const after = observe(4).owned;
    _ = c.printf("task_control_after_exit expected_active=0 observed_active=%d\n", after);
    if (after != 0) c.atf_tc_fail("exited task retained an active control port");
}
fn reuse(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    const child = c.fork();
    if (child == 0) {
        _ = observe(3);
        c._exit(0);
    }
    wait(child);
    // Hold the old port across further births; inspect Mach activity, not slots.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const next = c.fork();
        if (next == 0) c._exit(0);
        wait(next);
        if (observe(4).owned != 0) c.atf_tc_fail("old task control port remained active across later process lifetimes");
    }
}
fn worker(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    return if (observe(6).owned == 1) null else @ptrFromInt(1);
}
fn threadDeath(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    var thread: c.pthread_t = undefined;
    var result: ?*anyopaque = null;
    if (c.pthread_create(&thread, null, &worker, null) != 0 or c.pthread_join(thread, &result) != 0 or result != null) c.atf_tc_fail("thread observation failed");
    // Dtor runs in the reaper; bound the wait for its post-gate port disable.
    var tries: usize = 0;
    while (tries < 100 and observe(4).owned != 0) : (tries += 1) _ = c.usleep(10000);
    const after = observe(4).owned;
    _ = c.printf("thread_control_after_exit expected_active=0 observed_active=%d\n", after);
    if (after != 0) c.atf_tc_fail("exited thread retained an active control port");
}
fn shared(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    var name: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 4), &name) != 0) c.atf_tc_fail("dead-name allocation failed");
    const child = c.rfork(c.RFPROC);
    if (child == 0) {
        var count: Observation = .{};
        var size: usize = @sizeOf(Observation);
        const rc = c.sysctlbyname("debug.rmx_urefs_observe", &count, &size, &name, @sizeOf(u32));
        c._exit(if (rc == 0 and count.result == 0 and count.owned == 1) 0 else 1);
    }
    wait(child);
    var count: Observation = .{};
    var size: usize = @sizeOf(Observation);
    if (c.sysctlbyname("debug.rmx_urefs_observe", &count, &size, &name, @sizeOf(u32)) != 0 or count.result != 0 or count.owned != 1) c.atf_tc_fail("shared-fd child exit revoked the parent's Mach name");
    if (c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), name) != 0) c.atf_tc_fail("shared Mach name could not be destroyed");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) _ = c.kldunload(module);
}
const Divorce = extern struct { fresh: c_int, special: c_int, old_result: c_int, new_result: c_int, new_count: c_int };
fn nameRefs(name_value: u32) Observation {
    var name = name_value;
    var result: Observation = .{};
    var size: usize = @sizeOf(Observation);
    if (c.sysctlbyname("debug.rmx_urefs_observe", &result, &size, &name, @sizeOf(u32)) != 0) c._exit(2);
    return result;
}
fn divorce(t: [*c]const c.atf_tc_t, flags: c_int) void {
    load(t);
    var cwd: [4096]u8 = undefined;
    var path: [4096]u8 = undefined;
    if (c.getcwd(&cwd, cwd.len) == null) c.atf_tc_fail("getcwd failed");
    const length = c.snprintf(&path, path.len, "%s/rfork-observation", &cwd);
    if (length < 0 or length >= path.len) c.atf_tc_fail("observation path too long");
    const child = c.rfork(c.RFPROC);
    if (child == 0) {
        if (observe(1).result != 0) c._exit(2);
        var old: u32 = 0;
        if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 4), &old) != 0) c._exit(2);
        _ = observe(8);
        if (c.rfork(flags) != 0) c._exit(2);
        // Two clean-table changes must not make the old table address current.
        if (flags == c.RFCFDG and c.rfork(flags) != 0) c._exit(2);
        // Enter Mach without allocating a name that could reuse the old name.
        _ = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), @as(c_uint, 0));
        const space = observe(9);
        const previous = nameRefs(old);
        var new: u32 = 0;
        if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 4), &new) != 0) c._exit(2);
        const next = nameRefs(new);
        const result = Divorce{ .fresh = space.result, .special = space.owned, .old_result = previous.result, .new_result = next.result, .new_count = next.owned };
        // RFCFDG closes every descriptor, including ATF's result channel.
        // Reopen a private file; only the parent performs the ATF verdict.
        const fd = c.open(&path, c.O_CREAT | c.O_TRUNC | c.O_WRONLY, @as(c_uint, 0o600));
        if (fd < 0 or c.write(fd, &result, @sizeOf(Divorce)) != @sizeOf(Divorce)) c._exit(2);
        _ = c.close(fd);
        c._exit(0);
    }
    wait(child);
    const fd = c.open(&path, c.O_RDONLY);
    if (fd < 0) c.atf_tc_fail("child observation missing");
    var result: Divorce = undefined;
    if (c.read(fd, &result, @sizeOf(Divorce)) != @sizeOf(Divorce)) c.atf_tc_fail("child observation truncated");
    _ = c.close(fd);
    _ = c.unlink(&path);
    _ = c.printf("rfork expected_fresh=1 observed_fresh=%d expected_special=1 observed_special=%d expected_old_result=15 observed_old_result=%d expected_new_result=0 observed_new_result=%d expected_new_urefs=1 observed_new_urefs=%d\n", result.fresh, result.special, result.old_result, result.new_result, result.new_count);
    if (result.fresh != 1 or result.special != 1 or result.old_result != 15 or result.new_result != 0 or result.new_count != 1) c.atf_tc_fail("in-place rfork did not rebind the empty namespace while retaining task special ports");
}
fn unshare(t: [*c]const c.atf_tc_t) callconv(.c) void {
    divorce(t, c.RFFDG);
}
fn cleanTable(t: [*c]const c.atf_tc_t) callconv(.c) void {
    divorce(t, c.RFCFDG);
}
fn failedCreation(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    const result = observe(10);
    _ = c.printf("failed_creation observed_constructed=%d expected_attached_after_dtor=0 observed_attached_after_dtor=%d\n", result.result, result.owned);
    // Batch 2 has no per-proc ctor; batch 3 must unwind its prepared task.
    if (result.owned != 0) c.atf_tc_fail("failed process creation retained a Mach task attachment");
}
fn parkedReply(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    const result = observe(11);
    _ = c.printf("parked_reply expected_cleared=1 observed_cleared=%d expected_extra_send_rights=0 observed_extra_send_rights=%d\n", result.result, result.owned);
    if (result.result != 1 or result.owned != 0) c.atf_tc_fail("thread IPC retirement retained a parked reply or its task control send right");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "inherited_rights", "task_control_death", "incarnation", "thread_control_death", "shared_fd_exit", "rfork_unshare", "rfork_clean_table", "failed_creation", "parked_reply" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &inherited, &taskDeath, &reuse, &threadDeath, &shared, &unshare, &cleanTable, &failedCreation, &parkedReply };
    for (names, bodies, 0..) |name, body, i| {
        const err = c.atf_tc_init(&cases[i], name, &head, body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
