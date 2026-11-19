// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

fn probe(tc: [*c]const c.atf_tc_t, name: [*:0]const u8, fail: bool) void {
    var path: [4096]u8 = undefined;
    const n = c.snprintf(&path, path.len, "%s/%s", c.atf_tc_get_config_var(tc, "srcdir"), name);
    if (n < 0 or n >= path.len) c.atf_tc_fail("probe path too long");
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) c.atf_tc_fail("pipe");
    const pid = c.fork();
    if (pid < 0) c.atf_tc_fail("fork");
    if (pid == 0) {
        _ = c.close(fds[0]);
        if (c.dup2(fds[1], 1) < 0 or c.dup2(fds[1], 2) < 0) c._exit(126);
        _ = c.close(fds[1]);
        _ = c.unsetenv("ROOT_BOOTSTRAP");
        _ = c.unsetenv("LD_PRELOAD");
        if (fail) {
            if (c.setenv("RMX_MACH_INIT_FAIL", "1", 1) != 0) c._exit(126);
        } else {
            _ = c.unsetenv("RMX_MACH_INIT_FAIL");
        }
        var argv = [_:null]?[*:0]const u8{ @ptrCast(&path), null };
        _ = c.execv(@ptrCast(&path), @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    var output: [1024]u8 = undefined;
    var used: usize = 0;
    while (used < output.len) {
        const count = c.read(fds[0], output[used..].ptr, output.len - used);
        if (count < 0) c.atf_tc_fail("read");
        if (count == 0) break;
        used += @intCast(count);
    }
    _ = c.close(fds[0]);
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid or status != 0) c.atf_tc_fail("probe did not exit normally with status 0");
    _ = c.printf("%s fail=%d observed:\n%.*s", name, @as(c_int, @intFromBool(fail)), @as(c_int, @intCast(used)), &output);
    const expected = "initial bootstrap=0 fetches=1 logs=0\nrepeat bootstrap=0 fetches=1 logs=0\n";
    if (!std.mem.eql(u8, output[0..used], expected)) c.atf_tc_fail("constructor must leave a null port, fetch once and make no syslog call");
}
fn quiet(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    probe(tc, "mach_init_static", true);
    probe(tc, "mach_init_dynamic", false);
    probe(tc, "mach_init_dynamic", true);
}
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var test_case: c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&test_case, "startup_quiet", null, &quiet, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &test_case);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
