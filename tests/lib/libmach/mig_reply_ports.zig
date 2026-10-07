// SPDX-License-Identifier: BSD-2-Clause
// op-547: runtime facts; expected/observed interpretation is in the host validator.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("mach/mach.h");
    @cInclude("pthread.h");
    @cInclude("pthread_np.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("mig_reply_echo.h");
    @cInclude("mig_reply_kernel.h");
});
extern fn mig_get_reply_port() callconv(.c) u32;
extern fn mig_dealloc_reply_port(u32) callconv(.c) void;
extern fn op547_echo_server(*c.mach_msg_header_t, *c.mach_msg_header_t) callconv(.c) c_int;
const Atomic = std.atomic.Value(u32);
var phase = Atomic.init(0);
var ready = Atomic.init(0);
var stop = Atomic.init(0);
var ports: [2]u32 = .{ 0, 0 };
var completed: [2]u32 = .{ 0, 0 };
var codes: [2]i32 = .{ 0, 0 };
var server_port: u32 = 0;
var mode: []const u8 = "";
fn now() i64 {
    var t: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &t) != 0) c._exit(90);
    return t.tv_sec * 1000 + @divTrunc(t.tv_nsec, 1_000_000);
}
fn wait(a: *Atomic, minimum: u32) bool {
    const begin = now();
    while (a.load(.acquire) < minimum) {
        if (now() - begin > 4000) return false;
        _ = c.usleep(100);
    }
    return true;
}
fn kernel() i32 {
    var info: [52]c_int = @splat(0);
    var count: u32 = c.TASK_THREAD_TIMES_INFO_COUNT;
    return c.op547_kernel_info(c.mach_task_self(), c.TASK_THREAD_TIMES_INFO, &info, &count);
}
pub export fn op547_server_op547_echo_call(_: u32, token: c_int, observed: *c_int) c_int {
    observed.* = token ^ 0x547;
    return 0;
}
fn server(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (stop.load(.acquire) == 0) {
        var input: [1024]u8 align(8) = @splat(0);
        var output: [1024]u8 align(8) = @splat(0);
        const h: *c.mach_msg_header_t = @ptrCast(&input);
        const r = c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, input.len, server_port, 100, 0);
        if (r == c.MACH_RCV_TIMED_OUT) continue;
        if (r != 0) return @ptrFromInt(1);
        const out: *c.mach_msg_header_t = @ptrCast(&output);
        if (op547_echo_server(h, out) == 0) return @ptrFromInt(2);
        if (c.mach_msg(out, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, out.msgh_size, 0, 0, 2000, 0) != 0) return @ptrFromInt(3);
    }
    return null;
}
fn client(context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const index: usize = if (context == null) 0 else 1;
    ports[index] = mig_get_reply_port();
    _ = ready.fetchAdd(1, .release);
    if (!wait(&phase, 1)) {
        codes[index] = -90;
        return null;
    }
    if (std.mem.eql(u8, mode, "identity")) return null;
    if (std.mem.eql(u8, mode, "exit")) {
        codes[index] = kernel();
        return null;
    }
    if (std.mem.eql(u8, mode, "dealloc")) {
        if (index == 0) {
            mig_dealloc_reply_port(ports[0]);
            phase.store(2, .release);
        } else {
            if (!wait(&phase, 3)) {
                codes[1] = -91;
                return null;
            }
            for (0..100) |_| {
                codes[1] = kernel();
                if (codes[1] != 0) break;
                completed[1] += 1;
            }
        }
        return null;
    }
    for (0..5000) |iteration| {
        if (index == 0) {
            var observed: c_int = 0;
            codes[0] = c.op547_echo_call(server_port, @intCast(iteration), &observed);
            if (codes[0] == 0 and observed != (@as(c_int, @intCast(iteration)) ^ 0x547)) codes[0] = -92;
        } else codes[1] = kernel();
        if (codes[index] != 0) break;
        completed[index] += 1;
    }
    return null;
}
fn refs(p: u32, label: [*:0]const u8) void {
    var n: u32 = 0;
    const rc = c.mach_port_get_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_RECEIVE, &n);
    _ = c.printf("mig547 refs phase=%s name=%u rc=%d receive=%u\n", label, p, rc, n);
}
fn join(t: c.pthread_t) void {
    var deadline: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    var result: ?*anyopaque = null;
    const rc = c.pthread_timedjoin_np(t, &result, &deadline);
    _ = c.printf("mig547 join rc=%d result=%zu\n", rc, @intFromPtr(result));
    if (rc != 0) {
        _ = c.fflush(null);
        c._exit(91);
    }
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc != 2) return 64;
    mode = std.mem.span(argv[1]);
    if (!std.mem.eql(u8, mode, "fork") and !std.mem.eql(u8, mode, "exit") and !std.mem.eql(u8, mode, "identity") and !std.mem.eql(u8, mode, "dealloc") and !std.mem.eql(u8, mode, "concurrent")) return 64;
    _ = c.alarm(25); // includes legacy unbounded rights-query MIG calls.
    _ = c.printf("mig547 begin case=%s limit=5000 rpc_ms=2000 wait_ms=4000\n", argv[1]);
    // Allocate the parent's query reply port before worker creation, so rights
    // queries cannot reuse a just-destroyed worker port's name.
    const parent = mig_get_reply_port();
    if (std.mem.eql(u8, mode, "fork")) {
        // Move the parent's cache above the child's initial port allocation range.
        mig_dealloc_reply_port(parent);
        var reserved: [64]u32 = @splat(0);
        for (&reserved) |*p| _ = c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, p);
        const old = mig_get_reply_port();
        const pid = c.fork();
        if (pid == 0) {
            const rc = kernel();
            const own = mig_get_reply_port();
            _ = c.printf("mig547 fork parent_port=%u child_port=%u kernel_rc=%d\n", old, own, rc);
            refs(own, "child");
            _ = c.fflush(null);
            c._exit(0);
        }
        var status: c_int = 0;
        const waited = c.waitpid(pid, &status, 0);
        _ = c.printf("mig547 child waited=%d status=%d\n", @as(c_int, @intFromBool(waited == pid and pid > 0)), status);
    } else {
        var s: c.pthread_t = undefined;
        if (std.mem.eql(u8, mode, "concurrent")) {
            const a = c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &server_port);
            const b = c.mach_port_insert_right(c.mach_task_self(), server_port, server_port, c.MACH_MSG_TYPE_MAKE_SEND);
            _ = c.printf("mig547 server allocate_rc=%d insert_rc=%d\n", a, b);
            const rc = c.pthread_create(&s, null, &server, null);
            _ = c.printf("mig547 create role=server rc=%d\n", rc);
            if (rc != 0) return 92;
        }
        var threads: [2]c.pthread_t = undefined;
        const count: usize = if (std.mem.eql(u8, mode, "exit")) 1 else 2;
        for (0..count) |i| {
            const rc = c.pthread_create(&threads[i], null, &client, if (i == 0) null else @ptrFromInt(1));
            _ = c.printf("mig547 create role=client%zu rc=%d\n", i, rc);
            if (rc != 0) return 92;
        }
        const observed_ready = wait(&ready, @intCast(count));
        _ = c.printf("mig547 ports parent=%u a=%u b=%u ready=%d\n", parent, ports[0], ports[1], @as(c_int, @intFromBool(observed_ready)));
        if (std.mem.eql(u8, mode, "exit")) refs(ports[0], "before_exit");
        if (std.mem.eql(u8, mode, "dealloc")) refs(ports[1], "before_dealloc");
        phase.store(1, .release);
        if (std.mem.eql(u8, mode, "dealloc")) {
            _ = wait(&phase, 2);
            refs(ports[1], "after_dealloc");
            phase.store(3, .release);
        }
        for (0..count) |i| join(threads[i]);
        if (std.mem.eql(u8, mode, "exit")) refs(ports[0], "after_exit");
        _ = c.printf("mig547 calls a_completed=%u a_rc=%d b_completed=%u b_rc=%d\n", completed[0], codes[0], completed[1], codes[1]);
        if (std.mem.eql(u8, mode, "concurrent")) {
            stop.store(1, .release);
            join(s);
        }
    }
    _ = c.printf("mig547 end case=%s\n", argv[1]);
    _ = c.fflush(null);
    return 0;
}
