// SPDX-License-Identifier: BSD-2-Clause
// swift-corelibs-libdispatch 6.4.0's dispatch_io_pipe_close, in its own
// process for io_pipe_close_test. A DISPATCH_IO_STREAM channel on a pipe's
// read end, low water 0, one dispatch_io_read of UINT_MAX bytes; one byte is
// written, and the read handler closes the write end and, one tick later,
// closes the channel. The cleanup handler prints its error and exits 0.
//   upstream: the test as upstream has it, including dispatch_resume(io)
//   close:    the same without dispatch_resume(io)
//   stop:     no byte is written; DISPATCH_IO_STOP while the read is pending
const std = @import("std");
const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});
const Object = ?*anyopaque;
const Descriptor = extern struct { reserved: c_ulong, size: c_ulong };
fn Block(comptime F: type) type {
    return extern struct { isa: *anyopaque, flags: c_int, reserved: c_int, invoke: F, descriptor: *const Descriptor };
}
const CleanupFn = *const fn (*const anyopaque, c_int) callconv(.c) void;
const ReadFn = *const fn (*const anyopaque, bool, Object, c_int) callconv(.c) void;
const WorkFn = *const fn (*const anyopaque) callconv(.c) void;
extern var _NSConcreteGlobalBlock: [32]?*anyopaque;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_io_create(c_ulong, c_int, Object, *const anyopaque) Object;
extern fn dispatch_io_set_low_water(Object, usize) void;
extern fn dispatch_io_read(Object, i64, usize, Object, *const anyopaque) void;
extern fn dispatch_io_close(Object, c_ulong) void;
extern fn dispatch_resume(Object) void;
extern fn dispatch_after(u64, Object, *const anyopaque) void;
extern fn dispatch_time(u64, i64) u64;
extern fn dispatch_data_get_size(Object) usize;
extern fn dispatch_main() noreturn;

const DISPATCH_IO_STREAM: c_ulong = 0;
const DISPATCH_IO_STOP: c_ulong = 0x1;
const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Block(WorkFn)) };
fn global(comptime F: type, f: F) Block(F) {
    return .{ .isa = @ptrCast(&_NSConcreteGlobalBlock), .flags = 1 << 28, .reserved = 0, .invoke = f, .descriptor = &descriptor };
}

var read_fd: c_int = -1;
var write_fd: c_int = -1;
var io: Object = null;
var q: Object = null;
var stop = false;
var closer: Block(WorkFn) = undefined;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = c.write(1, text.ptr, text.len);
}
fn cleanup(_: *const anyopaque, err: c_int) callconv(.c) void {
    say("cleanup err={d}", .{err});
    _ = c.close(read_fd);
    say("all done", .{});
    c._exit(0);
}
fn closeChannel(_: *const anyopaque) callconv(.c) void {
    say("closing channel flags={d}", .{@intFromBool(stop)});
    dispatch_io_close(io, if (stop) DISPATCH_IO_STOP else 0);
}
fn handler(_: *const anyopaque, done: bool, data: Object, err: c_int) callconv(.c) void {
    const size = if (data != null) dispatch_data_get_size(data) else 0;
    say("read done={d} size={d} err={d}", .{ @intFromBool(done), size, err });
    if (size > 0) {
        say("closing write end", .{});
        _ = c.close(write_fd);
        dispatch_after(dispatch_time(0, 1), q, &closer);
    }
}

pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc != 2) return 2;
    const mode = std.mem.span(argv[1]);
    const upstream = std.mem.eql(u8, mode, "upstream");
    stop = std.mem.eql(u8, mode, "stop");
    if (!upstream and !stop and !std.mem.eql(u8, mode, "close")) return 2;
    const bound = c.dlsym(c.RTLD_DEFAULT, "dispatch_io_create") orelse return 3;
    var info: c.Dl_info = undefined;
    if (c.dladdr(bound, &info) == 0 or info.dli_fname == null) return 3;
    say("lib={s}", .{std.mem.span(info.dli_fname)});
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return 4;
    read_fd = fds[0];
    write_fd = fds[1];
    closer = global(WorkFn, closeChannel);
    const cleanup_block = global(CleanupFn, cleanup);
    const read_block = global(ReadFn, handler);
    q = dispatch_queue_create("q", null);
    io = dispatch_io_create(DISPATCH_IO_STREAM, read_fd, q, &cleanup_block);
    if (io == null) return 5;
    dispatch_io_set_low_water(io, 0);
    dispatch_io_read(io, 0, std.math.maxInt(c_uint), q, &read_block);
    if (upstream) {
        say("resuming channel", .{});
        dispatch_resume(io);
    }
    if (stop) {
        // The read is pending: nothing has been written.
        dispatch_after(dispatch_time(0, 100_000_000), q, &closer);
    } else {
        say("writing", .{});
        _ = c.write(write_fd, "x", 1);
        say("written", .{});
    }
    dispatch_main();
}
