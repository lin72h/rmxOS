// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn Case(comptime number: c_int, comptime name: [:0]const u8) type {
    return struct {
        var tc: c.atf_tc_t = undefined;
        fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
            _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach yield returns with the scheduler thread lock released");
            _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
        }
        fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
            const observed = c.syscall(number, @as(c_int, 0));
            const err = c.__error().*;
            _ = c.printf("operation=%s expected=0 observed=%ld errno=%d\n", name.ptr, observed, err);
            if (observed != 0) c.atf_tc_fail("yield expected=0 observed=%ld errno=%d", observed, err);
        }
    };
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const config = c.atf_tp_get_config(tp);
    inline for (.{ Case(c.SYS_swtch_pri, "swtch_pri"), Case(c.SYS_swtch, "swtch") }, .{ "swtch_pri", "swtch" }) |T, name| {
        const err = c.atf_tc_init(&T.tc, name, &T.head, &T.body, null, config);
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &T.tc);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
