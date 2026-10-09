// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [2]c.atf_tc_t = undefined;
const names = [_][*:0]const u8{ "errors", "unsupported" };
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn check(label: [*:0]const u8, number: c_int, args: [6]u64, expected: c_int) bool {
    c.__error().* = 0;
    const result = c.syscall(number, args[0], args[1], args[2], args[3], args[4], args[5]);
    const err = c.__error().*;
    _ = c.printf("trap=%s number=%d expected=%d observed=%d expected_errno=0 observed_errno=%d\n", label, number, expected, result, err);
    return result == expected and err == 0;
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    var failed: usize = 0;
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(t)), "unsupported")) {
        const numbers = [_]c_int{
            c.SYS_semaphore_wait_trap,                 c.SYS_semaphore_signal_trap,
            c.SYS_semaphore_wait_signal_trap,          c.SYS_semaphore_signal_thread_trap,
            c.SYS_semaphore_signal_all_trap,           c.SYS_semaphore_timedwait_trap,
            c.SYS_semaphore_timedwait_signal_trap,     c.SYS_task_for_pid,
            c.SYS_task_name_for_pid,                   c.SYS_pid_for_task,
            c.SYS__kernelrpc_mach_port_construct_trap, c.SYS__kernelrpc_mach_port_destruct_trap,
            c.SYS__kernelrpc_mach_port_guard_trap,     c.SYS__kernelrpc_mach_port_unguard_trap,
            c.SYS_macx_swapon,                         c.SYS_macx_swapoff,
            c.SYS_macx_triggers,                       c.SYS_macx_backing_store_suspend,
            c.SYS_macx_backing_store_recovery,         c.SYS_mach_wait_until,
            c.SYS_mk_timer_destroy,                    c.SYS_mk_timer_arm,
            c.SYS_mk_timer_cancel,
        };
        for (numbers) |number| {
            if (!check("unsupported", number, .{ 0, 0, 0, 0, 0, 0 }, 46)) failed += 1;
        }
    } else {
        var name: u32 = 0;
        if (!check("port_allocate_right", c.SYS__kernelrpc_mach_port_allocate_trap, .{ 0, 99, @intFromPtr(&name), 0, 0, 0 }, 18)) failed += 1;
        if (!check("port_allocate_copyout", c.SYS__kernelrpc_mach_port_allocate_trap, .{ 0, 1, 4, 0, 0, 0 }, 1)) failed += 1;
        if (!check("port_destroy", c.SYS__kernelrpc_mach_port_destroy_trap, .{ 0, 0x7fffffff, 0, 0, 0, 0 }, 15)) failed += 1;
        if (!check("vm_map", c.SYS__kernelrpc_mach_vm_map_trap, .{ 0, 4, 4096, 0, 1, 3 }, 1)) failed += 1;
        if (!check("vm_allocate", c.SYS__kernelrpc_mach_vm_allocate_trap, .{ 0, 4, 4096, 1, 0, 0 }, 1)) failed += 1;
        if (!check("vm_deallocate", c.SYS__kernelrpc_mach_vm_deallocate_trap, .{ 0, 4, 4096, 0, 0, 0 }, 4)) failed += 1;
        // Reject unsupported protection bits before vm_prot_t narrowing.
        if (!check("vm_protect", c.SYS__kernelrpc_mach_vm_protect_trap, .{ 0, 4, 4096, 0, 0x40000000, 0 }, 4)) failed += 1;
        if (!check("timebase_copyout", c.SYS_mach_timebase_info, .{ 4, 0, 0, 0, 0, 0 }, 1)) failed += 1;
        // thread_switch currently has no error path; observe its success value.
        if (!check("thread_switch", c.SYS_thread_switch, .{ 0, 0, 0, 0, 0, 0 }, 0)) failed += 1;
    }
    if (failed != 0) c.atf_tc_fail("%zu traps returned a native syscall error instead of a Mach value", failed);
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var err = c.atf_tc_init(&cases[i], name, &head, &body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
