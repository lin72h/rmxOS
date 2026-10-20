// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
fn need(ok: bool, message: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", message);
}
fn knob(name: [*:0]const u8) void {
    var zero: c_int = 0;
    need(c.sysctlbyname(name, null, null, &zero, @sizeOf(c_int)) == 0, "disable debug knob");
}
fn msgbuf(buffer: []u8) []const u8 {
    var size: usize = buffer.len;
    need(c.sysctlbyname("kern.msgbuf", buffer.ptr, &size, null, 0) == 0, "read kern.msgbuf");
    return std.mem.trimEnd(u8, buffer[0..size], &.{0});
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    knob("debug.mach.ipc_entry_lookup_failed_log");
    knob("debug.mach.ipc_right_copyin_failed_log");
    var receive: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &receive) == 0, "receive right setup");
    var before_storage: [2 * 1024 * 1024]u8 = undefined;
    var after_storage: [2 * 1024 * 1024]u8 = undefined;
    const before = msgbuf(&before_storage);
    for (0..1000) |_| {
        var msg = std.mem.zeroes(c.mach_msg_header_t);
        msg.msgh_size = @sizeOf(c.mach_msg_header_t);
        msg.msgh_bits = c.MACH_MSG_TYPE_COPY_SEND;
        msg.msgh_remote_port = 0x7fff_fffe;
        need(c.mach_msg(&msg, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, msg.msgh_size, 0, 0, 0, 0) == c.MACH_SEND_INVALID_DEST, "nonexistent name error");
        msg.msgh_remote_port = receive;
        need(c.mach_msg(&msg, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, msg.msgh_size, 0, 0, 0, 0) == c.MACH_SEND_INVALID_DEST, "receive-only name lacks send right");
    }
    const after = msgbuf(&after_storage);
    // Fail closed if rotation prevents attributing the new bytes to this interval.
    need(std.mem.startsWith(u8, after, before), "msgbuf rotated during quiet-error check");
    const added = after[before.len..];
    for ([_][]const u8{ "ipc_right_lookup failed", "ipc_right_copyin failed", "entry for port name" }) |text| {
        need(std.mem.indexOf(u8, added, text) == null, "ordinary Mach error added a console diagnostic");
    }
    _ = c.printf("mach_error_prints expected_missing_errors=1000 observed_missing_errors=1000 expected_right_errors=1000 observed_right_errors=1000 expected_diagnostics=0 observed_diagnostics=0 added_msgbuf_bytes=%zu\n", added.len);
    need(c.mach_port_destroy(c.mach_task_self(), receive) == 0, "receive right cleanup");
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    var e = c.atf_tc_init(&tc, "quiet_errors", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(e)) return e;
    e = c.atf_tp_add_tc(tp, &tc);
    return e;
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
