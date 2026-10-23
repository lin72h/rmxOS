const std = @import("std");
const c = @cImport({
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
    try std.fs.cwd().writeFile(.{ .sub_path = file, .data = "{\"Label\":\"com.rmxos.unload.unit\"}" });
    defer std.fs.cwd().deleteFile(file) catch {};
    try std.testing.expectEqual(@as(c_int, 0), rmx_unload(file));
    try std.testing.expectEqual(@as(usize, 1), completed);
    try std.testing.expectEqual(@as(usize, 0), asynchronous);
    reject = true;
    try std.testing.expectEqual(@as(c_int, -1), rmx_unload(file));
    try std.testing.expectEqual(@as(c_int, c.EIO), c.__error().*);
}
