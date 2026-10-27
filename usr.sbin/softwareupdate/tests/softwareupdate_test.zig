const checks = @import("checks.zig");
const c = @cImport({
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn arguments(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.arguments() catch c.atf_tc_fail("argument parsing");
}
fn refusals(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.refusals() catch c.atf_tc_fail("BE refusals");
}
fn listing(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.listing() catch c.atf_tc_fail("catalog applicability");
}
fn malformed(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.malformed() catch c.atf_tc_fail("malformed catalog");
}
fn status(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.statusFields() catch c.atf_tc_fail("status fields");
}
fn disabled(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.unimplemented() catch c.atf_tc_fail("changing commands disabled");
}
fn installed(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.installed() catch c.atf_tc_fail("installed command");
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "20");
    _ = c.atf_tc_set_md_var(tc, "require.user", "root");
}
var cases: [7]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "arguments", "refusals", "list_local", "malformed_catalog", "status_fields", "not_implemented", "installed" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ arguments, refusals, listing, malformed, status, disabled, installed };
    for (&cases, names, bodies) |*tc, name, body| {
        var e = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
