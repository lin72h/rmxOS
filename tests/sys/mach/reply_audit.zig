// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/linker.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
fn control(op: u32) u32 {
    var input = op;
    var out: u32 = 0;
    var size: usize = 4;
    if (c.sysctlbyname("debug.rmx_mig_control", &out, &size, &input, 4) != 0 or size != 4) c.atf_tc_fail("MIG fixture failed");
    return out;
}
pub fn body(t: anytype) void {
    var path: [4096]u8 = undefined;
    _ = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(@ptrCast(t), "srcdir"));
    if (c.kldload(&path) < 0) c.atf_tc_fail("fixture load failed");
    const id = control(1);
    var port: u32 = 0;
    if (c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &port) != 0) c.atf_tc_fail("reply port failed");
    const task = c.syscall(c.SYS_task_self_trap);
    var request = [_]u32{ 19 | (21 << 8), 24, @intCast(task), port, 0, id };
    if (c.syscall(c.SYS_mach_msg_trap, &request, @as(c_uint, 1), @as(c_uint, 24), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0), @as(c_uint, 0)) != 0) c.atf_tc_fail("MIG request send failed");
    var wire: [128]u32 = [_]u32{0xa5} ** 128;
    const rc = c.syscall(c.SYS_mach_msg_trap, &wire, @as(c_uint, 0x102 | (3 << 24)), @as(c_uint, 0), @as(c_uint, @sizeOf(@TypeOf(wire))), port, @as(c_uint, 500), @as(c_uint, 0));
    const poisoned = control(3);
    _ = control(2);
    var token = true;
    const offset: usize = wire[1] / 4;
    if (offset + 13 > wire.len) c.atf_tc_fail("reply trailer bounds");
    for (wire[offset + 5 .. offset + 13]) |word| {
        if (word != 0) token = false;
    }
    _ = c.printf("mig_audit expected_poisoned=1 observed_poisoned=%u expected_result=0 observed_result=0x%x expected_kernel_token=1 observed_kernel_token=%d observed_audit0=0x%x\n", poisoned, rc, @as(c_int, @intFromBool(token)), wire[offset + 5]);
    _ = c.syscall(c.SYS__kernelrpc_mach_port_destroy_trap, @as(c_uint, 0), port);
    if (poisoned != 1 or rc != 0 or wire[5] != id + 100 or wire[offset] != 0 or wire[offset + 1] != 52 or !token) c.atf_tc_fail("queued MIG reply audit token was not initialized");
}
