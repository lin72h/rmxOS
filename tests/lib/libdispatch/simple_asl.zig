// SPDX-License-Identifier: BSD-2-Clause
// Compile the production libc logger with these Mach syscall stand-ins.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/mach/message.h");
    @cInclude("errno.h");
});
extern fn _simple_asl_log(c_int, ?[*:0]const u8, ?[*:0]const u8) void;
extern fn _simple_asl_log_prog(c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) void;
var id: c_int = 0;
var sends: usize = 0;
var released: usize = 0;
var destroyed: usize = 0;
var unavailable = false;
var receive_timeout = false;
var send_result: c_int = 0;
var wire: [2048]u8 = undefined;
var wire_len: usize = 0;
pub export fn __sys_task_self_trap() c_uint {
    return 16;
}
pub export fn __sys_mach_reply_port() c_uint {
    return 17;
}
pub export fn __sys__kernelrpc_mach_port_deallocate_trap(task: c_uint, port: c_uint) c_int {
    std.debug.assert(task == 16 and (port == 100 or port == 101));
    released += 1;
    return 0;
}
pub export fn __sys__kernelrpc_mach_port_destroy_trap(task: c_uint, port: c_uint) c_int {
    std.debug.assert(task == 16 and port == 17);
    destroyed += 1;
    return 0;
}
pub export fn __sys_mach_msg_trap(h: *c.mach_msg_header_t, options: c_uint, size: c_uint, capacity: c_uint, port: c_uint, timeout: c_uint, notify: c_uint) c_int {
    std.debug.assert(notify == 0);
    const bytes: [*]u8 = @ptrCast(h);
    const descriptor_offset = @sizeOf(c.mach_msg_header_t) + @sizeOf(c.mach_msg_body_t);
    if (options & c.MACH_SEND_MSG != 0) {
        id = h.msgh_id;
        std.debug.assert(size == h.msgh_size and options & c.MACH_SEND_TIMEOUT != 0);
        if (id == 118) {
            std.debug.assert(timeout == 0 and h.msgh_remote_port == 101);
            const ool = bytes + descriptor_offset;
            std.debug.assert(ool[8] == 0 and ool[9] == c.MACH_MSG_VIRTUAL_COPY and ool[11] == c.MACH_MSG_OOL_DESCRIPTOR);
            const address = std.mem.readInt(u64, ool[0..8], .little);
            const record: [*:0]const u8 = @ptrFromInt(address);
            const value = std.mem.span(record);
            std.debug.assert(std.mem.readInt(u32, ool[12..16], .little) == value.len + 1);
            @memcpy(wire[0..value.len], value);
            wire_len = value.len;
            sends += 1;
            return send_result;
        }
        std.debug.assert(timeout == 100 and (id == 3409 or id == 404));
        return 0;
    }
    std.debug.assert(options == c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT and timeout == 100 and port == 17 and capacity >= 40);
    if (receive_timeout) return c.MACH_RCV_TIMED_OUT;
    h.* = std.mem.zeroes(c.mach_msg_header_t);
    h.msgh_id = id + 100;
    if (unavailable) return 0; // MIG error reply without a port.
    h.msgh_bits = c.MACH_MSGH_BITS_COMPLEX;
    h.msgh_size = @intCast(descriptor_offset + 12);
    const body: *align(1) c.mach_msg_body_t = @ptrCast(bytes + @sizeOf(c.mach_msg_header_t));
    body.msgh_descriptor_count = 1;
    const desc = bytes + descriptor_offset;
    @memset(desc[0..12], 0);
    std.mem.writeInt(u32, desc[0..4], if (id == 3409) 100 else 101, .little);
    desc[10] = c.MACH_MSG_TYPE_PORT_SEND;
    desc[11] = c.MACH_MSG_PORT_DESCRIPTOR;
    return 0;
}
fn reset() void {
    sends = 0;
    released = 0;
    destroyed = 0;
    wire_len = 0;
    unavailable = false;
    receive_timeout = false;
    send_result = 0;
}
test "one escaped ASL record and no retry on a full queue or dead destination" {
    for ([_]c_int{ 0, c.MACH_SEND_TIMED_OUT, c.MACH_SEND_INVALID_DEST }) |result| {
        reset();
        send_result = result;
        c.__error().* = c.EDOM;
        _simple_asl_log_prog(5, "com.apple.libsystem.libdispatch", "brackets[]\\\n\r", "fixture");
        try std.testing.expectEqual(@as(usize, 1), sends);
        try std.testing.expectEqual(@as(usize, 2), released);
        try std.testing.expectEqual(@as(usize, 1), destroyed);
        try std.testing.expectEqual(c.EDOM, c.__error().*);
        const record = wire[0..wire_len];
        try std.testing.expect(std.mem.indexOf(u8, record, "[Level 5]") != null);
        try std.testing.expect(std.mem.indexOf(u8, record, "[Facility com.apple.libsystem.libdispatch]") != null);
        try std.testing.expect(std.mem.indexOf(u8, record, "[Sender fixture]") != null);
        try std.testing.expect(std.mem.indexOf(u8, record, "[Message brackets\\[\\]\\\\\\n\\r]") != null);
    }
}
test "unavailable logger and timed out lookup drop without sending" {
    reset();
    unavailable = true;
    _simple_asl_log(5, null, "absent");
    try std.testing.expectEqual(@as(usize, 0), sends);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    reset();
    receive_timeout = true;
    _simple_asl_log(5, null, "late");
    try std.testing.expectEqual(@as(usize, 0), sends);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
}
test "invalid and oversized input drop; default program entry point sends" {
    reset();
    const huge: [4096:0]u8 = @splat('a');
    _simple_asl_log(5, "user", &huge);
    _simple_asl_log(8, "user", "bad level");
    _simple_asl_log(5, "user", null);
    try std.testing.expectEqual(@as(usize, 0), sends);
    try std.testing.expectEqual(@as(usize, 0), destroyed);
    _simple_asl_log(5, null, "default");
    try std.testing.expectEqual(@as(usize, 1), sends);
    try std.testing.expect(std.mem.indexOf(u8, wire[0..wire_len], "[Facility user]") != null);
}
