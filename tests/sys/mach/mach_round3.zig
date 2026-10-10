// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const fm = @import("file_message.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{ "headroom", "ool_deallocate", "reply_once", "reply_send", "ool_cleanup", "file_extract" };
var cases: [names.len]c.atf_tc_t = undefined;
fn fact(name: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("round3 check=%s expected=%lld observed=%lld\n", name, @as(c_longlong, expected), @as(c_longlong, observed));
    if (expected != observed) c.atf_tc_fail("round3 observation differs");
}
fn send(buffer: []u8) i32 {
    return c.mach_msg(@ptrCast(@alignCast(buffer.ptr)), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, @intCast(buffer.len), 0, 0, 2000, 0);
}
fn receive(port: u32, buffer: []u8) i32 {
    return c.mach_msg(@ptrCast(@alignCast(buffer.ptr)), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @intCast(buffer.len), port, 2000, 0);
}
fn sendRight(port: u32) void {
    fact("make_send", 0, c.mach_port_insert_right(c.mach_task_self(), port, port, c.MACH_MSG_TYPE_MAKE_SEND));
}
const State = extern struct { size: u64, next: u64, prev: u64 };
const KmsgObservation = extern struct { result: c_int, pad: c_int, before: State, after: State };
fn headroom() void {
    const dest = fm.allocate();
    const carried = fm.allocate();
    sendRight(dest);
    sendRight(carried);
    defer _ = c.close(@intCast(dest));
    defer _ = c.close(@intCast(carried));
    for ([_]u32{ 1, 5, 11, 64 }) |count| {
        var msg: [1024]u8 align(8) = @splat(0);
        const size = 28 + 12 * count + 16;
        const h: *fm.Header = @ptrCast(&msg);
        h.* = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = size, .remote = dest, .local = 0, .voucher = 0, .id = 61701 };
        const n: *u32 = @ptrCast(@alignCast(msg[24..].ptr));
        n.* = count;
        for (0..count) |i| {
            const d: *align(1) fm.Descriptor = @ptrCast(msg[28 + 12 * i ..].ptr);
            d.* = .{ .name = carried, .pad = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = 0 };
        }
        @memset(msg[size - 16 .. size], 0xa7);
        var control: extern struct { address: u64, size: u32, pad: u32 } = .{ .address = @intFromPtr(&msg), .size = size, .pad = 0 };
        var observed: KmsgObservation = undefined;
        var len: usize = @sizeOf(KmsgObservation);
        fact("copyin_observe", 0, c.sysctlbyname("debug.rmx_kmsg_state", &observed, &len, &control, @sizeOf(@TypeOf(control))));
        fact("copyin_result", 0, observed.result);
        fact("queue_size", @intCast(observed.before.size), @intCast(observed.after.size));
        fact("queue_next", @bitCast(observed.before.next), @bitCast(observed.after.next));
        fact("queue_prev", @bitCast(observed.before.prev), @bitCast(observed.after.prev));
        fact("descriptor_send", 0, send(msg[0..size]));
        var out: [1200]u8 align(8) = @splat(0);
        fact("descriptor_receive", 0, receive(dest, &out));
        const rh: *fm.Header = @ptrCast(&out);
        fact("message_size", size, rh.size);
        fact("message_id", 61701, rh.id);
        fact("descriptor_count", count, @as(*u32, @ptrCast(@alignCast(out[24..].ptr))).*);
        for (0..count) |i| {
            const d: *align(1) fm.Descriptor = @ptrCast(out[28 + 12 * i ..].ptr);
            fact("descriptor_name", carried, d.name);
            fact("descriptor_type", 0, d.kind);
            fact("descriptor_right", c.MACH_MSG_TYPE_PORT_SEND, d.disposition);
        }
        for (out[size - 16 .. size]) |byte| fact("payload_byte", 0xa7, byte);
        c.mach_msg_destroy(@ptrCast(&out));
    }
}
const OolPorts = extern struct { address: u64, deallocate: u8, copy: u8, disposition: u8, kind: u8, count: u32 };
fn oolDeallocate() void {
    const page: usize = @intCast(c.getpagesize());
    const mapping = c.mmap(null, 2 * page, c.PROT_READ | c.PROT_WRITE, c.MAP_ANON | c.MAP_PRIVATE, -1, 0);
    if (mapping == c.MAP_FAILED) c.atf_tc_fail("array mmap failed");
    const bytes: [*]u8 = @ptrCast(mapping.?);
    @memset(bytes[0..page], 0);
    @memset(bytes[page .. 2 * page], 0x35);
    const dest = fm.allocate();
    sendRight(dest);
    defer _ = c.close(@intCast(dest));
    var msg: [44]u8 align(8) = @splat(0);
    const h: *fm.Header = @ptrCast(&msg);
    h.* = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = msg.len, .remote = dest, .local = 0, .voucher = 0, .id = 61702 };
    @as(*u32, @ptrCast(@alignCast(msg[24..].ptr))).* = 1;
    const d: *align(1) OolPorts = @ptrCast(msg[28..].ptr);
    d.* = .{ .address = @intFromPtr(bytes), .deallocate = 1, .copy = c.MACH_MSG_VIRTUAL_COPY, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_OOL_PORTS_DESCRIPTOR, .count = @intCast(page / 4) };
    fact("ool_send", 0, send(&msg));
    var vec: u8 = 0;
    fact("sender_array_unmapped", -1, c.mincore(mapping, page, &vec));
    fact("following_page_mapped", 0, c.mincore(bytes + page, page, &vec));
    var unchanged: usize = 0;
    for (bytes[page .. 2 * page]) |byte| unchanged += @intFromBool(byte == 0x35);
    fact("following_page_canary", @intCast(page), @intCast(unchanged));
    var out: [256]u8 align(8) = @splat(0);
    fact("ool_receive", 0, receive(dest, &out));
    const rd: *align(1) OolPorts = @ptrCast(out[28..].ptr);
    fact("ool_count", @intCast(page / 4), rd.count);
    const received: [*]const u32 = @ptrFromInt(rd.address);
    for (received[0..rd.count]) |name| if (name != 0) c.atf_tc_fail("null array changed");
    c.mach_msg_destroy(@ptrCast(&out));
    fact("following_page_cleanup", 0, c.munmap(bytes + page, page));
}
const ReplyRefs = extern struct { refs: u32, active: u32 };
fn replyWatch(command: u32, name: u32) ReplyRefs {
    var control: extern struct { command: u32, name: u32 } = .{ .command = command, .name = name };
    var observed: ReplyRefs = undefined;
    var len: usize = @sizeOf(ReplyRefs);
    fact("reply_watch", 0, c.sysctlbyname("debug.rmx_reply_refs", &observed, &len, &control, @sizeOf(@TypeOf(control))));
    return observed;
}
fn replyRefs(once: bool) void {
    const task = c.mach_task_self();
    const dest = fm.allocate();
    sendRight(dest);
    var saved: u32 = 0;
    fact("bootstrap_save", 0, c.task_get_special_port(task, c.TASK_BOOTSTRAP_PORT, &saved));
    fact("bootstrap_set", 0, c.task_set_special_port(task, c.TASK_BOOTSTRAP_PORT, dest));
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork failed");
    if (pid == 0) {
        _ = c.alarm(15);
        var target: u32 = 0;
        if (c.task_get_special_port(c.mach_task_self(), c.TASK_BOOTSTRAP_PORT, &target) != 0) c._exit(90);
        const reply = fm.allocate();
        const before = replyWatch(0, reply);
        for (0..200) |_| {
            var request = fm.Header{ .bits = @as(u32, c.MACH_MSG_TYPE_COPY_SEND) | (@as(u32, if (once) c.MACH_MSG_TYPE_MAKE_SEND_ONCE else c.MACH_MSG_TYPE_MAKE_SEND) << 8), .size = 24, .remote = target, .local = reply, .voucher = 0, .id = 61703 };
            if (send(std.mem.asBytes(&request)) != 0) c._exit(91);
            var buffer: [256]u8 align(8) = @splat(0);
            if (receive(reply, &buffer) != 0) c._exit(92);
            const h: *fm.Header = @ptrCast(&buffer);
            if (h.id != 61704) c._exit(93);
        }
        const after = replyWatch(1, 0);
        fact("reply_references_return", before.refs, after.refs);
        fact("reply_still_active", 1, after.active);
        fact("reply_close", 0, c.close(@intCast(reply)));
        const last = replyWatch(1, 0);
        fact("reply_last_reference", 1, last.refs);
        fact("reply_retired", 0, last.active);
        _ = replyWatch(2, 0);
        _ = c.fflush(null);
        c._exit(0);
    }
    fact("bootstrap_restore", 0, c.task_set_special_port(task, c.TASK_BOOTSTRAP_PORT, saved));
    if (saved != 0) _ = c.mach_port_deallocate(task, saved);
    for (0..200) |_| {
        var buffer: [256]u8 align(8) = @splat(0);
        if (receive(dest, &buffer) != 0) c.atf_tc_fail("request receive failed");
        const h: *fm.Header = @ptrCast(&buffer);
        if (h.id != 61703 or h.remote == 0) c.atf_tc_fail("reply right missing");
        var response = fm.Header{ .bits = @intCast(if (once) c.MACH_MSG_TYPE_MOVE_SEND_ONCE else c.MACH_MSG_TYPE_MOVE_SEND), .size = 24, .remote = h.remote, .local = 0, .voucher = 0, .id = 61704 };
        if (send(std.mem.asBytes(&response)) != 0) c.atf_tc_fail("reply send failed");
    }
    var status: c_int = 0;
    fact("reply_child_wait", pid, c.waitpid(pid, &status, 0));
    fact("reply_child_result", 0, status);
    fact("request_port_cleanup", 0, c.close(@intCast(dest)));
}
// Native kinfo_file prefix: the pathname tail makes record sizes variable.
const FilePrefix = extern struct { size: c_int, kind: c_int, fd: c_int, refs: c_int };
fn fileRefs(fd: c_int) i32 {
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_FILEDESC, c.getpid() };
    var buf: [65536]u8 align(8) = undefined;
    var len: usize = buf.len;
    fact("file_snapshot", 0, c.sysctl(&mib, mib.len, &buf, &len, null, 0));
    var offset: usize = 0;
    while (offset + @sizeOf(FilePrefix) <= len) {
        const p: *align(1) const FilePrefix = @ptrCast(buf[offset..].ptr);
        if (p.size < @sizeOf(FilePrefix) or @as(usize, @intCast(p.size)) > len - offset) c.atf_tc_fail("invalid file record");
        if (p.fd == fd) return p.refs;
        offset += @intCast(p.size);
    }
    c.atf_tc_fail("file missing from snapshot");
}
fn fileExtract() void {
    var pipe: [2]c_int = undefined;
    fact("pipe_setup", 0, c.pipe(&pipe));
    const before = fileRefs(pipe[1]);
    // The userland stub is ENOSYS; call the real kernel routine via the fixture.
    var name: u32 = @intCast(pipe[1]);
    var out: extern struct { result: c_int, present: u32, kind: u32 } = undefined;
    var len: usize = @sizeOf(@TypeOf(out));
    fact("extract_observe", 0, c.sysctlbyname("debug.rmx_extract_observe", &out, &len, &name, @sizeOf(u32)));
    fact("file_extract_unsupported", 46, out.result);
    fact("file_extract_empty", 0, out.present);
    fact("file_extract_type_empty", 0, out.kind);
    fact("file_references_unchanged", before, fileRefs(pipe[1]));
    fact("writer_close", 0, c.close(pipe[1]));
    var byte: u8 = 0;
    fact("no_retained_writer", 0, c.read(pipe[0], &byte, 1));
    _ = c.close(pipe[0]);
}
fn oolCleanup() void {
    const page: usize = @intCast(c.getpagesize());
    const mapping = c.mmap(null, page, c.PROT_READ | c.PROT_WRITE, c.MAP_ANON | c.MAP_PRIVATE, -1, 0);
    if (mapping == c.MAP_FAILED) c.atf_tc_fail("array mmap failed");
    const bytes: [*]u8 = @ptrCast(mapping.?);
    @memset(bytes[0..page], 0);
    const dest = fm.allocate();
    sendRight(dest);
    var msg: [56]u8 align(8) = @splat(0);
    const h: *fm.Header = @ptrCast(&msg);
    h.* = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = 44, .remote = dest, .local = 0, .voucher = 0, .id = 61705 };
    @as(*u32, @ptrCast(@alignCast(msg[24..].ptr))).* = 1;
    const d: *align(1) OolPorts = @ptrCast(msg[28..].ptr);
    d.* = .{ .address = @intFromPtr(bytes), .deallocate = 0, .copy = c.MACH_MSG_VIRTUAL_COPY, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_OOL_PORTS_DESCRIPTOR, .count = @intCast(page / 4) };
    fact("ool_queued", 0, send(msg[0..44]));
    // A failed second descriptor cleans up the already-copied OOL array.
    h.size = msg.len;
    @as(*u32, @ptrCast(@alignCast(msg[24..].ptr))).* = 2;
    const bad: *align(1) fm.Descriptor = @ptrCast(msg[44..].ptr);
    bad.* = .{ .name = 0x7fffffff, .pad = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = 0 };
    fact("ool_partial_cleanup", c.MACH_SEND_INVALID_RIGHT, send(&msg));
    fact("ool_queued_cleanup", 0, c.close(@intCast(dest)));
    var vec: u8 = 0;
    fact("ool_sender_retained", 0, c.mincore(mapping, page, &vec));
    for (bytes[0..page]) |byte| if (byte != 0) c.atf_tc_fail("sender names changed");
    fact("ool_sender_cleanup", 0, c.munmap(mapping, page));
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "25");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.alarm(25);
    var path: [4096]u8 = undefined;
    const n = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (n < 0 or n >= path.len) c.atf_tc_fail("fixture path too long");
    const module = c.kldload(&path);
    if (module < 0) c.atf_tc_fail("fixture load failed");
    defer _ = c.kldunload(module);
    const name = std.mem.span(c.atf_tc_get_ident(t));
    if (std.mem.eql(u8, name, "ool_deallocate")) oolDeallocate() else if (std.mem.eql(u8, name, "reply_once")) replyRefs(true) else if (std.mem.eql(u8, name, "reply_send")) replyRefs(false) else if (std.mem.eql(u8, name, "ool_cleanup")) oolCleanup() else if (std.mem.eql(u8, name, "file_extract")) fileExtract() else headroom();
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) {
        _ = replyWatch(2, 0);
        _ = c.kldunload(module);
    }
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, &head, &body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
