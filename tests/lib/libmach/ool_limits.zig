// SPDX-License-Identifier: BSD-2-Clause
// Shared by the OOL accounting cases: the mach.ool_* sysctls, OOL messages
// and fill patterns. A case that lowers mach.ool_max_total saves the value it
// found in state_path first; the body puts it back on every path through
// need(), and the case's cleanup puts it back from the file when a body was
// interrupted.
const std = @import("std");
pub const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/mman.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

pub const page: usize = 4096;
pub const state_path = "/tmp/rmx_ool_max_total.saved";
var saved: u64 = 0;

pub fn read(name: [*:0]const u8) u64 {
    var value: c_ulong = 0;
    var size: usize = @sizeOf(c_ulong);
    if (c.sysctlbyname(name, &value, &size, null, 0) != 0 or size != @sizeOf(c_ulong)) {
        restore();
        c.atf_tc_fail("read %s", name);
    }
    return value;
}
fn write(name: [*:0]const u8, value: u64) c_int {
    var v: c_ulong = value;
    return c.sysctlbyname(name, null, null, &v, @sizeOf(c_ulong));
}
pub fn bytes() u64 {
    return read("mach.ool_bytes");
}
// mach.ool_bytes once it equals target, or its last value after 2 s: OOL
// traffic elsewhere in the guest may hold bytes for a moment, a leak stays.
pub fn settle(target: u64) u64 {
    var value = bytes();
    var waited: u32 = 0;
    while (value != target and waited < 200) : (waited += 1) {
        _ = c.usleep(10_000);
        value = bytes();
    }
    return value;
}
fn saveFile(value: u64) bool {
    const fd = c.open(state_path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return false;
    var text: [32]u8 = undefined;
    const n = c.snprintf(&text, text.len, "%lu\n", @as(c_ulong, value));
    const ok = n > 0 and c.write(fd, &text, @intCast(n)) == n;
    return c.close(fd) == 0 and ok;
}
fn loadFile() ?u64 {
    const fd = c.open(state_path, c.O_RDONLY);
    if (fd < 0) return null;
    var text: [32]u8 = @splat(0);
    const n = c.read(fd, &text, text.len - 1);
    _ = c.close(fd);
    if (n <= 0) return null;
    return c.strtoul(&text, null, 10);
}
// Set mach.ool_max_total to value; restore() or cleanup() puts back the
// value found here.
pub fn lower(value: u64) void {
    cleanup();
    saved = read("mach.ool_max_total");
    if (!saveFile(saved)) {
        saved = 0;
        c.atf_tc_fail("save mach.ool_max_total");
    }
    if (write("mach.ool_max_total", value) != 0) {
        restore();
        c.atf_tc_fail("set mach.ool_max_total=%lu", @as(c_ulong, value));
    }
}
pub fn restore() void {
    if (saved == 0) return;
    if (write("mach.ool_max_total", saved) == 0) _ = c.unlink(state_path);
    saved = 0;
}
pub fn cleanup() void {
    const value = loadFile() orelse return;
    if (value != 0 and write("mach.ool_max_total", value) == 0) _ = c.unlink(state_path);
}
pub fn need(ok: bool, what: [*:0]const u8) void {
    if (ok) return;
    restore();
    c.atf_tc_fail("%s", what);
}

pub fn port() u32 {
    var p: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) == 0, "receive allocation");
    return p;
}
pub fn queued(p: u32) u32 {
    var status: c.mach_port_status_t = undefined;
    var count: c.mach_msg_type_number_t = c.MACH_PORT_RECEIVE_STATUS_COUNT;
    need(c.mach_port_get_attributes(c.mach_task_self(), p, c.MACH_PORT_RECEIVE_STATUS, @ptrCast(&status), &count) == 0, "receive status");
    return status.mps_msgcount;
}
pub fn destroy(p: u32) void {
    need(c.mach_port_destroy(c.mach_task_self(), p) == 0, "port cleanup");
}
pub fn map(len: usize) []u8 {
    const size = std.mem.alignForward(usize, len, page);
    const p = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_ANON | c.MAP_PRIVATE, -1, 0);
    need(p != c.MAP_FAILED, "mapping allocation");
    return @as([*]u8, @ptrCast(p.?))[0..len];
}
pub fn unmap(buf: []u8) void {
    _ = c.munmap(buf.ptr, std.mem.alignForward(usize, buf.len, page));
}
// Whether every page of buf is mapped.
pub fn mapped(buf: []const u8) bool {
    var vector: [65536]u8 = undefined;
    const size = std.mem.alignForward(usize, buf.len, page);
    if (size / page > vector.len) return false;
    return c.mincore(buf.ptr, size, &vector) == 0;
}
fn word(index: usize, seed: u64) u64 {
    return (index +% 1) *% 0x9e3779b97f4a7c15 ^ seed;
}
pub fn fill(buf: []u8, seed: u64) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 8) {
        const v = word(i / 8, seed);
        const n = @min(8, buf.len - i);
        @memcpy(buf[i..][0..n], std.mem.asBytes(&v)[0..n]);
    }
}
pub fn same(buf: []const u8, seed: u64) bool {
    var i: usize = 0;
    while (i < buf.len) : (i += 8) {
        const v = word(i / 8, seed);
        const n = @min(8, buf.len - i);
        if (!std.mem.eql(u8, buf[i..][0..n], std.mem.asBytes(&v)[0..n])) return false;
    }
    return true;
}

// The 64-bit user OOL and OOL ports descriptors; for ports, size is the count.
pub const Ool = extern struct {
    address: u64 align(4),
    deallocate: u8 = 0,
    copy: u8 = c.MACH_MSG_VIRTUAL_COPY,
    disposition: u8 = 0,
    kind: u8 = c.MACH_MSG_OOL_DESCRIPTOR,
    size: u32,
};
pub fn Message(comptime n: usize) type {
    return extern struct {
        header: c.mach_msg_header_t,
        count: u32,
        ool: [n]Ool,
        trailer: [128]u8 = @splat(0),

        const Self = @This();
        pub fn init(dest: u32, ool: [n]Ool) Self {
            var h = std.mem.zeroes(c.mach_msg_header_t);
            h.msgh_bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_MAKE_SEND;
            h.msgh_remote_port = dest;
            h.msgh_id = 534;
            return .{ .header = h, .count = n, .ool = ool };
        }
        pub fn send(m: *Self) c_int {
            const size = @sizeOf(c.mach_msg_header_t) + @sizeOf(u32) + n * @sizeOf(Ool);
            m.header.msgh_size = size;
            return c.mach_msg(&m.header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, size, 0, 0, 0, 0);
        }
        pub fn receive(m: *Self, from: u32) c_int {
            m.* = std.mem.zeroes(Self);
            return c.mach_msg(&m.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Self), from, 1000, 0);
        }
        // A received region as a slice, or null when it is absent.
        pub fn region(m: *const Self, i: usize) ?[]const u8 {
            if (m.ool[i].address == 0) return null;
            return @as([*]const u8, @ptrFromInt(m.ool[i].address))[0..m.ool[i].size];
        }
    };
}
pub fn release(address: u64, size: usize) void {
    need(c.mach_vm_deallocate(c.mach_task_self(), address, size) == 0, "received region cleanup");
}

comptime {
    if (@offsetOf(Message(1), "ool") != 28 or @sizeOf(Ool) != 16) @compileError("Mach OOL wire layout");
}
