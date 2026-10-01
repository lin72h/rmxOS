// SPDX-License-Identifier: BSD-2-Clause
pub const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/event.h");
    @cInclude("sys/capsicum.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
pub extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
pub const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
pub const Descriptor = extern struct { name: u32, pad: u32, pad2: u16, disposition: u8, kind: u8 };
pub const Message = extern struct { header: Header, count: u32, descriptor: Descriptor, trailer: [128]u8 };
pub fn allocate() u32 {
    var port: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &port) != 0) c.atf_tc_fail("receive port setup failed");
    return port;
}
pub fn sendFile(port: u32, fd: c_int) c_int {
    var msg = Message{ .header = .{ .bits = 0x80000000 | 20, .size = 40, .remote = port, .local = 0, .voucher = 0, .id = 39507 }, .count = 1, .descriptor = .{ .name = @intCast(fd), .pad = 0, .pad2 = 0, .disposition = 19, .kind = 0 }, .trailer = [_]u8{0} ** 128 };
    return c.syscall(c.SYS_mach_msg_trap, &msg, @as(c_uint, 1), @as(c_uint, 40), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0));
}
pub fn receiveFile(port: u32, msg: *Message) c_int {
    return c.syscall(c.SYS_mach_msg_trap, msg, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, @sizeOf(Message)), port, @as(c_uint, 0), @as(c_uint, 0));
}
