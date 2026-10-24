//! Test-side interposition around unchanged production source, never in libc.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/mach/message.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
    @cInclude("syslog.h");
    @cInclude("dlfcn.h");
    @cInclude("time.h");
});
const Port = *const fn () callconv(.c) c_uint;
pub export fn task_self_trap() c_uint {
    return if (mock) 16 else real(Port, "task_self_trap")();
}
pub export fn mach_reply_port() c_uint {
    return if (mock) 17 else real(Port, "mach_reply_port")();
}
extern fn _kernelrpc_mach_port_deallocate_trap(c_uint, c_uint) c_int;
pub export fn rmx_observe_task() c_uint {
    return if (mock) 16 else task_self_trap();
}
pub export fn rmx_observe_reply() c_uint {
    return if (mock) 17 else mach_reply_port();
}
pub export fn rmx_observe_deallocate(t: c_uint, p: c_uint) c_int {
    return if (mock) 0 else _kernelrpc_mach_port_deallocate_trap(t, p);
}
const Trap = *const fn (*c.mach_msg_header_t, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint) callconv(.c) c_int;
const Overwrite = *const fn (*c.mach_msg_header_t, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, ?*anyopaque, c_uint) callconv(.c) c_int;
const Send = *const fn (c_int, ?*const anyopaque, usize, c_int) callconv(.c) isize;
fn real(comptime T: type, name: [*:0]const u8) T {
    return @ptrCast(@alignCast(c.dlsym(c.RTLD_NEXT, name) orelse @panic("missing real transport")));
}
var active = false;
var verbose = true;
var quiet = false;
pub fn setQuiet(value: bool) void {
    quiet = value;
}
pub fn setVerbose(value: bool) void {
    verbose = value;
}
pub fn controlBegin() void {
    active = true;
}
pub fn controlEnd() void {
    active = false;
}
pub export fn mach_msg_trap(p: *c.mach_msg_header_t, o: c_uint, s: c_uint, r: c_uint, n: c_uint, t: c_uint, x: c_uint) c_int {
    if (!active) return real(Trap, "mach_msg_trap")(p, o, s, r, n, t, x);
    return rmx_observe_trap(p, o, s, r, n, t, x);
}
pub export fn mach_msg_overwrite_trap(p: *c.mach_msg_header_t, o: c_uint, s: c_uint, r: c_uint, n: c_uint, t: c_uint, x: c_uint, tail: ?*anyopaque, scatter: c_uint) c_int {
    const id = p.msgh_id;
    const rc = real(Overwrite, "mach_msg_overwrite_trap")(p, o, s, r, n, t, x, tail, scatter);
    if (active) _ = c.printf("op982_libasl_trap record=%zu request=%d options=%#x kr=%#x\n", current, id, o, @as(c_uint, @bitCast(rc)));
    return rc;
}
pub export fn send(fd: c_int, b: ?*const anyopaque, s: usize, f: c_int) isize {
    if (!active) return real(Send, "send")(fd, b, s, f);
    return rmx_observe_send(fd, b, s, f);
}

