// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
    @cInclude("pthread.h");
    @cInclude("time.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{ "scans", "native_modes", "members", "attach_enqueue", "buffers", "silent_close" };
var cases: [names.len]c.atf_tc_t = undefined;
var current: [*:0]const u8 = undefined;
var index: usize = 0;
var differs = false;
fn fact(expected: i64, observed: i64) void {
    _ = c.printf("mach515 case=%s fact=%zu expected=%lld observed=%lld\n", current, index, @as(c_longlong, expected), @as(c_longlong, observed));
    index += 1;
    if (expected != observed) differs = true;
}
fn boolean(value: bool) void {
    fact(1, @intFromBool(value));
}
fn alloc(right: u32) u32 {
    var name: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), right, &name) != 0) c.atf_tc_fail("readiness fixture allocation failed");
    return name;
}
fn move(port: u32, set: u32) void {
    if (c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), port, set) != 0) c.atf_tc_fail("readiness fixture membership failed");
}
fn send(port: u32, id: u32) void {
    var wire = [_]u32{ 20, 24, port, 0, 0, id };
    if (c.syscall(c.SYS_mach_msg_trap, &wire, @as(c_uint, 1), @as(c_uint, 24), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) != 0) c.atf_tc_fail("readiness fixture send failed");
}
fn receive(name: u32, id: u32) void {
    var wire: [32]u32 = [_]u32{0} ** 32;
    fact(0, c.syscall(c.SYS_mach_msg_trap, &wire, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, @sizeOf(@TypeOf(wire))), name, @as(c_uint, 0), @as(c_uint, 0)));
    fact(id, wire[5]);
}
fn queue() c_int {
    const q = c.kqueue();
    if (q < 0) c.atf_tc_fail("readiness fixture kqueue failed");
    return q;
}
fn change(q: c_int, set: u32, flags: c_int) void {
    var note = c.struct_kevent{ .ident = set, .filter = c.EVFILT_MACHPORT, .flags = @intCast(flags), .fflags = 0, .data = 0, .udata = null, .ext = .{ 0, 0, 0, 0 } };
    if (c.kevent(q, &note, 1, null, 0, null) != 0) c.atf_tc_fail("readiness fixture registration failed");
}
fn event(q: c_int, port: u32, ready: bool) void {
    var note: c.struct_kevent = undefined;
    var timeout = c.struct_timespec{ .tv_sec = 0, .tv_nsec = if (ready) 500000000 else 0 };
    const n = c.kevent(q, null, 0, &note, 1, &timeout);
    fact(if (ready) 1 else 0, n);
    if (ready) {
        fact(port, if (n == 1) note.data else 0);
        fact(0, if (n == 1) note.fflags else -1);
        boolean(n == 1 and note.flags & (c.EV_EOF | c.EV_ERROR) == 0 and note.ext[0] == 0 and note.ext[1] == 0 and note.ext[2] == 0 and note.ext[3] == 0);
    }
}
fn scans() void {
    const p = alloc(1);
    defer _ = c.close(@intCast(p));
    const s = alloc(3);
    defer _ = c.close(@intCast(s));
    move(p, s);
    send(p, 51501);
    send(p, 51502);
    const q = queue();
    defer _ = c.close(q);
    change(q, s, c.EV_ADD);
    event(q, p, true);
    change(q, s, c.EV_ENABLE);
    event(q, p, true);
    change(q, s, c.EV_ADD);
    event(q, p, true);
    event(q, p, true);
    receive(s, 51501);
    event(q, p, true);
    receive(s, 51502);
    event(q, 0, false);
}
fn nativeModes() void {
    for ([_]c_int{ c.EV_DISPATCH, c.EV_ONESHOT, c.EV_CLEAR }) |mode| {
        const p = alloc(1);
        defer _ = c.close(@intCast(p));
        const s = alloc(3);
        defer _ = c.close(@intCast(s));
        move(p, s);
        const q = queue();
        defer _ = c.close(q);
        send(p, 51511);
        send(p, 51512);
        change(q, s, c.EV_ADD | mode);
        event(q, p, true);
        event(q, 0, false);
        if (mode == c.EV_DISPATCH) {
            change(q, s, c.EV_ENABLE);
            event(q, p, true);
        } else if (mode == c.EV_ONESHOT) {
            change(q, s, c.EV_ADD | mode);
            event(q, p, true);
        }
        receive(s, 51511);
        receive(s, 51512);
        event(q, 0, false);
        if (mode == c.EV_DISPATCH) change(q, s, c.EV_ENABLE) else if (mode == c.EV_ONESHOT) change(q, s, c.EV_ADD | mode);
        send(p, 51513);
        event(q, p, true);
        receive(s, 51513);
        event(q, 0, false);
    }
}
fn members() void {
    const a = alloc(1);
    defer _ = c.close(@intCast(a));
    const b = alloc(1);
    defer _ = c.close(@intCast(b));
    const s = alloc(3);
    defer _ = c.close(@intCast(s));
    move(a, s);
    move(b, s);
    const q = queue();
    defer _ = c.close(q);
    change(q, s, c.EV_ADD);
    send(a, 51521);
    send(a, 51522);
    send(b, 51523);
    event(q, a, true);
    receive(s, 51521);
    // A remains busy; selecting it once must expose B next.
    event(q, b, true);
    receive(s, 51523);
    event(q, a, true);
    move(a, 0);
    event(q, 0, false);
    move(a, s);
    event(q, a, true);
    if (c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), a) != 0) c.atf_tc_fail("member destruction failed");
    event(q, 0, false);
}
var race_port: u32 = 0;
var race_go: u32 = 0;
fn racingSend(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    // Bounded start handshake; no thread join can wait indefinitely.
    for (0..2000) |_| {
        if (@atomicLoad(u32, &race_go, .acquire) != 0) {
            send(race_port, 51531);
            return null;
        }
        _ = c.usleep(1000);
    }
    return @ptrFromInt(1);
}
fn attachEnqueue() void {
    // Scheduling stress across both orders, not a claimed fixed interleaving.
    for (0..32) |_| {
        const p = alloc(1);
        defer _ = c.close(@intCast(p));
        const s = alloc(3);
        defer _ = c.close(@intCast(s));
        move(p, s);
        const q = queue();
        defer _ = c.close(q);
        race_port = p;
        @atomicStore(u32, &race_go, 0, .release);
        var t: c.pthread_t = undefined;
        if (c.pthread_create(&t, null, &racingSend, null) != 0) c.atf_tc_fail("enqueue worker failed");
        @atomicStore(u32, &race_go, 1, .release);
        change(q, s, c.EV_ADD | c.EV_ONESHOT);
        event(q, p, true);
        var result: ?*anyopaque = null;
        if (c.pthread_join(t, &result) != 0 or result != null) c.atf_tc_fail("enqueue worker handshake failed");
        receive(s, 51531);
    }
}
fn buffers() void {
    const p = alloc(1);
    defer _ = c.close(@intCast(p));
    const s = alloc(3);
    defer _ = c.close(@intCast(s));
    move(p, s);
    const q = queue();
    defer _ = c.close(q);
    var wire: [128]u8 align(8) = [_]u8{0xa5} ** 128;
    var note = c.struct_kevent{ .ident = s, .filter = c.EVFILT_MACHPORT, .flags = c.EV_ADD | c.EV_RECEIPT, .fflags = 2, .data = 0, .udata = null, .ext = .{ @intFromPtr(&wire), wire.len, 0, 0 } };
    var receipt: c.struct_kevent = undefined;
    var timeout = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 0 };
    fact(1, c.kevent(q, &note, 1, &receipt, 1, &timeout));
    fact(c.ENOTSUP, receipt.data);
    boolean(receipt.flags & c.EV_ERROR != 0);
    // Remove the old kernel's accepted buffered note before the positive path.
    note.flags = c.EV_DELETE;
    _ = c.kevent(q, &note, 1, null, 0, null);
    change(q, s, c.EV_ADD);
    send(p, 51541);
    send(p, 51542);
    note.flags = c.EV_ADD | c.EV_ENABLE;
    fact(0, c.kevent(q, &note, 1, null, 0, null));
    event(q, p, true);
    boolean(@import("std").mem.allEqual(u8, &wire, 0xa5));
    receive(s, 51541);
    receive(s, 51542);
    event(q, 0, false);
}
fn silentClose() void {
    for (0..2) |mode| {
        const s = alloc(3);
        const q = queue();
        defer _ = c.close(q);
        change(q, s, c.EV_ADD);
        const rc = if (mode == 0) c.close(@intCast(s)) else c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), s);
        fact(0, rc);
        event(q, 0, false);
    }
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach port sets publish readiness without receiving");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    current = c.atf_tc_get_ident(t);
    index = 0;
    differs = false;
    const std = @import("std");
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, std.mem.span(current), std.mem.span(name))) switch (i) {
            0 => scans(),
            1 => nativeModes(),
            2 => members(),
            3 => attachEnqueue(),
            4 => buffers(),
            5 => silentClose(),
            else => unreachable,
        };
    }
    if (differs) c.atf_tc_fail("Mach readiness observations differ");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        const e = c.atf_tc_init(&cases[i], name, &head, &body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        const a = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(a)) return a;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
