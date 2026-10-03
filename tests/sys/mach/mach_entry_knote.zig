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
    @cInclude("sys/sysctl.h");
    @cInclude("sys/linker.h");
    @cInclude("time.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
var pin_cases: [3]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Destroying a Mach port set removes its registered knote");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var name: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &name) != 0) c.atf_tc_fail("port set allocation failed");
    const kq = c.kqueue();
    if (kq < 0) c.atf_tc_fail("kqueue allocation failed");
    defer _ = c.close(kq);
    var change = c.struct_kevent{ .ident = name, .filter = c.EVFILT_MACHPORT, .flags = c.EV_ADD | c.EV_RECEIPT, .fflags = 0, .data = 0, .udata = null, .ext = .{ 0, 0, 0, 0 } };
    var event: c.struct_kevent = undefined;
    if (c.kevent(kq, &change, 1, &event, 1, null) != 1 or event.data != 0) c.atf_tc_fail("knote registration failed");
    const destroyed = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), name);
    if (destroyed != 0) c.atf_tc_fail("port set destroy failed");
    var immediate = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 0 };
    const count = c.kevent(kq, null, 0, &event, 1, &immediate);
    _ = c.printf("destroyed_pset expected_pending=0 observed_pending=%d\n", count);
    if (count != 0) c.atf_tc_fail("destroyed port set left a stale knote");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "destroy_detaches", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    const added = c.atf_tp_add_tc(tp, &tc);
    if (c.atf_is_error(added)) return added;
    for ([_][*:0]const u8{ "send_pin", "move_pin", "retire_pin" }, 0..) |name, i| {
        const e = c.atf_tc_init(&pin_cases[i], name, &pinHead, if (i == 0) &sendPin else if (i == 1) &movePin else &retirePin, &pinCleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        const a = c.atf_tp_add_tc(tp, &pin_cases[i]);
        if (c.atf_is_error(a)) return a;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
const Obs = extern struct { result: c_int = 0, owned: c_int = 0 };
fn pin(command: u32, name: u32) Obs {
    var input: u64 = (@as(u64, command) << 32) | name;
    var output: Obs = .{};
    var size: usize = @sizeOf(Obs);
    if (c.sysctlbyname("debug.rmx_pset_pin_observe", &output, &size, &input, @sizeOf(u64)) != 0 or size != @sizeOf(Obs)) c.atf_tc_fail("pin fixture observation failed");
    return output;
}
var selected_port: u32 = 0;
var selected_set: u32 = 0;
var moving: bool = false;
fn holdNote(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = pin(2, 0);
    return null;
}
fn notify(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (moving) {
        return if (c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), selected_port, selected_set) == 0) null else @ptrFromInt(1);
    }
    var message = [_]u32{ 19, 24, selected_port, 0, 0, 447 };
    return if (c.syscall(c.SYS_mach_msg_trap, &message, @as(c_uint, 1), @as(c_uint, 24), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) == 0) null else @ptrFromInt(1);
}
fn pinHead(t: [*c]c.atf_tc_t) callconv(.c) void {
    head(t);
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn pinCleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) _ = c.kldunload(module);
}
fn pinCase(t: [*c]const c.atf_tc_t, move: bool) void {
    var path: [4096]u8 = undefined;
    _ = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (c.kldload(&path) < 0) c.atf_tc_fail("fixture load failed");
    moving = move;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &selected_port) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &selected_set) != 0) c.atf_tc_fail("port/set allocation failed");
    if (c.syscall(c.SYS__kernelrpc_mach_port_insert_right_trap, @as(c_uint, 0), selected_port, selected_port, @as(c_uint, 20)) != 0) c.atf_tc_fail("send right failed");
    var message = [_]u32{ 19, 24, selected_port, 0, 0, 447 };
    if (move) {
        if (c.syscall(c.SYS_mach_msg_trap, &message, @as(c_uint, 1), @as(c_uint, 24), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) != 0) c.atf_tc_fail("queued message failed");
    } else if (c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), selected_port, selected_set) != 0) c.atf_tc_fail("membership failed");
    _ = pin(1, selected_set);
    var holder: c.pthread_t = undefined;
    if (c.pthread_create(&holder, null, &holdNote, null) != 0) c.atf_tc_fail("note holder creation failed");
    var tries: usize = 0;
    while (pin(6, 0).result != 1 and tries < 1000) : (tries += 1) _ = c.usleep(1000);
    var sender: c.pthread_t = undefined;
    if (c.pthread_create(&sender, null, &notify, null) != 0) c.atf_tc_fail("notifier creation failed");
    tries = 0;
    var observed = pin(3, 0);
    while (observed.result != 1 and tries < 1000) : (tries += 1) {
        _ = c.usleep(1000);
        observed = pin(3, 0);
    }
    const ready = observed.result == 1;
    const removed = c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), selected_port, @as(c_uint, 0));
    const refs = pin(3, 0).owned;
    _ = pin(4, 0);
    var result: ?*anyopaque = null;
    const joined = c.pthread_join(holder, &result) == 0 and c.pthread_join(sender, &result) == 0 and result == null;
    _ = pin(5, 0);
    _ = c.printf("pset_notification_pin expected_waiter=1 observed_waiter=%d expected_refs=3 observed_refs=%d move=%d\n", @as(c_int, @intFromBool(ready)), refs, @as(c_int, @intFromBool(move)));
    if (!ready or removed != 0 or !joined) c.atf_tc_fail("controlled notification interlock failed");
    if (refs != 3) c.atf_tc_fail("notification lost its pset storage pin after membership removal");
}
fn sendPin(t: [*c]const c.atf_tc_t) callconv(.c) void {
    pinCase(t, false);
}
fn movePin(t: [*c]const c.atf_tc_t) callconv(.c) void {
    pinCase(t, true);
}
fn holdPort(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = pin(8, 0);
    return null;
}
fn destroySet(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var tries: usize = 0;
    while (pin(6, 0).result != 1 and tries < 1000) : (tries += 1) _ = c.usleep(1000);
    return if (c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), selected_set) == 0) null else @ptrFromInt(1);
}
fn retirePin(t: [*c]const c.atf_tc_t) callconv(.c) void {
    var path: [4096]u8 = undefined;
    _ = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (c.kldload(&path) < 0) c.atf_tc_fail("fixture load failed");
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &selected_port) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &selected_set) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), selected_port, selected_set) != 0) c.atf_tc_fail("retirement membership failed");
    _ = pin(1, selected_set);
    _ = pin(7, selected_port);
    var holder: c.pthread_t = undefined;
    var destroyer: c.pthread_t = undefined;
    if (c.pthread_create(&destroyer, null, &destroySet, null) != 0) c.atf_tc_fail("set destroyer failed");
    if (c.pthread_create(&holder, null, &holdPort, null) != 0) c.atf_tc_fail("port holder failed");
    var result: ?*anyopaque = null;
    const joined = c.pthread_join(holder, null) == 0 and c.pthread_join(destroyer, &result) == 0 and result == null;
    const observed = pin(9, 0);
    _ = pin(10, 0);
    _ = pin(5, 0);
    _ = c.printf("pset_retire_pin expected_waiter=1 observed_waiter=%d expected_refs=3 observed_refs=%d\n", observed.result, observed.owned);
    if (observed.result != 1 or !joined) c.atf_tc_fail("controlled retirement interlock failed");
    if (observed.owned != 3) c.atf_tc_fail("retiring set lost its member storage pin while dropping its lock");
}
