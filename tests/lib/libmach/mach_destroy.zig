// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/mman.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
const Port = extern struct { name: u32, pad: u32 = 0, pad2: u16 = 0, disposition: u8, kind: u8 = c.MACH_MSG_PORT_DESCRIPTOR };
const Ool = extern struct { address: u64, deallocate: u8 = 0, copy: u8 = c.MACH_MSG_VIRTUAL_COPY, disposition: u8 = 0, kind: u8, count: u32 };
fn port() u32 {
    var p: u32 = 0;
    if (c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) != 0) c.atf_tc_fail("receive allocation");
    return p;
}
fn sendRight(p: u32) void {
    if (c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) != 0) c.atf_tc_fail("send allocation");
}
fn mapping() [*]u8 {
    const p = c.mmap(null, 4096, c.PROT_READ | c.PROT_WRITE, c.MAP_ANON | c.MAP_PRIVATE, -1, 0);
    if (p == c.MAP_FAILED) c.atf_tc_fail("mapping allocation");
    return @ptrCast(p.?);
}
fn write(bytes: []u8, offset: *usize, value: anytype) void {
    const v = value;
    @memcpy(bytes[offset.*..][0..@sizeOf(@TypeOf(v))], std.mem.asBytes(&v));
    offset.* += @sizeOf(@TypeOf(v));
}
fn refs(p: u32) u32 {
    var n: u32 = 0;
    const rc = c.mach_port_get_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_SEND, &n);
    if (rc != 0) c.atf_tc_fail("owned send query kr=%d name=%u", rc, p);
    return n;
}
noinline fn destroyPoisoned(h: *c.mach_msg_header_t) u32 {
    var storage: [8192]u8 = undefined;
    const poison: *volatile [8192]u8 = &storage;
    for (0..storage.len) |i| poison[i] = 0xa5;
    c.mach_msg_destroy(h);
    var sum: u32 = 0;
    for (0..storage.len) |i| sum += poison[i];
    return sum;
}
fn run(second: bool) void {
    const destination = port();
    const a = port();
    const b = port();
    const moved_receive = port();
    const unrelated = port();
    sendRight(a);
    sendRight(b);
    sendRight(unrelated);
    if (c.mach_port_mod_refs(c.mach_task_self(), unrelated, c.MACH_PORT_RIGHT_SEND, 2) != 0) c.atf_tc_fail("unrelated urefs setup");
    const region = mapping();
    @memset(region[0..4096], 0x5a);
    const array = mapping();
    const ports: [*]u32 = @ptrCast(@alignCast(array));
    ports[0] = a;
    ports[1] = b;
    var wire: [512]u8 align(8) = @splat(0);
    const h: *c.mach_msg_header_t = @ptrCast(&wire);
    h.* = std.mem.zeroes(c.mach_msg_header_t);
    h.msgh_bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_MAKE_SEND;
    h.msgh_remote_port = destination;
    h.msgh_id = 48101;
    var offset: usize = @sizeOf(c.mach_msg_header_t);
    write(&wire, &offset, @as(u32, 4));
    const order = if (second) [4]u8{ 2, 0, 3, 1 } else [4]u8{ 0, 1, 2, 3 };
    for (order) |kind| switch (kind) {
        0 => write(&wire, &offset, Port{ .name = a, .disposition = c.MACH_MSG_TYPE_COPY_SEND }),
        1 => write(&wire, &offset, Port{ .name = moved_receive, .disposition = c.MACH_MSG_TYPE_MOVE_RECEIVE }),
        2 => write(&wire, &offset, Ool{ .address = @intFromPtr(region), .kind = c.MACH_MSG_OOL_DESCRIPTOR, .count = 4096 }),
        3 => write(&wire, &offset, Ool{ .address = @intFromPtr(array), .kind = c.MACH_MSG_OOL_PORTS_DESCRIPTOR, .count = 2, .disposition = c.MACH_MSG_TYPE_COPY_SEND }),
        else => unreachable,
    };
    h.msgh_size = @intCast(offset);
    const sent = c.mach_msg(h, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, h.msgh_size, 0, 0, 0, 0);
    if (sent != 0) c.atf_tc_fail("complex send kr=%d", sent);
    @memset(&wire, 0);
    const got = c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, wire.len, destination, 1000, 0);
    if (got != 0 or h.msgh_id != 48101 or (h.msgh_bits & c.MACH_MSGH_BITS_COMPLEX) == 0) c.atf_tc_fail("complex receive kr=%d", got);
    offset = @sizeOf(c.mach_msg_header_t) + 4;
    var receive_name: u32 = 0;
    var ool_address: usize = 0;
    var array_address: usize = 0;
    for (order) |kind| {
        if (kind < 2) {
            const d = std.mem.bytesToValue(Port, wire[offset..][0..@sizeOf(Port)]);
            if (kind == 1) receive_name = d.name;
            offset += @sizeOf(Port);
        } else {
            const d = std.mem.bytesToValue(Ool, wire[offset..][0..@sizeOf(Ool)]);
            if (kind == 2) ool_address = @intCast(d.address) else array_address = @intCast(d.address);
            offset += @sizeOf(Ool);
        }
    }
    var vector: u8 = 0;
    const mapped_region = c.mincore(@ptrFromInt(ool_address), 4096, &vector);
    const mapped_array = c.mincore(@ptrFromInt(array_address), 4096, &vector);
    const copied: [*]const u32 = @ptrFromInt(array_address);
    var typ: u32 = 0;
    const receive_before = c.mach_port_type(c.mach_task_self(), receive_name, &typ);
    const before_a = refs(a);
    const before_b = refs(b);
    if (mapped_region != 0 or mapped_array != 0 or @as(*const u8, @ptrFromInt(ool_address)).* != 0x5a or copied[0] != a or copied[1] != b or receive_before != 0 or (typ & c.MACH_PORT_TYPE_RECEIVE) == 0 or before_a != 3 or before_b != 2 or refs(unrelated) != 3) c.atf_tc_fail("complex copyout fixture mismatch");
    const poison = destroyPoisoned(h);
    const after_a = refs(a);
    const after_b = refs(b);
    const unrelated_after = refs(unrelated);
    const receive_after = c.mach_port_type(c.mach_task_self(), receive_name, &typ);
    const region_rc = c.mincore(@ptrFromInt(ool_address), 4096, &vector);
    const region_errno = c.__error().*;
    const array_rc = c.mincore(@ptrFromInt(array_address), 4096, &vector);
    const array_errno = c.__error().*;
    _ = c.printf("destroy order=%u refs_before_expected=3,2 refs_before_observed=%u,%u refs_after_expected=1,1 refs_after_observed=%u,%u receive_absent_expected=%d receive_absent_observed=%d unrelated_expected=3 unrelated_observed=%u region_rc_expected=-1 region_rc_observed=%d region_errno_expected=%d region_errno_observed=%d array_rc_expected=-1 array_rc_observed=%d array_errno_expected=%d array_errno_observed=%d poison_expected=1351680 poison_observed=%u\n", @as(u32, @intFromBool(second)), before_a, before_b, after_a, after_b, @as(c_int, c.KERN_INVALID_NAME), receive_after, unrelated_after, region_rc, @as(c_int, c.ENOMEM), region_errno, array_rc, @as(c_int, c.ENOMEM), array_errno, poison);
    if (after_a != 1 or after_b != 1 or receive_after != c.KERN_INVALID_NAME or unrelated_after != 3 or region_rc != -1 or array_rc != -1 or region_errno != c.ENOMEM or array_errno != c.ENOMEM or poison != 1351680) c.atf_tc_fail("received complex message resources not destroyed");
    _ = c.munmap(region, 4096);
    _ = c.munmap(array, 4096);
}
fn first(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(false);
}
fn secondOrder(_: [*c]const c.atf_tc_t) callconv(.c) void {
    run(true);
}
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [2]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "destroy_ports_first", "destroy_ool_first" };
    const bodies = .{ &first, &secondOrder };
    inline for (0..2) |i| {
        const err = c.atf_tc_init(&cases[i], names[i], &head, bodies[i], null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
