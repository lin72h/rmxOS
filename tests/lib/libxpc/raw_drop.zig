// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cDefine("OS_OBJECT_USE_OBJC", "0");
    @cInclude("Availability.h");
    @cInclude("xpc/xpc.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("nv.h");
    @cInclude("projection.h");
    @cInclude("atf-c.h");
});
const O = c.xpc_object_t;
extern fn xpc_pipe_try_receive(u32, *O, *u32, *const fn (*c.mach_msg_header_t, *c.mach_msg_header_t) callconv(.c) c_int, u32, c_int) c_int;
extern fn op500_pipe_send(O, u32, u32, u64) c_int;
extern fn mallctl([*:0]const u8, ?*anyopaque, ?*usize, ?*anyopaque, usize) c_int;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const raw_drop = 1;
const message_id = 0x58504300;
var unpacks: usize = 0;
var hooks = std.mem.zeroes(c.struct_op500_hooks);
var wire_bytes: ?*anyopaque = null;
var wire_bytes_size: usize = 0;
var synthetic = false;
var mig = false;
var delivered_ool: usize = 0;
var delivered_ports: usize = 0;
var demux_calls: usize = 0;
fn need(ok: bool, label: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", label);
}
fn unpack(_: ?*anyopaque, _: usize) callconv(.c) void {
    unpacks += 1;
}
const Ool = extern struct { address: u64 align(4), deallocate: u8, copy: u8, disposition: u8, kind: u8, size: u32 };
const Port = extern struct { name: u32, pad: u32, pad2: u16, disposition: u8, kind: u8 };
const Resources = extern struct { header: c.mach_msg_header_t, count: u32, port: Port, file: Port, ool: Ool, ports: Ool };
fn demux(h: *c.mach_msg_header_t, r: *c.mach_msg_header_t) callconv(.c) c_int {
    demux_calls += 1;
    if (!mig or h.msgh_id != 400) return 0;
    const reply: *c.mig_reply_error_t = @ptrCast(@alignCast(r));
    reply.* = std.mem.zeroes(c.mig_reply_error_t);
    reply.Head.msgh_bits = c.MACH_MSG_TYPE_MOVE_SEND_ONCE;
    reply.Head.msgh_remote_port = h.msgh_remote_port;
    reply.Head.msgh_size = @sizeOf(c.mig_reply_error_t);
    reply.Head.msgh_id = h.msgh_id + 100;
    reply.RetCode = c.KERN_SUCCESS;
    return 1;
}
fn receive(h: [*c]c.mach_msg_header_t, options: c.mach_msg_option_t, send: u32, capacity: u32, port: u32, timeout: u32, notify: u32) callconv(.c) c_int {
    if (!synthetic) {
        const rc = c.mach_msg(h, options, send, capacity, port, timeout, notify);
        if (rc == 0 and (h.*.msgh_bits & c.MACH_MSGH_BITS_COMPLEX) != 0) {
            const res: *Resources = @ptrCast(@alignCast(h));
            delivered_ool = @intCast(res.ool.address);
            delivered_ports = @intCast(res.ports.address);
        }
        return rc;
    }
    const offset = std.mem.alignForward(usize, @sizeOf(c.mach_msg_header_t), 8) + 16;
    const end = std.mem.alignForward(usize, offset + wire_bytes_size, 4);
    need(end + @sizeOf(c.mach_msg_audit_trailer_t) <= capacity, "synthetic capacity");
    const bytes: [*]u8 = @ptrCast(h);
    @memset(bytes[0..capacity], 0);
    h.*.msgh_size = @intCast(end);
    h.*.msgh_id = message_id;
    @as(*usize, @ptrCast(@alignCast(bytes + offset - 16))).* = wire_bytes_size;
    @memcpy(bytes[offset..][0..wire_bytes_size], @as([*]const u8, @ptrCast(wire_bytes))[0..wire_bytes_size]);
    const tr: *align(4) c.mach_msg_audit_trailer_t = @ptrCast(@alignCast(bytes + end));
    tr.msgh_trailer_size = @sizeOf(c.mach_msg_audit_trailer_t);
    return 0;
}
fn install() void {
    hooks.receive = &receive;
    hooks.unpack = &unpack;
    c.op500_install(&hooks);
}
fn allocated() usize {
    _ = mallctl("thread.tcache.flush", null, null, null, 0);
    var epoch: u64 = 1;
    var size: usize = @sizeOf(u64);
    need(mallctl("epoch", &epoch, &size, &epoch, size) == 0, "allocator epoch");
    var n: usize = 0;
    size = @sizeOf(usize);
    need(mallctl("stats.allocated", &n, &size, null, 0) == 0, "allocator stats");
    return n;
}
fn drop(port: u32) c_int {
    var obj: O = null;
    var remote: u32 = 0;
    const rc = xpc_pipe_try_receive(port, &obj, &remote, &demux, 0, raw_drop);
    if (obj != null) c.xpc_release(obj);
    return rc;
}
fn heap(_: [*c]const c.atf_tc_t) callconv(.c) void {
    synthetic = true;
    install();
    const nv = c.nvlist_create_dictionary(0);
    const payload: [4096]u8 = @splat('P');
    c.nvlist_add_binary(nv, "payload", &payload, payload.len);
    wire_bytes = c.nvlist_pack_buffer(nv, null, &wire_bytes_size);
    need(wire_bytes != null, "wire_bytes payload");
    for (0..32) |_| need(drop(0) == 0, "warm drop");
    _ = allocated();
    const before = allocated();
    for (0..1024) |_| need(drop(0) == 0, "raw drop result");
    const after = allocated();
    _ = c.printf("rawDropHeapFlat iterations=1024 before=%zu after=%zu unpacks=%zu\n", before, after, unpacks);
    c.free(wire_bytes);
    c.nvlist_destroy(nv);
    need(after <= before and unpacks == 0, "raw drop must leave live heap flat and never unpack");
    if (c.getenv("OP233_REAL_MACH") != null) {
        synthetic = false;
        for (0..32) |_| resources(false);
        _ = allocated();
        const real_before = allocated();
        for (0..1024) |_| resources(false);
        const real_after = allocated();
        _ = c.printf("rawDropHeapFlat resources=1024 before=%zu after=%zu unpacks=%zu\n", real_before, real_after, unpacks);
        need(real_after <= real_before and unpacks == 0, "resource raw drop heap flat");
    }
}
fn makePort() u32 {
    var p: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) == 0, "allocate port");
    need(c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "insert send");
    return p;
}
fn refs(p: u32, right: u32) u32 {
    var n: u32 = 0;
    need(c.mach_port_get_refs(c.mach_task_self(), p, right, &n) == 0, "port refs");
    return n;
}
fn portset(p: u32) u32 {
    var ps: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_PORT_SET, &ps) == 0, "port set");
    need(c.mach_port_move_member(c.mach_task_self(), p, ps) == 0, "port set member");
    return ps;
}
fn unmapped(address: usize) bool {
    var vec: u8 = 0;
    return c.mincore(@ptrFromInt(address), 4096, &vec) == -1 and c.__error().* == c.ENOMEM;
}
fn rights(_: [*c]const c.atf_tc_t) callconv(.c) void {
    resources(true);
}
fn resources(verbose: bool) void {
    for ([_]u8{ c.MACH_MSG_PHYSICAL_COPY, c.MACH_MSG_VIRTUAL_COPY }) |copy| resourceMessage(verbose, copy);
}
fn resourceMessage(verbose: bool, copy: u8) void {
    install();
    const dst = makePort();
    const ps = portset(dst);
    const carried = makePort();
    const send_before = refs(carried, c.MACH_PORT_RIGHT_SEND);
    const recv_before = refs(carried, c.MACH_PORT_RIGHT_RECEIVE);
    var pipe: [2]c_int = undefined;
    need(c.pipe(&pipe) == 0, "file fixture");
    const payload: [4096]u8 = @splat(0x5a);
    const names = [_]u32{carried};
    var msg = std.mem.zeroes(Resources);
    msg.header.msgh_bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND;
    msg.header.msgh_size = @sizeOf(Resources);
    msg.header.msgh_remote_port = dst;
    msg.header.msgh_id = message_id;
    msg.count = 4;
    msg.port = .{ .name = carried, .pad = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
    msg.file = .{ .name = @intCast(pipe[1]), .pad = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
    msg.ool = .{ .address = @intFromPtr(&payload), .deallocate = 0, .copy = copy, .disposition = 0, .kind = c.MACH_MSG_OOL_DESCRIPTOR, .size = payload.len };
    msg.ports = .{ .address = @intFromPtr(&names), .deallocate = 0, .copy = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_OOL_PORTS_DESCRIPTOR, .size = names.len };
    need(c.mach_msg_send(&msg.header) == 0, "send resources");
    need(c.close(pipe[1]) == 0, "close source writer");
    const rc = drop(ps);
    const send_after = refs(carried, c.MACH_PORT_RIGHT_SEND);
    const recv_after = refs(carried, c.MACH_PORT_RIGHT_RECEIVE);
    need(c.fcntl(pipe[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) == 0, "nonblocking EOF check");
    var byte: u8 = 0;
    const eof = c.read(pipe[0], &byte, 1);
    if (verbose) _ = c.printf("rawDropReleasesRights rc=%d send_before=%u send_after=%u receive_before=%u receive_after=%u pipe_read=%zd ool=%zu ports=%zu unpacks=%zu\n", rc, send_before, send_after, recv_before, recv_after, eof, delivered_ool, delivered_ports, unpacks);
    need(delivered_ool != 0 and delivered_ports != 0 and unmapped(delivered_ool) and unmapped(delivered_ports), "received OOL regions released");
    need(payload[0] == 0x5a and payload[payload.len - 1] == 0x5a and names[0] == carried, "sender regions preserved");
    need(send_after == send_before and recv_after == recv_before and eof == 0 and unpacks == 0 and rc == 0, "raw resource drop contract");
    _ = c.close(pipe[0]);
    _ = c.mach_port_destroy(c.mach_task_self(), carried);
    _ = c.mach_port_destroy(c.mach_task_self(), ps);
    _ = c.mach_port_destroy(c.mach_task_self(), dst);
}
fn sendId(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const dst = makePort();
    const obj = c.xpc_dictionary_create(null, null, 0);
    // Both requests and replies use the same send primitive; local is absent
    // for a reply, while the 64-bit sequence ID stays independent of msgh_id.
    for ([_]u32{ 0, dst }) |local| {
        need(op500_pipe_send(obj, dst, local, 233) == 0, "send XPC");
        var buffer: [16384]u8 align(8) = undefined;
        const h: *c.mach_msg_header_t = @ptrCast(&buffer);
        need(c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, buffer.len, dst, 1000, 0) == 0, "receive sent XPC");
        _ = c.printf("sendSetsMessageId local=%u expected=%d observed=%d\n", local, @as(c_int, message_id), h.msgh_id);
        const id = h.msgh_id;
        const offset = std.mem.alignForward(usize, @sizeOf(c.mach_msg_header_t), 8) + 8;
        need(@as(*const u64, @ptrCast(@alignCast(&buffer[offset]))).* == 233, "sequence ID preserved");
        c.mach_msg_destroy(h);
        need(id == message_id, "fixed msgh_id on request and reply");
    }
    c.xpc_release(obj);
    _ = c.mach_port_destroy(c.mach_task_self(), dst);
}
fn migTest(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install();
    mig = true;
    const dst = makePort();
    const ps = portset(dst);
    const rp = makePort();
    var h = std.mem.zeroes(c.mach_msg_header_t);
    h.msgh_bits = c.MACH_MSG_TYPE_COPY_SEND;
    h.msgh_remote_port = dst;
    h.msgh_size = @sizeOf(c.mach_msg_header_t);
    h.msgh_id = message_id;
    need(c.mach_msg_send(&h) == 0, "send non-MIG on same port set");
    const raw_result = drop(ps);
    need(raw_result == 0 or raw_result == c.EINVAL, "non-MIG consumed before MIG");
    h.msgh_bits = c.MACH_MSGH_BITS(c.MACH_MSG_TYPE_COPY_SEND, c.MACH_MSG_TYPE_MAKE_SEND_ONCE);
    h.msgh_remote_port = dst;
    h.msgh_local_port = rp;
    h.msgh_size = @sizeOf(c.mach_msg_header_t);
    h.msgh_id = 400;
    need(c.mach_msg_send(&h) == 0, "send MIG");
    need(drop(ps) == 1 and demux_calls == 2 and unpacks == 0, "MIG handled with raw drop flag");
    var reply: extern struct { msg: c.mig_reply_error_t, trailer: [128]u8 } = undefined;
    need(c.mach_msg(&reply.msg.Head, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(@TypeOf(reply)), rp, 1000, 0) == 0, "MIG reply received");
    need(reply.msg.Head.msgh_id == 500 and reply.msg.RetCode == 0, "MIG reply unchanged");
    _ = c.mach_port_destroy(c.mach_task_self(), rp);
    _ = c.mach_port_destroy(c.mach_task_self(), ps);
    _ = c.mach_port_destroy(c.mach_task_self(), dst);
}
var cases: [4]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &rights, &heap, &sendId, &migTest };
    for ([_][*:0]const u8{ "rawDropReleasesRights", "rawDropHeapFlat", "sendSetsMessageId", "migUnaffected" }, 0..) |name, i| {
        const err = c.atf_tc_init(&cases[i], name, null, bodies[i], null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        _ = c.atf_tp_add_tc(tp, &cases[i]);
    }
    return c.atf_no_error();
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, &add);
}
comptime {
    @export(&main, .{ .name = "main" });
}
