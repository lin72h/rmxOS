// SPDX-License-Identifier: BSD-2-Clause
// op-541: observations of select(kqueue) -> Mach port-set RPC -> kevent.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/select.h");
    @cInclude("mach/mach.h");
    @cInclude("pthread.h");
    @cInclude("pthread_np.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
const Atomic = std.atomic.Value(u32);
const limit: u32 = 10_000;
const duration_ms: u64 = 60_000;
const wait_ms: u32 = 2000;
const names = [_][*:0]const u8{ "socket_written", "select_woke", "request_queued", "request_received", "kevent_event", "reply_received" };
const Packet = extern struct {
    header: c.mach_msg_header_t,
    iteration: u64,
    trailer: [128]u8 = @splat(0),
};
var progress: [6]Atomic = .{ Atomic.init(0), Atomic.init(0), Atomic.init(0), Atomic.init(0), Atomic.init(0), Atomic.init(0) };
var stopped = Atomic.init(0);
var error_step = Atomic.init(0);
var error_code = std.atomic.Value(i64).init(0);
var kq: c_int = -1;
var sockets: [2]c_int = .{ -1, -1 };
var request_port: u32 = 0;
var port_set: u32 = 0;
var reply_port: u32 = 0;
fn now() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) c._exit(90);
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
}
fn mark(step: usize, iteration: u32) void {
    progress[step].store(iteration, .release);
}
fn fault(step: u32, code: i64) void {
    // Only the first failing syscall supplies the diagnostic; no cause inference.
    if (error_step.cmpxchgStrong(0, step + 1, .acq_rel, .acquire) == null) error_code.store(code, .release);
    stopped.store(1, .release);
}
fn errnoCode() i64 {
    return -@as(i64, c.__error().*);
}
fn helper(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var iteration: u32 = 1;
    while (stopped.load(.acquire) == 0) : (iteration += 1) {
        var set = std.mem.zeroes(c.fd_set);
        const word: usize = @intCast(@divTrunc(kq, 64));
        set.__fds_bits[word] |= @as(c.__fd_mask, 1) << @as(u6, @intCast(@mod(kq, 64)));
        var timeout = c.struct_timeval{ .tv_sec = 2, .tv_usec = 0 };
        const selected = c.select(kq + 1, &set, null, null, &timeout);
        if (stopped.load(.acquire) != 0) return null;
        if (selected != 1) {
            fault(1, if (selected < 0) errnoCode() else selected);
            return null;
        }
        mark(1, iteration);
        var request = std.mem.zeroes(Packet);
        request.header.msgh_bits = c.MACH_MSG_TYPE_COPY_SEND | (c.MACH_MSG_TYPE_MAKE_SEND_ONCE << 8);
        request.header.msgh_size = @offsetOf(Packet, "trailer");
        request.header.msgh_remote_port = request_port;
        request.header.msgh_local_port = reply_port;
        request.header.msgh_id = 137000;
        request.iteration = iteration;
        const sent = c.mach_msg(&request.header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, request.header.msgh_size, 0, 0, 1000, 0);
        if (sent != 0) {
            fault(2, sent);
            return null;
        }
        mark(2, iteration);
        var reply: Packet = undefined;
        const received = c.mach_msg(&reply.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Packet), reply_port, wait_ms, 0);
        if (received != 0 or reply.header.msgh_id != 137100 or reply.iteration != iteration or reply.header.msgh_size != @offsetOf(Packet, "trailer")) {
            fault(5, if (received != 0) received else -1001);
            return null;
        }
        mark(5, iteration);
    }
    return null;
}
fn port(right: u32, destination: *u32) bool {
    return c.mach_port_allocate(c.mach_task_self(), right, destination) == 0;
}
pub fn main() u8 {
    _ = c.setvbuf(c.stdout(), null, c._IOLBF, 0);
    const started = now();
    _ = c.printf("chain541 begin limit=%u duration_ms=%llu wait_ms=%u threads=2\n", limit, @as(c_ulonglong, duration_ms), wait_ms);
    kq = c.kqueue();
    if (kq < 0 or kq >= c.FD_SETSIZE or c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, &sockets) != 0 or
        !port(c.MACH_PORT_RIGHT_RECEIVE, &request_port) or !port(c.MACH_PORT_RIGHT_PORT_SET, &port_set) or !port(c.MACH_PORT_RIGHT_RECEIVE, &reply_port)) return setupFailure(1);
    defer _ = c.close(kq);
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    defer _ = c.mach_port_destroy(c.mach_task_self(), reply_port);
    defer _ = c.mach_port_destroy(c.mach_task_self(), port_set);
    defer _ = c.mach_port_destroy(c.mach_task_self(), request_port);
    if (c.mach_port_insert_right(c.mach_task_self(), request_port, request_port, c.MACH_MSG_TYPE_MAKE_SEND) != 0 or
        c.mach_port_move_member(c.mach_task_self(), request_port, port_set) != 0) return setupFailure(2);
    var event = std.mem.zeroes(c.struct_kevent);
    event.ident = @intCast(sockets[1]);
    event.filter = c.EVFILT_READ;
    event.flags = c.EV_ADD;
    var zero = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 0 };
    if (c.kevent(kq, &event, 1, null, 0, &zero) != 0) return setupFailure(3);
    var thread: c.pthread_t = undefined;
    const created = c.pthread_create(&thread, null, helper, null);
    if (created != 0) return setupFailure(created);
    var completed: u32 = 0;
    var attempted: u32 = 0;
    while (completed < limit and now() - started < duration_ms) {
        const iteration = completed + 1;
        attempted = iteration;
        var value: u64 = iteration;
        const wrote = c.send(sockets[0], &value, @sizeOf(u64), c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
        if (wrote != @sizeOf(u64)) {
            fault(0, if (wrote < 0) errnoCode() else wrote);
            break;
        }
        mark(0, iteration);
        var request: Packet = undefined;
        const received = c.mach_msg(&request.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Packet), port_set, wait_ms, 0);
        if (received != 0 or request.header.msgh_local_port != request_port or request.header.msgh_id != 137000 or request.iteration != iteration or request.header.msgh_size != @offsetOf(Packet, "trailer")) {
            fault(3, if (received != 0) received else -1002);
            break;
        }
        mark(3, iteration);
        var observed: c.struct_kevent = undefined;
        const events = c.kevent(kq, null, 0, &observed, 1, &zero);
        if (events != 1 or observed.ident != @as(usize, @intCast(sockets[1])) or observed.filter != c.EVFILT_READ or (observed.flags & c.EV_ERROR) != 0) {
            fault(4, if (events < 0) errnoCode() else events);
            break;
        }
        mark(4, iteration);
        var socket_value: u64 = 0;
        const drained = c.recv(sockets[1], &socket_value, @sizeOf(u64), c.MSG_DONTWAIT);
        if (drained != @sizeOf(u64) or socket_value != iteration) {
            fault(4, if (drained < 0) errnoCode() else -1003);
            break;
        }
        var reply = std.mem.zeroes(Packet);
        reply.header.msgh_bits = c.MACH_MSG_TYPE_MOVE_SEND_ONCE;
        reply.header.msgh_size = @offsetOf(Packet, "trailer");
        reply.header.msgh_remote_port = request.header.msgh_remote_port;
        reply.header.msgh_id = 137100;
        reply.iteration = iteration;
        const sent = c.mach_msg(&reply.header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, reply.header.msgh_size, 0, 0, 1000, 0);
        if (sent != 0) {
            fault(5, sent);
            break;
        }
        const round_deadline = now() + wait_ms;
        while (progress[5].load(.acquire) != iteration and stopped.load(.acquire) == 0 and now() < round_deadline) _ = c.usleep(50);
        if (progress[5].load(.acquire) != iteration) {
            fault(5, -1004);
            break;
        }
        completed = iteration;
        if (completed % 1000 == 0) _ = c.printf("chain541 progress iterations=%u elapsed_ms=%llu\n", completed, @as(c_ulonglong, now() - started));
    }
    stopped.store(1, .release);
    var deadline: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 3;
    const joined = c.pthread_timedjoin_np(thread, null, &deadline);
    var stalled: u32 = 0;
    if (completed != attempted) {
        for (&progress, 0..) |*counter, i| {
            if (counter.load(.acquire) != attempted) {
                stalled = @intCast(i + 1);
                break;
            }
        }
    }
    if (stalled != 0) _ = c.printf("chain541 stall iteration=%u first_missing=%s syscall_step=%u syscall_code=%lld\n", attempted, names[stalled - 1], error_step.load(.acquire), @as(c_longlong, error_code.load(.acquire)));
    for (&progress, 0..) |*counter, i| _ = c.printf("chain541 step=%s completed=%u\n", names[i], counter.load(.acquire));
    _ = c.printf("chain541 end iterations=%u attempted=%u elapsed_ms=%llu stalled=%u join_rc=%d limit=%u duration_ms=%llu\n", completed, attempted, @as(c_ulonglong, now() - started), stalled, joined, limit, @as(c_ulonglong, duration_ms));
    // If the bounded join failed, exit without destroying objects used by A.
    if (joined != 0) c._exit(3);
    return if (stalled == 0) 0 else 1;
}
fn setupFailure(code: c_int) u8 {
    _ = c.printf("chain541 setup_error=%d errno=%d\n", code, c.__error().*);
    return 2;
}
