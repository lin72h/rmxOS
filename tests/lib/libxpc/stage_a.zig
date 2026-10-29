// SPDX-License-Identifier: BSD-2-Clause
// xpc-lite-v1 stage A object-core and connection contracts. SDK citations refer to the staged
// macOS 27 xpc/xpc.h. New entry points are looked up at run time so that a
// library without them fails a named check instead of failing to link.
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("OS_OBJECT_USE_OBJC", "0");
    @cInclude("Availability.h");
    @cInclude("xpc/xpc.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("dlfcn.h");
    @cInclude("sys/wait.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("grp.h");
    @cInclude("pthread.h");
    @cInclude("pthread_np.h");
    @cInclude("semaphore.h");
    @cInclude("time.h");
    @cInclude("signal.h");
});
const O = c.xpc_object_t;
extern const _xpc_type_dictionary: u8;
extern const _xpc_type_fd: u8;
const Failure = error{ContractViolation};
fn check(label: []const u8, ok: bool) Failure!void {
    if (!ok) {
        std.debug.print("stage_a FAIL {s}\n", .{label});
        return error.ContractViolation;
    }
}
fn entry(comptime T: type, name: [*:0]const u8) Failure!T {
    const raw = c.dlsym(c.RTLD_DEFAULT, name);
    try check("public entry point available", raw != null);
    return @ptrCast(raw);
}
fn refs(o: O, expected: u32) Failure!void {
    if (builtin.os.tag == .freebsd) {
        const raw = c.dlsym(c.RTLD_DEFAULT, "op211_reference_count");
        try check("consumer fixture reference-count projection available", raw != null);
        const f: *const fn (O) callconv(.c) u32 = @ptrCast(raw);
        const observed = f(o);
        std.debug.print("stage_a refs expected={d} observed={d}\n", .{ expected, observed });
        try check("reference count", observed == expected);
    }
}

// xpc.h:1959-1962: an empty dictionary, +1.
pub fn dictionaryCreateEmpty() !void {
    const create = try entry(*const fn () callconv(.c) O, "xpc_dictionary_create_empty");
    const d = create();
    try check("empty dictionary created", d != null);
    try check("dictionary type", c.xpc_get_type(d) == @as(c.xpc_type_t, @ptrCast(&_xpc_type_dictionary)));
    try check("empty count", c.xpc_dictionary_get_count(d) == 0);
    try refs(d, 1);
    c.xpc_dictionary_set_int64(d, "n", 5);
    try check("usable after creation", c.xpc_dictionary_get_count(d) == 1 and c.xpc_dictionary_get_int64(d, "n") == 5);
    c.xpc_release(d);
}

// xpc.h:2618-2621: the dictionary at key, +0; NULL for another type or no key.
pub fn dictionaryGetDictionary() !void {
    const get = try entry(*const fn (O, [*:0]const u8) callconv(.c) O, "xpc_dictionary_get_dictionary");
    const parent = c.xpc_dictionary_create(null, null, 0);
    const child = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_value(parent, "child", child);
    c.xpc_dictionary_set_string(parent, "text", "not a dictionary");
    try check("dictionary value returned", get(parent, "child") == child);
    try refs(child, 2); // caller and parent; the getter adds none.
    try check("other type returns NULL", get(parent, "text") == null);
    try check("absent key returns NULL", get(parent, "absent") == null);
    c.xpc_release(child);
    try check("borrowed value lives in parent", get(parent, "child") == child);
    c.xpc_release(parent);
}

// xpc.h:971-1028: fd_create holds its own duplicate; fd_dup returns a new
// descriptor the caller owns. Local objects only; no message transport.
pub fn fdLocal() !void {
    const create = try entry(*const fn (c_int) callconv(.c) O, "xpc_fd_create");
    const dup = try entry(*const fn (O) callconv(.c) c_int, "xpc_fd_dup");
    var p: [2]c_int = undefined;
    try check("pipe fixture", c.pipe(&p) == 0);
    const boxed = create(p[0]);
    try check("descriptor boxed", boxed != null);
    try check("fd type", c.xpc_get_type(boxed) == @as(c.xpc_type_t, @ptrCast(&_xpc_type_fd)));
    _ = c.close(p[0]);
    const first = dup(boxed);
    const second = dup(boxed);
    try check("dup returns new descriptors", first >= 0 and second >= 0 and first != second);
    c.xpc_release(boxed);
    var byte: u8 = 'A';
    try check("write", c.write(p[1], &byte, 1) == 1);
    byte = 0;
    try check("caller descriptor outlives object", c.read(first, &byte, 1) == 1 and byte == 'A');
    _ = c.close(first);
    byte = 'B';
    try check("write", c.write(p[1], &byte, 1) == 1);
    byte = 0;
    try check("each dup independent", c.read(second, &byte, 1) == 1 and byte == 'B');
    _ = c.close(second);
    _ = c.close(p[1]);
    try check("invalid descriptor refused", create(-1) == null);
}

// xpc.h:2002-2005: a NULL value removes the key; removing an absent key is a no-op.
pub fn setValueNullRemoves() !void {
    const d = c.xpc_dictionary_create(null, null, 0);
    const v = c.xpc_int64_create(9);
    c.xpc_dictionary_set_value(d, "k", v);
    try refs(v, 2);
    c.xpc_dictionary_set_value(d, "k", null);
    try check("NULL removes the key", c.xpc_dictionary_get_value(d, "k") == null and c.xpc_dictionary_get_count(d) == 0);
    try refs(v, 1);
    c.xpc_dictionary_set_value(d, "absent", null);
    try check("absent removal is a no-op", c.xpc_dictionary_get_count(d) == 0);
    c.xpc_dictionary_set_value(d, "k", v);
    try check("key can be set again", c.xpc_dictionary_get_value(d, "k") == v and c.xpc_dictionary_get_count(d) == 1);
    c.xpc_release(d);
    try refs(v, 1);
    c.xpc_release(v);
}

