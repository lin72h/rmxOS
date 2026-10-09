// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/thrworkq.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var args = @import("std").mem.zeroes(c.struct_twq_init_args);
    args.tqi_version = c.TWQ_SPI_VERSION_CURRENT;
    c.__error().* = 0;
    const init_rc = c.syscall(c.SYS_twq_kernreturn, @as(c_int, c.TWQ_OP_INIT), &args, @as(c_int, @sizeOf(@TypeOf(args))), @as(c_int, 0));
    const init_errno = c.__error().*;
    _ = c.printf("exec_workqueue init_version=%u expected_min=0 observed_result=%d expected_errno=0 observed_errno=%d\n", @as(c_uint, args.tqi_version), init_rc, init_errno);
    if (init_rc < 0) c.atf_tc_fail("workqueue init failed");
    var argv = [_:null]?[*:0]const u8{"missing"};
    var env = [_:null]?[*:0]const u8{};
    const exec_rc = c.execve("/op583-missing-executable", @ptrCast(&argv), @ptrCast(&env));
    const exec_errno = c.__error().*;
    c.__error().* = 0;
    const result = c.syscall(c.SYS_twq_kernreturn, @as(c_int, c.TWQ_OP_SHOULD_NARROW), @as(?*anyopaque, null), @as(c_int, 0), @as(c_int, 0));
    _ = c.printf("exec_workqueue expected_exec=-1 observed_exec=%d expected_errno=%d observed_errno=%d expected_workqueue=0 observed_workqueue=%d\n", exec_rc, @as(c_int, c.ENOENT), exec_errno, result);
    if (exec_rc != -1 or exec_errno != c.ENOENT or result != 0) c.atf_tc_fail("failed exec discarded workqueue state");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    var e = c.atf_tc_init(&tc, "failed_exec", null, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(e)) return e;
    e = c.atf_tp_add_tc(tp, &tc);
    return e;
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
