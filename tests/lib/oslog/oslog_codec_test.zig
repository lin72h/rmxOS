const std = @import("std");
const checks = @import("checks.zig");
const c = @cImport({
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, ?*const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [5]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "60");
    _ = c.atf_tc_set_md_var(tc, "require.arch", "amd64");
}
fn oracle(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.oracle() catch |err| c.atf_tc_fail("oracle: %s", @errorName(err).ptr);
}
fn malformed(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.malformed() catch |err| c.atf_tc_fail("malformed: %s", @errorName(err).ptr);
}
fn wire(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.wire() catch |err| c.atf_tc_fail("wire: %s", @errorName(err).ptr);
}
fn fieldWidth(_: [*c]const c.atf_tc_t) callconv(.c) void {
    for (0..4) |i| checks.op697(i) catch |err|
        c.atf_tc_fail("field width sample %zu: %s", i, @errorName(err).ptr);
}
fn redactedItems(_: [*c]const c.atf_tc_t) callconv(.c) void {
    for (4..9) |i| checks.op697(i) catch |err|
        c.atf_tc_fail("redacted item sample %zu: %s", i, @errorName(err).ptr);
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "oracle", "malformed", "wire", "field_width", "redacted_items" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ oracle, malformed, wire, fieldWidth, redactedItems };
    for (&cases, names, bodies) |*tc, name, body| {
        var err = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