// rmxOS arrays link through the element: an object is in one array at a time.
// A second insert is refused with a message and leaves both arrays unchanged.
fn insertTwice() u8 {
    const v = c.xpc_string_create("member");
    const a = c.xpc_array_create(null, 0);
    const b = c.xpc_array_create(null, 0);
    c.xpc_array_append_value(a, v);
    c.xpc_array_append_value(b, v);
    c.xpc_array_append_value(a, v);
    c.xpc_array_set_value(b, c.XPC_ARRAY_APPEND, v);
    if (c.xpc_array_get_count(a) != 1 or c.xpc_array_get_value(a, 0) != v) return 1;
    if (c.xpc_array_get_count(b) != 0) return 2;
    c.xpc_release(a);
    // Out of the first array, the object may join another.
    c.xpc_array_append_value(b, v);
    if (c.xpc_array_get_count(b) != 1 or c.xpc_array_get_value(b, 0) != v) return 3;
    c.xpc_release(b);
    c.xpc_release(v);
    return 0;
}
pub fn secondArrayInsertRefused() !void {
    var p: [2]c_int = undefined;
    try check("pipe fixture", c.pipe(&p) == 0);
    const pid = c.fork();
    try check("fork", pid >= 0);
    if (pid == 0) {
        _ = c.close(p[0]);
        _ = c.dup2(p[1], 2);
        c._exit(insertTwice());
    }
    _ = c.close(p[1]);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = c.read(p[0], &buf[len], buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    _ = c.close(p[0]);
    var status: c_int = 0;
    try check("child reaped", c.waitpid(pid, &status, 0) == pid);
    const exited = (status & 0x7f) == 0;
    const code = (status >> 8) & 0xff;
    std.debug.print("stage_a child exited={} code={d} stderr=\"{s}\"\n", .{ exited, code, buf[0..len] });
    try check("child completed", exited);
    try check("first array intact (count 1, same element)", code != 1);
    try check("second insert refused (count 0)", code != 2);
    try check("released element joins another array", code == 0);
    try check("refusal message", std.mem.indexOf(u8, buf[0..len], "already in an array") != null);
}

// ---------------------------------------------------------------------------
// Connections (op-246). Listeners check in with PID 1 launchd and clients look
// the name up through it; each case uses its own name. connection.h citations
// are the staged macOS 27 xpc/connection.h. Blocks are built here by the
// Blocks ABI so a handler can retain the connection it serves, as a Swift
// closure capturing it does.
extern fn xpc_connection_create_mach_service([*:0]const u8, O, u64) O;
extern fn xpc_connection_set_event_handler(O, ?*anyopaque) void;
extern fn xpc_connection_set_target_queue(O, O) void;
extern fn xpc_connection_set_context(O, ?*anyopaque) void;
extern fn xpc_connection_set_finalizer_f(O, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn xpc_connection_resume(O) void;
extern fn xpc_connection_suspend(O) void;
extern fn xpc_connection_cancel(O) void;
extern fn xpc_connection_send_message(O, O) void;
extern fn xpc_connection_send_message_with_reply(O, O, O, ?*anyopaque) void;
extern fn xpc_connection_send_message_with_reply_sync(O, O) O;
extern fn xpc_connection_get_euid(O) u32;
extern fn xpc_connection_get_pid(O) c_int;
extern fn xpc_dictionary_get_audit_token(O, *Token) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern fn dispatch_release(O) void;
extern fn dispatch_get_global_queue(c_long, c_ulong) O;
extern fn dispatch_async_f(O, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn audit_token_to_au32(Token, ?*u32, ?*u32, ?*u32, ?*u32, ?*u32, ?*c_int, ?*c_int, ?*anyopaque) void;
extern const _xpc_error_connection_invalid: u8;
extern const _xpc_error_connection_interrupted: u8;
extern const _xpc_type_connection: u8;
extern var _NSConcreteStackBlock: [32]?*anyopaque;
extern fn _Block_copy(?*const anyopaque) ?*anyopaque;
extern fn _Block_release(?*const anyopaque) void;
const Token = extern struct { val: [8]u32 };
const LISTENER: u64 = 1;
const INVALID: u64 = 1 << 32;
const INTERRUPTED: u64 = (1 << 32) + 1;
const PEER: u64 = (1 << 32) + 2;
const tests_user: u32 = 977;
var self_path: [*:0]const u8 = "stage_a_test";

fn invalidObject() O {
    return @ptrCast(@constCast(&_xpc_error_connection_invalid));
}
fn eventCode(o: O) u64 {
    if (o == invalidObject()) return INVALID;
    if (o == @as(O, @ptrCast(@constCast(&_xpc_error_connection_interrupted)))) return INTERRUPTED;
    if (c.xpc_get_type(o) == @as(c.xpc_type_t, @ptrCast(&_xpc_type_connection))) return PEER;
    return c.xpc_dictionary_get_uint64(o, "value");
}
fn bump(p: *u64) void {
    _ = @atomicRmw(u64, p, .Add, 1, .seq_cst);
}
fn load(p: *u64) u64 {
    return @atomicLoad(u64, p, .seq_cst);
}
fn waitMs(s: *c.sem_t, ms: u64) bool {
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &t);
    const ns: u64 = @as(u64, @intCast(t.tv_nsec)) + ms * 1_000_000;
    t.tv_sec += @intCast(ns / 1_000_000_000);
    t.tv_nsec = @intCast(ns % 1_000_000_000);
    return c.sem_timedwait(s, &t) == 0;
}
fn sleepMs(ms: u32) void {
    _ = c.usleep(ms * 1000);
}

// An ordered record of the events one handler saw.
const Events = struct {
    sem: c.sem_t = undefined,
    log: [512]u64 = @splat(0),
    n: u64 = 0,
    main_thread: u64 = 0,
    fn init(e: *Events) void {
        e.* = .{};
        _ = c.sem_init(&e.sem, 0, 0);
    }
    fn record(e: *Events, o: O) void {
        if (c.pthread_main_np() == 1) bump(&e.main_thread);
        const i = @atomicRmw(u64, &e.n, .Add, 1, .seq_cst);
        if (i < e.log.len) e.log[@intCast(i)] = eventCode(o);
        _ = c.sem_post(&e.sem);
    }
    fn count(e: *Events) u64 {
        return load(&e.n);
    }
    fn waitFor(e: *Events, n: u64, ms: u64) bool {
        var seen: u64 = 0;
        while (seen < n) : (seen += 1) if (!waitMs(&e.sem, ms)) return false;
        return true;
    }
    fn show(e: *Events, label: []const u8) void {
        const n: usize = @intCast(@min(e.count(), 16));
        std.debug.print("stage_a events {s} count={d} log={any}\n", .{ label, e.count(), e.log[0..n] });
    }
};

// Blocks ABI (BlocksRuntime runtime.c): a stack literal with copy/dispose
// helpers, copied to the heap once. `retains` makes the block hold `conn`.
const Fn = *const fn (?*anyopaque, O, O) callconv(.c) void;
const Descriptor = extern struct {
    reserved: c_ulong,
    size: c_ulong,
    copy: *const fn (*Block, *const Block) callconv(.c) void,
    dispose: *const fn (*Block) callconv(.c) void,
};
const Block = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*Block, O) callconv(.c) void,
    descriptor: *const Descriptor,
    f: Fn,
    ctx: ?*anyopaque,
    conn: O,
    retains: bool,
    released: ?*u64,
};
fn blockInvoke(b: *Block, o: O) callconv(.c) void {
    b.f(b.ctx, b.conn, o);
}
fn blockCopy(_: *Block, src: *const Block) callconv(.c) void {
    if (src.retains) _ = c.xpc_retain(src.conn);
}
fn blockDispose(b: *Block) callconv(.c) void {
    if (b.retains) c.xpc_release(b.conn);
    if (b.released) |r| bump(r);
}
const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Block), .copy = &blockCopy, .dispose = &blockDispose };
fn block(f: Fn, ctx: ?*anyopaque, conn: O, retains: bool, released: ?*u64) ?*anyopaque {
    var literal = Block{ .isa = @ptrCast(&_NSConcreteStackBlock), .flags = 1 << 25, .reserved = 0, .invoke = &blockInvoke, .descriptor = &descriptor, .f = f, .ctx = ctx, .conn = conn, .retains = retains, .released = released };
    return _Block_copy(&literal);
}
fn setHandler(conn: O, f: Fn, ctx: ?*anyopaque, retains: bool, released: ?*u64) void {
    const b = block(f, ctx, conn, retains, released);
    xpc_connection_set_event_handler(conn, b);
    _Block_release(b);
}
fn recordEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const e: *Events = @ptrCast(@alignCast(ctx.?));
    e.record(o);
}
fn sendReply(conn: O, value: u64, events: *Events) void {
    const m = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_uint64(m, "value", value);
    const b = block(&recordEvent, events, null, false, null);
    xpc_connection_send_message_with_reply(conn, m, null, b);
    _Block_release(b);
    c.xpc_release(m);
}
fn sendValue(conn: O, value: u64) void {
    const m = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_uint64(m, "value", value);
    xpc_connection_send_message(conn, m);
    c.xpc_release(m);
}
fn exchange(conn: O, value: u64) Failure!void {
    const m = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_uint64(m, "value", value);
    const r = xpc_connection_send_message_with_reply_sync(conn, m);
    c.xpc_release(m);
    try check("reply received", r != null);
    defer c.xpc_release(r);
    std.debug.print("stage_a exchange expected={d} observed={d}\n", .{ value, eventCode(r) });
    try check("reply echoes the request", eventCode(r) == value);
}

