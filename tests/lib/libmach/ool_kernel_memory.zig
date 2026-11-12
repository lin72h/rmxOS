// SPDX-License-Identifier: BSD-2-Clause
// OOL copy buffers live in the kernel from send to receive. mach.ool_bytes
// counts them, mach.ool_max_message bounds one message's OOL bytes and
// mach.ool_max_total all of them; a send over either returns
// MACH_MSG_VM_KERNEL.
const std = @import("std");
const lim = @import("ool_limits.zig");
const c = lim.c;
const need = lim.need;

// Two regions, each within mach.ool_max_message, together over it. The
// refusal comes before any copy, so both stay mapped though they ask to be
// deallocated.
fn messageLimit(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const start = lim.bytes();
    const max = lim.read("mach.ool_max_message");
    const half: usize = std.mem.alignForward(usize, @intCast(max / 2 + 1), lim.page);
    const a = lim.map(half);
    const b = lim.map(half);
    lim.fill(a, 1);
    lim.fill(b, 2);
    const dest = lim.port();
    var m = lim.Message(2).init(dest, .{
        .{ .address = @intFromPtr(a.ptr), .size = @intCast(half), .deallocate = 1 },
        .{ .address = @intFromPtr(b.ptr), .size = @intCast(half), .deallocate = 1 },
    });
    const rc = m.send();
    const after = lim.settle(start);
    const pending = lim.queued(dest);
    const kept = lim.mapped(a) and lim.mapped(b) and lim.same(a, 1) and lim.same(b, 2);
    _ = c.printf("ool_message_limit max=%lu sum=%lu expected_rc=%d observed_rc=%d expected_bytes=%lu observed_bytes=%lu expected_queued=0 observed_queued=%u expected_sender_kept=1 observed_sender_kept=%d\n", max, @as(c_ulong, 2 * half), @as(c_int, c.MACH_MSG_VM_KERNEL), rc, start, after, pending, @as(c_int, @intFromBool(kept)));
    need(rc == c.MACH_MSG_VM_KERNEL, "send over mach.ool_max_message not refused with MACH_MSG_VM_KERNEL");
    need(kept, "refused send changed or unmapped the sender's regions");
    need(after == start and pending == 0, "refused send left bytes counted or a message queued");
    lim.unmap(a);
    lim.unmap(b);
    lim.destroy(dest);
}

// With mach.ool_max_total at the starting count plus 1 MiB, three 300 KiB
// messages queue and a fourth is refused. The bytes return when the three
// are received, and in the second round when their port is destroyed.
const region: usize = 300 * 1024;
fn totalLimit(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const start = lim.bytes();
    const limit = start + 1024 * 1024;
    var bufs: [4][]u8 = undefined;
    for (&bufs, 0..) |*buf, i| {
        buf.* = lim.map(region);
        lim.fill(buf.*, 10 + i);
    }
    lim.lower(limit);
    for (0..2) |round| {
        const dest = lim.port();
        var rcs: [4]c_int = undefined;
        for (&rcs, bufs) |*rc, buf| {
            var m = lim.Message(1).init(dest, .{.{ .address = @intFromPtr(buf.ptr), .size = @intCast(region) }});
            rc.* = m.send();
        }
        const held = lim.bytes();
        var received: u32 = 0;
        if (round == 0) {
            for (0..3) |i| {
                var m: lim.Message(1) = undefined;
                if (m.receive(dest) != 0) continue;
                const got = m.region(0) orelse continue;
                if (got.len == region and lim.same(got, 10 + i)) received += 1;
                lim.release(m.ool[0].address, got.len);
            }
            lim.destroy(dest);
        } else {
            lim.destroy(dest);
        }
        const after = lim.settle(start);
        _ = c.printf("ool_total_limit round=%u limit=%lu expected_rcs=0,0,0,%d observed_rcs=%d,%d,%d,%d expected_held=%lu observed_held=%lu expected_received=%u observed_received=%u expected_bytes=%lu observed_bytes=%lu\n", @as(c_uint, @intCast(round)), limit, @as(c_int, c.MACH_MSG_VM_KERNEL), rcs[0], rcs[1], rcs[2], rcs[3], start + 3 * @as(u64, region), held, @as(c_uint, if (round == 0) 3 else 0), received, start, after);
        need(rcs[0] == 0 and rcs[1] == 0 and rcs[2] == 0, "three 300 KiB messages within mach.ool_max_total not queued");
        need(rcs[3] == c.MACH_MSG_VM_KERNEL, "fourth message over mach.ool_max_total not refused with MACH_MSG_VM_KERNEL");
        need(held <= limit, "mach.ool_bytes above mach.ool_max_total");
        need(round != 0 or received == 3, "queued messages did not arrive intact");
        need(after == start, "mach.ool_bytes not back at its starting value");
    }
    lim.restore();
    for (bufs) |buf| lim.unmap(buf);
}

