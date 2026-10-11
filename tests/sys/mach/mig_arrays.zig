// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_port.h");
    @cInclude("mach/mach_host.h");
    @cInclude("mach/host_priv.h");
    @cInclude("mach/clock.h");
    @cInclude("mach/task.h");
    @cInclude("mach/mach_vm.h");
    @cInclude("mach/vm_map.h");
    @cInclude("mach/ndr.h");
    @cInclude("mach/vm_region.h");
    @cInclude("mach/vm_statistics.h");
    @cInclude("atf-c.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});
const fm = @import("file_message.zig");
fn fact(name: [*:0]const u8, expected: i32, observed: i32) void {
    _ = c.printf("mig_arrays call=%s expected=%d observed=%d\n", name, expected, observed);
    if (expected != observed) c.atf_tc_fail("counted-array result differs");
}
pub fn limits(count: u32, temp: bool) void {
    const port = fm.allocate();
    defer _ = c.close(@intCast(port));
    // launchd passes sizeof(limits) as an element count. Supply that many
    // initialized elements so this call shape does not read beyond the test.
    var info: [4]i32 = .{ 3, 0, 0, 0 };
    const flavor = if (temp) c.MACH_PORT_TEMPOWNER else c.MACH_PORT_LIMITS_INFO;
    fact("set_attributes", 0, c.mach_port_set_attributes(c.mach_task_self(), port, flavor, &info, count));
    var out: [17]i32 = @splat(0);
    var n: u32 = 17;
    fact("get_attributes", 0, c.mach_port_get_attributes(c.mach_task_self(), port, c.MACH_PORT_LIMITS_INFO, &out, &n));
    fact("limits_count", 1, @intCast(n));
    fact("limits_value", if (temp) c.MACH_PORT_QLIMIT_DEFAULT else 3, out[0]);
}
pub fn maximum() void {
    const port = fm.allocate();
    defer _ = c.close(@intCast(port));
    const reply = fm.allocate();
    defer _ = c.close(@intCast(reply));
    // Bypass the client-side maximum check to exercise the kernel checker.
    var req: extern struct { head: fm.Header, descriptors: u32, ndr: c.NDR_record_t, name: u32, flavor: i32, count: u32, info: [18]i32 } = .{
        .head = .{ .bits = @as(u32, c.MACH_MSGH_BITS_COMPLEX) | 19 | (21 << 8), .size = 120, .remote = c.mach_task_self(), .local = reply, .voucher = 0, .id = 3218 },
        .descriptors = 0,
        .ndr = c.NDR_record,
        .name = port,
        .flavor = c.MACH_PORT_LIMITS_INFO,
        .count = 18,
        .info = @splat(0),
    };
    if (@sizeOf(@TypeOf(req)) != 120) @compileError("request wire size");
    var response: [256]u8 align(8) = @splat(0);
    fact("oversized_send", 0, c.mach_msg(@ptrCast(&req), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 120, 0, 0, 0, 0));
    fact("oversized_receive", 0, c.mach_msg(@ptrCast(&response), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, response.len, reply, 1000, 0));
    fact("oversized_reply_id", 3318, @as(*fm.Header, @ptrCast(&response)).id);
    fact("oversized_count", c.MIG_BAD_ARGUMENTS, @as(*i32, @ptrCast(@alignCast(response[32..].ptr))).*);
}
pub fn inventory() void {
    const self = c.mach_task_self();
    const host = c.mach_host_self();
    defer _ = c.mach_port_deallocate(self, host);
    const port = fm.allocate();
    defer _ = c.close(@intCast(port));
    var words: [256]i32 = @splat(0);
    var n: u32 = 68;
    fact("host_info", 46, c.host_info(host, c.HOST_BASIC_INFO, &words, &n));
    n = 68;
    fact("host_statistics", 46, c.host_statistics(host, c.HOST_VM_INFO, &words, &n));
    n = 256;
    fact("host_statistics64", 46, c.host_statistics64(host, 4, &words, &n));
    n = 68;
    fact("host_priv_statistics", 46, c.host_priv_statistics(host, c.HOST_VM_INFO, &words, &n));
    var boot: [4096]u8 = @splat(0);
    var version: [512]u8 = @splat(0);
    fact("host_get_boot_info", 46, c.host_get_boot_info(host, &boot));
    fact("host_kernel_version", 46, c.host_kernel_version(host, &version));
    var voucher: u32 = 0;
    var recipe: [16]u8 = @splat(0);
    fact("host_create_mach_voucher", 46, c.host_create_mach_voucher(host, &recipe, 0, &voucher));
    var seq: u32 = 0;
    var msg_size: u32 = 0;
    var msg_id: i32 = 0;
    n = 68;
    fact("mach_port_peek", 46, c.mach_port_peek(self, port, c.MACH_MSG_TRAILER_FORMAT_0, &seq, &msg_size, &msg_id, @ptrCast(&words), &n));
    n = 52;
    fact("task_info", 0, c.task_info(self, c.TASK_BASIC_INFO, &words, &n));
    fact("task_set_info", 4, c.task_set_info(self, c.TASK_DYLD_INFO, &words, 5));
    var default: i32 = 0;
    n = 16;
    fact("task_policy_get", 46, c.task_policy_get(self, c.TASK_CATEGORY_POLICY, &words, &n, &default));
    fact("task_policy_set", 46, c.task_policy_set(self, c.TASK_CATEGORY_POLICY, &words, 1));
    fact("task_policy", 5, c.task_policy(self, c.POLICY_TIMESHARE, &words, 1, 0, 0));
    var pset: u32 = 0;
    fact("processor_set_default", 0, c.processor_set_default(host, &pset));
    defer _ = c.mach_port_deallocate(self, pset);
    fact("task_set_policy", 5, c.task_set_policy(self, pset, c.POLICY_TIMESHARE, &words, 1, &words, 1, 0));
    var state: [32]u32 = @splat(0);
    n = 32;
    fact("task_get_state", 46, c.task_get_state(self, c.THREAD_STATE_NONE, &state, &n));
    fact("task_set_state", 46, c.task_set_state(self, c.THREAD_STATE_NONE, &state, 0));
    var thread: u32 = 0;
    fact("thread_create_running", 46, c.thread_create_running(self, c.THREAD_STATE_NONE, &state, 0, &thread));
    var masks: [32]u32 = @splat(0);
    var handlers: [32]u32 = @splat(0);
    var behaviors: [32]i32 = @splat(0);
    var flavors: [32]i32 = @splat(0);
    n = 32;
    fact("host_get_exception_ports", 0, c.host_get_exception_ports(host, c.EXC_MASK_BAD_ACCESS, &masks, &n, &handlers, &behaviors, &flavors));
    n = 32;
    fact("host_swap_exception_ports", 0, c.host_swap_exception_ports(host, c.EXC_MASK_BAD_ACCESS, 0, c.EXCEPTION_DEFAULT, c.THREAD_STATE_NONE, &masks, &n, &handlers, &behaviors, &flavors));
    n = 32;
    fact("task_get_exception_ports", 0, c.task_get_exception_ports(self, c.EXC_MASK_BAD_ACCESS, &masks, &n, &handlers, &behaviors, &flavors));
    n = 32;
    fact("task_swap_exception_ports", 0, c.task_swap_exception_ports(self, c.EXC_MASK_BAD_ACCESS, 0, c.EXCEPTION_DEFAULT, c.THREAD_STATE_NONE, &masks, &n, &handlers, &behaviors, &flavors));
    var address: u64 = 0;
    var size: u64 = 0;
    var depth: u32 = 0;
    var object: u32 = 0;
    n = 10;
    fact("mach_vm_region", 46, c.mach_vm_region(self, &address, &size, 9, &words, &n, &object));
    n = 19;
    fact("mach_vm_region_recurse", 46, c.mach_vm_region_recurse(self, &address, &size, &depth, &words, &n));
    n = 32;
    fact("mach_vm_page_info", 46, c.mach_vm_page_info(self, 0, 1, &words, &n));
    n = 10;
    fact("vm_region", 46, c.vm_region(self, &address, &size, 9, &words, &n, &object));
    n = 10;
    fact("vm_region_64", 46, c.vm_region_64(self, &address, &size, 9, &words, &n, &object));
    n = 19;
    fact("vm_region_recurse", 46, c.vm_region_recurse(self, &address, &size, &depth, &words, &n));
    n = 19;
    fact("vm_region_recurse_64", 46, c.vm_region_recurse_64(self, &address, &size, &depth, &words, &n));
    // The clock service is not implemented, so a real clock-port call is
    // unavailable. Record that prerequisite instead of using a wrong target.
    var clock: u32 = 0;
    fact("clock_service_prerequisite", 46, c.host_get_clock_service(host, 0, &clock));
    fact("clock_service_empty", 0, @intCast(clock));
}