// A listener and what its peers did.
const Mode = enum { echo, retain, hold, task, swap, burst, token };
const Server = struct {
    mode: Mode,
    listener: O = null,
    events: Events = .{},
    listener_events: Events = .{},
    peer_sem: c.sem_t = undefined,
    peer: O = null,
    peer_disposed: u64 = 0,
    peer_finalized: u64 = 0,
    finalized_sem: c.sem_t = undefined,
    token: Token = .{ .val = @splat(0) },
    conn_euid: u32 = 0,
    conn_pid: c_int = 0,
};
fn serverInit(s: *Server, mode: Mode) void {
    s.* = .{ .mode = mode };
    s.events.init();
    s.listener_events.init();
    _ = c.sem_init(&s.peer_sem, 0, 0);
    _ = c.sem_init(&s.finalized_sem, 0, 0);
}
fn peerFinalized(ctx: ?*anyopaque) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    bump(&s.peer_finalized);
    _ = c.sem_post(&s.finalized_sem);
}
fn peerEcho(ctx: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (s.mode == .token and eventCode(o) < INVALID) {
        xpc_dictionary_get_audit_token(o, &s.token);
        s.conn_euid = xpc_connection_get_euid(peer);
        s.conn_pid = xpc_connection_get_pid(peer);
    }
    if (s.mode == .burst and eventCode(o) < INVALID) {
        const n = c.xpc_dictionary_get_uint64(o, "burst");
        var i: u64 = 1;
        while (i <= n) : (i += 1) sendValue(peer, i);
    }
    // rmxOS create_reply answers any wire message with an ID; the burst
    // request expects none.
    if (eventCode(o) < INVALID and s.mode != .burst) {
        const r = c.xpc_dictionary_create_reply(o);
        if (r != null) {
            c.xpc_dictionary_set_uint64(r, "value", eventCode(o));
            xpc_connection_send_message(peer, r);
            c.xpc_release(r);
        }
    }
    s.events.record(o);
}
fn swapSecond(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) < INVALID) {
        const i = @atomicRmw(u64, &s.events.n, .Add, 1, .seq_cst);
        if (i < s.events.log.len) s.events.log[@intCast(i)] = 100 + eventCode(o);
        _ = c.sem_post(&s.events.sem);
    }
}
fn swapFirst(ctx: ?*anyopaque, peer: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) >= INVALID) return;
    s.events.record(o);
    // The listener receives the next messages meanwhile.
    sleepMs(300);
    setHandler(peer, &swapSecond, s, false, null);
}
fn setupPeer(ctx: ?*anyopaque) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    const peer = @atomicLoad(O, &s.peer, .seq_cst);
    setHandler(peer, &peerEcho, s, false, &s.peer_disposed);
    xpc_connection_resume(peer);
    if (s.mode == .task) c.xpc_release(peer);
}
fn listenerEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (eventCode(o) != PEER) {
        s.listener_events.record(o);
        return;
    }
    const peer = o;
    switch (s.mode) {
        .echo, .burst, .token => {
            setHandler(peer, &peerEcho, s, false, &s.peer_disposed);
            xpc_connection_resume(peer);
        },
        .retain => {
            xpc_connection_set_context(peer, s);
            xpc_connection_set_finalizer_f(peer, &peerFinalized);
            setHandler(peer, &peerEcho, s, true, &s.peer_disposed);
            xpc_connection_resume(peer);
        },
        .swap => {
            setHandler(peer, &swapFirst, s, false, null);
            xpc_connection_resume(peer);
        },
        // The peer's handler is set later, by the test or from a task.
        .hold, .task => {
            @atomicStore(O, &s.peer, c.xpc_retain(peer), .seq_cst);
            if (s.mode == .task) dispatch_async_f(dispatch_get_global_queue(0, 0), s, &setupPeer);
        },
    }
    _ = c.sem_post(&s.peer_sem);
}
fn serviceName(buf: *[96]u8, tag: []const u8) [*:0]const u8 {
    const n = c.snprintf(buf, buf.len, "org.rmxos.op246.%.*s.%d", @as(c_int, @intCast(tag.len)), tag.ptr, c.getpid());
    std.debug.assert(n > 0 and n < buf.len);
    return @ptrCast(buf);
}
fn listen(s: *Server, name: [*:0]const u8, q: O) Failure!void {
    s.listener = xpc_connection_create_mach_service(name, q, LISTENER);
    try check("listener created", s.listener != null);
    setHandler(s.listener, &listenerEvent, s, false, null);
    xpc_connection_resume(s.listener);
}
fn client(name: [*:0]const u8, q: O, events: *Events) Failure!O {
    const conn = xpc_connection_create_mach_service(name, q, 0);
    try check("client created", conn != null);
    setHandler(conn, &recordEvent, events, false, null);
    return conn;
}
fn stop(conn: O) void {
    if (conn == null) return;
    xpc_connection_cancel(conn);
    c.xpc_release(conn);
}
fn serialQueue() O {
    return dispatch_queue_create("org.rmxos.op246.queue", null);
}

