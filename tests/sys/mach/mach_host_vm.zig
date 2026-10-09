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
const names = [_][*:0]const u8{"self_calls"};
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
    if (std.mem.eql(u8, name, "self_calls")) {
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
