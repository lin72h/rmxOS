// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
const Message = extern struct { header: Header, payload: [64]u8 };
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Named port sets initialize membership and knote locks");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
const AllocateName = extern struct { header: Header, descriptors: u32, ndr: [8]u8, right: u32, name: u32 };
const Reply = extern struct { header: Header, ndr: [8]u8, result: i32 };
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const task = c.syscall(c.SYS_task_self_trap);
    if (task < 0) c.atf_tc_fail("task setup failed");
    var reply: u32 = 0;
    var member: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &reply) != 0) c.atf_tc_fail("reply port setup failed");
    defer _ = c.close(@intCast(reply));
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &member) != 0) c.atf_tc_fail("member port setup failed");
    defer _ = c.close(@intCast(member));
    // Reserve an unused name without creating an alias of a Mach right.
    const vacant = c.open("/dev/null", c.O_RDONLY);
    if (vacant < 0) c.atf_tc_fail("name setup failed");
    if (c.close(vacant) != 0) c.atf_tc_fail("name release failed");
    var storage: [128]u8 align(8) = [_]u8{0} ** 128;
    const request: *AllocateName = @ptrCast(&storage);
    request.* = .{ .header = .{ .bits = 0x80000000 | 19 | (21 << 8), .size = @sizeOf(AllocateName), .remote = @intCast(task), .local = reply, .voucher = 0, .id = 3203 }, .descriptors = 0, .ndr = .{ 0, 0, 0, 0, 1, 0, 0, 0 }, .right = 3, .name = @intCast(vacant) };
    const rpc = c.syscall(c.SYS_mach_msg_trap, &storage, @as(c_uint, 3), @as(c_uint, @sizeOf(AllocateName)), @as(c_uint, 128), reply, @as(c_uint, 0), @as(c_uint, 0));
    const response: *const Reply = @ptrCast(&storage);
    if (rpc != 0 or response.header.id != 3303 or response.result != 0) c.atf_tc_fail("named pset setup failed transport=%d", rpc);
    defer _ = c.close(vacant);
    const moved = c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), member, @as(c_uint, @intCast(vacant)));
    _ = c.printf("named_pset expected_move=0 observed_move=%d\n", moved);
    if (moved != 0) c.atf_tc_fail("named pset member insertion failed=%d", moved);
    const kq = c.kqueue();
    if (kq < 0) c.atf_tc_fail("kqueue setup failed");
    defer _ = c.close(kq);
    var change = c.struct_kevent{ .ident = @intCast(vacant), .filter = c.EVFILT_MACHPORT, .flags = c.EV_ADD | c.EV_RECEIPT, .fflags = 0, .data = 0, .udata = null, .ext = .{ 0, 0, 0, 0 } };
    var event: c.struct_kevent = undefined;
    const count = c.kevent(kq, &change, 1, &event, 1, null);
    _ = c.printf("named_pset expected_receipt=1 observed_receipt=%d\n", count);
    if (count != 1 or event.flags & c.EV_ERROR == 0 or event.data != 0 or event.ident != @as(usize, @intCast(vacant))) c.atf_tc_fail("named pset filter registration failed");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "named_pset", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
