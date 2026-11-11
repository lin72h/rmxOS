// SPDX-License-Identifier: BSD-2-Clause
// mach_port_get_set_status returns its member list as an OOL copy. When the
// copy cannot be made the call returns the error instead of taking the copy
// for granted.
const lim = @import("ool_limits.zig");
const c = lim.c;
const need = lim.need;

const members = 8;
fn status(set: u32, names: *[members]u32) struct { kr: c_int, count: u32, matched: u32 } {
    var array: c.mach_port_name_array_t = null;
    var count: c.mach_msg_type_number_t = 0;
    const kr = c.mach_port_get_set_status(c.mach_task_self(), set, &array, &count);
    var matched: u32 = 0;
    if (kr == 0 and count != 0) {
        for (array[0..count]) |got| {
            for (names) |name| {
                if (got == name) matched += 1;
            }
        }
        lim.release(@intFromPtr(array), count * @sizeOf(c.mach_port_name_t));
    }
    return .{ .kr = kr, .count = count, .matched = matched };
}

fn shortage(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var set: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_PORT_SET, &set) == 0, "port set allocation");
    var names: [members]u32 = undefined;
    for (&names) |*name| {
        name.* = lim.port();
        need(c.mach_port_insert_member(c.mach_task_self(), name.*, set) == 0, "port set member");
    }
    const start = lim.bytes();
    lim.lower(start);
    const short = status(set, &names);
    lim.restore();
    const full = status(set, &names);
    const after = lim.settle(start);
    _ = c.printf("port_set_status_shortage expected_short_kr=%d observed_short_kr=%d expected_kr=0 observed_kr=%d expected_count=%u observed_count=%u expected_matched=%u observed_matched=%u expected_bytes=%lu observed_bytes=%lu\n", @as(c_int, c.KERN_RESOURCE_SHORTAGE), short.kr, full.kr, @as(c_uint, members), full.count, @as(c_uint, members), full.matched, start, after);
    need(short.kr == c.KERN_RESOURCE_SHORTAGE, "mach_port_get_set_status did not return the copy's KERN_RESOURCE_SHORTAGE");
    need(full.kr == 0 and full.count == members and full.matched == members, "mach_port_get_set_status after the limit was set back did not return the members");
    need(after == start, "mach.ool_bytes not back at its starting value");
    for (names) |name| lim.destroy(name);
    lim.destroy(set);
}

fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    lim.cleanup();
}
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "get_set_status_shortage", &head, &shortage, &cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    const added = c.atf_tp_add_tc(tp, &tc);
    if (c.atf_is_error(added)) return added;
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
