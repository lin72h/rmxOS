// SPDX-License-Identifier: BSD-2-Clause
// Test-only lifecycle timestamps around the unchanged retention command.
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("sys/time.h");
    @cInclude("sys/wait.h");
});
fn record(event: [*:0]const u8, pid: c.pid_t, status: c_int) void {
    var time: c.struct_timeval = undefined;
    _ = c.gettimeofday(&time, null);
    const f = c.fopen("/tmp/op040-retention-times", "a") orelse return;
    _ = c.fprintf(f, "op040_logd_retention event=%s pid=%d time=%lld.%06ld wait_status=%d\n", event, pid, @as(c_longlong, time.tv_sec), time.tv_usec, status);
    _ = c.fclose(f);
}
pub export fn main() c_int {
    const pid = c.fork();
    if (pid < 0) return 125;
    if (pid == 0) {
        var args = [_][*c]const u8{ "/usr/libexec/logd-retention", "-once", "-wait-for-filesystems", "-s", "/var/db/logd", null };
        record("start", c.getpid(), 0);
        _ = c.execv(args[0], @ptrCast(&args));
        c._exit(127);
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) return 126;
    record("exit", pid, status);
    return if (status == 0) 0 else 1;
}
