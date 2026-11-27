// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("pthread.h");
    @cInclude("stdio.h");
});
extern fn pthread_mach_thread_np(usize) u32;
extern fn dispatch_queue_create([*:0]const u8, ?*anyopaque) ?*anyopaque;
extern fn dispatch_sync_f(?*anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_release(?*anyopaque) void;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn threadPort() u32 {
    return pthread_mach_thread_np(@intFromPtr(c.pthread_self()));
}
fn refs(p: u32) u32 {
    var n: u32 = 0;
    if (c.mach_port_get_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_SEND, &n) != 0) c.atf_tc_fail("thread send query");
    return n;
}
const Context = struct { port: u32, callbacks: usize = 0 };
fn callback(value: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(value.?));
    if (threadPort() != ctx.port) c.atf_tc_fail("sync callback thread port changed");
    ctx.callbacks += 1;
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Queue operations borrow one cached thread send right");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "60");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var ctx = Context{ .port = threadPort() };
    const before = refs(ctx.port);
    const queue = dispatch_queue_create("op672.thread-port", null) orelse c.atf_tc_fail("queue allocation");
    for (0..70000) |_| dispatch_sync_f(queue, &ctx, callback);
    const after = refs(ctx.port);
    dispatch_release(queue);
    _ = c.printf("thread_port queue_operations=%zu expected=%u observed=%u\n", ctx.callbacks, before, after);
    if (before != 1 or after != before or ctx.callbacks != 70000) c.atf_tc_fail("thread send urefs grew before=%u after=%u", before, after);
}

