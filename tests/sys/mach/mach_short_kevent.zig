// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("pthread.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("sys/mach/message.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
const Message = extern struct { header: Header, payload: [64]u8 };
var tc: c.atf_tc_t = undefined;
var boundary: [7]c.atf_tc_t = undefined;
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
    const add = c.atf_tp_add_tc(tp, &tc);
    if (c.atf_is_error(add)) return add;
    for ([_][*:0]const u8{ "large_port", "large_set", "audit_boundary", "context_boundary", "reply_route", "wait_large", "queued_member" }, 0..) |name, i| {
        const e = c.atf_tc_init(&boundary[i], name, &head, if (i == 4) &replyBody else if (i == 5) &waitBody else if (i == 6) &memberBody else &boundaryBody, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        const a = c.atf_tp_add_tc(tp, &boundary[i]);
        if (c.atf_is_error(a)) return a;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
fn boundaryBody(t: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = c.atf_tc_get_ident(t);
    const is_set = c.strcmp(name, "large_set") == 0;
    const audit = c.strcmp(name, "audit_boundary") == 0;
    const context = c.strcmp(name, "context_boundary") == 0;
    var port: u32 = 0;
    var pset: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &port) != 0) c.atf_tc_fail("receive setup failed");
    var receive = port;
    if (is_set) {
        if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &pset) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), port, pset) != 0) c.atf_tc_fail("set setup failed");
        receive = pset;
    }
    var sent = Message{ .header = .{ .bits = 20, .size = @sizeOf(Message), .remote = port, .local = 0, .voucher = 0, .id = 44702 }, .payload = [_]u8{0x5a} ** 64 };
    if (c.syscall(c.SYS_mach_msg_trap, &sent, @as(c_uint, 1), @as(c_uint, @sizeOf(Message)), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) != 0) c.atf_tc_fail("send failed");
    var wire: [192]u8 align(8) = [_]u8{0xa5} ** 192;
    const trailer: u32 = if (audit) @sizeOf(c.mach_msg_audit_trailer_t) else if (context) @sizeOf(c.mach_msg_context_trailer_t) else @sizeOf(c.mach_msg_trailer_t);
    const elements: u32 = if (audit) 3 else if (context) 4 else 0;
    const options: u32 = 0x102 | 4 | 8 | (elements << 24);
    const capacity: u32 = if (audit or context) @sizeOf(Message) + trailer - 1 else 8;
    const short = c.syscall(c.SYS_mach_msg_trap, &wire, options, @as(c_uint, 0), capacity, receive, @as(c_uint, 0), @as(c_uint, 0));
    const header: *Header = @ptrCast(&wire);
    var canary = true;
    for (wire[capacity..]) |byte| {
        if (byte != 0xa5) canary = false;
    }
    _ = c.printf("receive_large expected_result=0x10004004 observed_result=0x%x expected_size=%u observed_size=%u expected_canary=1 observed_canary=%d trailer=%u\n", short, @as(c_uint, @sizeOf(Message)), header.size, @as(c_int, @intFromBool(canary)), trailer);
    if (short != 0x10004004 or header.size != @sizeOf(Message) or !canary) c.atf_tc_fail("LARGE size or receive boundary differs");
    if (!audit and !context) {
        const fault = c.syscall(c.SYS_mach_msg_trap, @as(*anyopaque, @ptrFromInt(1)), options, @as(c_uint, 0), @as(c_uint, 8), receive, @as(c_uint, 0), @as(c_uint, 0));
        if (fault != 0x10004008) c.atf_tc_fail("LARGE size copyout fault did not return INVALID_DATA");
    }
    wire = [_]u8{0xa5} ** 192;
    const exact = c.syscall(c.SYS_mach_msg_trap, &wire, options, @as(c_uint, 0), @as(c_uint, @sizeOf(Message)) + trailer, receive, @as(c_uint, 0), @as(c_uint, 0));
    if (exact != 0 or header.id != 44702) c.atf_tc_fail("LARGE retry did not receive the retained message");
    for (wire[@sizeOf(Message) + trailer ..]) |byte| {
        if (byte != 0xa5) c.atf_tc_fail("exact receive overwrote canary");
    }
    const words: *[48]u32 = @ptrCast(&wire);
    if (words[23] != trailer) c.atf_tc_fail("requested trailer size differs");
    if (audit or context) {
        if (words[32] != @as(u32, @intCast(c.getpid()))) c.atf_tc_fail("audit trailer lost send-time pid");
    }
    if (context) {
        const value: *align(4) const u64 = @ptrCast(&wire[@sizeOf(Message) + @offsetOf(c.mach_msg_context_trailer_t, "msgh_context")]);
        if (value.* != 0) c.atf_tc_fail("default receive context differs");
    }
    const empty = c.syscall(c.SYS_mach_msg_trap, &wire, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, wire.len), receive, @as(c_uint, 0), @as(c_uint, 0));
    if (empty != 0x10004003) c.atf_tc_fail("message delivered more than once");
}
var reply_name: u32 = 0;
fn replyReceive(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var wire: [128]u32 = [_]u32{0} ** 128;
    for (0..2) |i| {
        const rc = c.syscall(c.SYS_mach_msg_trap, &wire, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, @sizeOf(@TypeOf(wire))), reply_name, @as(c_uint, 500), @as(c_uint, 0));
        _ = c.printf("mig_reply expected_result=0 observed_result=0x%x expected_id=%u observed_id=%u expected_error=-303 observed_error=%d\n", rc, @as(c_uint, @intCast(123550 + i)), wire[5], @as(i32, @bitCast(wire[8])));
        if (rc != 0 or wire[5] != 123550 + i or @as(i32, @bitCast(wire[8])) != -303) return @ptrFromInt(1);
    }
    return null;
}
fn replyBody(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const task = c.syscall(c.SYS_task_self_trap);
    var reply_port: u32 = 0;
    var unrelated: u32 = 0;
    var pset: u32 = 0;
    if (task <= 0 or c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &reply_port) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &unrelated) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &pset) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), reply_port, pset) != 0) c.atf_tc_fail("reply ports failed");
    reply_name = pset;
    for (0..2) |i| {
        var request = Header{ .bits = 19 | (21 << 8), .size = 24, .remote = @intCast(task), .local = reply_port, .voucher = 0, .id = @intCast(123450 + i) };
        if (c.syscall(c.SYS_mach_msg_trap, &request, @as(c_uint, 1), @as(c_uint, 24), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) != 0) c.atf_tc_fail("send-only MIG request failed");
    }
    var buffer: [128]u32 = [_]u32{0} ** 128;
    const wrong = c.syscall(c.SYS_mach_msg_trap, &buffer, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, @sizeOf(@TypeOf(buffer))), unrelated, @as(c_uint, 0), @as(c_uint, 0));
    _ = c.printf("unrelated_receive expected_result=0x10004003 observed_result=0x%x\n", wrong);
    if (wrong != 0x10004003) c.atf_tc_fail("MIG reply followed the sending thread instead of its reply port");
    var thread: c.pthread_t = undefined;
    var result: ?*anyopaque = null;
    if (c.pthread_create(&thread, null, &replyReceive, null) != 0 or c.pthread_join(thread, &result) != 0 or result != null) c.atf_tc_fail("another thread did not receive both distinct replies");
    if (c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), reply_port) != 0) c.atf_tc_fail("reply destination cleanup failed");
}
var wait_port: u32 = 0;
var wait_result: c_long = 0;
var wait_wire: [192]u8 align(8) = undefined;
fn waitingReceive(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    wait_wire = [_]u8{0xa5} ** 192;
    wait_result = c.syscall(c.SYS_mach_msg_trap, &wait_wire, @as(c_uint, 0x106), @as(c_uint, 0), @as(c_uint, 8), wait_port, @as(c_uint, 1000), @as(c_uint, 0));
    return null;
}
fn waitBody(_: [*c]const c.atf_tc_t) callconv(.c) void {
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &wait_port) != 0) c.atf_tc_fail("waiting port setup failed");
    var thread: c.pthread_t = undefined;
    if (c.pthread_create(&thread, null, &waitingReceive, null) != 0) c.atf_tc_fail("receiver creation failed");
    // Scheduling stress: this pause normally admits the empty-queue receive first.
    _ = c.usleep(100000);
    var sent = Message{ .header = .{ .bits = 20, .size = @sizeOf(Message), .remote = wait_port, .local = 0, .voucher = 0, .id = 44703 }, .payload = [_]u8{0x5a} ** 64 };
    if (c.syscall(c.SYS_mach_msg_trap, &sent, @as(c_uint, 1), @as(c_uint, @sizeOf(Message)), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) != 0 or c.pthread_join(thread, null) != 0) c.atf_tc_fail("waiting send/join failed");
    const header: *Header = @ptrCast(&wait_wire);
    _ = c.printf("waiting_large expected_result=0x10004004 observed_result=0x%x expected_size=88 observed_size=%u\n", wait_result, header.size);
    if (wait_result != 0x10004004 or header.size != 88) c.atf_tc_fail("waiting LARGE did not report retained body");
    const retry = c.syscall(c.SYS_mach_msg_trap, &wait_wire, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, wait_wire.len), wait_port, @as(c_uint, 0), @as(c_uint, 0));
    if (retry != 0 or header.id != 44703) c.atf_tc_fail("waiting receive consumed the LARGE message");
    waitControls();
}
fn nowMillis() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) c.atf_tc_fail("monotonic clock failed");
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}
var normal_name: u32 = 0;
var normal_timeout: u32 = 1000;
var normal_result: c_long = 0;
fn normalReceive(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var wire: [128]u32 = [_]u32{0} ** 128;
    normal_result = c.syscall(c.SYS_mach_msg_trap, &wire, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, @sizeOf(@TypeOf(wire))), normal_name, normal_timeout, @as(c_uint, 0));
    return null;
}
fn receiveSignal(_: c_int) callconv(.c) void {}
fn waitControls() void {
    _ = c.signal(c.SIGUSR2, &receiveSignal);
    for (0..4) |mode| {
        var port: u32 = 0;
        var pset: u32 = 0;
        if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &port) != 0) c.atf_tc_fail("wait control setup failed");
        normal_name = port;
        normal_timeout = if (mode == 0) 80 else 1000;
        const begin = nowMillis();
        var thread: c.pthread_t = undefined;
        if (c.pthread_create(&thread, null, &normalReceive, null) != 0) c.atf_tc_fail("wait control thread failed");
        if (mode != 0) {
            _ = c.usleep(100000);
            switch (mode) {
                1 => {
                    if (c.pthread_kill(thread, c.SIGUSR2) != 0) c.atf_tc_fail("receiver signal failed");
                },
                2 => {
                    if (c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), port) != 0) c.atf_tc_fail("receiver destruction failed");
                },
                3 => {
                    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &pset) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), port, pset) != 0) c.atf_tc_fail("receiver membership change failed");
                },
                else => unreachable,
            }
        }
        if (c.pthread_join(thread, null) != 0) c.atf_tc_fail("wait control join failed");
        const elapsed = nowMillis() - begin;
        const expected: u32 = switch (mode) {
            0 => 0x10004003,
            1 => 0x10004005,
            2 => 0x10004009,
            3 => 0x10004006,
            else => unreachable,
        };
        _ = c.printf("receive_wait mode=%u expected_result=0x%x observed_result=0x%x elapsed_ms=%lld\n", @as(c_uint, @intCast(mode)), expected, normal_result, @as(c_longlong, elapsed));
        if (normal_result != expected or elapsed > 800 or (mode == 0 and elapsed < 50)) c.atf_tc_fail("receive wait lost cancellation or monotonic timeout");
        if (mode != 2) _ = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), port);
        if (pset != 0) _ = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), pset);
    }
}
fn memberBody(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var port: u32 = 0;
    var pset: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &port) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &pset) != 0) c.atf_tc_fail("queued member setup failed");
    var sent = Header{ .bits = 20, .size = 24, .remote = port, .local = 0, .voucher = 0, .id = 44704 };
    if (c.syscall(c.SYS_mach_msg_trap, &sent, @as(c_uint, 1), @as(c_uint, 24), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) != 0) c.atf_tc_fail("queued member send failed");
    normal_name = pset;
    normal_timeout = 1000;
    var receiver: c.pthread_t = undefined;
    if (c.pthread_create(&receiver, null, &normalReceive, null) != 0) c.atf_tc_fail("set receiver failed");
    _ = c.usleep(100000);
    if (c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), port, pset) != 0 or c.pthread_join(receiver, null) != 0) c.atf_tc_fail("queued membership/join failed");
    _ = c.printf("queued_member expected_result=0 observed_result=0x%x\n", normal_result);
    if (normal_result != 0) c.atf_tc_fail("queued member did not wake its set receiver");
}
