// SPDX-License-Identifier: BSD-2-Clause
// rmxOS-only wire fixture. Exercise the existing real pipe decoder through
// XPC_CONSUMER_FIXTURE's receive seam; no Mach call or fake decoder is used.
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("OS_OBJECT_USE_OBJC", "0");
    @cInclude("Availability.h");
    @cInclude("xpc/xpc.h");
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("nv.h");
    @cInclude("projection.h");
});
extern fn op736_pipe_receive(u32, *u32, *c.xpc_object_t, *u64) c_int;
extern fn mallctl([*:0]const u8, ?*anyopaque, ?*usize, ?*anyopaque, usize) c_int;
var wire_buffer: ?*anyopaque = null;
var packed_size: usize = 0;
var source: ?*c.nvlist_t = null;
var nested: ?*c.nvlist_t = null;
var hooks: c.struct_op500_hooks = undefined;
fn check(label: []const u8, ok: bool) !void {
    if (!ok) {
        std.debug.print("decode_lifetime FAIL {s}\n", .{label});
        return error.ContractViolation;
    }
}
fn receive(h: [*c]c.mach_msg_header_t, _: c.mach_msg_option_t, _: u32, capacity: u32, _: u32, _: u32, _: u32) callconv(.c) c_int {
    // Native wire layout: header, size_t size, uint64_t id, wire_buffer bytes.
    const data_offset = std.mem.alignForward(usize, @sizeOf(c.mach_msg_header_t), @alignOf(usize)) + 16;
    const body_end = std.mem.alignForward(usize, data_offset + packed_size, 4);
    if (body_end + @sizeOf(c.mach_msg_audit_trailer_t) > capacity) return c.MACH_RCV_TOO_LARGE;
    const bytes: [*]u8 = @ptrCast(h);
    @memset(bytes[0..capacity], 0);
    h.* = std.mem.zeroes(c.mach_msg_header_t);
    h.*.msgh_size = @intCast(body_end);
    h.*.msgh_id = 211;
    @as(*usize, @ptrCast(@alignCast((bytes + data_offset - 16)))).* = packed_size;
    @as(*u64, @ptrCast(@alignCast((bytes + data_offset - 8)))).* = 211;
    @memcpy(bytes[data_offset..][0..packed_size], @as([*]const u8, @ptrCast(wire_buffer))[0..packed_size]);
    const trailer: *align(4) c.mach_msg_audit_trailer_t = @ptrCast(@alignCast(bytes + body_end));
    trailer.* = std.mem.zeroes(c.mach_msg_audit_trailer_t);
    trailer.msgh_trailer_type = c.MACH_MSG_TRAILER_FORMAT_0;
    trailer.msgh_trailer_size = @sizeOf(c.mach_msg_audit_trailer_t);
    return 0;
}
fn setup() !void {
    source = c.nvlist_create_dictionary(0);
    nested = c.nvlist_create_dictionary(0);
    try check("fixture nvlist allocations", source != null and nested != null);
    c.nvlist_add_string(nested, "text", "decoded-child");
    const payload: [4096]u8 = @splat('P');
    c.nvlist_add_binary(nested, "data", &payload, payload.len);
    c.nvlist_add_nvlist_dictionary(source, "nested", nested);
    wire_buffer = c.nvlist_pack_buffer(source, null, &packed_size);
    try check("fixture wire_buffer", wire_buffer != null);
    hooks = std.mem.zeroes(c.struct_op500_hooks);
    hooks.receive = &receive;
    c.op500_install(&hooks);
}
fn teardown() void {
    c.free(wire_buffer);
    c.nvlist_destroy(source);
    c.nvlist_destroy(nested);
    hooks = std.mem.zeroes(c.struct_op500_hooks);
    c.op500_install(&hooks);
}
fn decode() !c.xpc_object_t {
    var root: c.xpc_object_t = null;
    var remote: u32 = 0;
    var id: u64 = 0;
    try check("real pipe decode result", op736_pipe_receive(0, &remote, &root, &id) == 0 and root != null and id == 211 and remote == 0);
    return root;
}
pub fn retainedDecodedChild() !void {
    try setup();
    defer teardown();
    const root = try decode();
    const container = c.xpc_dictionary_get_value(root, "nested");
    const child = c.xpc_retain(c.xpc_dictionary_get_value(container, "text"));
    const blob = c.xpc_retain(c.xpc_dictionary_get_value(container, "data"));
    c.xpc_release(root);
    const text = c.xpc_string_get_string_ptr(child);
    try check("retained decoded child survives root release", text != null and std.mem.eql(u8, std.mem.span(text), "decoded-child"));
    // Overwrite/free the original wire bytes before the final child access.
    @memset(@as([*]u8, @ptrCast(wire_buffer))[0..packed_size], 0x5a);
    c.free(wire_buffer);
    wire_buffer = null;
    const data: [*]const u8 = @ptrCast(c.xpc_data_get_bytes_ptr(blob));
    try check("decoded data independent of wire", data[0] == 'P' and data[4095] == 'P');
    c.xpc_release(child);
    c.xpc_release(blob);
}
fn allocated() !usize {
    _ = mallctl("thread.tcache.flush", null, null, null, 0);
    var epoch: u64 = 1;
    var size: usize = @sizeOf(u64);
    try check("allocator epoch", mallctl("epoch", &epoch, &size, &epoch, @sizeOf(u64)) == 0);
    var bytes: usize = 0;
    size = @sizeOf(usize);
    try check("allocator live bytes available", mallctl("stats.allocated", &bytes, &size, null, 0) == 0);
    return bytes;
}
pub fn repeatedDecodeHeap() !void {
    try setup();
    defer teardown();
    // Warm the same decoder, size classes and allocator-stat path first.
    for (0..32) |_| c.xpc_release(try decode());
    _ = try allocated();
    const before = try allocated();
    for (0..1024) |_| c.xpc_release(try decode());
    const after = try allocated();
    std.debug.print("decode_lifetime heap iterations=1024 before={d} after={d} growth={d}\n", .{ before, after, @as(i128, after) - before });
    try check("decode/release leaves live heap flat", after <= before);
}
test "retainedDecodedChild" {
    try retainedDecodedChild();
}
test "repeatedDecodeHeap" {
    try repeatedDecodeHeap();
}
const atf = if (builtin.is_test) struct {} else @cImport({
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t) c_int;
var cases: if (builtin.is_test) void else [2]atf.atf_tc_t = undefined;
fn body(t: [*c]const atf.atf_tc_t) callconv(.c) void {
    _ = c.alarm(20);
    if (std.mem.eql(u8, std.mem.span(atf.atf_tc_get_ident(t)), "retainedDecodedChild")) {
        retainedDecodedChild() catch atf.atf_tc_fail("decoded child lifetime contract failed; see named check");
    } else repeatedDecodeHeap() catch atf.atf_tc_fail("decoded heap lifetime contract failed; see named check");
}
fn add(tp: [*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t {
    for ([_][*:0]const u8{ "retainedDecodedChild", "repeatedDecodeHeap" }, 0..) |name, i| {
        const err = atf.atf_tc_init(&cases[i], name, null, &body, null, atf.atf_tp_get_config(tp));
        if (atf.atf_is_error(err)) return err;
        _ = atf.atf_tp_add_tc(tp, &cases[i]);
    }
    return atf.atf_no_error();
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, &add);
}
comptime {
    if (!builtin.is_test) @export(&main, .{ .name = "main" });
}