// connection.h:343-366: activation; a second activation has no effect, even on
// a suspended connection.
pub fn activateInactive() !void {
    const activate = try entry(*const fn (O) callconv(.c) void, "xpc_connection_activate");
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "activate");
    var s: Server = undefined;
    serverInit(&s, .echo);
    const q = serialQueue();
    s.listener = xpc_connection_create_mach_service(name, q, LISTENER);
    try check("listener created", s.listener != null);
    setHandler(s.listener, &listenerEvent, &s, false, null);
    activate(s.listener);
    var events: Events = undefined;
    events.init();
    const conn = try client(name, q, &events);
    activate(conn);
    activate(conn);
    try exchange(conn, 7);
    xpc_connection_suspend(conn);
    activate(conn);
    var replies: Events = undefined;
    replies.init();
    sendReply(conn, 8, &replies);
    const held = !replies.waitFor(1, 500);
    std.debug.print("stage_a suspended reply held={}\n", .{held});
    try check("activating a suspended connection has no effect", held);
    xpc_connection_resume(conn);
    try check("reply after resume", replies.waitFor(1, 3000) and replies.log[0] == 8);
    stop(conn);
    stop(s.listener);
    dispatch_release(q);
}

// connection.h:151-155: creation succeeds for an absent name; the look-up at
// activation fails with one INVALID, to the handler and to queued replies. A
// listener whose check-in fails gets one INVALID as well.
pub fn absentServiceInvalid() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "absent");
    const q = serialQueue();
    var events: Events = undefined;
    events.init();
    const conn = xpc_connection_create_mach_service(name, q, 0);
    try check("create returns a connection for an absent name", conn != null);
    setHandler(conn, &recordEvent, &events, false, null);
    var replies: Events = undefined;
    replies.init();
    sendReply(conn, 1, &replies);
    xpc_connection_resume(conn);
    try check("event handler told", events.waitFor(1, 3000));
    try check("queued reply told", replies.waitFor(1, 3000));
    sleepMs(300);
    events.show("client");
    replies.show("reply");
    try check("one INVALID to the event handler", events.count() == 1 and events.log[0] == INVALID);
    try check("one INVALID to the queued reply", replies.count() == 1 and replies.log[0] == INVALID);
    c.xpc_release(conn);

    var buf2: [96]u8 = undefined;
    const taken = serviceName(&buf2, "taken");
    var s: Server = undefined;
    serverInit(&s, .echo);
    try listen(&s, taken, q);
    var probe: Events = undefined;
    probe.init();
    const c2 = try client(taken, q, &probe);
    xpc_connection_resume(c2);
    try exchange(c2, 3);
    stop(c2);
    var second: Server = undefined;
    serverInit(&second, .echo);
    try listen(&second, taken, q);
    try check("second listener told", second.listener_events.waitFor(1, 3000));
    sleepMs(300);
    second.listener_events.show("second listener");
    try check("one INVALID when the check-in fails", second.listener_events.count() == 1 and second.listener_events.log[0] == INVALID);
    c.xpc_release(second.listener);
    stop(s.listener);
    dispatch_release(q);
}

// connection.h:140-145: a NULL target queue is DISPATCH_TARGET_QUEUE_DEFAULT.
// Nothing here drains the main queue.
pub fn defaultTargetQueue() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "default");
    var s: Server = undefined;
    serverInit(&s, .echo);
    try listen(&s, name, null);
    var events: Events = undefined;
    events.init();
    const conn = try client(name, null, &events);
    xpc_connection_resume(conn);
    var replies: Events = undefined;
    replies.init();
    sendReply(conn, 5, &replies);
    try check("reply delivered on the default target queue", replies.waitFor(1, 3000) and replies.log[0] == 5);
    const q = serialQueue();
    var events2: Events = undefined;
    events2.init();
    const conn2 = try client(name, q, &events2);
    xpc_connection_set_target_queue(conn2, null);
    xpc_connection_resume(conn2);
    sendReply(conn2, 6, &replies);
    try check("reply after setting a NULL target queue", replies.waitFor(1, 3000) and replies.log[1] == 6);
    xpc_connection_cancel(conn);
    try check("event delivered on the default target queue", events.waitFor(1, 3000) and events.log[0] == INVALID);
    std.debug.print("stage_a main_thread replies={d} events={d}\n", .{ replies.main_thread, events.main_thread });
    try check("not on the main thread", replies.main_thread == 0 and events.main_thread == 0);
    c.xpc_release(conn);
    stop(conn2);
    stop(s.listener);
    dispatch_release(q);
}

