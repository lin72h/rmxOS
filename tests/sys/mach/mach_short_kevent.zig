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
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Direct kevent short receive cleans up the saved message");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var port: u32 = 0;
    var pset: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &port) != 0) c.atf_tc_fail("receive port setup failed");
    defer _ = c.close(@intCast(port));
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &pset) != 0) c.atf_tc_fail("port set setup failed");
    defer _ = c.close(@intCast(pset));
    if (c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), port, pset) != 0) c.atf_tc_fail("move member failed");
    var sent = Message{ .header = .{ .bits = 20, .size = @sizeOf(Message), .remote = port, .local = 0, .voucher = 0, .id = 39503 }, .payload = [_]u8{0x5a} ** 64 };
    if (c.syscall(c.SYS_mach_msg_trap, &sent, @as(c_uint, 1), @as(c_uint, @sizeOf(Message)), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) != 0) c.atf_tc_fail("message send failed");
    const kq = c.kqueue();
    if (kq < 0) c.atf_tc_fail("kqueue setup failed");
    defer _ = c.close(kq);
    // Reserve trailer space while advertising only a short receive size.
    var received: [128]u8 = undefined;
    var change = c.struct_kevent{ .ident = pset, .filter = c.EVFILT_MACHPORT, .flags = c.EV_ADD | c.EV_ONESHOT, .fflags = 2, .data = 0, .udata = null, .ext = .{ @intFromPtr(&received), @sizeOf(Header), 0, 0 } };
    var event: c.struct_kevent = undefined;
    var immediate = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 0 };
    const count = c.kevent(kq, &change, 1, &event, 1, &immediate);
    _ = c.printf("kevent expected_count=1 observed_count=%d expected_result=0x10004004 observed_result=0x%x\n", count, if (count == 1) event.fflags else @as(c_uint, 0));
    if (count != 1) c.atf_tc_fail("expected one kevent observed=%d", count);
    if (event.filter != c.EVFILT_MACHPORT or event.ident != pset or event.flags & c.EV_ERROR != 0 or event.fflags != 0x10004004) c.atf_tc_fail("unexpected direct receive event");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "short_buffer", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
