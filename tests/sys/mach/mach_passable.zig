// SPDX-License-Identifier: BSD-2-Clause
const abi = @import("file_message.zig");
const c = abi.c;
fn Case(comptime nonpassable: bool) type {
    return struct {
        var tc: c.atf_tc_t = undefined;
        fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
            _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach transfer rejects a non-passable kqueue and accepts a pipe");
            _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
        }
        fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
            const port = abi.allocate();
            defer _ = c.close(@intCast(port));
            var pipe: [2]c_int = .{ -1, -1 };
            const source = if (nonpassable) c.kqueue() else blk: {
                if (c.pipe(&pipe) != 0) c.atf_tc_fail("pipe setup failed");
                break :blk pipe[1];
            };
            if (source < 0) c.atf_tc_fail("source setup failed");
            defer _ = c.close(source);
            defer {
                if (pipe[0] >= 0) _ = c.close(pipe[0]);
            }
            const sent = abi.sendFile(port, source);
            _ = c.printf("file_send nonpassable=%d observed=0x%x\n", @as(c_int, @intFromBool(nonpassable)), @as(c_uint, @bitCast(sent)));
            if (nonpassable) {
                if (sent != 0x1000000a) c.atf_tc_fail("expected MACH_SEND_INVALID_RIGHT observed=0x%x", @as(c_uint, @bitCast(sent)));
            } else {
                if (sent != 0) c.atf_tc_fail("passable file send failed");
                var received: abi.Message = undefined;
                const rc = abi.receiveFile(port, &received);
                if (rc != 0 or received.count != 1 or received.descriptor.kind != 0) c.atf_tc_fail("passable file receive failed");
                if (c.close(@intCast(received.descriptor.name)) != 0) c.atf_tc_fail("received file close failed");
            }
        }
    };
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    inline for (.{ Case(true), Case(false) }, .{ "reject_kqueue", "accept_pipe" }) |T, name| {
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
