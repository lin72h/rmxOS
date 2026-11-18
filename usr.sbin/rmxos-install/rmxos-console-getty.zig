// launchd starts this job at load and after every console logout; getty
// sees no terminal until this boot's reader has completed (including no
// seed/already owned/error), or 60 seconds pass. Neither a clock step nor a
// key that cannot be read yet offers login early.
const std = @import("std");
const sys = @import("engine").sys;
const completion = @import("seed-completion.zig");
pub const limit_ms = completion.limit_ms;
pub const Decision = enum { wait, ready, timeout };
// id: this boot's key, null while kern.boot_id cannot be read;
// record: the completion record's bytes, null while it cannot be read.
pub fn decide(id: ?[]const u8, record: ?[]const u8, elapsed_ms: i64) Decision {
    if (id) |k| if (record) |r| if (std.mem.eql(u8, k, r)) return .ready;
    return if (elapsed_ms >= limit_ms) .timeout else .wait;
}
pub const Outcome = enum { ready, reader, boot_id };
fn wait() Outcome {
    var polls: i64 = 0;
    var read_id = false;
    while (true) : (polls += 1) {
        var key: completion.Id = undefined;
        var bytes: [@sizeOf(completion.Id) + 1]u8 = undefined;
        const id = completion.boot(&key) catch null;
        read_id = read_id or id != null;
        switch (decide(id, completion.record(completion.path, &bytes), polls * completion.poll_ms)) {
            .ready => return .ready,
            .timeout => return if (read_id) .reader else .boot_id,
            .wait => completion.pause(),
        }
    }
}
pub fn main() u8 {
    const message: []const u8 = switch (wait()) {
        .ready => "",
        .reader => "console-getty: owner reader has not finished within 60 s; offering login\n",
        .boot_id => "console-getty: cannot read kern.boot_id within 60 s; offering login\n",
    };
    if (message.len > 0) sys.writeAll(2, message) catch {};
    const argv = [_:null]?[*:0]const u8{ "/usr/libexec/getty", "3wire.115200", "console" };
    _ = sys.c.execv(argv[0].?, @ptrCast(&argv));
    return 127;
}
