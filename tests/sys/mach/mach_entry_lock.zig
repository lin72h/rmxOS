// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/param.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/module.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/sysctl.h");
    @cInclude("pthread.h");
    @cInclude("sched.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Observation = extern struct { result: c_int, owned: c_int };
const Control = extern struct { name: u32, flags: u64 };
const Flags = extern struct { go: u32 = 0, attempted: u32 = 0, closed: u32 = 0 };
var flags = Flags{};
var name: u32 = 0;
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Descriptor revocation waits for the Mach entry lookup transaction");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn closeWorker(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (@atomicLoad(u32, &flags.go, .acquire) == 0) _ = c.sched_yield();
    @atomicStore(u32, &flags.attempted, 1, .release);
    const rc = c.close(@intCast(name));
    @atomicStore(u32, &flags.closed, if (rc == 0) 1 else 2, .release);
    return null;
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &name) != 0) c.atf_tc_fail("receive allocation failed");
    var path: [4096]u8 = undefined;
    const length = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (length < 0 or length >= path.len) c.atf_tc_fail("fixture path too long");
    const module = c.kldload(&path);
    if (module < 0) c.atf_tc_fail("fixture load failed");
    defer _ = c.kldunload(module);
    flags = .{};
    var worker: c.pthread_t = undefined;
    if (c.pthread_create(&worker, null, &closeWorker, null) != 0) c.atf_tc_fail("worker setup failed");
    const control = Control{ .name = name, .flags = @intFromPtr(&flags) };
    var observed: Observation = undefined;
    var size: usize = @sizeOf(Observation);
    const rc = c.sysctlbyname("debug.rmx_entry_lock_observe", &observed, &size, @constCast(&control), @sizeOf(Control));
    @atomicStore(u32, &flags.go, 1, .release);
    if (c.pthread_join(worker, null) != 0) c.atf_tc_fail("worker join failed");
    if (rc != 0 or size != @sizeOf(Observation)) c.atf_tc_fail("entry observation failed");
    _ = c.printf("entry_lock expected_entry=1 observed_entry=%d expected_closed_before_unlock=0 observed_closed_before_unlock=%d expected_closed_after_unlock=1 observed_closed_after_unlock=%u\n", observed.owned, observed.result, flags.closed);
    if (observed.owned != 1 or observed.result != 0 or flags.attempted != 1 or flags.closed != 1) c.atf_tc_fail("descriptor close did not respect the entry transaction");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) _ = c.kldunload(module);
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "close_lookup", &head, &body, &cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
