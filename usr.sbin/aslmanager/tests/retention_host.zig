// Host-only preload adapter, never installed. The CLI/retention implementation
// is the unchanged product binary. Only host privilege, bootstrap/config
// discovery, constructors and the wall-clock input are projected here.
const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});
pub export fn geteuid() c_uint {
    return 0;
}
pub export fn time(out: ?*c.time_t) c.time_t {
    var now: c.time_t = undefined;
    if (c.getenv("RMX_RETENTION_TIME")) |value| {
        now = std.fmt.parseInt(c.time_t, std.mem.span(value), 10) catch @panic("retention clock input");
    } else {
        var ts: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_REALTIME, &ts) != 0) return -1;
        now = ts.tv_sec;
    }
    if (out) |p| p.* = now;
    return now;
}
pub export fn vproc_swap_integer(_: ?*anyopaque, _: c_int, _: ?*i64, out: ?*i64) ?*anyopaque {
    if (out) |p| p.* = 0;
    return null;
}
pub export fn asl_out_module_init() ?*anyopaque {
    return null;
}
pub export fn mach_init() void {}
pub export fn _libdispatch_init() void {}
pub export fn dispatch_once_f(predicate: *isize, context: ?*anyopaque, function: *const fn (?*anyopaque) callconv(.c) void) void {
    if (predicate.* == 0) {
        predicate.* = -1;
        function(context);
    }
}
const Block = extern struct {
    isa: ?*anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *const fn (*const Block) callconv(.c) void,
};
pub export fn dispatch_once(predicate: *isize, block: *const Block) void {
    if (predicate.* == 0) {
        predicate.* = -1;
        block.invoke(block);
    }
}
pub export fn notify_register_plain(_: [*:0]const u8, _: *c_int) c_uint {
    return 1;
}
pub export fn notify_register_check(_: [*:0]const u8, _: *c_int) c_uint {
    return 1;
}
