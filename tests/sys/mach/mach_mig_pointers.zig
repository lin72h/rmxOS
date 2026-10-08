// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn mach_vm_machine_attribute(u32, u64, u64, c_int, *c_int) c_int;
extern fn vm_machine_attribute(u32, u64, u64, c_int, *c_int) c_int;
var cases: [2]c.atf_tc_t = undefined;
const names = [_][*:0]const u8{ "vm_attribute", "clock_reply" };
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(t)), "vm_attribute")) {
        const task: u32 = @intCast(c.syscall(c.SYS_task_self_trap));
        for ([_]*const fn (u32, u64, u64, c_int, *c_int) callconv(.c) c_int{ &mach_vm_machine_attribute, &vm_machine_attribute }, 0..) |rpc, i| {
            var value: c_int = 6; // MATTR_VAL_CACHE_FLUSH
            const result = rpc(task, 0, 0, 1, &value);
            _ = c.printf("vm_attribute family=%zu expected_result=0 observed_result=%d expected_value=6 observed_value=%d\n", i, result, value);
            if (result != 0 or value != 6) c.atf_tc_fail("MIG kernel value field rejected");
            value = 99;
            if (rpc(task, 0, 0, 1, &value) != 5) c.atf_tc_fail("unknown cache value accepted");
        }
    } else {
        var path: [4096]u8 = undefined;
        _ = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
        if (c.kldload(&path) < 0) c.atf_tc_fail("clock fixture load failed");
        const Clock = extern struct { result: c_int, sec: u32, nsec: c_int, guard: u64 };
        var observed: Clock = undefined;
        var size: usize = @sizeOf(Clock);
        if (c.sysctlbyname("debug.rmx_clock_pointer", &observed, &size, null, 0) != 0 or size != @sizeOf(Clock)) c.atf_tc_fail("clock observation failed");
        _ = c.printf("clock_reply expected_result=0 observed_result=%d sec=%u nsec=%d expected_guard=%llu observed_guard=%llu\n", observed.result, observed.sec, observed.nsec, @as(u64, 0x569569569569569), observed.guard);
        if (observed.result != 0 or observed.sec == 0 or observed.nsec < 0 or observed.nsec >= 1000000000 or observed.guard != 0x569569569569569) c.atf_tc_fail("clock kernel reply field incorrect");
    }
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0 and c.kldunload(module) != 0) c.atf_tc_fail("fixture unload failed");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var err = c.atf_tc_init(&cases[i], name, &head, &body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
