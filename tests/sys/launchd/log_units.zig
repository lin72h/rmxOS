const std = @import("std");
const f = @import("job_fixture.zig");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [3]c.atf_tc_t = undefined;
fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    const binary = if (std.mem.eql(u8, name, "queue")) "/usr/tests/sys/launchd/log_queue_unit" else if (std.mem.eql(u8, name, "binding")) "/usr/tests/sys/launchd/log_binding_unit" else "/usr/tests/sys/launchd/job_actions_unit";
    if (f.run(&.{binary}) != 0) c.atf_tc_fail("launchd logger unit runner failed");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for ([_][*:0]const u8{ "queue", "binding", "job_actions" }, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, null, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
