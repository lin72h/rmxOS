// SPDX-License-Identifier: BSD-2-Clause
const fm = @import("file_message.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/syscall.h");
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
var bad: bool = false;
fn closer(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    for (0..1000) |_| {
        const port = fm.allocate();
        if (c.sysctlbyname("mach.current_task_port_name", null, null, @constCast(&port), @sizeOf(u32)) != 0 or c.close(@intCast(port)) != 0) bad = true;
    }
    return null;
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var worker: c.pthread_t = undefined;
    bad = false;
    if (c.pthread_create(&worker, null, &closer, null) != 0) c.atf_tc_fail("closer thread creation failed");
    var reads: usize = 0;
    for (0..1000) |_| {
        inline for (.{ "mach.current_task_space_stats", "mach.current_task_port_status" }) |name| {
            var buf: [512]u8 = undefined;
            var size: usize = buf.len;
            if (c.sysctlbyname(name, &buf, &size, null, 0) != 0 or size == 0 or size > buf.len) c.atf_tc_fail("debug sysctl read failed");
            reads += 1;
        }
    }
    if (c.pthread_join(worker, null) != 0 or bad) c.atf_tc_fail("concurrent close failed");
    var zero: u32 = 0;
    if (c.sysctlbyname("mach.current_task_port_name", null, null, &zero, @sizeOf(u32)) != 0) c.atf_tc_fail("selector cleanup failed");
    _ = c.printf("debug_sysctls expected_reads=2000 observed_reads=%zu expected_closes=1000 observed_closes=1000\n", reads);
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    var e = c.atf_tc_init(&tc, "concurrent_close", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(e)) return e;
    e = c.atf_tp_add_tc(tp, &tc);
    return e;
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
