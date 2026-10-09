// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_vm.h");
    @cInclude("mach/mach_host.h");
    @cInclude("mach/ndr.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{ "self_calls", "copy_zero", "copy_overlap", "map_prototype", "map_fixed", "map_inheritance", "map_mask", "map_protection" };
var cases: [names.len]c.atf_tc_t = undefined;
fn fact(name: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("host_vm check=%s expected=%lld observed=%lld\n", name, @as(c_longlong, expected), @as(c_longlong, observed));
    if (expected != observed) c.atf_tc_fail("host/task/VM observations differ");
}
const Allocate = extern struct { header: c.mach_msg_header_t, count: u32, ndr: c.NDR_record_t, address: u64 align(4), size: u64 align(4), flags: i32 };
const AllocateReply = extern struct { header: c.mach_msg_header_t, ndr: c.NDR_record_t, result: i32, address: u64 align(4) };
fn migAllocate() u64 {
    var reply: u32 = 0;
    fact("reply_allocate", 0, c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &reply));
    var buffer: [512]u8 align(8) = @splat(0);
    const request: *Allocate = @ptrCast(&buffer);
    request.* = .{ .header = .{ .msgh_bits = 0x80000000 | 19 | (21 << 8), .msgh_size = @sizeOf(Allocate), .msgh_remote_port = c.mach_task_self(), .msgh_local_port = reply, .msgh_voucher_port = 0, .msgh_id = 3801 }, .count = 0, .ndr = c.NDR_record, .address = 0, .size = 4096, .flags = 1 };
    fact("vm_allocate_mig_transport", 0, c.mach_msg(&request.header, 0x113, @sizeOf(Allocate), buffer.len, reply, 2000, 0));
    const response: *AllocateReply = @ptrCast(&buffer);
    fact("vm_allocate_mig_id", 3901, response.header.msgh_id);
    fact("vm_allocate_mig_result", 0, response.result);
    const address = response.address;
    fact("vm_allocate_mig_nonzero", 1, @intFromBool(address != 0));
    _ = c.close(@intCast(reply));
    return address;
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(t));
    if (std.mem.eql(u8, name, "map_fixed")) {
        var address: u64 = 0;
        fact("fixed_setup", 0, c.mach_vm_allocate(c.mach_task_self(), &address, 4096, 1));
        const bytes: *[4096]u8 = @ptrFromInt(address);
        bytes[0] = 0x58;
        var requested = address;
        fact("fixed_occupied", 3, c.mach_vm_map(c.mach_task_self(), &requested, 4096, 0, 0, 0, 0, 0, 3, 7, 2));
        fact("fixed_occupied_address", @intCast(address), @intCast(requested));
        fact("fixed_occupied_data", 0x58, bytes[0]);
        fact("fixed_free_page", 0, c.mach_vm_deallocate(c.mach_task_self(), address, 4096));
        fact("fixed_free", 0, c.mach_vm_map(c.mach_task_self(), &requested, 4096, 0, 0, 0, 0, 0, 3, 7, 2));
        fact("fixed_exact_address", @intCast(address), @intCast(requested));
        fact("fixed_cleanup", 0, c.mach_vm_deallocate(c.mach_task_self(), address, 4096));
    } else if (std.mem.eql(u8, name, "map_inheritance")) {
        var none: u64 = 0;
        var share: u64 = 0;
        fact("map_none", 0, c.mach_vm_map(c.mach_task_self(), &none, 4096, 0, 1, 0, 0, 0, 3, 7, 2));
        fact("map_share", 0, c.mach_vm_map(c.mach_task_self(), &share, 4096, 0, 1, 0, 0, 0, 3, 7, 0));
        const bytes: *u8 = @ptrFromInt(share);
        bytes.* = 0x58;
        const pid = c.fork();
        if (pid < 0) c.atf_tc_fail("map fork failed");
        if (pid == 0) {
            var state: u8 = 0;
            if (c.mincore(@ptrFromInt(none), 4096, &state) == 0) c._exit(91);
            bytes.* = 0x59;
            c._exit(0);
        }
        var status: c_int = 0;
        fact("map_child_reaped", pid, c.waitpid(pid, &status, 0));
        fact("map_none_child_absent", 0, status);
        fact("map_shared_child_write", 0x59, bytes.*);
        fact("map_none_cleanup", 0, c.mach_vm_deallocate(c.mach_task_self(), none, 4096));
        fact("map_share_cleanup", 0, c.mach_vm_deallocate(c.mach_task_self(), share, 4096));
    } else if (std.mem.eql(u8, name, "map_mask")) {
        var address: u64 = 0;
        fact("map_mask_32", 0, c.mach_vm_map(c.mach_task_self(), &address, 4096, 0xffffffff, 1, 0, 0, 0, 3, 7, 2));
        fact("map_mask_aligned", 0, @intCast(address & 0xffffffff));
        fact("map_mask_cleanup", 0, c.mach_vm_deallocate(c.mach_task_self(), address, 4096));
        address = 0;
        fact("map_unrepresentable_mask", 4, c.mach_vm_map(c.mach_task_self(), &address, 4096, 0xffffffffffffffff, 1, 0, 0, 0, 3, 7, 2));
        fact("map_mask_failure_address", 0, @intCast(address));
    } else if (std.mem.eql(u8, name, "map_protection")) {
        var address: u64 = 0;
        fact("map_full_protection", 4, c.syscall(c.SYS__kernelrpc_mach_vm_map_trap, @as(u32, 0), &address, @as(u64, 4096), @as(u64, 0), @as(c_int, 1), @as(c_int, 0x103)));
        fact("map_invalid_protection_address", 0, @intCast(address));
        fact("map_invalid_maximum", 4, c.mach_vm_map(c.mach_task_self(), &address, 4096, 0, 1, 0, 0, 0, 3, 0x80, 2));
        fact("map_invalid_maximum_address", 0, @intCast(address));
    } else if (std.mem.eql(u8, name, "map_prototype")) {
        var address: u64 = 0;
        fact("map_size_then_mask", 0, c.mach_vm_map(c.mach_task_self(), &address, 8192, 0, 1, 0, 0, 0, 3, 7, 2));
        var state: u8 = 0;
        fact("map_second_page_present", 0, c.mincore(@ptrFromInt(address + 4096), 4096, &state));
        const bytes: *[8192]u8 = @ptrFromInt(address);
        bytes[8191] = 0x58;
        fact("map_second_page_writable", 0x58, bytes[8191]);
        fact("map_cleanup", 0, c.mach_vm_deallocate(c.mach_task_self(), address, 8192));
    } else if (std.mem.eql(u8, name, "copy_zero") or std.mem.eql(u8, name, "copy_overlap")) {
        var address: u64 = 0;
        fact("copy_allocate", 0, c.mach_vm_allocate(c.mach_task_self(), &address, 4 * 4096, 1));
        const bytes: *[4 * 4096]u8 = @ptrFromInt(address);
        for (0..4) |i| @memset(bytes[i * 4096 ..][0..4096], @as(u8, @intCast(0x11 * (i + 1))));
        const zero = std.mem.eql(u8, name, "copy_zero");
        fact("copy_result", 0, c.mach_vm_copy(c.mach_task_self(), address, if (zero) 0 else 3 * 4096, address + 4096));
        for (0..4) |i| {
            const value: u8 = @intCast(0x11 * (if (zero or i == 0) i + 1 else i));
            for (bytes[i * 4096 ..][0..4096]) |observed| if (observed != value) c.atf_tc_fail("copy page/canary differs");
        }
        fact("copy_cleanup", 0, c.mach_vm_deallocate(c.mach_task_self(), address, 4 * 4096));
    } else if (std.mem.eql(u8, name, "self_calls")) {
        for (0..32) |_| {
            const address = migAllocate();
            const bytes: *[4096]u8 = @ptrFromInt(address);
            bytes[0] = 0x58;
            fact("vm_allocate_mig_writable", 0x58, bytes[0]);
            fact("vm_allocate_mig_cleanup", 0, c.mach_vm_deallocate(c.mach_task_self(), address, 4096));
        }
        var port: u32 = 0;
        fact("task_name_unsupported", 46, c.task_get_special_port(c.mach_task_self(), c.TASK_NAME_PORT, &port));
        fact("task_name_empty", 0, port);
        fact("default_pset", 0, c.processor_set_default(c.mach_host_self(), &port));
        fact("default_pset_nonzero", 1, @intFromBool(port != 0));
        _ = c.close(@intCast(port));
    }
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, &head, &body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
