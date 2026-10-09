// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const fm = @import("file_message.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_vm.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/rctl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{ "foreign_target", "maximum", "mig_errors", "vmem_limit", "racct_limit", "ool_allocation" };
var cases: [names.len]c.atf_tc_t = undefined;
var child: c.pid_t = -1;
var rule: [128]u8 = @splat(0);
fn fact(name: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("vm_contract check=%s expected=%lld observed=%lld\n", name, @as(c_longlong, expected), @as(c_longlong, observed));
    if (expected != observed) c.atf_tc_fail("VM wrapper contract differs");
}
fn allocate() u64 {
    var addr: u64 = 0;
    fact("allocate", 0, c.syscall(c.SYS__kernelrpc_mach_vm_allocate_trap, @as(u32, 0), &addr, @as(u64, 4096), @as(c_int, 1)));
    return addr;
}
fn point(value: [*:0]const u8) void {
    if (c.sysctlbyname("debug.fail_point.mach_ool_copyin_alloc", null, null, @constCast(value), std.mem.len(value)) != 0) c.atf_tc_fail("allocation fail point control failed");
}
const Ool = extern struct { address: u64 align(4), deallocate: u8, copy: u8, pad: u8, kind: u8, size: u32 };
const Message = extern struct { header: fm.Header, count: u32, ool: Ool, trailer: [128]u8 };
fn oolAllocation() void {
    const port = fm.allocate();
    const payload = [_]u8{0x58} ** 16;
    var msg = Message{ .header = .{ .bits = 0x80000000 | 20, .size = 44, .remote = port, .local = 0, .voucher = 0, .id = 583 }, .count = 1, .ool = .{ .address = @intFromPtr(&payload), .deallocate = 0, .copy = 0, .pad = 0, .kind = 1, .size = payload.len }, .trailer = @splat(0) };
    point("1*return(1)");
    const rc = c.syscall(c.SYS_mach_msg_trap, &msg, @as(u32, 0x11), @as(u32, 44), @as(u32, 0), @as(u32, 0), @as(u32, 1000), @as(u32, 0));
    point("off");
    fact("ool_sender_error", 0x1000000c, rc); // MACH_SEND_INVALID_MEMORY
    fact("ool_no_queued_message", 0x10004003, c.syscall(c.SYS_mach_msg_trap, &msg, @as(u32, 0x102), @as(u32, 0), @as(u32, @sizeOf(Message)), port, @as(u32, 0), @as(u32, 0)));
    fact("ool_receive_right_survives", 0, c.close(@intCast(port)));
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(t));
    const task = c.mach_task_self();
    if (std.mem.eql(u8, name, "ool_allocation")) return oolAllocation();
    if (std.mem.eql(u8, name, "vmem_limit")) {
        var limit: c.struct_rlimit = undefined;
        if (c.getrlimit(c.RLIMIT_VMEM, &limit) != 0) c.atf_tc_fail("getrlimit failed");
        limit.rlim_cur = 1;
        if (c.setrlimit(c.RLIMIT_VMEM, &limit) != 0) c.atf_tc_fail("setrlimit failed");
        var address: u64 = 0;
        fact("vmem_denied", 3, c.syscall(c.SYS__kernelrpc_mach_vm_allocate_trap, @as(u32, 0), &address, @as(u64, 4096), @as(c_int, 1)));
        fact("vmem_address_unchanged", 0, @intCast(address));
        return;
    }
    if (std.mem.eql(u8, name, "racct_limit")) {
        _ = c.snprintf(&rule, rule.len, "process:%d:vmemoryuse:deny=1", c.getpid());
        if (c.rctl_add_rule(&rule, std.mem.len(@as([*:0]const u8, @ptrCast(&rule))), null, 0) != 0) c.atf_tc_fail("RCTL VMEM rule install failed");
        var address: u64 = 0;
        const rc = c.syscall(c.SYS__kernelrpc_mach_vm_allocate_trap, @as(u32, 0), &address, @as(u64, 4096), @as(c_int, 1));
        _ = c.rctl_remove_rule(&rule, std.mem.len(@as([*:0]const u8, @ptrCast(&rule))), null, 0);
        rule[0] = 0;
        fact("racct_denied", 3, rc);
        fact("racct_address_unchanged", 0, @intCast(address));
        return;
    }
    const address = allocate();
    const bytes: *[4096]u8 = @ptrFromInt(address);
    bytes[0] = 0x58;
    if (std.mem.eql(u8, name, "foreign_target")) {
        const port = fm.allocate();
        var saved_bootstrap: u32 = 0;
        fact("save_bootstrap", 0, c.task_get_special_port(task, c.TASK_BOOTSTRAP_PORT, &saved_bootstrap));
        fact("channel_send_right", 0, c.mach_port_insert_right(task, port, port, c.MACH_MSG_TYPE_MAKE_SEND));
        fact("child_bootstrap_channel", 0, c.task_set_special_port(task, c.TASK_BOOTSTRAP_PORT, port));
        child = c.fork();
        if (child < 0) c.atf_tc_fail("fork failed");
        if (child == 0) {
            _ = c.alarm(5);
            var channel: u32 = 0;
            if (c.task_get_special_port(c.mach_task_self(), c.TASK_BOOTSTRAP_PORT, &channel) != 0 or fm.sendFile(channel, @intCast(c.mach_task_self())) != 0) c._exit(91);
            _ = c.pause();
            c._exit(0);
        }
        fact("restore_bootstrap", 0, c.task_set_special_port(task, c.TASK_BOOTSTRAP_PORT, saved_bootstrap));
        if (saved_bootstrap != 0) _ = c.mach_port_deallocate(task, saved_bootstrap);
        var packet: fm.Message = undefined;
        if (c.syscall(c.SYS_mach_msg_trap, &packet, @as(u32, 0x102), @as(u32, 0), @as(u32, @sizeOf(fm.Message)), port, @as(u32, 1000), @as(u32, 0)) != 0) c.atf_tc_fail("child task receive failed");
        const other = packet.descriptor.name;
        fact("foreign_protect", 46, c.mach_vm_protect(other, address, 4096, 0, 1));
        fact("foreign_deallocate", 46, c.mach_vm_deallocate(other, address, 4096));
        var allocated: u64 = 0;
        fact("foreign_allocate", 46, c.mach_vm_allocate(other, &allocated, 4096, 1));
        fact("foreign_inherit", 46, c.mach_vm_inherit(other, address, 4096, 2));
        fact("foreign_allocate_trap", 46, c.syscall(c.SYS__kernelrpc_mach_vm_allocate_trap, other, &allocated, @as(u64, 4096), @as(c_int, 1)));
        fact("non_task_allocate_trap", 4, c.syscall(c.SYS__kernelrpc_mach_vm_allocate_trap, port, &allocated, @as(u64, 4096), @as(c_int, 1)));
        var info: c.task_basic_info_data_t = undefined;
        var count: u32 = @sizeOf(c.task_basic_info_data_t) / @sizeOf(c.natural_t);
        fact("foreign_task_info", 46, c.task_info(other, c.TASK_BASIC_INFO, @ptrCast(&info), &count));
        bytes[0] = 0x59; // Still mapped and writable in the caller.
        fact("caller_mapping_preserved", 0x59, bytes[0]);
        _ = c.kill(child, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(child, &status, 0);
        child = -1;
        _ = c.close(@intCast(other));
        _ = c.close(@intCast(port));
    } else if (std.mem.eql(u8, name, "maximum")) {
        fact("set_maximum", 0, c.mach_vm_protect(task, address, 4096, 1, 1));
        fact("raise_above_maximum", 2, c.mach_vm_protect(task, address, 4096, 0, 3));
        fact("content_preserved", 0x58, bytes[0]);
        const second = allocate();
        fact("trap_set_maximum", 0, c.syscall(c.SYS__kernelrpc_mach_vm_protect_trap, @as(u32, 0), second, @as(u64, 4096), @as(c_int, 1), @as(c_int, 1)));
        fact("trap_raise_above_maximum", 2, c.syscall(c.SYS__kernelrpc_mach_vm_protect_trap, @as(u32, 0), second, @as(u64, 4096), @as(c_int, 0), @as(c_int, 3)));
        fact("second_cleanup", 0, c.mach_vm_deallocate(task, second, 4096));
    } else {
        fact("mig_protection_byte", 4, c.mach_vm_protect(task, address, 4096, 0, 0x80));
        bytes[0] = 0x59;
        fact("invalid_byte_preserved_mapping", 0x59, bytes[0]);
        fact("mig_errno_translation", 4, c.mach_vm_inherit(task, address, 4096, 99));
    }
    fact("mapping_cleanup", 0, c.mach_vm_deallocate(task, address, 4096));
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    point("off");
    if (child > 0) {
        _ = c.kill(child, c.SIGKILL);
        _ = c.waitpid(child, null, 0);
    }
    if (rule[0] != 0) _ = c.rctl_remove_rule(&rule, std.mem.len(@as([*:0]const u8, @ptrCast(&rule))), null, 0);
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, &head, &body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
