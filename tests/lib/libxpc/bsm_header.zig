// SPDX-License-Identifier: BSD-2-Clause
// libbsm's audit-token field accessors as a consumer sees them: this program
// includes only <bsm/libbsm.h>, so it builds only where the header declares
// them, with audit_token_t visible.
const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline
    // (tests/lib/launchd/receive_capacity.zig does the same).
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("bsm/libbsm.h");
});
const atf = @cImport({
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t) c_int;
fn accessorsDeclared(_: [*c]const atf.atf_tc_t) callconv(.c) void {
    var t: c.audit_token_t = std.mem.zeroes(c.audit_token_t);
    t.val = .{ 11, 977, 978, 979, 980, 1234, 56, 0 };
    const got = [_]i64{ c.audit_token_to_auid(t), c.audit_token_to_euid(t), c.audit_token_to_egid(t), c.audit_token_to_ruid(t), c.audit_token_to_rgid(t), c.audit_token_to_pid(t), c.audit_token_to_asid(t) };
    const want = [_]i64{ 11, 977, 978, 979, 980, 1234, 56 };
    std.debug.print("bsm_header expected={any} observed={any}\n", .{ want, got });
    if (!std.mem.eql(i64, &want, &got)) atf.atf_tc_fail("accessors return the token's fields");
}
var case: atf.atf_tc_t = undefined;
fn add(tp: [*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t {
    const err = atf.atf_tc_init(&case, "accessorsDeclared", null, &accessorsDeclared, null, atf.atf_tp_get_config(tp));
    if (atf.atf_is_error(err)) return err;
    return atf.atf_tp_add_tc(tp, &case);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
