// SPDX-License-Identifier: BSD-2-Clause
// dispatch_suspend and dispatch_resume on one object, in its own process for
// suspend_resume_test. For a group, a semaphore, a data object and an I/O
// channel, a suspend/resume pair and an unbalanced resume return, and the
// object still works afterwards. For a plain queue an unbalanced resume must
// stop the process with "Over-resume of an object".
const std = @import("std");
const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("unistd.h");
});
const Object = ?*anyopaque;
const Descriptor = extern struct { reserved: c_ulong, size: c_ulong };
const CleanupFn = *const fn (*const anyopaque, c_int) callconv(.c) void;
const CleanupBlock = extern struct { isa: *anyopaque, flags: c_int, reserved: c_int, invoke: CleanupFn, descriptor: *const Descriptor };
extern var _NSConcreteGlobalBlock: [32]?*anyopaque;
extern fn dispatch_suspend(Object) void;
extern fn dispatch_resume(Object) void;
extern fn dispatch_group_create() Object;
extern fn dispatch_group_enter(Object) void;
extern fn dispatch_group_leave(Object) void;
extern fn dispatch_group_wait(Object, u64) c_long;
extern fn dispatch_semaphore_create(c_long) Object;
extern fn dispatch_semaphore_signal(Object) c_long;
extern fn dispatch_semaphore_wait(Object, u64) c_long;
extern fn dispatch_data_create(?*const anyopaque, usize, Object, ?*const anyopaque) Object;
extern fn dispatch_data_get_size(Object) usize;
extern fn dispatch_io_create(c_ulong, c_int, Object, *const anyopaque) Object;
extern fn dispatch_io_close(Object, c_ulong) void;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_time(u64, i64) u64;

const second: i64 = 1_000_000_000;
var failed = false;
fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = c.write(1, text.ptr, text.len);
}
fn check(ok: bool, comptime name: []const u8) void {
    say("check {s} {s}", .{ name, if (ok) "ok" else "FAIL" });
    if (!ok) failed = true;
}
// A suspend/resume pair, then an unbalanced resume.
fn exercise(o: Object) void {
    dispatch_suspend(o);
    dispatch_resume(o);
    dispatch_resume(o);
    say("suspend and resume returned", .{});
}

var cleanup_err = std.atomic.Value(c_int).init(-1);
var cleaned: Object = null;
fn cleanup(_: *const anyopaque, err: c_int) callconv(.c) void {
    cleanup_err.store(err, .seq_cst);
    _ = dispatch_semaphore_signal(cleaned);
}
const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(CleanupBlock) };

pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc != 2) return 2;
    const mode = std.mem.span(argv[1]);
    const bound = c.dlsym(c.RTLD_DEFAULT, "dispatch_resume") orelse return 3;
    var info: c.Dl_info = undefined;
    if (c.dladdr(bound, &info) == 0 or info.dli_fname == null) return 3;
    say("lib={s}", .{std.mem.span(info.dli_fname)});
    if (std.mem.eql(u8, mode, "group")) {
        const g = dispatch_group_create();
        exercise(g);
        dispatch_group_enter(g);
        check(dispatch_group_wait(g, dispatch_time(0, 100_000_000)) != 0, "group_wait_times_out_while_entered");
        dispatch_group_leave(g);
        check(dispatch_group_wait(g, dispatch_time(0, second)) == 0, "group_wait_returns_after_leave");
    } else if (std.mem.eql(u8, mode, "semaphore")) {
        const s = dispatch_semaphore_create(0);
        exercise(s);
        _ = dispatch_semaphore_signal(s);
        check(dispatch_semaphore_wait(s, dispatch_time(0, second)) == 0, "semaphore_signal_then_wait");
        check(dispatch_semaphore_wait(s, dispatch_time(0, 100_000_000)) != 0, "semaphore_wait_times_out_when_empty");
    } else if (std.mem.eql(u8, mode, "data")) {
        const bytes = "rmx!";
        const d = dispatch_data_create(bytes, 4, null, null);
        exercise(d);
        check(dispatch_data_get_size(d) == 4, "data_size_unchanged");
    } else if (std.mem.eql(u8, mode, "io")) {
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return 4;
        cleaned = dispatch_semaphore_create(0);
        const q = dispatch_queue_create("rmx.suspend_resume.io", null);
        const block = CleanupBlock{ .isa = @ptrCast(&_NSConcreteGlobalBlock), .flags = 1 << 28, .reserved = 0, .invoke = cleanup, .descriptor = &descriptor };
        const io = dispatch_io_create(0, fds[0], q, &block);
        if (io == null) return 5;
        exercise(io);
        dispatch_io_close(io, 0);
        check(dispatch_semaphore_wait(cleaned, dispatch_time(0, 5 * second)) == 0, "channel_cleanup_ran");
        check(cleanup_err.load(.seq_cst) == 0, "channel_cleanup_err_0");
    } else if (std.mem.eql(u8, mode, "queue")) {
        const q = dispatch_queue_create("rmx.suspend_resume.queue", null);
        say("unbalanced resume of a queue", .{});
        dispatch_resume(q);
        say("unbalanced queue resume returned", .{});
        return 1;
    } else return 2;
    say("done {s}", .{if (failed) "FAIL" else "ok"});
    return if (failed) 1 else 0;
}
