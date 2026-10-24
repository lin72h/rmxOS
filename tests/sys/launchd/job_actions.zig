const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("stddef.h");
    @cInclude("ipc_job_action.h");
});
var calls: usize = 0;
fn action(_: ?*c.struct_job_s) callconv(.c) void {
    calls += 1;
    c.__error().* = c.ENXIO;
}
test "accepted job action ignores incidental internal ENXIO" {
    calls = 0;
    var token: usize = 0;
    try std.testing.expectEqual(@as(c_int, 0), c.ipc_job_action(@ptrCast(&token), action));
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(c_int, c.ENXIO), c.__error().*);
}
test "unknown job answers ESRCH even with stale errno" {
    calls = 0;
    c.__error().* = c.ENXIO;
    try std.testing.expectEqual(@as(c_int, c.ESRCH), c.ipc_job_action(null, action));
    try std.testing.expectEqual(@as(usize, 0), calls);
}