// A new peer holds its messages until it is activated, here from a task after
// the listener's handler has returned.
pub fn peerHoldsUntilActivated() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "hold");
    var s: Server = undefined;
    serverInit(&s, .hold);
    const q = serialQueue();
    try listen(&s, name, q);
    var events: Events = undefined;
    events.init();
    const conn = try client(name, q, &events);
    xpc_connection_resume(conn);
    for (1..4) |i| sendValue(conn, i);
    try check("peer offered to the listener", waitMs(&s.peer_sem, 3000));
    sleepMs(200);
    dispatch_async_f(dispatch_get_global_queue(0, 0), &s, &setupPeer);
    const got = s.events.waitFor(3, 3000);
    s.events.show("peer");
    try check("held messages delivered after activation", got);
    try check("in order", s.events.log[0] == 1 and s.events.log[1] == 2 and s.events.log[2] == 3);
    stop(conn);
    try check("peer INVALID", s.events.waitFor(1, 3000) and s.events.log[3] == INVALID);
    c.xpc_release(s.peer);
    stop(s.listener);
    dispatch_release(q);
}

var client_finalized: c.sem_t = undefined;
fn clientFinalized(_: ?*anyopaque) callconv(.c) void {
    _ = c.sem_post(&client_finalized);
}

// connection.h:333-335: a peer is released after its final INVALID; a
// handler that captures its own connection is released then too.
pub fn peerReleasedAfterInvalid() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "release");
    var s: Server = undefined;
    serverInit(&s, .retain);
    const q = serialQueue();
    try listen(&s, name, q);
    _ = c.sem_init(&client_finalized, 0, 0);
    var events: Events = undefined;
    events.init();
    var disposed: u64 = 0;
    const conn = xpc_connection_create_mach_service(name, q, 0);
    try check("client created", conn != null);
    xpc_connection_set_finalizer_f(conn, &clientFinalized);
    setHandler(conn, &recordEvent, &events, true, &disposed);
    xpc_connection_resume(conn);
    try exchange(conn, 3);
    xpc_connection_cancel(conn);
    c.xpc_release(conn);
    try check("client INVALID", events.waitFor(1, 3000) and events.log[0] == INVALID);
    const freed = waitMs(&client_finalized, 3000);
    std.debug.print("stage_a client finalized={} disposed={d}\n", .{ freed, load(&disposed) });
    try check("a handler capturing its connection does not keep it", freed and load(&disposed) == 1);
    try check("peer INVALID", s.events.waitFor(2, 3000) and s.events.log[1] == INVALID);
    const peer_freed = waitMs(&s.finalized_sem, 3000);
    std.debug.print("stage_a peer finalized={} disposed={d}\n", .{ peer_freed, load(&s.peer_disposed) });
    try check("peer released after its final event while the listener lives", peer_freed and load(&s.peer_disposed) == 1);
    stop(s.listener);
    dispatch_release(q);
}

// Cancel releases the client's rights at once: the server's peer gets INVALID
// while the client still holds its reference.
pub fn cancelNotifiesPeer() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "cancel");
    var s: Server = undefined;
    serverInit(&s, .echo);
    const q = serialQueue();
    try listen(&s, name, q);
    var events: Events = undefined;
    events.init();
    const conn = try client(name, q, &events);
    xpc_connection_resume(conn);
    try exchange(conn, 1);
    xpc_connection_cancel(conn);
    const told = s.events.waitFor(2, 3000);
    s.events.show("peer");
    try check("peer told at cancel", told and s.events.log[1] == INVALID);
    c.xpc_release(conn);
    stop(s.listener);
    dispatch_release(q);
}

// The same with the client in a child process: the child cancels, keeps its
// reference and stays alive; the peer is told before the child exits.
fn cancelRole(name: [*:0]const u8) u8 {
    const conn = xpc_connection_create_mach_service(name, null, 0);
    if (conn == null) return 2;
    var events: Events = undefined;
    events.init();
    setHandler(conn, &recordEvent, &events, false, null);
    xpc_connection_resume(conn);
    exchange(conn, 4) catch return 3;
    xpc_connection_cancel(conn);
    sleepMs(3000);
    c.xpc_release(conn);
    return 0;
}
pub fn cancelNotifiesPeerChild() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "cancelchild");
    var s: Server = undefined;
    serverInit(&s, .echo);
    const q = serialQueue();
    try listen(&s, name, q);
    const child = c.fork();
    try check("fork", child >= 0);
    if (child == 0) {
        const argv = [_:null]?[*:0]const u8{ self_path, "--op257-cancel", name };
        _ = c.execv(self_path, @ptrCast(&argv));
        c._exit(127);
    }
    const told = s.events.waitFor(2, 2500);
    var status: c_int = 0;
    const alive = c.waitpid(child, &status, c.WNOHANG) == 0;
    s.events.show("peer");
    std.debug.print("stage_a child alive_at_invalid={}\n", .{alive});
    var ms: u32 = 0;
    var waited: c_int = if (alive) 0 else child;
    while (waited == 0 and ms < 6000) : (ms += 10) {
        waited = c.waitpid(child, &status, c.WNOHANG);
        if (waited == 0) sleepMs(10);
    }
    if (waited == 0) {
        _ = c.kill(child, c.SIGKILL);
        _ = c.waitpid(child, &status, 0);
    }
    std.debug.print("stage_a child status={d}\n", .{status});
    try check("peer told at cancel", told and s.events.log[0] == 4 and s.events.log[1] == INVALID);
    try check("before the client exits", alive);
    try check("client completed", status == 0);
    stop(s.listener);
    dispatch_release(q);
}

// One connection shared by four threads; the server sets each peer's handler
// from a task; replies go to the default target queue.
var shared_replies: Events = undefined;
var shared_conn: O = null;
fn sender(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const t = @intFromPtr(arg);
    for (0..25) |i| sendReply(shared_conn, t * 100 + i + 1, &shared_replies);
    return null;
}
pub fn concurrentSends() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "concurrent");
    var s: Server = undefined;
    serverInit(&s, .task);
    const q = serialQueue();
    try listen(&s, name, q);
    shared_replies.init();
    var events: Events = undefined;
    events.init();
    shared_conn = try client(name, null, &events);
    xpc_connection_resume(shared_conn);
    var threads: [4]c.pthread_t = undefined;
    for (&threads, 0..) |*t, i| try check("sender thread", c.pthread_create(t, null, &sender, @ptrFromInt(i)) == 0);
    for (threads) |t| _ = c.pthread_join(t, null);
    const all = shared_replies.waitFor(100, 5000);
    shared_replies.show("replies");
    try check("100 replies", all and shared_replies.count() == 100);
    var seen: [400]u8 = @splat(0);
    for (shared_replies.log[0..100]) |v| {
        if (v >= 1 and v < 400) seen[@intCast(v)] += 1;
    }
    var each = true;
    for (0..4) |t| for (0..25) |i| {
        each = each and seen[t * 100 + i + 1] == 1;
    };
    try check("each request answered once", each);
    stop(shared_conn);
    stop(s.listener);
    dispatch_release(q);
}

