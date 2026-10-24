// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
});
extern fn dispatch_queue_create([*:0]const u8, ?*anyopaque) ?*anyopaque;
extern fn dispatch_source_create(*const anyopaque, usize, usize, ?*anyopaque) ?*anyopaque;
extern const _dispatch_source_type_timer: u8;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var executable: [*c]u8 = undefined;
fn now() i128 {
    var t: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &t) != 0) c.atf_tc_fail("clock_gettime");
    return @as(i128, t.tv_sec) * std.time.ns_per_s + t.tv_nsec;
}
fn run(mode: ?[*:0]const u8) void {
    const start = now();
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork");
    if (pid == 0) {
        if ((if (mode) |m| c.setenv("LIBDISPATCH_LOG", m, 1) else c.unsetenv("LIBDISPATCH_LOG")) != 0) c._exit(90);
        var args = [_][*c]const u8{ executable, "--timer-child", null };
        _ = c.execv(executable, @ptrCast(&args));
        c._exit(91);
    }
    var status: c_int = 0;
    while (now() - start < 2 * std.time.ns_per_s) {
        const got = c.waitpid(pid, &status, c.WNOHANG);
        if (got == pid) {
            if (status != 0) c.atf_tc_fail("fresh timer process failed: wait_status=%d", status);
            return;
        }
        if (got < 0) c.atf_tc_fail("waitpid");
        _ = c.usleep(1000);
    }
    _ = c.kill(pid, c.SIGKILL);
    _ = c.waitpid(pid, &status, 0);
    c.atf_tc_fail("fresh process did not reach the statement after dispatch_source_create within 2 s");
}
fn unset(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(null);
}
fn no(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run("NO");
}
fn stderr(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run("stderr");
}
const names = [_][*:0]const u8{ "unset", "no", "stderr" };
const bodies = .{ &unset, &no, &stderr };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "5");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (names, 0..) |name, i| {
        const err = c.atf_tc_init(&cases[i], name, &head, bodies[i], null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--timer-child")) {
        // No preceding dispatch call: serial queue creation then the BSD-output timer.
        const q = dispatch_queue_create("rmx.root_setup", null) orelse return 92;
        const source = dispatch_source_create(&_dispatch_source_type_timer, 0, 0, q);
        return if (source != null) 0 else 93;
    }
    executable = argv[0];
    return atf_tp_main(argc, argv, &add);
}
