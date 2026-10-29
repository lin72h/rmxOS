// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline
    // (tests/lib/libxpc/bsm_header.zig does the same).
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;

const runs = 10;
const deadline_ms = 10_000;
const Child = struct {
    pid: c.pid_t,
    out: c_int,
    started: i64,
    status: c_int = 0,
    done: bool = false,
    timed_out: bool = false,
    elapsed: i64 = 0,
    text: [256]u8 = undefined,
    len: usize = 0,
};
fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}
fn spawn(helper: [*:0]const u8, mode: [*:0]const u8) Child {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) c.atf_tc_fail("pipe");
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork");
    if (pid == 0) {
        const limit = c.struct_rlimit{ .rlim_cur = 0, .rlim_max = 0 };
        _ = c.setrlimit(c.RLIMIT_CORE, &limit);
        _ = c.dup2(fds[1], 1);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        const argv = [_:null]?[*:0]const u8{ helper, mode };
        _ = c.execv(helper, @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    return .{ .pid = pid, .out = fds[0], .started = now() };
}
// Every child runs at once; each must exit 0 within 10 s of its start.
fn reap(children: []Child) void {
    var left = children.len;
    while (left > 0) {
        for (children) |*ch| {
            if (ch.done) continue;
            const elapsed = now() - ch.started;
            var status: c_int = 0;
            var r = c.waitpid(ch.pid, &status, c.WNOHANG);
            if (r == 0 and elapsed >= deadline_ms) {
                _ = c.kill(ch.pid, c.SIGKILL);
                r = c.waitpid(ch.pid, &status, 0);
                ch.timed_out = true;
            }
            if (r == 0) continue;
            if (r != ch.pid) c.atf_tc_fail("waitpid");
            ch.status = status;
            ch.elapsed = elapsed;
            ch.done = true;
            left -= 1;
            while (ch.len < ch.text.len) {
                const n = c.read(ch.out, &ch.text[ch.len], ch.text.len - ch.len);
                if (n <= 0) break;
                ch.len += @intCast(n);
            }
            _ = c.close(ch.out);
        }
        _ = c.usleep(10_000);
    }
}
fn initTwice(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const srcdir = c.atf_tc_get_config_var(tc, "srcdir");
    var helper: [512]u8 = undefined;
    var lib: [512]u8 = undefined;
    _ = c.snprintf(&helper, helper.len, "%s/init_twice_child", srcdir);
    _ = c.snprintf(&lib, lib.len, "%s/lib/libdispatch.so.5", srcdir);
    var st: c.struct_stat = undefined;
    // A base copy beside the program carries its own libdispatch.
    const expected: [*:0]const u8 = if (c.stat(&lib, &st) == 0) @ptrCast(&lib) else "/usr/lib/libdispatch.so.5";
    var want: [600]u8 = undefined;
    const want_len: usize = @intCast(c.snprintf(&want, want.len, "lib=%s\nmain queue ran\n", expected));
    const modes = [_][*:0]const u8{ "implicit", "explicit" };
    var children: [modes.len * runs]Child = undefined;
    for (&children, 0..) |*ch, i| ch.* = spawn(@ptrCast(&helper), modes[i / runs]);
    reap(&children);
    var failed = false;
    for (modes, 0..) |mode, m| {
        var passed: u32 = 0;
        var timed_out: u32 = 0;
        var slowest: i64 = 0;
        for (children[m * runs ..][0..runs]) |ch| {
            slowest = @max(slowest, ch.elapsed);
            if (ch.timed_out) {
                timed_out += 1;
            } else if (c.WIFEXITED(ch.status) and c.WEXITSTATUS(ch.status) == 0 and
                std.mem.eql(u8, ch.text[0..ch.len], want[0..want_len]))
            {
                passed += 1;
            } else {
                _ = c.printf("init_twice mode=%s status=%d output=%.*s\n", mode, ch.status, @as(c_int, @intCast(ch.len)), &ch.text);
            }
        }
        _ = c.printf("init_twice mode=%s lib=%s passed=%u timed_out=%u slowest_ms=%ld\n", mode, expected, passed, timed_out, slowest);
        if (passed != runs) failed = true;
    }
    _ = c.fflush(null);
    if (failed) c.atf_tc_fail("every run exits 0 within 10 s with \"main queue ran\"");
}

const ApplyDescriptor = extern struct { reserved: c_ulong, size: c_ulong };
const ApplyBlock = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const ApplyBlock, usize) callconv(.c) void,
    descriptor: *const ApplyDescriptor,
};
extern var _NSConcreteGlobalBlock: [32]?*anyopaque;
extern fn dispatch_apply(usize, ?*anyopaque, *const ApplyBlock) void;
extern fn rmx_apply_auto() ?*anyopaque;
var hits: [8]std.atomic.Value(u32) = @splat(.init(0));
fn hit(_: *const ApplyBlock, i: usize) callconv(.c) void {
    if (i < hits.len) _ = hits[i].fetchAdd(1, .seq_cst);
}
const apply_descriptor = ApplyDescriptor{ .reserved = 0, .size = @sizeOf(ApplyBlock) };
fn applyAuto(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const auto = rmx_apply_auto();
    if (auto != null) c.atf_tc_fail("DISPATCH_APPLY_AUTO is the null queue");
    const block = ApplyBlock{ .isa = @ptrCast(&_NSConcreteGlobalBlock), .flags = 1 << 28, .reserved = 0, .invoke = &hit, .descriptor = &apply_descriptor };
    dispatch_apply(hits.len, auto, &block);
    for (&hits, 0..) |*h, i| {
        const n = h.load(.seq_cst);
        if (n != 1) c.atf_tc_fail("index %zu covered once: observed=%u", i, n);
    }
}

const names = [_][*:0]const u8{ "initTwice", "applyAuto" };
const bodies = .{ &initTwice, &applyAuto };
const timeouts = [_][*:0]const u8{ "60", "10" };
var cases: [names.len]c.atf_tc_t = undefined;
fn head(comptime i: usize) fn ([*c]c.atf_tc_t) callconv(.c) void {
    return struct {
        fn f(tc: [*c]c.atf_tc_t) callconv(.c) void {
            _ = c.atf_tc_set_md_var(tc, "timeout", "%s", timeouts[i]);
        }
    }.f;
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (names, 0..) |name, i| {
        const err = c.atf_tc_init(&cases[i], name, &head(i), bodies[i], null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