// Cancel while the handler runs: it finishes, then the INVALID is the only
// further event, then the handler is released.
var running_entered: c.sem_t = undefined;
var running_gate: c.sem_t = undefined;
var running_busy: u64 = 0;
var running_overlap: u64 = 0;
fn blockingEvent(ctx: ?*anyopaque, _: O, o: O) callconv(.c) void {
    const e: *Events = @ptrCast(@alignCast(ctx.?));
    if (@atomicRmw(u64, &running_busy, .Add, 1, .seq_cst) != 0) bump(&running_overlap);
    e.record(o);
    if (e.count() == 1) {
        _ = c.sem_post(&running_entered);
        _ = waitMs(&running_gate, 5000);
    }
    _ = @atomicRmw(u64, &running_busy, .Sub, 1, .seq_cst);
}
pub fn cancelWhileHandlerRuns() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "running");
    var s: Server = undefined;
    serverInit(&s, .burst);
    const q = serialQueue();
    try listen(&s, name, q);
    _ = c.sem_init(&running_entered, 0, 0);
    _ = c.sem_init(&running_gate, 0, 0);
    var events: Events = undefined;
    events.init();
    var disposed: u64 = 0;
    const conn = xpc_connection_create_mach_service(name, q, 0);
    try check("client created", conn != null);
    setHandler(conn, &blockingEvent, &events, false, &disposed);
    xpc_connection_resume(conn);
    const m = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_uint64(m, "burst", 3);
    xpc_connection_send_message(conn, m);
    c.xpc_release(m);
    try check("handler running", waitMs(&running_entered, 3000));
    sleepMs(100);
    xpc_connection_cancel(conn);
    sleepMs(100);
    const during = events.count();
    _ = c.sem_post(&running_gate);
    _ = events.waitFor(2, 3000);
    sleepMs(300);
    events.show("client");
    std.debug.print("stage_a during={d} overlap={d} disposed={d}\n", .{ during, load(&running_overlap), load(&disposed) });
    try check("nothing delivered while the handler runs", during == 1 and load(&running_overlap) == 0);
    try check("INVALID is the only event after cancel", events.count() == 2 and events.log[1] == INVALID);
    try check("handler released after the final event", load(&disposed) == 1);
    c.xpc_release(conn);
    stop(s.listener);
    dispatch_release(q);
}

// connection.h:268-275: a swap from inside the handler takes effect from the
// next event; swaps racing deliveries lose no event and release every block.
var swap_counts: [2]u64 = .{ 0, 0 };
var swap_created: u64 = 0;
var swap_disposed: u64 = 0;
var swap_stop: u32 = 0;
var swap_conn: O = null;
var swap_total: c.sem_t = undefined;
var swap_events: Events = undefined;
fn countA(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    countInto(0, o);
}
fn countB(_: ?*anyopaque, _: O, o: O) callconv(.c) void {
    countInto(1, o);
}
fn countInto(i: usize, o: O) void {
    if (eventCode(o) >= INVALID) {
        swap_events.record(o);
        return;
    }
    bump(&swap_counts[i]);
    _ = c.sem_post(&swap_total);
}
fn swapper(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var i: usize = 0;
    while (@atomicLoad(u32, &swap_stop, .seq_cst) == 0 and i < 100_000) : (i += 1) {
        bump(&swap_created);
        setHandler(swap_conn, if (i % 2 == 0) &countA else &countB, null, false, &swap_disposed);
    }
    return null;
}
pub fn handlerSwapWhileActive() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "swap");
    var s: Server = undefined;
    serverInit(&s, .swap);
    const q = serialQueue();
    try listen(&s, name, q);
    var events: Events = undefined;
    events.init();
    const conn = try client(name, q, &events);
    xpc_connection_resume(conn);
    for (1..4) |i| sendValue(conn, i);
    const got = s.events.waitFor(3, 3000);
    s.events.show("peer");
    try check("three events", got);
    try check("swap inside the handler takes effect from the next event", s.events.log[0] == 1 and s.events.log[1] == 102 and s.events.log[2] == 103);
    stop(conn);

    var b: Server = undefined;
    serverInit(&b, .burst);
    var buf2: [96]u8 = undefined;
    const name2 = serviceName(&buf2, "swaprace");
    try listen(&b, name2, q);
    _ = c.sem_init(&swap_total, 0, 0);
    swap_events.init();
    swap_conn = xpc_connection_create_mach_service(name2, q, 0);
    try check("client created", swap_conn != null);
    bump(&swap_created);
    setHandler(swap_conn, &countA, null, false, &swap_disposed);
    xpc_connection_resume(swap_conn);
    var t: c.pthread_t = undefined;
    try check("swapper thread", c.pthread_create(&t, null, &swapper, null) == 0);
    const m = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_uint64(m, "burst", 200);
    xpc_connection_send_message(swap_conn, m);
    c.xpc_release(m);
    var n: u32 = 0;
    while (n < 200 and waitMs(&swap_total, 5000)) n += 1;
    @atomicStore(u32, &swap_stop, 1, .seq_cst);
    _ = c.pthread_join(t, null);
    xpc_connection_cancel(swap_conn);
    const ended = swap_events.waitFor(1, 3000);
    sleepMs(300);
    std.debug.print("stage_a swaps created={d} disposed={d} a={d} b={d}\n", .{ load(&swap_created), load(&swap_disposed), load(&swap_counts[0]), load(&swap_counts[1]) });
    try check("every message delivered once across swaps", n == 200 and load(&swap_counts[0]) + load(&swap_counts[1]) == 200);
    try check("final INVALID", ended and swap_events.count() == 1);
    try check("every handler block released", load(&swap_created) == load(&swap_disposed));
    c.xpc_release(swap_conn);
    stop(b.listener);
    stop(s.listener);
    dispatch_release(q);
}