extern fn rmx_observed_syslog(c_int, [*:0]const u8, ...) void;
extern fn rmx_observed_openlog([*:0]const u8, c_int, c_int) void;
extern fn rmx_observed_closelog() void;
extern fn rmx_observed_pending() c_uint;
pub fn openlog(tag: [*:0]const u8, opts: c_int, fac: c_int) void {
    if (mock) rmx_observed_openlog(tag, opts, fac) else c.openlog(tag, opts, fac);
}
pub fn closelog() void {
    if (mock) rmx_observed_closelog() else c.closelog();
}
var sequence: usize = 0;
var current: usize = 0;
var mach_ok: usize = 0;
var socket_ok: usize = 0;
var refused: usize = 0;
var before_mach: usize = 0;
var before_socket: usize = 0;
var request_id: c_int = 0;
var logger_port: c_uint = 0;
pub fn loggerPort() c_uint {
    return logger_port;
}
var mock = false;
var use_installed = false;
var receive_failures: usize = 0;
var mock_id: c_int = 0;
pub export fn rmx_observe_trap(p: *c.mach_msg_header_t, options: c_uint, send_size: c_uint, recv_size: c_uint, recv_name: c_uint, timeout: c_uint, notify: c_uint) c_int {
    if (options & c.MACH_SEND_MSG != 0) {
        request_id = p.msgh_id;
        if (request_id == 118) logger_port = p.msgh_remote_port;
    }
    const id = request_id;
    const result = if (mock) mockTrap(p, options) else real(Trap, "mach_msg_trap")(p, options, send_size, recv_size, recv_name, timeout, notify);
    const err = c.__error().*;
    if (options & c.MACH_RCV_MSG != 0 and result == 0 and p.msgh_bits & c.MACH_MSGH_BITS_COMPLEX == 0 and p.msgh_size >= 36) {
        const bytes: [*]const u8 = @ptrCast(p);
        const code = std.mem.readInt(i32, bytes[32..36], .little);
        _ = c.printf("op982_mig_error request=%d code=%d\n", id, code);
    }
    if (options & c.MACH_SEND_MSG != 0 and id == 118 and result == 0) mach_ok += 1;
    if (!quiet and (verbose or result != 0)) _ = c.printf("op982_trap record=%zu request=%d phase=%s kr=%#x errno=%d received_id=%d bits=%#x size=%u\n", current, id, if (options & c.MACH_SEND_MSG != 0) @as([*:0]const u8, "send") else "receive", @as(c_uint, @bitCast(result)), err, p.msgh_id, p.msgh_bits, p.msgh_size);
    c.__error().* = err;
    return result;
}
pub export fn rmx_observe_send(fd: c_int, buffer: ?*const anyopaque, size: usize, flags: c_int) isize {
    const rc = if (mock) @as(isize, @intCast(size)) else real(Send, "send")(fd, buffer, size, flags);
    const err = c.__error().*;
    if (rc >= 0) socket_ok += 1;
    if (!quiet and (verbose or rc < 0)) _ = c.printf("op982_socket record=%zu rc=%zd errno=%d\n", current, rc, if (rc >= 0) @as(c_int, 0) else err);
    c.__error().* = err;
    return rc;
}
pub fn record(priority: c_int, text: [*:0]const u8) void {
    current = sequence;
    sequence += 1;
    before_mach = mach_ok;
    before_socket = socket_ok;
    active = true;
    if (mock and !use_installed) rmx_observed_syslog(priority, "%s", text) else c.syslog(priority, "%s", text);
    active = false;
    const m = mach_ok - before_mach;
    const s = socket_ok - before_socket;
    if (m + s == 0) refused += 1;
    if (!quiet and (verbose or m + s == 0)) _ = c.printf("op982_transport record=%zu mach_success=%zu socket_success=%zu outcome=%s\n", current, m, s, if (m + s == 0) @as([*:0]const u8, "refused") else if (s != 0) @as([*:0]const u8, "socket") else @as([*:0]const u8, "mach"));
}
pub fn totals() [3]usize {
    return .{ mach_ok, socket_ok, refused };
}
fn mockTrap(p: *c.mach_msg_header_t, options: c_uint) c_int {
    if (options & c.MACH_SEND_MSG != 0) {
        mock_id = p.msgh_id;
    } else {
        _ = mock_id;
        receive_failures += 1;
        return c.MACH_RCV_INVALID_NAME;
    }
    return 0;
}
test "a failed Mach lookup leaves the record counted without socket delivery" {
    mock = true;
    rmx_observed_openlog("op982-host", c.LOG_PID, c.LOG_USER);
    record(c.LOG_NOTICE, "test unavailable Mach");
    const t = totals();
    try std.testing.expectEqual(@as(usize, 0), t[0]);
    try std.testing.expectEqual(@as(usize, 0), t[1]);
    try std.testing.expectEqual(@as(usize, 1), t[2]);
    rmx_observed_closelog();
}

test "the installed libc enters the observed Mach client" {
    mock = true;
    use_installed = true;
    const before = receive_failures;
    c.openlog("op982-installed-host", c.LOG_PID, c.LOG_USER);
    record(c.LOG_NOTICE, "actual libc mock transport");
    try std.testing.expectEqual(before + 1, receive_failures);
    c.closelog();
}
test "undelivered applications count once and failed reports wait a second before retrying" {
    mock = true;
    use_installed = false;
    setQuiet(true);
    defer setQuiet(false);
    const pending = rmx_observed_pending();
    try std.testing.expect(pending > 0);
    const before = receive_failures;
    var began: c.struct_timespec = undefined;
    var ended: c.struct_timespec = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.clock_gettime(c.CLOCK_MONOTONIC, &began));
    for (0..20) |_| record(c.LOG_NOTICE, "undelivered application");
    try std.testing.expectEqual(@as(c_int, 0), c.clock_gettime(c.CLOCK_MONOTONIC, &ended));
    const elapsed = (ended.tv_sec - began.tv_sec) * std.time.ns_per_s + ended.tv_nsec - began.tv_nsec;
    try std.testing.expect(elapsed < std.time.ns_per_s);
    try std.testing.expectEqual(pending + 20, rmx_observed_pending());
    // Twenty application lookups plus exactly one failed report attempt.
    try std.testing.expectEqual(before + 21, receive_failures);
}
pub export fn __sys_task_self_trap() c_uint {
    return task_self_trap();
}
pub export fn __sys_mach_reply_port() c_uint {
    return mach_reply_port();
}
pub export fn __sys_mach_msg_trap(p: *c.mach_msg_header_t, o: c_uint, s: c_uint, r: c_uint, n: c_uint, t: c_uint, x: c_uint) c_int {
    return mach_msg_trap(p, o, s, r, n, t, x);
}
pub export fn __sys__kernelrpc_mach_port_destroy_trap(task: c_uint, port: c_uint) c_int {
    if (mock) return 0;
    return real(*const fn (c_uint, c_uint) callconv(.c) c_int, "__sys__kernelrpc_mach_port_destroy_trap")(task, port);
}
