// SPDX-License-Identifier: BSD-2-Clause
// An OOL source the kernel cannot read returns MACH_SEND_INVALID_MEMORY; a
// copy the count declines returns MACH_MSG_VM_KERNEL, as macOS reports a
// kernel allocation it cannot make.
const lim = @import("ool_limits.zig");
const c = lim.c;
const need = lim.need;

fn unmappedAddress(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const start = lim.bytes();
    const buf = lim.map(lim.page);
    lim.unmap(buf);
    const unmapped = !lim.mapped(buf);
    const dest = lim.port();
    var m = lim.Message(1).init(dest, .{.{ .address = @intFromPtr(buf.ptr), .size = @intCast(lim.page) }});
    const rc = m.send();
    const after = lim.settle(start);
    const pending = lim.queued(dest);
    _ = c.printf("ool_unmapped_address expected_unmapped=1 observed_unmapped=%d expected_rc=%d observed_rc=%d expected_bytes=%lu observed_bytes=%lu expected_queued=0 observed_queued=%u\n", @as(c_int, @intFromBool(unmapped)), @as(c_int, c.MACH_SEND_INVALID_MEMORY), rc, start, after, pending);
    need(unmapped, "region still mapped");
    need(rc == c.MACH_SEND_INVALID_MEMORY, "unreadable OOL source not refused with MACH_SEND_INVALID_MEMORY");
    need(after == start and pending == 0, "refused send left bytes counted or a message queued");
    lim.destroy(dest);
}

// mach.ool_max_total at the starting count: no further OOL byte fits until
// the limit is set back.
fn countDeclined(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const start = lim.bytes();
    const buf = lim.map(lim.page);
    lim.fill(buf, 7);
    const dest = lim.port();
    lim.lower(start);
    var m = lim.Message(1).init(dest, .{.{ .address = @intFromPtr(buf.ptr), .size = @intCast(lim.page) }});
    const declined = m.send();
    const held = lim.bytes();
    const pending = lim.queued(dest);
    lim.restore();
    m = lim.Message(1).init(dest, .{.{ .address = @intFromPtr(buf.ptr), .size = @intCast(lim.page) }});
    const accepted = m.send();
    var rrc: c_int = -1;
    var intact = false;
    if (accepted == 0) {
        rrc = m.receive(dest);
        if (rrc == 0) {
            if (m.region(0)) |got| {
                intact = got.len == lim.page and lim.same(got, 7);
                lim.release(m.ool[0].address, got.len);
            }
        }
    }
    const after = lim.settle(start);
    _ = c.printf("ool_count_declined expected_declined=%d observed_declined=%d expected_held=%lu observed_held=%lu expected_queued=0 observed_queued=%u expected_accepted=0 observed_accepted=%d expected_receive=0 observed_receive=%d expected_intact=1 observed_intact=%d expected_bytes=%lu observed_bytes=%lu\n", @as(c_int, c.MACH_MSG_VM_KERNEL), declined, start, held, pending, accepted, rrc, @as(c_int, @intFromBool(intact)), start, after);
    need(declined == c.MACH_MSG_VM_KERNEL, "copy over mach.ool_max_total not refused with MACH_MSG_VM_KERNEL");
    need(held <= start and pending == 0, "declined send counted bytes or queued a message");
    need(accepted == 0 and rrc == 0 and intact, "send after the limit was set back did not arrive intact");
    need(after == start, "mach.ool_bytes not back at its starting value");
    lim.unmap(buf);
    lim.destroy(dest);
}

fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    lim.cleanup();
}
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [2]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "unmapped_address", "count_declined" };
    const bodies = .{ &unmappedAddress, &countDeclined };
    inline for (0..2) |i| {
        const err = c.atf_tc_init(&cases[i], names[i], &head, bodies[i], &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