// Nothing on standard output: ten messages with stdout on a pipe.
pub fn noStdout() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "stdout");
    var s: Server = undefined;
    serverInit(&s, .echo);
    const q = serialQueue();
    try listen(&s, name, q);
    var events: Events = undefined;
    events.init();
    const conn = try client(name, q, &events);
    xpc_connection_resume(conn);
    var p: [2]c_int = undefined;
    try check("pipe", c.pipe(&p) == 0);
    _ = c.fflush(null);
    const saved = c.dup(1);
    try check("stdout on the pipe", saved >= 0 and c.dup2(p[1], 1) == 1);
    var ok = true;
    for (1..11) |i| exchange(conn, i) catch {
        ok = false;
    };
    _ = c.fflush(null);
    _ = c.dup2(saved, 1);
    _ = c.close(saved);
    _ = c.close(p[1]);
    var out: [4096]u8 = undefined;
    const n = c.read(p[0], &out, out.len);
    _ = c.close(p[0]);
    const len: usize = if (n > 0) @intCast(n) else 0;
    std.debug.print("stage_a stdout bytes={d} first=\"{s}\"\n", .{ len, out[0..@min(len, 80)] });
    try check("ten exchanges", ok);
    try check("standard output stays empty", n == 0);
    stop(conn);
    stop(s.listener);
    dispatch_release(q);
}

// Nothing on standard error either: ten exchanges with stderr on a pipe. The
// exchanges here print nothing themselves.
fn quietExchange(conn: O, value: u64) bool {
    const m = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_uint64(m, "value", value);
    const r = xpc_connection_send_message_with_reply_sync(conn, m);
    c.xpc_release(m);
    if (r == null) return false;
    defer c.xpc_release(r);
    return eventCode(r) == value;
}
pub fn noStderr() !void {
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "stderr");
    var p: [2]c_int = undefined;
    try check("pipe", c.pipe(&p) == 0);
    _ = c.fflush(null);
    const saved = c.dup(2);
    try check("stderr on the pipe", saved >= 0 and c.dup2(p[1], 2) == 2);
    var s: Server = undefined;
    serverInit(&s, .echo);
    const q = serialQueue();
    var ok = true;
    if (xpc_connection_create_mach_service(name, q, LISTENER)) |l| {
        s.listener = l;
        setHandler(l, &listenerEvent, &s, false, null);
        xpc_connection_resume(l);
        var events: Events = undefined;
        events.init();
        if (xpc_connection_create_mach_service(name, q, 0)) |conn| {
            setHandler(conn, &recordEvent, &events, false, null);
            xpc_connection_resume(conn);
            for (1..11) |i| ok = quietExchange(conn, i) and ok;
            stop(conn);
        } else ok = false;
        stop(l);
    } else ok = false;
    sleepMs(200);
    _ = c.fflush(null);
    _ = c.dup2(saved, 2);
    _ = c.close(saved);
    _ = c.close(p[1]);
    var out: [4096]u8 = undefined;
    const n = c.read(p[0], &out, out.len);
    _ = c.close(p[0]);
    const len: usize = if (n > 0) @intCast(n) else 0;
    std.debug.print("stage_a stderr bytes={d} first=\"{s}\"\n", .{ len, out[0..@min(len, 80)] });
    try check("ten exchanges", ok);
    try check("standard error stays empty", n == 0);
    dispatch_release(q);
}

// libbsm accessors on the token a client running as the tests user sent.
fn clientRole(name: [*:0]const u8) u8 {
    const conn = xpc_connection_create_mach_service(name, null, 0);
    if (conn == null) return 2;
    var events: Events = undefined;
    events.init();
    setHandler(conn, &recordEvent, &events, false, null);
    // Look the name up as root: launchd sends a non-root anonymous caller
    // to a per-user bootstrap (core.c:9293), which is not under test.
    xpc_connection_resume(conn);
    const groups = [_]c.gid_t{tests_user};
    if (c.setgroups(1, &groups) != 0 or c.setgid(tests_user) != 0 or c.setuid(tests_user) != 0) return 3;
    const m = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_uint64(m, "value", @intCast(c.getpid()));
    const r = xpc_connection_send_message_with_reply_sync(conn, m);
    if (r == null or eventCode(r) != @as(u64, @intCast(c.getpid()))) return 4;
    return 0;
}
pub fn tokenFields() !void {
    const Get = *const fn (Token) callconv(.c) u32;
    const auid = try entry(Get, "audit_token_to_auid");
    const euid = try entry(Get, "audit_token_to_euid");
    const egid = try entry(Get, "audit_token_to_egid");
    const ruid = try entry(Get, "audit_token_to_ruid");
    const rgid = try entry(Get, "audit_token_to_rgid");
    const pid = try entry(*const fn (Token) callconv(.c) c_int, "audit_token_to_pid");
    const asid = try entry(*const fn (Token) callconv(.c) c_int, "audit_token_to_asid");
    var buf: [96]u8 = undefined;
    const name = serviceName(&buf, "token");
    var s: Server = undefined;
    serverInit(&s, .token);
    const q = serialQueue();
    try listen(&s, name, q);
    const child = c.fork();
    try check("fork", child >= 0);
    if (child == 0) {
        const argv = [_:null]?[*:0]const u8{ self_path, "--op246-client", name };
        _ = c.execv(self_path, @ptrCast(&argv));
        c._exit(127);
    }
    var status: c_int = 0;
    var waited: c_int = 0;
    var ms: u32 = 0;
    while (ms < 8000) : (ms += 10) {
        waited = c.waitpid(child, &status, c.WNOHANG);
        if (waited != 0) break;
        sleepMs(10);
    }
    if (waited == 0) {
        _ = c.kill(child, c.SIGKILL);
        _ = c.waitpid(child, &status, 0);
    }
    std.debug.print("stage_a client status={d}\n", .{status});
    try check("client ran as the tests user and got its reply", waited == child and status == 0);
    try check("server saw the request", s.events.waitFor(1, 1000));
    var a: [7]u32 = undefined;
    var p32: c_int = 0;
    var s32: c_int = 0;
    audit_token_to_au32(s.token, &a[0], &a[1], &a[2], &a[3], &a[4], &p32, &s32, null);
    const got = [_]u32{ auid(s.token), euid(s.token), egid(s.token), ruid(s.token), rgid(s.token) };
    std.debug.print("stage_a token au32={any} pid={d} asid={d} accessors={any} pid={d} asid={d} child={d} conn_euid={d} conn_pid={d}\n", .{ a[0..5], p32, s32, got, pid(s.token), asid(s.token), child, s.conn_euid, s.conn_pid });
    try check("accessors match audit_token_to_au32", std.mem.eql(u32, got[0..], a[0..5]) and pid(s.token) == p32 and asid(s.token) == s32);
    try check("client uid and gid", got[1] == tests_user and got[2] == tests_user and got[3] == tests_user and got[4] == tests_user);
    try check("client pid", pid(s.token) == child);
    try check("connection credentials agree", s.conn_euid == tests_user and s.conn_pid == child);
    stop(s.listener);
    dispatch_release(q);
}

