// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const MachTime = extern struct { sec: u32, nsec: c_int };
fn now() u64 {
    var t: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_UPTIME, &t) != 0) c.atf_tc_fail("uptime read failed");
    return @as(u64, @intCast(t.tv_sec)) * 1000000000 + @as(u64, @intCast(t.tv_nsec));
}
fn sleep(clock: u32, kind: u32, sec: c_int, nsec: c_int, out: ?*MachTime) c_int {
    return c.syscall(c.SYS_clock_sleep_trap, clock, kind, sec, nsec, out);
}
var cases: [5]c.atf_tc_t = undefined;
const names = [_][*:0]const u8{ "relative", "absolute", "past", "invalid", "interrupt" };
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach clock sleep uses uptime, nanoseconds and Mach result codes");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn ignore(_: c_int) callconv(.c) void {}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(t));
    var wake: MachTime = undefined;
    const before = now();
    if (std.mem.eql(u8, name, "invalid")) {
        if (sleep(99, 1, 0, 1, &wake) != 4 or sleep(0, 99, 0, 1, &wake) != 4 or sleep(0, 1, -1, 0, &wake) != 4 or sleep(0, 1, 0, 1000000000, &wake) != 4) c.atf_tc_fail("invalid clock/type/duration must return KERN_INVALID_ARGUMENT");
        if (sleep(0, 1, 0, 0, @ptrFromInt(4)) != 1) c.atf_tc_fail("bad wakeup pointer must return KERN_INVALID_ADDRESS");
        return;
    }
    if (std.mem.eql(u8, name, "past")) {
        if (sleep(0, 0, 0, 0, &wake) != 0) c.atf_tc_fail("past deadline must succeed");
        return;
    }
    if (std.mem.eql(u8, name, "interrupt")) {
        var action: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
        action.__sigaction_u.__sa_handler = &ignore;
        if (c.sigaction(c.SIGUSR1, &action, null) != 0) c.atf_tc_fail("signal setup failed");
        const parent = c.getpid();
        const child = c.fork();
        if (child < 0) c.atf_tc_fail("fork failed");
        if (child == 0) {
            _ = c.usleep(100000);
            _ = c.kill(parent, c.SIGUSR1);
            c._exit(0);
        }
        const result = sleep(0, 1, 2, 0, &wake);
        var status: c_int = 0;
        if (c.waitpid(child, &status, 0) != child or status != 0) c.atf_tc_fail("signal child failed");
        if (result != 14) c.atf_tc_fail("interrupted sleep expected KERN_ABORTED=14 observed=%d", result);
        return;
    }
    var result: c_int = undefined;
    if (std.mem.eql(u8, name, "absolute")) {
        const deadline = before + 200000000;
        result = sleep(0, 0, @intCast(deadline / 1000000000), @intCast(deadline % 1000000000), &wake);
    } else {
        result = sleep(0, 1, 0, 200000000, &wake);
    }
    const after = now();
    const duration = after - before;
    const woke = @as(u64, wake.sec) * 1000000000 + @as(u64, @intCast(wake.nsec));
    _ = c.printf("sleep result=%d elapsed_ns=%lu wake_ns=%lu before_ns=%lu after_ns=%lu\n", result, duration, woke, before, after);
    if (result != 0 or duration < 180000000 or duration > 1000000000 or woke < before or woke > after) c.atf_tc_fail("sleep duration or uptime wake result incorrect");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var err = c.atf_tc_init(&cases[i], name, &head, &body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
