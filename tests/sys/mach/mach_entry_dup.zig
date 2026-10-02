// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn __error() *c_int;
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach name aliases are rejected without changing its rights");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var name: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &name) != 0) c.atf_tc_fail("receive allocation failed");
    defer _ = c.close(@intCast(name));
    var pipe: [2]c_int = undefined;
    if (c.pipe(&pipe) != 0) c.atf_tc_fail("native pipe setup failed");
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    const native_alias = c.dup(pipe[0]);
    if (native_alias < 0) c.atf_tc_fail("ordinary descriptor duplication failed");
    defer _ = c.close(native_alias);
    const alias = c.dup(@intCast(name));
    const dup_errno = __error().*;
    if (alias >= 0) _ = c.close(alias);
    const replaced = c.dup2(@intCast(name), native_alias);
    const dup2_errno = __error().*;
    _ = c.printf("dup expected=-1 observed=%d expected_errno=%d observed_errno=%d dup2 expected=-1 observed=%d expected_errno=%d observed_errno=%d\n", alias, c.EOPNOTSUPP, dup_errno, replaced, c.EOPNOTSUPP, dup2_errno);
    if (alias != -1 or dup_errno != c.EOPNOTSUPP or replaced != -1 or dup2_errno != c.EOPNOTSUPP) c.atf_tc_fail("Mach descriptor alias was accepted");
    const destroyed = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), name);
    if (destroyed != 0) c.atf_tc_fail("rejected aliases changed the receive right");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "reject_aliases", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
