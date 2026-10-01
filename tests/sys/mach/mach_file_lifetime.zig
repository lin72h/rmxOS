// SPDX-License-Identifier: BSD-2-Clause
const abi = @import("file_message.zig");
const c = abi.c;
fn Case(comptime exhaust: bool) type {
    return struct {
        var tc: c.atf_tc_t = undefined;
        fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
            _ = c.atf_tc_set_md_var(t, "descr", "%s", "File wrappers release exactly one reference on success and failure");
            _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
        }
        fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
            const port = abi.allocate();
            defer _ = c.close(@intCast(port));
            var pipe: [2]c_int = undefined;
            if (c.pipe(&pipe) != 0) c.atf_tc_fail("pipe setup failed");
            defer _ = c.close(pipe[0]);
            if (c.fcntl(pipe[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) != 0) c.atf_tc_fail("nonblocking setup failed");
            if (abi.sendFile(port, pipe[1]) != 0) c.atf_tc_fail("file send failed");
            if (c.close(pipe[1]) != 0) c.atf_tc_fail("original writer close failed");
            var limit: c.struct_rlimit = undefined;
            var filled: [128]c_int = undefined;
            var count: usize = 0;
            if (exhaust) {
                if (c.getrlimit(c.RLIMIT_NOFILE, &limit) != 0) c.atf_tc_fail("getrlimit failed");
                var small = limit;
                small.rlim_cur = @min(limit.rlim_cur, 128);
                if (c.setrlimit(c.RLIMIT_NOFILE, &small) != 0) c.atf_tc_fail("setrlimit failed");
                while (count < filled.len) {
                    const fd = c.dup(pipe[0]);
                    if (fd < 0) break;
                    filled[count] = fd;
                    count += 1;
                }
                if (count == filled.len or c.__error().* != c.EMFILE) c.atf_tc_fail("descriptor exhaustion not established");
            }
            defer {
                for (filled[0..count]) |fd| _ = c.close(fd);
                if (exhaust) _ = c.setrlimit(c.RLIMIT_NOFILE, &limit);
            }
            var msg: abi.Message = undefined;
            const received = abi.receiveFile(port, &msg);
            _ = c.printf("file_receive exhausted=%d observed_result=0x%x\n", @as(c_int, @intFromBool(exhaust)), @as(c_uint, @bitCast(received)));
            if (exhaust) {
                if (@as(c_uint, @bitCast(received)) != 0x1000600c) c.atf_tc_fail("expected MACH_RCV_BODY_ERROR|MACH_MSG_IPC_SPACE result=0x%x", @as(c_uint, @bitCast(received)));
            } else {
                if (received != 0 or msg.count != 1 or msg.descriptor.kind != 0) c.atf_tc_fail("file receive failed");
                if (c.close(@intCast(msg.descriptor.name)) != 0) c.atf_tc_fail("received writer close failed");
            }
            var byte: u8 = 0;
            const eof = c.read(pipe[0], &byte, 1);
            _ = c.printf("pipe expected_eof=0 observed_read=%ld errno=%d\n", eof, c.__error().*);
            if (eof != 0) c.atf_tc_fail("pipe retained a writer after visible references closed");
        }
    };
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (.{ Case(false), Case(true) }, .{ "success_eof", "fd_exhaustion" }) |T, name| {
        const err = c.atf_tc_init(&T.tc, name, &T.head, &T.body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &T.tc);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return abi.atf_tp_main(argc, argv, &addTests);
}
