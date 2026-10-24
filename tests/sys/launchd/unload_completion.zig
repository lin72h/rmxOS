const std = @import("std");
// ATF callbacks have no process.Init; their file operations are synchronous.
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("launch.h");
    @cInclude("errno.h");
});
extern fn launch_data_new_errno(c_int) ?*anyopaque;
extern fn rmx_unload([*:0]const u8) c_int;
var asynchronous: usize = 0;
var completed: usize = 0;
var reject = false;
pub export fn launch_msg(_: ?*anyopaque) ?*anyopaque {
    asynchronous += 1;
    return launch_data_new_errno(0);
}
pub export fn _vproc_send_signal_by_label(label: [*:0]const u8, signal: c_int) ?*anyopaque {
    if (!std.mem.eql(u8, std.mem.span(label), "com.rmxos.unload.unit") or signal != 0x4141504c or reject) return @ptrFromInt(1);
    completed += 1;
    return null;
}
test "unload returns only through the removal-completion RPC" {
    const file = "op026-unload.json";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "{\"Label\":\"com.rmxos.unload.unit\"}" });
    defer std.Io.Dir.cwd().deleteFile(io, file) catch {};
    try std.testing.expectEqual(@as(c_int, 0), rmx_unload(file));
    try std.testing.expectEqual(@as(usize, 1), completed);
    try std.testing.expectEqual(@as(usize, 0), asynchronous);
    reject = true;
    try std.testing.expectEqual(@as(c_int, -1), rmx_unload(file));
    try std.testing.expectEqual(@as(c_int, c.EIO), c.__error().*);
}
