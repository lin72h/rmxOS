// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("notify.h");
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn notify_register_dispatch([*:0]const u8, *c_int, ?*anyopaque, *const anyopaque) u32;
extern fn dispatch_get_global_queue(c_long, usize) ?*anyopaque;
extern var _NSConcreteGlobalBlock: [32]usize;
const Descriptor = extern struct { reserved: usize = 0, size: usize = @sizeOf(Block) };
const Block = extern struct {
    isa: *anyopaque = &_NSConcreteGlobalBlock,
    flags: c_int = 1 << 28,
    reserved: c_int = 0,
    invoke: *const fn (*const Block, c_int) callconv(.c) void = handler,
    descriptor: *const Descriptor = &descriptor,
};
const descriptor: Descriptor = .{};
const block: Block = .{};
fn handler(_: *const Block, _: c_int) callconv(.c) void {}
var lookups: u32 = 0;
var inserts: u32 = 0;
// Fixture boundaries: unavailable bootstrap service and observable insert calls.
pub export fn bootstrap_look_up2(_: u32, _: [*:0]const u8, port: *u32, _: c_int, _: u64) c_int {
    lookups += 1;
    port.* = 0;
    return 1102; // BOOTSTRAP_UNKNOWN_SERVICE
}
pub export fn mach_port_insert_right(_: u32, _: u32, _: u32, _: u32) c_int {
    inserts += 1;
    return c.KERN_INVALID_VALUE;
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var token: c_int = -1;
    for (0..3) |_| {
        const status = notify_register_dispatch("com.apple.system.notify.service.path:0x87:/etc/asl/.noquota", &token, dispatch_get_global_queue(0, 0), &block);
        if (status != c.NOTIFY_STATUS_FAILED or token != -1) c.atf_tc_fail("early dispatch status=%u token=%d", status, token);
        var port: u32 = 0;
        const reused = c.notify_register_mach_port("op824.unavailable", &port, c.NOTIFY_REUSE, &token);
        if (reused == c.NOTIFY_STATUS_OK or token != -1 or port != 0) c.atf_tc_fail("early reuse status=%u token=%d port=%u", reused, token, port);
        const allocated = c.notify_register_mach_port("op824.unavailable", &port, 0, &token);
        if (allocated != c.NOTIFY_STATUS_FAILED or token != -1 or port != 0) c.atf_tc_fail("early allocate status=%u token=%d port=%u", allocated, token, port);
    }
    _ = c.printf("notify_startup expected_lookups=1 observed=%u expected_inserts=0 observed=%u\n", lookups, inserts);
    if (lookups != 1 or inserts != 0) c.atf_tc_fail("unavailable notifyd reached insert-right");
}
var tc: c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "unavailable", null, body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
