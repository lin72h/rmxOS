// SPDX-License-Identifier: BSD-2-Clause
// Bounded real queue cycles and native child-server process watchers.
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
    @cInclude("semaphore.h");
    @cInclude("pthread.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
});
const O = ?*anyopaque;
extern fn xpc_connection_create_mach_service([*:0]const u8, O, u64) O;
extern fn xpc_connection_send_message(O, O) void;
extern fn xpc_connection_resume(O) void;
extern fn xpc_connection_suspend(O) void;
extern fn xpc_connection_cancel(O) void;
extern fn xpc_connection_set_finalizer_f(O, *const fn (O) callconv(.c) void) void;
extern fn xpc_release(O) void;
extern fn xpc_dictionary_create(O, O, usize) O;
extern fn xpc_dictionary_set_uint64(O, [*:0]const u8, u64) void;
extern fn xpc_dictionary_get_uint64(O, [*:0]const u8) u64;
extern var _xpc_error_connection_invalid: u8;
extern var _xpc_error_connection_interrupted: u8;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern fn dispatch_async_f(O, O, *const fn (O) callconv(.c) void) void;
extern fn dispatch_sync_f(O, O, *const fn (O) callconv(.c) void) void;
extern fn dispatch_release(O) void;
extern fn op500_local(O) u32;
extern fn op500_recv_queue(O) O;
extern fn op500_send_queue(O) O;
extern fn op500_event_handler(O, O, *const fn (O, O) callconv(.c) void) void;
extern fn op500_reply(O, O, O, O, *const fn (O, O) callconv(.c) void) void;
extern fn op500_pipe_send(O, u32, u32, u64) c_int;
extern fn op507_barrier(O, O, *const fn (O) callconv(.c) void) void;
extern fn op507_proc_pid(O) c_int;
extern fn op507_remote_pid(O) c_int;
const Hooks = extern struct {
    before_handler: ?*const fn (O) callconv(.c) void = null,
    after_receive: ?*const fn (O, c_int) callconv(.c) void = null,
    receive: ?*const fn (*c.mach_msg_header_t, c_int, u32, u32, u32, u32, u32) callconv(.c) c_int = null,
    unpack: ?*const fn (O, usize) callconv(.c) void = null,
    source_cancelled: ?*const fn (O) callconv(.c) void = null,
    port_release: ?*const fn (O, u32, u32) callconv(.c) void = null,
    pending_free: ?*const fn (O) callconv(.c) void = null,
    lookup: ?*const fn (u32, [*:0]const u8, *u32) callconv(.c) c_int = null,
};
extern fn op500_install(*const Hooks) void;
var conn: O = null;
var target: O = null;
var replies: O = null;
var remote: u32 = 0;
var replacement: u32 = 0;
var which: u32 = 0;
var events: c.sem_t = undefined;
var done: c.sem_t = undefined;
var finalized: c.sem_t = undefined;
var reply_done: c.sem_t = undefined;
var acknowledged: c.sem_t = undefined;
var lookups: u64 = 0;
var interruptions: u64 = 0;
var invalids: u64 = 0;
var barriers: u64 = 0;
var valid_replies: u64 = 0;
var pending_calls: u64 = 0;
var pending_interrupted: u64 = 0;
var local_releases: u64 = 0;
var remote_releases: u64 = 0;
var old_releases: u64 = 0;
fn get(p: *u64) u64 {
    return @atomicLoad(u64, p, .seq_cst);
}
fn add(p: *u64) void {
    _ = @atomicRmw(u64, p, .Add, 1, .seq_cst);
}
fn need(ok: bool, msg: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("fixture setup: %s", msg);
}
fn wait(s: *c.sem_t, ms: u64) bool {
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &t);
    const ns: @TypeOf(ms) = @as(u64, @intCast(t.tv_nsec)) + ms * 1_000_000;
    t.tv_sec += @intCast(ns / 1_000_000_000);
    t.tv_nsec = @intCast(ns % 1_000_000_000);
    return c.sem_timedwait(s, &t) == 0;
}
fn port() u32 {
    var p: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) == 0, "receive right");
    need(c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "send right");
    return p;
}
fn lookup(_: u32, name: [*:0]const u8, out: *u32) callconv(.c) c_int {
    if (!std.mem.eql(u8, std.mem.span(name), "op507.fixture.service")) return 1102;
    const n = @atomicRmw(u64, &lookups, .Add, 1, .seq_cst);
    const p = if (n == 0) remote else replacement;
    const kr = c.mach_port_mod_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_SEND, 1);
    if (kr == 0) out.* = p;
    return kr;
}
fn release(p: O, _: u32, kind: u32) callconv(.c) void {
    if (p != conn) return;
    if (kind == 1) add(&remote_releases) else if (kind == 2) add(&local_releases) else if (kind == 3) add(&old_releases);
}
fn final(_: O) callconv(.c) void {
    _ = c.sem_post(&finalized);
}
fn markBarrier(_: O) callconv(.c) void {
    add(&barriers);
}
fn retry(_: O) callconv(.c) void {
    const obj = xpc_dictionary_create(null, null, 0);
    xpc_dictionary_set_uint64(obj, "value", 42);
    xpc_connection_send_message(conn, obj);
    xpc_release(obj);
    op507_barrier(conn, null, &markBarrier);
    _ = c.sem_post(&done);
}
fn thread(_: O) callconv(.c) O {
    retry(null);
    return null;
}
fn event(_: O, obj: O) callconv(.c) void {
    if (obj == @as(O, @ptrCast(&_xpc_error_connection_interrupted))) {
        add(&interruptions);
        _ = c.sem_post(&events);
        if (which == 2 and get(&interruptions) == 1) retry(null);
    } else if (obj == @as(O, @ptrCast(&_xpc_error_connection_invalid))) add(&invalids);
}
fn reply(ctx: O, obj: O) callconv(.c) void {
    if (ctx == null) {
        if (obj != @as(O, @ptrCast(&_xpc_error_connection_invalid)) and obj != @as(O, @ptrCast(&_xpc_error_connection_interrupted)) and xpc_dictionary_get_uint64(obj, "value") == 42) add(&valid_replies);
    } else {
        add(&pending_calls);
        if (obj == @as(O, @ptrCast(&_xpc_error_connection_interrupted))) add(&pending_interrupted);
    }
    _ = c.sem_post(&reply_done);
}
fn noop(_: O) callconv(.c) void {}
fn acknowledge(_: O) callconv(.c) void {
    _ = c.sem_post(&acknowledged);
}
fn fence(q: O) void {
    for (0..2) |_| {
        dispatch_async_f(q, null, &acknowledge);
        need(wait(&acknowledged, 3000), "queue fence exceeded bound");
    }
}
fn setup(mode: u32) void {
    which = mode;
    for ([_]*c.sem_t{ &events, &done, &finalized, &reply_done, &acknowledged }) |s| need(c.sem_init(s, 0, 0) == 0, "semaphore");
    const hooks = Hooks{ .lookup = &lookup, .port_release = &release };
    op500_install(&hooks);
    target = dispatch_queue_create("op507.target", null);
    replies = dispatch_queue_create("op507.replies", null);
    conn = xpc_connection_create_mach_service("op507.fixture.service", target, 0);
    need(conn != null, "named client");
    op500_event_handler(conn, null, &event);
    xpc_connection_set_finalizer_f(conn, &final);
    xpc_connection_resume(conn);
}
fn finish() void {
    xpc_connection_cancel(conn);
    xpc_release(conn);
    need(wait(&finalized, 3000), "final cancellation");
    dispatch_release(target);
    dispatch_release(replies);
}
fn receive(p: u32, ms: u32, respond: bool) bool {
    var bytes: [8192]u8 align(8) = @splat(0);
    const h: *c.mach_msg_header_t = @ptrCast(&bytes);
    if (c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, p, ms, 0) != 0) return false;
    if (respond) {
        const Wire = extern struct { header: c.mach_msg_header_t, size: usize, id: u64 };
        const w: *Wire = @ptrCast(&bytes);
        const obj = xpc_dictionary_create(null, null, 0);
        xpc_dictionary_set_uint64(obj, "value", 42);
        const kr = op500_pipe_send(obj, h.msgh_remote_port, p, w.id);
        xpc_release(obj);
        c.mach_msg_destroy(h);
        return kr == 0;
    }
    c.mach_msg_destroy(h);
    return true;
}
fn report(name: [*:0]const u8, want: []const u64, got: []const u64) void {
    var bad = false;
    for (want, got, 0..) |e, o, i| {
        _ = c.printf("xpc507 case=%s fact=%u expected=%llu observed=%llu\n", name, @as(c_uint, @intCast(i)), e, o);
        bad = bad or e != o;
    }
    if (bad) c.atf_tc_fail("libxpc reconnect observations differ");
}
fn queueCase(mode: u32) void {
    remote = port();
    replacement = port();
    setup(mode);
    need(c.mach_port_mod_refs(c.mach_task_self(), remote, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0, "service interruption");
    need(wait(&events, 3000), "interruption delivered");
    var worker: c.pthread_t = undefined;
    if (mode == 1) {
        xpc_connection_suspend(conn);
        need(c.pthread_create(&worker, null, &thread, null) == 0, "independent sender");
        need(c.pthread_detach(worker) == 0, "detached bounded sender");
    } else if (mode == 3) dispatch_async_f(target, null, &retry);
    const completed = wait(&done, 500);
    const before_lookups = get(&lookups);
    const arrived = receive(replacement, 0, false);
    if (mode == 1) {
        // Rescue occurs only after the observation, on both images.
        xpc_connection_resume(conn);
        if (!completed) need(wait(&done, 3000), "suspension rescue");
    }
    if (!completed and mode != 1) {
        // The event/target cycle cannot be unwound without changing its order.
        // ATF exits this process after the bounded facts; the guest keeps going.
        report(if (mode == 2) "handler_barrier" else "target_barrier", &.{ 1, 2, 1, 1, 1, 1 }, &.{ 0, before_lookups, @intFromBool(arrived), get(&barriers), 0, 0 });
        return;
    }
    finish();
    var refs: u32 = 0;
    _ = c.mach_port_get_refs(c.mach_task_self(), remote, c.MACH_PORT_RIGHT_DEAD_NAME, &refs);
    const old_refs = refs;
    _ = c.mach_port_destroy(c.mach_task_self(), remote);
    _ = c.mach_port_destroy(c.mach_task_self(), replacement);
    report(if (mode == 1) "suspended_barrier" else if (mode == 2) "handler_barrier" else "target_barrier", &.{ 1, 2, 1, 1, 1, 1 }, &.{ @intFromBool(completed), before_lookups, @intFromBool(arrived), get(&barriers), get(&old_releases), old_refs });
}
pub fn suspended() void {
    queueCase(1);
}
pub fn handler() void {
    queueCase(2);
}
pub fn targetQueue() void {
    queueCase(3);
}
const Child = struct { pid: c.pid_t, commands: [2]c_int };
fn childServer(p: u32) Child {
    var fds: [2]c_int = undefined;
    need(c.pipe(&fds) == 0, "child command pipe");
    const pid = c.rfork(c.RFPROC);
    need(pid >= 0, "shared-fd child server");
    if (pid == 0) {
        while (true) {
            var ready = c.struct_pollfd{ .fd = fds[0], .events = c.POLLIN, .revents = 0 };
            if (c.poll(&ready, 1, 10000) <= 0) c._exit(2);
            var cmd: u8 = 0;
            if (c.read(fds[0], &cmd, 1) != 1) c._exit(3);
            if (cmd == 0) c._exit(0);
            if (!receive(p, 2000, true)) c._exit(4);
        }
    }
    return .{ .pid = pid, .commands = fds };
}
fn command(child: Child, cmd: u8) void {
    need(c.write(child.commands[1], &cmd, 1) == 1, "child command");
}
fn reap(child: Child) void {
    var status: c_int = 0;
    var elapsed: u32 = 0;
    while (elapsed < 3000) : (elapsed += 10) {
        const rc = c.waitpid(child.pid, &status, c.WNOHANG);
        if (rc == child.pid) {
            need(status == 0, "child status");
            return;
        }
        need(rc == 0, "wait child");
        _ = c.usleep(10000);
    }
    _ = c.kill(child.pid, c.SIGKILL);
    c.atf_tc_fail("child exit exceeded bound");
}
fn request(ctx: O) void {
    const obj = xpc_dictionary_create(null, null, 0);
    need(obj != null, "request");
    xpc_dictionary_set_uint64(obj, "value", 42);
    op500_reply(conn, obj, replies, ctx, &reply);
    xpc_release(obj);
    fence(op500_send_queue(conn));
}
pub fn processWatcher() void {
    // RFPROC shares the native descriptor group, an existing rmxOS contract.
    // Parent holds the receive rights across exits: only PROC_EXIT can signal B.
    remote = port();
    replacement = port();
    const a = childServer(remote);
    const b = childServer(replacement);
    setup(4);
    request(null);
    command(a, 1);
    need(wait(&reply_done, 3000), "A native reply");
    const saw_a = @intFromBool(op507_remote_pid(conn) == a.pid and op507_proc_pid(conn) == a.pid);
    need(c.mach_port_mod_refs(c.mach_task_self(), remote, c.MACH_PORT_RIGHT_RECEIVE, -1) == 0, "A relinquishes receive right while alive");
    need(wait(&events, 3000), "A send-right death");
    request(null);
    command(b, 1);
    need(wait(&reply_done, 3000), "B native reply");
    const saw_b = @intFromBool(op507_remote_pid(conn) == b.pid);
    const watched_b = @intFromBool(op507_proc_pid(conn) == b.pid);
    request(@ptrFromInt(1));
    command(a, 0);
    reap(a);
    // On base the observed watcher still names A; wait for its wrong event.
    _ = wait(&events, if (watched_b == 0) 2000 else 500);
    const a_events = get(&interruptions) - 1;
    const a_pending = get(&pending_calls);
    command(b, 0);
    reap(b);
    if (watched_b == 1) need(wait(&events, 3000), "B process exit interruption");
    fence(op500_recv_queue(conn));
    fence(replies);
    const b_events = get(&interruptions) - 1 - a_events;
    const total_pending = get(&pending_calls);
    const error_pending = get(&pending_interrupted);
    const bad = get(&invalids);
    finish();
    _ = c.mach_port_destroy(c.mach_task_self(), remote);
    _ = c.mach_port_destroy(c.mach_task_self(), replacement);
    for ([_]Child{ a, b }) |child| for (child.commands) |fd| {
        _ = c.close(fd);
    };
    report("process_watcher", &.{ 1, 1, 1, 0, 0, 1, 1, 1, 0, 2, 1, 1 }, &.{ saw_a, saw_b, watched_b, a_events, a_pending, b_events, total_pending, error_pending, bad, get(&valid_replies), get(&old_releases), get(&local_releases) });
}
