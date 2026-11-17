// launchd starts this job at load; getty sees no terminal until the reader
// has completed (including no seed/already owned/error), or 60 seconds pass.
const std = @import("std");
const sys = @import("engine").sys;
const completion = @import("seed-completion.zig");
pub const limit_ms = 60_000;
pub const Decision = enum { wait, ready, timeout };
pub fn decide(done: bool, elapsed_ms: i64) Decision {
    if (done) return .ready;
    return if (elapsed_ms >= limit_ms) .timeout else .wait;
}
fn now() !i64 {
    var ts: sys.c.struct_timespec = undefined;
    if (sys.c.clock_gettime(sys.c.CLOCK_MONOTONIC, &ts) != 0) return error.Clock;
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}
fn wait() !void {
    var buf: [80]u8 = undefined;
    const boot = try completion.boot(&buf);
    const start = try now();
    while (true) {
        switch (decide(completion.done(boot), (try now()) - start)) {
            .ready => return,
            .timeout => return error.ReaderTimeout,
            .wait => _ = sys.c.usleep(100_000),
        }
    }
}
pub fn main() u8 {
    wait() catch |err| {
        const message = if (err == error.ReaderTimeout)
            "console-getty: owner reader has not finished within 60 s; offering login\n"
        else
            "console-getty: cannot check owner reader completion; offering login\n";
        sys.writeAll(2, message) catch {};
    };
    const argv = [_:null]?[*:0]const u8{ "/usr/libexec/getty", "3wire.115200", "console" };
    _ = sys.c.execv(argv[0].?, &argv);
    return 127;
}
