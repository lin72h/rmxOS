// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("sys/mach/message.h");
    @cInclude("sys/mach/ndr.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("sys/wait.h");
});
extern fn rmx_observed_asl_send([*:0]const u8) c_int;
extern fn rmx_observed_asl_open() c_int;
extern fn rmx_observed_asl_close() void;
var mode: enum { full, rpc_send, rpc_receive, interrupted, invalid_dest, recover, success } = .full;
var request_id: c_int = 0;
var calls: usize = 0;
var sends: usize = 0;
var lookups: usize = 0;
var released: usize = 0;
var waiting = true;
pub export fn rmx_observe_task() c_uint {
    return 16;
}
pub export fn rmx_observe_reply() c_uint {
    return 17;
}
pub export fn rmx_observe_deallocate(_: c_uint, _: c_uint) c_int {
    released += 1;
    return 0;
}
pub export fn __sys__kernelrpc_mach_port_destroy_trap(_: c_uint, _: c_uint) c_int {
    return 0;
}
pub export fn rmx_observe_trap(p: *c.mach_msg_header_t, o: c_uint, _: c_uint, _: c_uint, _: c_uint, t: c_uint, _: c_uint) c_int {
    calls += 1;
    waiting = waiting and o & (c.MACH_SEND_TIMEOUT | c.MACH_RCV_TIMEOUT) == 0 and t == 0;
    if (o & c.MACH_SEND_MSG != 0) {
        request_id = p.msgh_id;
        if (mode == .rpc_send and request_id != 118) return c.MACH_SEND_INTERRUPTED;
        if (request_id == 404) lookups += 1;
        if (request_id == 118) {
            sends += 1;
            const bytes: [*]const u8 = @ptrCast(p);
            waiting = waiting and bytes[36] == 0; // OOL memory stays caller-owned.
            return switch (mode) {
                .full => c.MACH_SEND_TIMED_OUT,
                .interrupted => c.MACH_SEND_INTERRUPTED,
                .invalid_dest => c.MACH_SEND_INVALID_DEST,
                .recover => if (sends == 1) c.MACH_SEND_INTERRUPTED else 0,
                else => 0,
            };
        }
    } else {
        if (mode == .rpc_receive) return c.MACH_RCV_INTERRUPTED;
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
        sends = 0;
        lookups = 0;
        released = 0;
        waiting = true;
        const result = rmx_observed_asl_send("[Message waiting]");
        const expected_sends: usize = switch (which) {
            .rpc_send, .rpc_receive => 0,
            .success => 1,
            else => 2,
        };
        const expected_result: c_int = if (which == .success or which == .recover) 0 else -1;
        const expected_lookups: usize = if (expected_sends == 0) 0 else expected_sends;
        const expected_released: usize = switch (which) {
            .full, .interrupted, .invalid_dest => 2,
            .recover => 1,
            else => 0,
        };
        _ = c.printf("mach_wait_case mode=%d expected_sends=%zu observed_sends=%zu expected_result=%d observed_result=%d lookups=%zu released=%zu no_timeout=%d\n", @as(c_int, @intFromEnum(which)), expected_sends, sends, expected_result, result, lookups, released, @as(c_int, if (waiting) 1 else 0));
        _ = c.fflush(null);
        c._exit(if (waiting and calls <= 8 and sends == expected_sends and lookups == expected_lookups and released == expected_released and result == expected_result) 0 else 1);
    }
    var status: c_int = 0;
    try std.testing.expect(c.waitpid(child, &status, 0) == child);
    try std.testing.expectEqual(@as(c_int, 0), status);
}
test "Mach sends and lookup RPCs wait; every failed log send relooks up and retries once" {
    inline for (std.meta.tags(@TypeOf(mode))) |which| try isolated(which);
}
test "early lookup tolerates failure; close drops the cached server" {
    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        mode = .rpc_receive;
        if (rmx_observed_asl_open() != -1) c._exit(1);
        mode = .success;
        if (rmx_observed_asl_open() != 0) c._exit(2);
        const before = released;
        rmx_observed_asl_close();
        if (released != before + 1) c._exit(3);
        const lookups_before = lookups;
        if (rmx_observed_asl_send("[Message reopened]") != 0 or lookups != lookups_before + 1 or !waiting) c._exit(4);
        c._exit(0);
    }
    var status: c_int = 0;
    try std.testing.expect(c.waitpid(child, &status, 0) == child);
    try std.testing.expectEqual(@as(c_int, 0), status);
}
