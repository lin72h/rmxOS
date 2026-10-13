// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("pthread.h");
    @cInclude("stdio.h");
});
extern fn pthread_mach_thread_np(usize) u32;
extern fn dispatch_queue_create([*:0]const u8, ?*anyopaque) ?*anyopaque;
extern fn dispatch_sync_f(?*anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_release(?*anyopaque) void;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn threadPort() u32 {
    return pthread_mach_thread_np(@intFromPtr(c.pthread_self()));
}
fn refs(p: u32) u32 {
    var n: u32 = 0;
    if (c.mach_port_get_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_SEND, &n) != 0) c.atf_tc_fail("thread send query");
    return n;
}
const Context = struct { port: u32, callbacks: usize = 0 };
fn callback(value: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(value.?));
    if (threadPort() != ctx.port) c.atf_tc_fail("sync callback thread port changed");
    ctx.callbacks += 1;
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Queue operations borrow one cached thread send right");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "60");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var ctx = Context{ .port = threadPort() };
    const before = refs(ctx.port);
    const queue = dispatch_queue_create("op672.thread-port", null) orelse c.atf_tc_fail("queue allocation");
    for (0..70000) |_| dispatch_sync_f(queue, &ctx, callback);
    const after = refs(ctx.port);
    dispatch_release(queue);
    _ = c.printf("thread_port queue_operations=%zu expected=%u observed=%u\n", ctx.callbacks, before, after);
    if (before != 1 or after != before or ctx.callbacks != 70000) c.atf_tc_fail("thread send urefs grew before=%u after=%u", before, after);
}
var tc: c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "queue_port_steady", head, body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, add);
}
