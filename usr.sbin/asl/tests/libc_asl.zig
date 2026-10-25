const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/types.h");
    @cInclude("sys/mach/message.h");
    @cInclude("sys/time.h");
});
extern fn __libc_asl_send([*:0]const u8) c_int;
extern fn __libc_asl_record([*:0]const u8, c_int, c_int, *const c.struct_timeval, [*:0]const u8, [*:0]const u8, u64) ?[*:0]u8;
extern fn rmx_port_reply(*anyopaque, c_int, c_uint) void;
extern fn rmx_asl_bytes(*anyopaque) [*:0]const u8;
extern fn rmx_asl_size(*anyopaque) c_uint;
extern fn rmx_asl_deallocate(*anyopaque) c_uint;
extern fn asl_msg_from_string([*:0]const u8) ?*anyopaque;
extern fn asl_msg_get_val_for_key(*anyopaque, [*:0]const u8) ?[*:0]const u8;
extern fn asl_msg_release(*anyopaque) void;
extern fn free(?*anyopaque) void;
extern fn rmx_test_rpc() c_int;
extern fn __libc_asl_close() void;
var last_id: c_int = 0;
var lookups: usize = 0;
var sends: usize = 0;
var invalidate = false;
var options_ok = true;
var wire_ok = true;
var error_code: c_int = 0;
var short_reply = false;
var wrong_id = false;
var contexts: usize = 0;
var retry_error: c_int = 0;
var last_destination: c_uint = 0;
var context_released: usize = 0;
pub export fn rmx_task_self() c_uint {
    return 16;
}
pub export fn rmx_reply_port() c_uint {
    return 19;
}
pub export fn rmx_port_deallocate(_: c_uint, port: c_uint) c_int {
    if (port == 22) context_released += 1;
    return 0;
}
pub export fn rmx_port_destroy(_: c_uint, _: c_uint) c_int {
    return 0;
}
pub export fn rmx_mach_msg_trap(p: *c.mach_msg_header_t, options: c_uint, send_size: c_uint, _: c_uint, _: c_uint, timeout: c_uint, _: c_uint) c_int {
    options_ok = options_ok and options & c.MACH_SEND_TIMEOUT == 0 and timeout == 0;
    if (options & c.MACH_SEND_MSG != 0) {
        last_id = p.msgh_id;
        last_destination = p.msgh_remote_port;
        if (last_id == 418) {
            contexts += 1;
            const bytes: [*]const u8 = @ptrCast(p);
            std.debug.assert(send_size == 36 and p.msgh_remote_port == 20);
            std.debug.assert(std.mem.readInt(u32, bytes[32..36], .little) == 0);
        }
        wire_ok = wire_ok and p.msgh_size == send_size;
        if (last_id == 118) {
            sends += 1;
            wire_ok = wire_ok and rmx_asl_deallocate(p) == 0 and rmx_asl_size(p) == 16 and std.mem.eql(u8, std.mem.span(rmx_asl_bytes(p)), "[Message hello]");
            if (invalidate) {
                invalidate = false;
                return c.MACH_SEND_INVALID_DEST;
            }
        } else if (last_id == 404) lookups += 1;
    } else {
        rmx_port_reply(p, last_id, if (last_id == 3409) 20 else if (last_id == 418) 22 else 21);
        if (last_id == 404) {
            const code = if (last_destination == 22) retry_error else error_code;
            if (code != 0) {
                p.msgh_bits = 0x1200;
                p.msgh_size = 36;
                const bytes: [*]u8 = @ptrCast(p);
                @memcpy(bytes[24..32], &[_]u8{ 0, 0, 0, 0, 1, 0, 0, 0 });
                std.mem.writeInt(i32, bytes[32..36], code, .little);
            }
            if (short_reply) p.msgh_size = 32;
            if (wrong_id) p.msgh_id += 1;
        }
    }
    return 0;
}
test "reply classifier accepts success and MIG errors, refuses short and wrong-id replies" {
    defer {
        error_code = 0;
        short_reply = false;
        wrong_id = false;
    }
    try std.testing.expectEqual(@as(c_int, 0), rmx_test_rpc());
    for ([_]c_int{ 1099, 1102 }) |code| {
        error_code = code;
        try std.testing.expectEqual(code, rmx_test_rpc());
    }
    short_reply = true;
    try std.testing.expectEqual(@as(c_int, -1), rmx_test_rpc());
    short_reply = false;
    wrong_id = true;
    try std.testing.expectEqual(@as(c_int, -1), rmx_test_rpc());
}
test "per-user retry is once only and releases the context on success and failure" {
    defer {
        error_code = 0;
        retry_error = 0;
        __libc_asl_close();
    }
    for ([_]c_int{ 0, 1099, 1102 }) |code| {
        __libc_asl_close();
        error_code = 1099;
        retry_error = code;
        contexts = 0;
        context_released = 0;
        const rc = __libc_asl_send("[Message hello]");
        try std.testing.expectEqual(code == 0, rc == 0);
        try std.testing.expectEqual(@as(usize, 1), contexts);
        try std.testing.expectEqual(contexts, context_released);
    }
    __libc_asl_close();
    contexts = 0;
    error_code = 1102;
    try std.testing.expectEqual(@as(c_int, -1), __libc_asl_send("[Message hello]"));
    try std.testing.expectEqual(@as(usize, 0), contexts);
}
test "ASL transport caches lookup and retries only a dead destination without timeouts" {
    __libc_asl_close();
    lookups = 0;
    sends = 0;
    try std.testing.expectEqual(@as(c_int, 0), __libc_asl_send("[Message hello]"));
    try std.testing.expectEqual(@as(c_int, 0), __libc_asl_send("[Message hello]"));
    try std.testing.expectEqual(@as(usize, 1), lookups);
    invalidate = true;
    try std.testing.expectEqual(@as(c_int, 0), __libc_asl_send("[Message hello]"));
    try std.testing.expectEqual(@as(usize, 2), lookups);
    try std.testing.expectEqual(@as(usize, 4), sends);
    try std.testing.expect(options_ok and wire_ok);
}
test "ASL formatter round trips delimiters, identity and native loss metadata" {
    const time = c.struct_timeval{ .tv_sec = 100, .tv_usec = 123456 };
    const raw = __libc_asl_record("sender[child]", 42, 14, &time, "host", "brackets ] [ slash \\ and\nnewline", 7) orelse return error.Allocation;
    defer free(raw);
    const msg = asl_msg_from_string(raw) orelse return error.Parse;
    defer asl_msg_release(msg);
    for ([_][2][*:0]const u8{ .{ "Sender", "sender[child]" }, .{ "Message", "brackets ] [ slash \\ and\nnewline" }, .{ "Facility", "user" }, .{ "TimeNanoSec", "123456000" }, .{ "com.rmxos.syslog.sender_dropped", "7" } }) |pair| {
        try std.testing.expectEqualStrings(std.mem.span(pair[1]), std.mem.span(asl_msg_get_val_for_key(msg, pair[0]).?));
    }
    try std.testing.expect(asl_msg_get_val_for_key(msg, "RFC5424.Timestamp") == null);
}