// An OOL ports array holds eight bytes a port in the kernel until copyout.
fn portsArray(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const count = 1024;
    const carried = lim.port();
    need(c.mach_port_insert_right(c.mach_task_self(), carried, carried, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "send right");
    var refs_before: u32 = 0;
    need(c.mach_port_get_refs(c.mach_task_self(), carried, c.MACH_PORT_RIGHT_SEND, &refs_before) == 0, "send refs");
    var names: [count]u32 = @splat(carried);
    const start = lim.bytes();
    for (0..2) |round| {
        const dest = lim.port();
        var m = lim.Message(1).init(dest, .{.{ .address = @intFromPtr(&names), .size = count, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_OOL_PORTS_DESCRIPTOR, .copy = c.MACH_MSG_PHYSICAL_COPY }});
        const rc = m.send();
        const held = lim.settle(start + count * 8);
        var delivered: u32 = 0;
        if (round == 0) {
            if (m.receive(dest) == 0 and m.ool[0].size == count and m.ool[0].address != 0) {
                const got: [*]const u32 = @ptrFromInt(m.ool[0].address);
                for (got[0..count]) |name| {
                    if (name == carried) delivered += 1;
                }
                c.mach_msg_destroy(&m.header);
            }
        }
        lim.destroy(dest);
        const after = lim.settle(start);
        var refs_after: u32 = 0;
        need(c.mach_port_get_refs(c.mach_task_self(), carried, c.MACH_PORT_RIGHT_SEND, &refs_after) == 0, "send refs");
        _ = c.printf("ool_ports_array round=%u expected_rc=0 observed_rc=%d expected_held=%lu observed_held=%lu expected_delivered=%u observed_delivered=%u expected_bytes=%lu observed_bytes=%lu expected_refs=%u observed_refs=%u\n", @as(c_uint, @intCast(round)), rc, start + count * 8, held, @as(c_uint, if (round == 0) count else 0), delivered, start, after, refs_before, refs_after);
        need(rc == 0, "OOL ports message not queued");
        need(held == start + count * 8, "queued OOL ports array not counted at eight bytes a port");
        need(round != 0 or delivered == count, "OOL ports array did not arrive");
        need(after == start, "OOL ports array bytes not released");
        need(refs_after == refs_before, "carried send rights not released");
    }
    lim.destroy(carried);
}

// Regions up to mach.ool_max_message arrive with their content.
fn regionsIntact(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const start = lim.bytes();
    const max = lim.read("mach.ool_max_message");
    const sizes = [_]usize{ 4096, 64 * 1024, 1024 * 1024, 8 * 1024 * 1024, @intCast(max) };
    var ok = true;
    for (sizes, 0..) |size, i| {
        const buf = lim.map(size);
        lim.fill(buf, 100 + i);
        const dest = lim.port();
        var m = lim.Message(1).init(dest, .{.{ .address = @intFromPtr(buf.ptr), .size = @intCast(size) }});
        const rc = m.send();
        var rrc: c_int = -1;
        var intact = false;
        if (rc == 0) {
            rrc = m.receive(dest);
            if (rrc == 0) {
                if (m.region(0)) |got| {
                    intact = got.len == size and lim.same(got, 100 + i);
                    lim.release(m.ool[0].address, got.len);
                }
            }
        }
        const sender_kept = lim.same(buf, 100 + i);
        lim.unmap(buf);
        lim.destroy(dest);
        const after = lim.settle(start);
        _ = c.printf("ool_region size=%lu expected_rc=0 observed_rc=%d expected_receive=0 observed_receive=%d expected_intact=1 observed_intact=%d expected_sender_kept=1 observed_sender_kept=%d expected_bytes=%lu observed_bytes=%lu\n", @as(c_ulong, size), rc, rrc, @as(c_int, @intFromBool(intact)), @as(c_int, @intFromBool(sender_kept)), start, after);
        if (rc != 0 or rrc != 0 or !intact or !sender_kept or after != start) ok = false;
    }
    need(ok, "an OOL region did not arrive intact or left bytes counted");
}

// The kernel's registered-port reply holds three OOL ports until copyout.
fn portsLookup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const start = lim.bytes();
    var ports: c.mach_port_array_t = null;
    var count: c.mach_msg_type_number_t = 0;
    const rc = c.mach_ports_lookup(c.mach_task_self(), &ports, &count);
    const after = lim.bytes();
    _ = c.printf("mach_ports_lookup expected_rc=0 observed_rc=%d expected_count=3 observed_count=%u expected_bytes=%lu observed_bytes=%lu\n", rc, count, start, after);
    need(rc == c.KERN_SUCCESS, "mach_ports_lookup failed");
    need(count == 3, "mach_ports_lookup did not return three registered ports");
    need(after == start, "mach_ports_lookup reply left OOL bytes counted");
    for (ports[0..count]) |port| {
        if (port != c.MACH_PORT_NULL and port != c.MACH_PORT_DEAD)
            need(c.mach_port_deallocate(c.mach_task_self(), port) == 0, "registered send right release");
    }
    lim.release(@intFromPtr(ports), count * @sizeOf(c.mach_port_t));
}

fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "30");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    lim.cleanup();
}
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [5]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "message_limit", "total_limit", "ports_array", "regions_intact", "ports_lookup" };
    const bodies = .{ &messageLimit, &totalLimit, &portsArray, &regionsIntact, &portsLookup };
    inline for (0..names.len) |i| {
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
