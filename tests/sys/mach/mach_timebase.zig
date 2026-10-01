// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("dlfcn.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: [2]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach absolute time is uptime nanoseconds with a 1/1 timebase");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn now() u64 {
    var time: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_UPTIME, &time) != 0) c.atf_tc_fail("uptime failed");
    return @as(u64, @intCast(time.tv_sec)) * 1000000000 + @as(u64, @intCast(time.tv_nsec));
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(t)), "ratio")) {
        var ratio: extern struct { numer: u32, denom: u32 } = undefined;
        if (c.syscall(c.SYS_mach_timebase_info, &ratio) != 0) c.atf_tc_fail("timebase syscall failed");
        _ = c.printf("timebase expected_numer=1 observed_numer=%u expected_denom=1 observed_denom=%u\n", ratio.numer, ratio.denom);
        if (ratio.numer != 1 or ratio.denom != 1) c.atf_tc_fail("timebase is not 1/1");
        return;
    }
    // Load only inside the guest body: metadata listing never initializes libmach.
    const library = c.dlopen("/usr/lib/libmach.so.5", c.RTLD_NOW | c.RTLD_LOCAL) orelse c.atf_tc_fail("staged libmach failed to load");
    defer _ = c.dlclose(library);
    const symbol = c.dlsym(library, "mach_absolute_time") orelse c.atf_tc_fail("mach_absolute_time missing");
    const absolute: *const fn () callconv(.c) u64 = @ptrCast(symbol);
    var previous: u64 = 0;
    for (0..100) |_| {
        const before = now();
        const observed = absolute();
        const after = now();
        if (observed < before or observed > after or observed < previous) c.atf_tc_fail("absolute time is outside uptime interval or regressed");
        previous = observed;
    }
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for ([_][*:0]const u8{ "ratio", "uptime" }, 0..) |name, i| {
        var err = c.atf_tc_init(&tc[i], name, &head, &body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, &tc[i]);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
