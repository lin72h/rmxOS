// SPDX-License-Identifier: BSD-2-Clause
const fm = @import("file_message.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/linker.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("mach/mach.h");
});
const Ool = extern struct { address: u64 align(4), deallocate: u8, copy: u8, pad: u8, kind: u8, size: u32 };
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Message = extern struct { header: fm.Header, count: u32, ool: Ool, trailer: [128]u8 };
var tc: c.atf_tc_t = undefined;
var ports_tc: c.atf_tc_t = undefined;
fn portsPoint(value: [*:0]const u8) void {
    const std = @import("std");
    if (c.sysctlbyname("debug.fail_point.mach_ool_ports_allocate", null, null, @constCast(value), std.mem.len(value)) != 0) c.atf_tc_fail("OOL ports allocation fail point control failed");
}
fn refs(port: u32, right: u32) u32 {
    var value: u32 = 0;
    if (c.mach_port_get_refs(c.mach_task_self(), port, right, &value) != 0) c.atf_tc_fail("carried port reference observation failed");
    return value;
}
fn portsBody(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const destination = fm.allocate();
    const carried = fm.allocate();
    if (c.mach_port_insert_right(c.mach_task_self(), carried, carried, c.MACH_MSG_TYPE_MAKE_SEND) != 0) c.atf_tc_fail("carried send right setup failed");
    const send_before = refs(carried, c.MACH_PORT_RIGHT_SEND);
    const receive_before = refs(carried, c.MACH_PORT_RIGHT_RECEIVE);
    const names = [_]u32{carried};
    // Failure first; the next message must work with the fail point disabled.
    for (0..2) |iteration| {
        var msg = Message{ .header = .{ .bits = 0x80000000 | 20, .size = 44, .remote = destination, .local = 0, .voucher = 0, .id = 729 }, .count = 1, .ool = .{ .address = @intFromPtr(&names), .deallocate = 0, .copy = 0, .pad = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_OOL_PORTS_DESCRIPTOR, .size = names.len }, .trailer = [_]u8{0} ** 128 };
        if (c.syscall(c.SYS_mach_msg_trap, &msg, @as(u32, 0x11), @as(u32, 44), @as(u32, 0), @as(u32, 0), @as(u32, 1000), @as(u32, 0)) != 0) c.atf_tc_fail("OOL ports send failed");
        portsPoint(if (iteration == 0) "1*return(1)" else "off");
        const result = c.syscall(c.SYS_mach_msg_trap, &msg, @as(u32, 0x102), @as(u32, 0), @as(u32, @sizeOf(Message)), destination, @as(u32, 1000), @as(u32, 0));
        portsPoint("off");
        if (iteration == 0) {
            _ = c.printf("ool_ports_failure expected_result=%u observed_result=%u expected_address=0 observed_address=%llu expected_send_refs=%u observed_send_refs=%u expected_receive_refs=%u observed_receive_refs=%u\n", @as(u32, 0x1000500c), @as(u32, @bitCast(result)), msg.ool.address, send_before, refs(carried, c.MACH_PORT_RIGHT_SEND), receive_before, refs(carried, c.MACH_PORT_RIGHT_RECEIVE));
            if (result != 0x1000500c or msg.ool.address != 0 or refs(carried, c.MACH_PORT_RIGHT_SEND) != send_before or refs(carried, c.MACH_PORT_RIGHT_RECEIVE) != receive_before) c.atf_tc_fail("failed OOL ports allocation returned a nonzero address, wrong error or retained rights");
        } else {
            if (result != 0 or msg.ool.address == 0 or msg.ool.size != 1 or msg.ool.kind != c.MACH_MSG_OOL_PORTS_DESCRIPTOR or msg.ool.pad != c.MACH_MSG_TYPE_PORT_SEND) c.atf_tc_fail("second OOL ports message did not arrive");
            const delivered: *const u32 = @ptrFromInt(msg.ool.address);
            if (delivered.* != carried or refs(carried, c.MACH_PORT_RIGHT_SEND) != send_before + 1) c.atf_tc_fail("second OOL ports message delivered wrong name or reference count");
            if (c.mach_port_deallocate(c.mach_task_self(), delivered.*) != 0 or c.mach_vm_deallocate(c.mach_task_self(), msg.ool.address, @sizeOf(u32)) != 0) c.atf_tc_fail("delivered OOL ports cleanup failed");
        }
        if (refs(carried, c.MACH_PORT_RIGHT_SEND) != send_before or refs(carried, c.MACH_PORT_RIGHT_RECEIVE) != receive_before) c.atf_tc_fail("OOL ports reference counts changed after cleanup");
    }
    if (c.mach_port_destroy(c.mach_task_self(), destination) != 0 or c.mach_port_destroy(c.mach_task_self(), carried) != 0) c.atf_tc_fail("OOL ports receive right cleanup failed");
}
fn point(value: [*:0]const u8) void {
    const std = @import("std");
    if (c.sysctlbyname("debug.fail_point.mach_ool_copyout", null, null, @constCast(value), std.mem.len(value)) != 0) c.atf_tc_fail("copyout fail point control failed");
}
fn mapped() u64 {
    var size: usize = @sizeOf(u64);
    var value: u64 = 0;
    if (c.sysctlbyname("debug.rmx_map_size", &value, &size, null, 0) != 0 or size != @sizeOf(u64)) c.atf_tc_fail("map size observation failed");
    return value;
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    if (@offsetOf(Message, "ool") != 28 or @sizeOf(Ool) != 16) @compileError("Mach OOL wire layout");
    var path: [4096]u8 = undefined;
    _ = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (c.kldload(&path) < 0) c.atf_tc_fail("OOL fixture load failed");
    const port = fm.allocate();
    const payload: [16]u8 = [_]u8{0x56} ** 16;
    for (0..2) |iteration| {
        var msg = Message{ .header = .{ .bits = 0x80000000 | 20, .size = 44, .remote = port, .local = 0, .voucher = 0, .id = 569 }, .count = 1, .ool = .{ .address = @intFromPtr(&payload), .deallocate = 0, .copy = 0, .pad = 0, .kind = 1, .size = payload.len }, .trailer = [_]u8{0} ** 128 };
        if (c.syscall(c.SYS_mach_msg_trap, &msg, @as(u32, 0x11), @as(u32, 44), @as(u32, 0), @as(u32, 0), @as(u32, 1000), @as(u32, 0)) != 0) c.atf_tc_fail("OOL send failed");
        point(if (iteration == 0) "off" else "1*return(1)");
        const before = mapped();
        const result = c.syscall(c.SYS_mach_msg_trap, &msg, @as(u32, 0x102), @as(u32, 0), @as(u32, @sizeOf(Message)), port, @as(u32, 1000), @as(u32, 0));
        const after = mapped();
        point("off");
        if (iteration == 0) {
            if (result != 0 or msg.ool.size != payload.len or msg.ool.address == 0) c.atf_tc_fail("successful OOL copyout failed");
            const bytes: *const [16]u8 = @ptrFromInt(msg.ool.address);
            if (!@import("std").mem.eql(u8, bytes, &payload)) c.atf_tc_fail("OOL payload differs");
            if (c.syscall(c.SYS__kernelrpc_mach_vm_deallocate_trap, @as(u32, 0), msg.ool.address, @as(u64, 4096)) != 0) c.atf_tc_fail("OOL mapping cleanup failed");
        } else {
            _ = c.printf("ool_failure expected_result=%u observed_result=%u expected_mapped=%llu observed_mapped=%llu expected_address=0 observed_address=%llu expected_size=0 observed_size=%u\n", @as(u32, 0x1000500c), @as(u32, @bitCast(result)), before, after, msg.ool.address, msg.ool.size);
            if (result != 0x1000500c or after != before or msg.ool.address != 0 or msg.ool.size != 0) c.atf_tc_fail("failed OOL copyout leaked a mapping or did not return its error");
        }
    }
    if (c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(u32, 0), port) != 0) c.atf_tc_fail("receive right cleanup failed");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    point("off");
    portsPoint("off");
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0 and c.kldunload(module) != 0) c.atf_tc_fail("fixture unload failed");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    var err = c.atf_tc_init(&tc, "copyout_failure", &head, &body, &cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    err = c.atf_tp_add_tc(tp, &tc);
    if (c.atf_is_error(err)) return err;
    err = c.atf_tc_init(&ports_tc, "ports_allocate_failure", &head, &portsBody, &cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    err = c.atf_tp_add_tc(tp, &ports_tc);
    if (c.atf_is_error(err)) return err;
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
