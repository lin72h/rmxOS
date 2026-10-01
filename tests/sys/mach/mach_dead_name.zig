// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
const Message = extern struct { header: Header, payload: [64]u8 };
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Receiving on a dead name returns MACH_RCV_INVALID_NAME");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var dead: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 4), &dead) != 0) c.atf_tc_fail("dead-name setup failed");
    defer _ = c.close(@intCast(dead));
    var buffer: [128]u8 align(8) = undefined;
    const result = c.syscall(c.SYS_mach_msg_trap, &buffer, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, 128), dead, @as(c_uint, 0), @as(c_uint, 0));
    _ = c.printf("receive expected=0x10004002 observed=0x%x\n", @as(c_uint, @bitCast(result)));
    if (result != 0x10004002) c.atf_tc_fail("dead-name receive returned wrong result=%d", result);
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "dead_name", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
