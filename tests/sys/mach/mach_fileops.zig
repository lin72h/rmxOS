// SPDX-License-Identifier: BSD-2-Clause
// Observations stay in observe(); the ATF body validates their exact values.
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Operation = enum { poll, nonblock, async_flag, chmod, chown, kevent_read, kevent_write };
const Observation = struct { result: c_int, err: c_int, detail: c_int };

fn observe(op: Operation, fd: c_int) Observation {
    c.__error().* = 0;
    var detail: c_int = 0;
    const result: c_int = switch (op) {
        .poll => blk: {
            var p = c.struct_pollfd{ .fd = fd, .events = c.POLLIN | c.POLLOUT, .revents = 0 };
            const r = c.poll(&p, 1, 0);
            detail = p.revents;
            break :blk r;
        },
        .nonblock => c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK)),
        .async_flag => c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_ASYNC)),
        .chmod => c.fchmod(fd, 0o600),
        .chown => c.fchown(fd, c.getuid(), c.getgid()),
        .kevent_read, .kevent_write => blk: {
            const kq = c.kqueue();
            if (kq < 0) c.atf_tc_fail("kqueue setup failed errno=%d", c.__error().*);
            defer _ = c.close(kq);
            var change = c.struct_kevent{ .ident = @intCast(fd), .filter = if (op == .kevent_read) c.EVFILT_READ else c.EVFILT_WRITE, .flags = c.EV_ADD | c.EV_RECEIPT, .fflags = 0, .data = 0, .udata = null, .ext = .{ 0, 0, 0, 0 } };
            var event: c.struct_kevent = undefined;
            const r = c.kevent(kq, &change, 1, &event, 1, null);
            if (r == 1) {
                detail = @intCast(event.data);
                if (event.flags & c.EV_ERROR == 0) c.atf_tc_fail("kevent receipt lacks EV_ERROR");
            }
            break :blk r;
        },
    };
    return .{ .result = result, .err = c.__error().*, .detail = detail };
}

fn Case(comptime op: Operation) type {
    return struct {
        var tc: c.atf_tc_t = undefined;
        fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
            _ = c.atf_tc_set_md_var(t, "descr", "%s", "Defined native fileops for a Mach receive-right descriptor");
            _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
        }
        fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
            var name: u32 = 0;
            const r = c.syscall(c.SYS__kernelrpc_mach_port_allocate_trap, @as(c_uint, 0), @as(c_uint, 1), &name);
            if (r != 0) c.atf_tc_fail("Mach receive right setup failed result=%d errno=%d", r, c.__error().*);
            defer _ = c.close(@intCast(name));
            const o = observe(op, @intCast(name));
            _ = c.printf("operation=%s result=%d errno=%d detail=%d\n", @tagName(op).ptr, o.result, o.err, o.detail);
            if (op == .poll) {
                if (o.result != 1 or o.detail != c.POLLNVAL) c.atf_tc_fail("poll expected count=1 revents=POLLNVAL observed count=%d revents=%d", o.result, o.detail);
            } else if (op == .kevent_read or op == .kevent_write) {
                if (o.result != 1 or o.detail != c.EINVAL) c.atf_tc_fail("kevent expected receipt=1 error=EINVAL observed result=%d error=%d", o.result, o.detail);
            } else {
                const expected: c_int = if (op == .nonblock or op == .async_flag) c.ENOTTY else c.EINVAL;
                if (o.result != -1 or o.err != expected) c.atf_tc_fail("expected result=-1 errno=%d observed result=%d errno=%d", expected, o.result, o.err);
            }
        }
    };
}

fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const config = c.atf_tp_get_config(tp);
    inline for (.{ Operation.poll, Operation.nonblock, Operation.async_flag, Operation.chmod, Operation.chown, Operation.kevent_read, Operation.kevent_write }) |op| {
        const T = Case(op);
        const init_error = c.atf_tc_init(&T.tc, @tagName(op).ptr, &T.head, &T.body, null, config);
        if (c.atf_is_error(init_error)) return init_error;
        const add_error = c.atf_tp_add_tc(tp, &T.tc);
        if (c.atf_is_error(add_error)) return add_error;
    }
    return c.atf_no_error();
}

pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
