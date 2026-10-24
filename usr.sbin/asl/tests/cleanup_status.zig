const std = @import("std");
const recovery = @import("asld_recovery.zig");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});
test "cleanup reports failure by exit one and never aborts" {
    for ([_]bool{ true, false }) |ok| {
        const child = c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            recovery.cleanupResult(ok, "unit");
            c._exit(0);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
        try std.testing.expectEqual(@as(c_int, if (ok) 0 else 256), status);
    }
}
