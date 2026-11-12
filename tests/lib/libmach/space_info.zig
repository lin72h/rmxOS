// SPDX-License-Identifier: BSD-2-Clause
// An unimplemented debug RPC must refuse rather than send unwritten fields.
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
});

fn unsupported(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var info: c.ipc_info_space_t = undefined;
    var table: c.ipc_info_name_array_t = null;
    var table_count: c.mach_msg_type_number_t = 0;
    var tree: c.ipc_info_tree_name_array_t = null;
    var tree_count: c.mach_msg_type_number_t = 0;
    const rc = c.mach_port_space_info(c.mach_task_self(), &info, &table, &table_count, &tree, &tree_count);
    _ = c.printf("mach_port_space_info expected_rc=%d observed_rc=%d\n", @as(c_int, c.KERN_NOT_SUPPORTED), rc);
    if (rc != c.KERN_NOT_SUPPORTED) c.atf_tc_fail("mach_port_space_info did not refuse with KERN_NOT_SUPPORTED");
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "not_supported", null, &unsupported, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
