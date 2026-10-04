// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/linker.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("pthread.h");
    @cInclude("string.h");
});
const std = @import("std");
var receive: u32 = 0;
var result: c_long = 0;
var done: u32 = 0;
var wire: [128]u32 = undefined;
fn control(op: u32, value: u32) [8]u32 {
    var input: u64 = (@as(u64, op) << 32) | value;
    var out: [8]u32 = [_]u32{0} ** 8;
    var size: usize = @sizeOf(@TypeOf(out));
    if (c.sysctlbyname("debug.rmx_revoke_control", &out, &size, &input, 8) != 0 or size != 32) c.atf_tc_fail("revocation fixture failed");
    return out;
}
fn worker(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = control(3, 0);
    result = c.syscall(c.SYS_mach_msg_trap, &wire, @as(c_uint, 0x102), @as(c_uint, 0), @as(c_uint, @sizeOf(@TypeOf(wire))), receive, @as(c_uint, 2000), @as(c_uint, 0));
    if (result == 0 and (wire[0] & 0x80000000) != 0) { // release the transferred send right on the defective base
        _ = c.syscall(c.SYS__kernelrpc_mach_port_deallocate_trap, @as(c_uint, 0), wire[7]);
    }
    _ = control(9, 0);
    @atomicStore(u32, &done, 1, .release);
    return null;
}
pub fn body(t: anytype) void {
    const set = c.strcmp(c.atf_tc_get_ident(@ptrCast(t)), "revoked_set") == 0;
    var path: [4096]u8 = undefined;
    _ = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(@ptrCast(t), "srcdir"));
    if (c.kldload(&path) < 0) c.atf_tc_fail("fixture load failed");
    var port: u32 = 0;
    var pset: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &port) != 0) c.atf_tc_fail("port allocation failed");
    receive = port;
    if (set) {
        if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 3), &pset) != 0 or c.syscall(c.SYS__kernelrpc_mach_port_move_member_trap, @as(c_uint, 0), port, pset) != 0) c.atf_tc_fail("set allocation failed");
        receive = pset;
    }
    _ = control(1, receive);
    _ = control(2, port);
    const before = control(4, 0);
    @atomicStore(u32, &done, 0, .release);
    var thread: c.pthread_t = undefined;
    if (c.pthread_create(&thread, null, &worker, null) != 0) c.atf_tc_fail("receive thread failed");
    var enrolled = false;
    for (0..1000) |_| {
        if (control(4, 0)[0] == 1) {
            enrolled = true;
            break;
        }
        _ = c.usleep(1000);
    }
    if (!enrolled) c.atf_tc_fail("receive enrollment was not observed");
    _ = control(5, 0);
    var woke = false;
    for (0..200) |_| {
        if (@atomicLoad(u32, &done, .acquire) == 1) {
            woke = true;
            break;
        }
        _ = c.usleep(1000);
    }
    _ = control(6, 0);
    if (c.pthread_join(thread, null) != 0) c.atf_tc_fail("receive join failed");
    const held = control(4, 0);
    _ = control(7, 0);
    if (set) _ = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), port);
    const after = control(4, 0);
    const expected_object_refs = before[3] + @as(u32, if (set) 0 else 1);
    _ = c.printf("entry_revoke expected_enrolled=1 observed_enrolled=%d expected_wake=1 observed_wake=%d expected_result=0x10004009 observed_result=0x%x expected_queued=1 observed_queued=%u expected_carried=1 observed_carried=%u expected_entry_refs=%u observed_entry_refs=%u expected_object_refs=%u observed_object_refs=%u expected_post_rights=0 observed_post_rights=%u\n", @as(c_int, @intFromBool(enrolled)), @as(c_int, @intFromBool(woke)), result, held[4], held[5], before[2] - 1, held[2], expected_object_refs, held[3], after[5]);
    _ = control(8, 0);
    _ = c.close(@intCast(receive));
    if (result != 0x10004009 or !woke or held[4] != 1 or held[5] != 1 or held[2] != before[2] - 1 or held[3] != expected_object_refs or after[5] != 0) c.atf_tc_fail("revoked admitted entry received or did not wake");
}