// op-831: the parent's thread port N is a number its forked child never
// looked up (Mach names are descriptors that fork does not copy). The child
// makes a port of its own at N, a receive right with one send right; neither
// its next pthread_mach_thread_np (forkedChildKeepsThreadPort) nor its forking
// thread's end through pthread_exit, which runs the thread-port key's
// destructor (forkedChildThreadExitKeepsPort), may take a reference from it.
// The child reports through a pipe opened before the fork; only the parent
// asserts. Process calls are declared here: sys/wait.h and fcntl.h would
// bring sys/time.h, whose bintime_shift Zig 0.16 cannot translate.
extern fn fork() c_int;
extern fn pipe(*[2]c_int) c_int;
extern fn waitpid(c_int, *c_int, c_int) c_int;
extern fn _exit(c_int) noreturn;
extern fn fcntl(c_int, c_int, ...) c_int;
extern fn read(c_int, [*]u8, usize) isize;
extern fn write(c_int, [*]const u8, usize) isize;
extern fn close(c_int) c_int;
extern fn __error() *c_int;
extern fn getpid() c_int;
extern fn pthread_exit(?*anyopaque) noreturn;
const f_getfd = 1;
const ebadf = 9;
const Ending = enum { call, thread_exit };
const Report = extern struct {
    free: u8 = 0,
    held: u8 = 0,
    called: u8 = 0,
    watched: u8 = 0,
    target: u32 = 0,
    made: u32 = 0,
    again: u32 = 0,
    create: i32 = -1,
    join: i32 = -1,
    receive_kr: i32 = -1,
    receive: u32 = 0,
    send_kr: i32 = -1,
    send: u32 = 0,
};
fn kept(r: *const Report) bool {
    return r.receive_kr == 0 and r.receive == 1 and r.send_kr == 0 and r.send == 1;
}
// Ports take the lowest free number from 16: allocate receive rights until
// one is N, then give N one send right and drop the others (all traps, so the
// child makes no MIG reply port before its checks).
fn holdPort(target: u32, r: *Report) void {
    const task = c.mach_task_self();
    var names: [512]c.mach_port_name_t = undefined;
    var count: usize = 0;
    while (count < names.len) {
        if (c.mach_port_allocate(task, c.MACH_PORT_RIGHT_RECEIVE, &names[count]) != 0) break;
        count += 1;
        if (names[count - 1] == target) {
            r.held = @intFromBool(c.mach_port_insert_right(task, target, target, c.MACH_MSG_TYPE_MAKE_SEND) == 0);
            break;
        }
    }
    r.made = @intCast(count);
    for (names[0..count]) |n| {
        if (n != target) _ = c.mach_port_mod_refs(task, n, c.MACH_PORT_RIGHT_RECEIVE, -1);
    }
}
fn checkPort(target: u32, r: *Report) void {
    const task = c.mach_task_self();
    r.receive_kr = c.mach_port_get_refs(task, target, c.MACH_PORT_RIGHT_RECEIVE, &r.receive);
    r.send_kr = c.mach_port_get_refs(task, target, c.MACH_PORT_RIGHT_SEND, &r.send);
}
fn finish(fd: c_int, r: *const Report) noreturn {
    const bytes = std.mem.asBytes(r);
    _ = write(fd, bytes.ptr, bytes.len);
    _exit(if (kept(r)) 0 else 1);
}
// The watcher's state outlives the forking thread's stack.
const Watch = struct { main: c.pthread_t, target: u32, fd: c_int, r: Report };
var watch: Watch = undefined;
fn watcher(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const w: *Watch = @ptrCast(@alignCast(arg.?));
    // pthread_join returns once the forking thread has ended: its thread
    // specific data destructors have run.
    w.r.join = c.pthread_join(w.main, null);
    w.r.watched = @intFromBool(w.r.join == 0);
    checkPort(w.target, &w.r);
    finish(w.fd, &w.r);
}
fn child(ending: Ending, target: u32, fd: c_int) noreturn {
    var r: Report = .{ .target = target };
    r.free = @intFromBool(fcntl(@intCast(target), f_getfd) == -1 and __error().* == ebadf);
    if (r.free == 1) holdPort(target, &r);
    if (r.held != 1) finish(fd, &r);
    switch (ending) {
        .call => {
            r.again = threadPort();
            r.called = 1;
            checkPort(target, &r);
            finish(fd, &r);
        },
        .thread_exit => {
            watch = .{ .main = c.pthread_self(), .target = target, .fd = fd, .r = r };
            var t: c.pthread_t = undefined;
            watch.r.create = c.pthread_create(&t, null, watcher, &watch);
            if (watch.r.create != 0) finish(fd, &watch.r);
            pthread_exit(null);
        },
    }
}
fn fact(case: [*:0]const u8, name: u32, label: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("op831 case=%s name=%u fact=%s expected=%lld observed=%lld\n", case, name, label, @as(c_longlong, expected), @as(c_longlong, observed));
}
fn readAll(fd: c_int, buf: []u8) usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = read(fd, buf[got..].ptr, buf.len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return got;
}
fn need(ok: bool, text: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", text);
}
fn forkedChild(case: [*:0]const u8, ending: Ending, grandchild: bool) void {
    var n = if (grandchild) 0 else threadPort();
    const before = if (grandchild) 0 else refs(n);
    if (!grandchild) {
        _ = c.printf("op831 case=%s thread_port=%u parent_send_refs=%u pid=%d\n", case, n, before, getpid());
        need(n != 0 and n != 0xffffffff, "the parent's thread port");
    }
    var fds: [2]c_int = undefined;
    need(pipe(&fds) == 0, "report pipe");
    _ = c.fflush(null);
    const pid = fork();
    need(pid >= 0, "fork");
    if (pid == 0) {
        _ = close(fds[0]);
        if (grandchild) {
            const m = threadPort();
            const send = refs(m);
            _ = c.printf("op831 case=%s thread_port=%u parent_send_refs=%u pid=%d\n", case, m, send, getpid());
            _ = c.fflush(null);
            if (m == 0 or m == 0xffffffff or send != 1) _exit(1);
            const nested = fork();
            if (nested == 0) child(.call, m, fds[1]);
            var status: c_int = -1;
            if (nested < 0 or waitpid(nested, &status, 0) != nested) status = -1;
            _ = c.printf("op831 case=%s name=%u fact=grandchild_wait_status expected=0 observed=%d\n", case, m, status);
            _ = c.fflush(null);
            _exit(if (status == 0) 0 else 1);
        }
        child(ending, n, fds[1]);
    }
    _ = close(fds[1]);
    var r: Report = .{};
    const got = readAll(fds[0], std.mem.asBytes(&r));
    _ = close(fds[0]);
    var status: c_int = -1;
    const waited = waitpid(pid, &status, 0);
    if (grandchild) n = r.target;
    fact(case, n, "child_report_bytes", @sizeOf(Report), @intCast(got));
    fact(case, n, "free_in_child", 1, r.free);
    fact(case, n, "child_holds_number", 1, r.held);
    _ = c.printf("op831 case=%s name=%u made=%u again=%u\n", case, n, r.made, r.again);
    switch (ending) {
        .call => fact(case, n, "child_called", 1, r.called),
        .thread_exit => {
            fact(case, n, "watcher_create", 0, r.create);
            fact(case, n, "watcher_join", 0, r.join);
        },
    }
    fact(case, n, "receive_kr", 0, r.receive_kr);
    fact(case, n, "receive_refs", 1, r.receive);
    fact(case, n, "send_kr", 0, r.send_kr);
    fact(case, n, "send_refs", 1, r.send);
    fact(case, n, "child_wait_status", 0, if (waited == pid) status else -1);
    const after = if (grandchild) 0 else refs(n);
    if (!grandchild) fact(case, n, "parent_send_refs_after", before, after);
    _ = c.fflush(null);
    need(got == @sizeOf(Report), "the child's report arrived whole");
    need(r.free == 1 and r.held == 1, "the child did not get the number: free in it, then held by its own port");
    switch (ending) {
        .call => need(r.called == 1, "the child called pthread_mach_thread_np"),
        .thread_exit => need(r.create == 0 and r.join == 0, "the watcher saw the forking thread end"),
    }
    need(r.receive_kr == 0 and r.receive == 1, "the child's port at the number keeps its receive right");
    need(r.send_kr == 0 and r.send == 1, "the child's port at the number keeps one send reference");
    need(waited == pid and status == 0, "the child exits 0");
    if (!grandchild) need(after == before, "the parent's thread port keeps its send references");
}
fn forkedChildKeepsThreadPort(_: [*c]const c.atf_tc_t) callconv(.c) void {
    forkedChild("forkedChildKeepsThreadPort", .call, false);
}
fn forkedChildThreadExitKeepsPort(_: [*c]const c.atf_tc_t) callconv(.c) void {
    forkedChild("forkedChildThreadExitKeepsPort", .thread_exit, false);
}
fn forkFromWorker(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    forkedChild("forkedFromOtherThreadKeepsPort", .call, false);
    return null;
}
fn forkedFromOtherThreadKeepsPort(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var thread: c.pthread_t = undefined;
    need(c.pthread_create(&thread, null, forkFromWorker, null) == 0, "create forking thread");
    need(c.pthread_join(thread, null) == 0, "join forking thread");
}
fn grandchildKeepsPort(_: [*c]const c.atf_tc_t) callconv(.c) void {
    forkedChild("grandchildKeepsPort", .call, true);
}
fn forkHead(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "A forked child's own port at its parent's thread-port number keeps its rights");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
var cases: [5]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "queue_port_steady", "forkedChildKeepsThreadPort", "forkedChildThreadExitKeepsPort", "forkedFromOtherThreadKeepsPort", "grandchildKeepsPort" };
    const heads = [_]*const fn ([*c]c.atf_tc_t) callconv(.c) void{ head, forkHead, forkHead, forkHead, forkHead };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ body, forkedChildKeepsThreadPort, forkedChildThreadExitKeepsPort, forkedFromOtherThreadKeepsPort, grandchildKeepsPort };
    for (&cases, names, heads, bodies) |*tc, name, h, b| {
        var err = c.atf_tc_init(tc, name, h, b, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, add);
}
