// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("sys/mach/message.h");
    @cInclude("sys/mach/ndr.h");
    @cInclude("unistd.h");
});
extern fn rmx_observed_asl_send([*:0]const u8) c_int;
var mode: enum { full, rpc_send, rpc_receive, interrupted, success } = .full;
var request_id: c_int = 0;
var calls: usize = 0;
var bounded = true;
pub export fn rmx_observe_task() c_uint {
    return 16;
}
pub export fn rmx_observe_reply() c_uint {
    return 17;
}
pub export fn rmx_observe_deallocate(_: c_uint, _: c_uint) c_int {
    return 0;
}
pub export fn __sys__kernelrpc_mach_port_destroy_trap(_: c_uint, _: c_uint) c_int {
    return 0;
}
pub export fn rmx_observe_trap(p: *c.mach_msg_header_t, o: c_uint, _: c_uint, _: c_uint, _: c_uint, t: c_uint, _: c_uint) c_int {
    calls += 1;
    if (o & c.MACH_SEND_MSG != 0) {
        request_id = p.msgh_id;
        bounded = bounded and o & c.MACH_SEND_TIMEOUT != 0 and t <= 100;
        if (mode == .interrupted) return c.MACH_SEND_INTERRUPTED;
        if (mode == .rpc_send and request_id != 118) return c.MACH_SEND_TIMED_OUT;
        if (request_id == 118) return if (mode == .full) c.MACH_SEND_TIMED_OUT else 0;
    } else {
        bounded = bounded and o & c.MACH_RCV_TIMEOUT != 0 and t <= 100;
        if (mode == .rpc_receive) return c.MACH_RCV_TIMED_OUT;
        const bytes: [*]u8 = @ptrCast(p);
        @memset(bytes[0..40], 0);
        p.msgh_id = request_id + 100;
        p.msgh_bits = c.MACH_MSGH_BITS_COMPLEX;
        p.msgh_size = 40;
        std.mem.writeInt(u32, bytes[24..28], 1, .little);
        std.mem.writeInt(u32, bytes[28..32], if (request_id == 3409) 18 else 19, .little);
        bytes[38] = c.MACH_MSG_TYPE_PORT_SEND;
        bytes[39] = c.MACH_MSG_PORT_DESCRIPTOR;
    }
    return 0;
}
fn isolated(which: @TypeOf(mode)) !void {
    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        mode = which;
        calls = 0;
        bounded = true;
        const result = rmx_observed_asl_send("[Message bounded]");
        c._exit(if (bounded and calls <= 5 and (if (which == .success) result == 0 else result == -1)) 0 else 1);
    }
    var status: c_int = 0;
    _ = extern struct {
        extern fn waitpid(c_int, *c_int, c_int) c_int;
    }.waitpid(child, &status, 0);
    try std.testing.expectEqual(@as(c_int, 0), status);
}
test "full queue, lookup send, lookup receive and interruption never select an unbounded Mach operation" {
    try isolated(.full);
    try isolated(.rpc_send);
    try isolated(.rpc_receive);
    try isolated(.interrupted);
    try isolated(.success);
}
