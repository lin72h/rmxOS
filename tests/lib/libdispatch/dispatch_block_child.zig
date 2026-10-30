// SPDX-License-Identifier: BSD-2-Clause
// One dispatch block operation in its own process, for dispatch_block_test:
// "wait", "notify", "cancel" or "perform" on a block from
// dispatch_block_create(0, ...) ("plain") or
// dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS,
// QOS_CLASS_USER_INITIATED, 0, ...) ("qos"). It prints the libdispatch rtld
// bound, one line per check, and exits 0 only when every check holds.
const std = @import("std");
const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});
const Object = ?*anyopaque;
const Fn = *const fn (Object) callconv(.c) void;
const Descriptor = extern struct { reserved: c_ulong, size: c_ulong };
const Block = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const Block) callconv(.c) void,
    descriptor: *const Descriptor,
};
extern var _NSConcreteGlobalBlock: [32]?*anyopaque;
extern fn dispatch_block_create(c_ulong, *const Block) ?*const Block;
extern fn dispatch_block_create_with_qos_class(c_ulong, c_uint, c_int, *const Block) ?*const Block;
extern fn dispatch_block_wait(*const Block, u64) c_long;
extern fn dispatch_block_notify(*const Block, Object, *const Block) void;
extern fn dispatch_block_cancel(*const Block) void;
extern fn dispatch_block_testcancel(*const Block) c_long;
extern fn dispatch_block_perform(c_ulong, *const Block) void;
extern fn dispatch_async(Object, *const Block) void;
extern fn dispatch_sync_f(Object, Object, Fn) void;
extern fn dispatch_queue_create([*:0]const u8, Object) Object;
extern fn dispatch_suspend(Object) void;
extern fn dispatch_resume(Object) void;
extern fn dispatch_time(u64, i64) u64;
extern fn _Block_release(*const anyopaque) void;

const DISPATCH_BLOCK_ENFORCE_QOS_CLASS: c_ulong = 0x20;
const QOS_CLASS_USER_INITIATED: c_uint = 0x19;
const ms: i64 = 1_000_000;

// Events in order: 'B' for the block's body, 'N' for the notify block.
var events: [16]u8 = undefined;
var count = std.atomic.Value(usize).init(0);
fn record(e: u8) void {
    const i = count.fetchAdd(1, .seq_cst);
    if (i < events.len) events[i] = e;
}
fn body(_: *const Block) callconv(.c) void {
    record('B');
}
fn notified(_: *const Block) callconv(.c) void {
    record('N');
}
const descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Block) };
fn literal(f: *const fn (*const Block) callconv(.c) void) Block {
    return .{ .isa = @ptrCast(&_NSConcreteGlobalBlock), .flags = 1 << 28, .reserved = 0, .invoke = f, .descriptor = &descriptor };
}
var body_block: Block = undefined;
var notify_block: Block = undefined;

fn nop(_: Object) callconv(.c) void {}
fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = c.write(1, text.ptr, text.len);
}
var failed = false;
fn check(ok: bool, comptime name: []const u8) void {
    say("check {s} {s}", .{ name, if (ok) "ok" else "FAIL" });
    if (!ok) failed = true;
}
fn seen() []const u8 {
    return events[0..@min(count.load(.seq_cst), events.len)];
}
fn settle(q: Object) void {
    dispatch_sync_f(q, null, nop);
}

fn make(kind: []const u8) *const Block {
    const b = if (std.mem.eql(u8, kind, "qos"))
        dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS, QOS_CLASS_USER_INITIATED, 0, &body_block)
    else
        dispatch_block_create(0, &body_block);
    return b orelse {
        say("check created FAIL", .{});
        c._exit(1);
    };
}

fn wait(kind: []const u8, q: Object) void {
    const db = make(kind);
    dispatch_async(q, db);
    check(dispatch_block_wait(db, dispatch_time(0, 5000 * ms)) == 0, "wait_returns_0_after_async_run");
    check(std.mem.eql(u8, seen(), "B"), "body_ran_once");
    _Block_release(db);
    // A block that has not run: the queue is held so it cannot.
    const pending = make(kind);
    dispatch_suspend(q);
    dispatch_async(q, pending);
    check(dispatch_block_wait(pending, dispatch_time(0, 100 * ms)) != 0, "wait_times_out_before_run");
    check(std.mem.eql(u8, seen(), "B"), "pending_body_not_run");
    dispatch_resume(q);
    settle(q);
    _Block_release(pending);
}

fn notify(kind: []const u8, q: Object) void {
    const db = make(kind);
    dispatch_block_notify(db, q, &notify_block);
    _ = c.usleep(100_000);
    check(count.load(.seq_cst) == 0, "notify_waits_for_block");
    dispatch_async(q, db);
    for (0..500) |_| {
        if (count.load(.seq_cst) >= 2) break;
        _ = c.usleep(10_000);
    }
    _ = c.usleep(100_000);
    settle(q);
    check(std.mem.eql(u8, seen(), "BN"), "notify_once_after_block");
    _Block_release(db);
}

fn cancel(kind: []const u8, q: Object) void {
    const db = make(kind);
    check(dispatch_block_testcancel(db) == 0, "testcancel_0_before_cancel");
    dispatch_block_cancel(db);
    check(dispatch_block_testcancel(db) != 0, "testcancel_nonzero_after_cancel");
    dispatch_async(q, db);
    settle(q);
    check(count.load(.seq_cst) == 0, "cancelled_body_not_run");
    _Block_release(db);
}

fn perform(kind: []const u8) void {
    const db = make(kind);
    dispatch_block_perform(0, db);
    check(std.mem.eql(u8, seen(), "B"), "perform_runs_body_once");
    _Block_release(db);
}

pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc != 3) return 2;
    const op = std.mem.span(argv[1]);
    const kind = std.mem.span(argv[2]);
    if (!std.mem.eql(u8, kind, "plain") and !std.mem.eql(u8, kind, "qos")) return 2;
    // The definition rtld bound, not a canonical PLT address in this program.
    const bound = c.dlsym(c.RTLD_DEFAULT, "dispatch_block_wait") orelse return 3;
    var info: c.Dl_info = undefined;
    if (c.dladdr(bound, &info) == 0 or info.dli_fname == null) return 3;
    say("lib={s}", .{std.mem.span(info.dli_fname)});
    body_block = literal(body);
    notify_block = literal(notified);
    const q = dispatch_queue_create("rmx.dispatch_block", null);
    if (std.mem.eql(u8, op, "wait")) {
        wait(kind, q);
    } else if (std.mem.eql(u8, op, "notify")) {
        notify(kind, q);
    } else if (std.mem.eql(u8, op, "cancel")) {
        cancel(kind, q);
    } else if (std.mem.eql(u8, op, "perform")) {
        perform(kind);
    } else return 2;
    say("done {s}", .{if (failed) "FAIL" else "ok"});
    return if (failed) 1 else 0;
}
