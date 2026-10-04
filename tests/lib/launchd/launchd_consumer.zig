// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const p = @import("protocol.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/time.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("mach/message.h");
});
fn request(op: p.Operation) p.Reply {
    const fd = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET, 0);
    if (fd < 0) c.atf_tc_fail("launchd control socket creation");
    defer _ = c.close(fd);
    var timeout = c.timeval{ .tv_sec = 8, .tv_usec = 0 };
    if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.timeval)) != 0) c.atf_tc_fail("launchd control timeout");
    var address = std.mem.zeroes(c.sockaddr_un);
    address.sun_len = @sizeOf(c.sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..p.socket_path.len], p.socket_path);
    if (c.connect(fd, @ptrCast(&address), @sizeOf(c.sockaddr_un)) != 0) c.atf_tc_fail("PID-1 test control unavailable");
    const q = p.Request{ .operation = @intFromEnum(op) };
    if (c.send(fd, &q, @sizeOf(p.Request), 0) != @sizeOf(p.Request)) c.atf_tc_fail("launchd control request");
    var reply: p.Reply = undefined;
    if (c.recv(fd, &reply, @sizeOf(p.Reply), 0) != @sizeOf(p.Reply)) c.atf_tc_fail("launchd control reply missing");
    if (reply.magic != 0x48400002 or reply.operation != q.operation or reply.pid != 1 or reply.setup_error != 0) c.atf_tc_fail("launchd fixture setup error=%u pid=%u", reply.setup_error, reply.pid);
    return reply;
}
fn observe(name: [*:0]const u8, reply: p.Reply, expected: []const u64) void {
    _ = c.printf("launchd case=%s pid_expected=1 pid_observed=%u\n", name, reply.pid);
    var mismatch = false;
    for (expected, 0..) |want, i| {
        _ = c.printf("launchd case=%s fact=%u expected=%llu observed=%llu\n", name, @as(c_uint, @intCast(i)), want, reply.facts[i]);
        mismatch = mismatch or want != reply.facts[i];
    }
    // The control response is complete before probing the normal public API.
    const rc = c.system("/bin/launchctl list >/var/tmp/op484-launchctl-list 2>&1");
    _ = c.printf("launchd case=%s list_expected=0 list_observed=%d\n", name, rc);
    if (rc != 0 or mismatch) c.atf_tc_fail("launchd consumer observations differ");
}
fn demand(_: [*c]const c.atf_tc_t) callconv(.c) void {
    // Snapshot seen, job removed, no launch of that job or the unrelated job;
    // detach precedes receive-right destruction.
    observe("demand_removed", request(.demand_removed), &.{ 1, 1, 0, 0, 1 });
}
fn drain(_: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = request(.drain_start);
    var reply: p.Reply = undefined;
    for (0..50) |_| {
        _ = c.usleep(100_000);
        reply = request(.drain_observe);
        if (reply.facts[0] != 0) break;
    }
    // Reaped, three unique messages, timeout follows successes, no cap,
    // request/reply buffers allocated and freed.
    observe("drain_all", reply, &.{ 1, 3, 3, 1, 0, 2, 2, c.SIGABRT, c.MACH_RCV_TIMED_OUT, 48410, 48411, 48412 });
}
fn terminal(_: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = request(.terminal_start);
    var reply: p.Reply = undefined;
    for (0..50) |_| {
        _ = c.usleep(100_000);
        reply = request(.terminal_observe);
        if (reply.facts[0] != 0) break;
    }
    // Both jobs reaped; invalid-name and oversize each receive once, no cap,
    // all four buffer allocations freed.
    observe("drain_terminal", reply, &.{ 1, 1, 1, 0, 4, 4, c.SIGABRT, c.SIGABRT, c.MACH_RCV_INVALID_NAME, c.MACH_RCV_TOO_LARGE });
}
fn dead(_: [*c]const c.atf_tc_t) callconv(.c) void {
    // Job absent; real notification; one fixture uref plus notification uref
    // before handling, one afterwards; unrelated send urefs remain three.
    observe("late_dead_name", request(.late_dead_name), &.{ 1, 1, 2, 1, 3, 3 });
}
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [4]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "25");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "demand_removed", "drain_all", "drain_terminal", "late_dead_name" };
    const bodies = .{ &demand, &drain, &terminal, &dead };
    inline for (0..4) |i| {
        const err = c.atf_tc_init(&cases[i], names[i], &head, bodies[i], null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--crash-job")) {
        _ = c.raise(c.SIGABRT);
        return 99;
    }
    return atf_tp_main(argc, argv, &add);
}
