const std = @import("std");
const c = @cImport({
    @cInclude("mach/mach.h");
});
pub fn observation(buffer: []u8, iteration: usize, status: c_int, calls: u32) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, "ownership_dispatch_large iteration={d} receive_status={d} receive_status_hex=0x{x} demux_calls={d}", .{ iteration, status, @as(u32, @bitCast(status)), calls });
}
test "dispatch oversized receive diagnostics preserve status and iteration" {
    var buffer: [256]u8 = undefined;
    const Case = struct { status: c_int, iteration: usize, calls: u32, expected: []const u8 };
    for ([_]Case{
        .{ .status = c.MACH_RCV_TOO_LARGE, .iteration = 0, .calls = 0, .expected = "ownership_dispatch_large iteration=0 receive_status=268451844 receive_status_hex=0x10004004 demux_calls=0" },
        .{ .status = c.MACH_RCV_TIMED_OUT, .iteration = 10, .calls = 0, .expected = "ownership_dispatch_large iteration=10 receive_status=268451843 receive_status_hex=0x10004003 demux_calls=0" },
        .{ .status = c.MACH_RCV_INVALID_NAME, .iteration = 3, .calls = 2, .expected = "ownership_dispatch_large iteration=3 receive_status=268451842 receive_status_hex=0x10004002 demux_calls=2" },
        .{ .status = 0, .iteration = 7, .calls = 1, .expected = "ownership_dispatch_large iteration=7 receive_status=0 receive_status_hex=0x0 demux_calls=1" },
    }) |case| {
        try std.testing.expectEqualStrings(case.expected, try observation(&buffer, case.iteration, case.status, case.calls));
    }
}