// logd-retention's managed server exits non-zero when its check-in fails: this
// process holds the service name first. The base program runs the parent
// image's logd-retention, staged beside it.
fn exitStatus(text: []const u8) ?i64 {
    if (std.mem.indexOf(u8, text, "\"PID\"") != null) return null;
    const key = "\"LastExitStatus\":";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    var rest = std.mem.trimStart(u8, text[at + key.len ..], " ");
    var end: usize = 0;
    while (end < rest.len and (rest[end] == '-' or (rest[end] >= '0' and rest[end] <= '9'))) end += 1;
    rest = rest[0..end];
    const v = std.fmt.parseInt(i64, rest, 10) catch return null;
    return if (v == 0) null else v;
}
pub fn retentionCheckInFails() !void {
    var s: Server = undefined;
    serverInit(&s, .echo);
    const q = serialQueue();
    try listen(&s, "org.rmxos.logd.retention", q);
    var events: Events = undefined;
    events.init();
    const probe = try client("org.rmxos.logd.retention", q, &events);
    xpc_connection_resume(probe);
    try exchange(probe, 9);
    stop(probe);
    const base = std.mem.startsWith(u8, std.mem.span(self_path), "/usr/tests/op246-base/");
    const program: []const u8 = if (base) "/usr/tests/op246-base/logd-retention" else "/usr/libexec/logd-retention";
    const plist = "/tmp/op246-retention.plist";
    const f = c.fopen(plist, "w");
    try check("job plist", f != null);
    _ = c.fprintf(f, "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>org.rmxos.op246.retention</string><key>ProgramArguments</key><array><string>%.*s</string></array><key>RunAtLoad</key><true/></dict></plist>\n", @as(c_int, @intCast(program.len)), program.ptr);
    _ = c.fclose(f);
    try check("launchctl load", c.system("launchctl load " ++ plist) == 0);
    var status: ?i64 = null;
    var text: [8192]u8 = undefined;
    var len: usize = 0;
    var tries: u32 = 0;
    while (status == null and tries < 50) : (tries += 1) {
        sleepMs(100);
        const pipe = c.popen("launchctl list org.rmxos.op246.retention", "r");
        if (pipe == null) continue;
        len = c.fread(&text, 1, text.len, pipe);
        _ = c.pclose(pipe);
        status = exitStatus(text[0..len]);
    }
    _ = c.system("launchctl unload " ++ plist);
    _ = c.unlink(plist);
    std.debug.print("stage_a retention program={s} status={?d}\n", .{ program, status });
    try check("logd-retention exits 1 when its check-in fails", status != null and status.? == 256);
    stop(s.listener);
    dispatch_release(q);
}

test "dictionaryCreateEmpty" {
    try dictionaryCreateEmpty();
}
test "dictionaryGetDictionary" {
    try dictionaryGetDictionary();
}
test "fdLocal" {
    try fdLocal();
}
test "setValueNullRemoves" {
    try setValueNullRemoves();
}
test "secondArrayInsertRefused" {
    try secondArrayInsertRefused();
}

const atf = if (builtin.is_test) struct {} else @cImport({
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t) c_int;
const names = [_][*:0]const u8{ "dictionaryCreateEmpty", "dictionaryGetDictionary", "fdLocal", "setValueNullRemoves", "secondArrayInsertRefused", "activateInactive", "absentServiceInvalid", "defaultTargetQueue", "peerHoldsUntilActivated", "peerReleasedAfterInvalid", "cancelNotifiesPeer", "cancelNotifiesPeerChild", "concurrentSends", "cancelWhileHandlerRuns", "handlerSwapWhileActive", "noStdout", "noStderr", "tokenFields", "retentionCheckInFails" };
const functions = [_]*const fn () anyerror!void{ &dictionaryCreateEmpty, &dictionaryGetDictionary, &fdLocal, &setValueNullRemoves, &secondArrayInsertRefused, &activateInactive, &absentServiceInvalid, &defaultTargetQueue, &peerHoldsUntilActivated, &peerReleasedAfterInvalid, &cancelNotifiesPeer, &cancelNotifiesPeerChild, &concurrentSends, &cancelWhileHandlerRuns, &handlerSwapWhileActive, &noStdout, &noStderr, &tokenFields, &retentionCheckInFails };
var cases: if (builtin.is_test) void else [names.len]atf.atf_tc_t = undefined;
fn body(t: [*c]const atf.atf_tc_t) callconv(.c) void {
    _ = c.alarm(15);
    for (names, functions) |name, f| if (std.mem.eql(u8, std.mem.span(atf.atf_tc_get_ident(t)), std.mem.span(name))) {
        f() catch atf.atf_tc_fail("stage A contract failed; see named check");
        return;
    };
    atf.atf_tc_fail("unknown case");
}
fn add(tp: [*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t {
    for (names, 0..) |name, i| {
        const err = atf.atf_tc_init(&cases[i], name, null, &body, null, atf.atf_tp_get_config(tp));
        if (atf.atf_is_error(err)) return err;
        _ = atf.atf_tp_add_tc(tp, &cases[i]);
    }
    return atf.atf_no_error();
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    self_path = @ptrCast(argv[0]);
    if (argc == 3 and std.mem.eql(u8, std.mem.span(argv[1]), "--op246-client")) return clientRole(argv[2]);
    if (argc == 3 and std.mem.eql(u8, std.mem.span(argv[1]), "--op257-cancel")) return cancelRole(argv[2]);
    return atf_tp_main(argc, argv, &add);
}
comptime {
    if (!builtin.is_test) @export(&main, .{ .name = "main" });
}
