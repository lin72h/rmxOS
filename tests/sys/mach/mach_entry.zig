// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/param.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/module.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("pthread.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Observation = extern struct { result: c_int, owned: c_int };
var tc: c.atf_tc_t = undefined;
var concurrent_tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "A native file hold does not add a Mach user reference");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    var name: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 4), &name) != 0) c.atf_tc_fail("dead-name allocation failed");
    defer _ = c.close(@intCast(name));
    var path: [4096]u8 = undefined;
    const length = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (length < 0 or length >= path.len) c.atf_tc_fail("fixture path too long");
    const module = c.kldload(&path);
    if (module < 0) c.atf_tc_fail("fixture load failed");
    defer _ = c.kldunload(module);
    var observed: Observation = undefined;
    var size: usize = @sizeOf(Observation);
    const rc = c.sysctlbyname("debug.rmx_urefs_observe", &observed, &size, &name, @sizeOf(u32));
    if (rc != 0 or size != @sizeOf(Observation)) c.atf_tc_fail("uref observation failed");
    _ = c.printf("urefs expected_result=0 observed_result=%d expected_urefs=1 observed_urefs=%d\n", observed.result, observed.owned);
    if (observed.result != 0 or observed.owned != 1) c.atf_tc_fail("native hold changed Mach user references");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) _ = c.kldunload(module);
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "native_hold", &head, &body, &cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    const added = c.atf_tp_add_tc(tp, &tc);
    if (c.atf_is_error(added)) return added;
    const next = c.atf_tc_init(&concurrent_tc, "first_copyout", &head, &copyoutBody, &cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(next)) return next;
    return c.atf_tp_add_tc(tp, &concurrent_tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
fn copyout(command: u64) Observation {
    var input = command;
    var observed: Observation = undefined;
    var size: usize = @sizeOf(Observation);
    if (c.sysctlbyname("debug.rmx_copyout_observe", &observed, &size, &input, @sizeOf(u64)) != 0 or size != @sizeOf(Observation)) c.atf_tc_fail("copyout fixture failed");
    return observed;
}
var copies: [2]Observation = undefined;
fn copyWorker(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const index = @intFromPtr(arg);
    copies[index] = copyout(2);
    return null;
}
fn copyoutBody(t: [*c]const c.atf_tc_t) callconv(.c) void {
    var path: [4096]u8 = undefined;
    _ = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    const module = c.kldload(&path);
    if (module < 0) c.atf_tc_fail("fixture load failed");
    defer _ = c.kldunload(module);
    var duplicate: bool = false;
    // Synchronized starts, but allocation interleaving remains stress.
    for (0..200) |iteration| {
        _ = copyout(1);
        var threads: [2]c.pthread_t = undefined;
        for (0..2) |i| {
            if (c.pthread_create(&threads[i], null, &copyWorker, @ptrFromInt(i)) != 0) c.atf_tc_fail("copyout thread failed");
        }
        for (threads) |thread| {
            if (c.pthread_join(thread, null) != 0) c.atf_tc_fail("copyout join failed");
        }
        if (copies[0].result != 0 or copies[1].result != 0) c.atf_tc_fail("copyout returned error");
        duplicate = copies[0].owned != copies[1].owned;
        _ = c.printf("first_copyout iteration=%u expected_same_name=1 observed_same_name=%d\n", @as(c_uint, @intCast(iteration)), @as(c_int, @intFromBool(!duplicate)));
        _ = copyout(3);
        _ = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), @as(c_uint, @intCast(copies[0].owned)));
        if (duplicate) {
            _ = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), @as(c_uint, @intCast(copies[1].owned)));
            break;
        }
    }
    if (duplicate) c.atf_tc_fail("one send right acquired two Mach names");
}
