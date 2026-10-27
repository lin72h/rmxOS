const std = @import("std");
const checks = @import("checks.zig");
const install = @import("install_checks.zig");
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
fn first(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.fileRules(true) catch |err| c.atf_tc_fail("first update: %s", @errorName(err).ptr);
}
fn second(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.fileRules(false) catch |err| c.atf_tc_fail("second update: %s", @errorName(err).ptr);
}
fn negative(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.negative() catch |err| c.atf_tc_fail("negative: %s", @errorName(err).ptr);
}
fn unsafePaths(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.unsafe() catch |err| c.atf_tc_fail("unsafe path: %s", @errorName(err).ptr);
}
fn fakeBE(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.orchestration(false) catch |err| c.atf_tc_fail("fake BE: %s", @errorName(err).ptr);
}
fn failedHints(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.orchestration(true) catch |err| c.atf_tc_fail("hints refusal: %s", @errorName(err).ptr);
}
fn guest(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    if (!c.atf_tc_has_config_var(tc, "install_fixture")) c.atf_tc_skip("requires a disposable guest commissioned for an install");
    install.guestInstall() catch |err| c.atf_tc_fail("guest install: %s", @errorName(err).ptr);
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "20");
    _ = c.atf_tc_set_md_var(tc, "require.user", "root");
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), "install_guest")) {
        _ = c.atf_tc_set_md_var(tc, "timeout", "120");
        _ = c.atf_tc_set_md_var(tc, "require.config", "install_fixture");
    }
}
var cases: [14]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "arguments", "refusals", "list_local", "malformed_catalog", "status_fields", "not_implemented", "installed", "first_update", "second_update", "install_refusals", "unsafe_paths", "fake_bectl", "hints_failure", "install_guest" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ arguments, refusals, listing, malformed, status, disabled, installed, first, second, negative, unsafePaths, fakeBE, failedHints, guest };
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
