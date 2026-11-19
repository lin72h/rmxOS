// SPDX-License-Identifier: BSD-2-Clause
// Exercise the real library constructor with a controlled bootstrap RPC.
// Static Mach programs remain unsupported; no Mach syscall is needed here.
const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});
extern var bootstrap_port: c.mach_port_t;
extern fn mach_init() void;
var fetches: c_uint = 0;
var logs: c_uint = 0;

pub export fn task_self_trap() c.mach_port_t {
    return 123;
}
pub export fn mach_reply_port() c.mach_port_t {
    return 124;
}
pub export fn task_get_special_port(_: c.mach_port_t, _: c_int, port: *c.mach_port_t) c.kern_return_t {
    fetches += 1;
    if (c.getenv("RMX_MACH_INIT_FAIL") != null) {
        // A failing RPC may have touched its output: failure must clear it.
        port.* = 125;
        return c.KERN_FAILURE;
    }
    port.* = c.MACH_PORT_NULL;
    return c.KERN_SUCCESS;
}
// Interpose the log sink so the case observes calls without logging itself.
pub export fn syslog(_: c_int, _: [*:0]const u8) void {
    logs += 1;
}
pub export fn main() c_int {
    _ = c.printf("initial bootstrap=%u fetches=%u logs=%u\n", bootstrap_port, fetches, logs);
    mach_init();
    mach_init();
    _ = c.printf("repeat bootstrap=%u fetches=%u logs=%u\n", bootstrap_port, fetches, logs);
    return 0;
}
