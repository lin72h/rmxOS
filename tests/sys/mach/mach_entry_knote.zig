// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Destroying a Mach port set removes its registered knote");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var name: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &name) != 0) c.atf_tc_fail("port set allocation failed");
    const kq = c.kqueue();
    if (kq < 0) c.atf_tc_fail("kqueue allocation failed");
    defer _ = c.close(kq);
    var change = c.struct_kevent{ .ident = name, .filter = c.EVFILT_MACHPORT, .flags = c.EV_ADD | c.EV_RECEIPT, .fflags = 0, .data = 0, .udata = null, .ext = .{ 0, 0, 0, 0 } };
    var event: c.struct_kevent = undefined;
    if (c.kevent(kq, &change, 1, &event, 1, null) != 1 or event.data != 0) c.atf_tc_fail("knote registration failed");
    const destroyed = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), name);
    if (destroyed != 0) c.atf_tc_fail("port set destroy failed");
    var immediate = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 0 };
    const count = c.kevent(kq, null, 0, &event, 1, &immediate);
    _ = c.printf("destroyed_pset expected_pending=0 observed_pending=%d\n", count);
    if (count != 0) c.atf_tc_fail("destroyed port set left a stale knote");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "destroy_detaches", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
