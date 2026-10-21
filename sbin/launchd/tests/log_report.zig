const std = @import("std");
extern fn rmx_report(i32, i32, u32, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) u64;
test "only launchd own identity can report losses" {
    const name = "com.apple.launchd";
    const msg = "launchd log queue dropped 7 records";
    try std.testing.expectEqual(@as(u64, 7), rmx_report(1, 1, 0, name, name, msg));
    try std.testing.expectEqual(@as(u64, 0), rmx_report(1, 123, 0, name, "job", msg));
    try std.testing.expectEqual(@as(u64, 0), rmx_report(1, 123, 0, name, name, msg));
    try std.testing.expectEqual(@as(u64, 0), rmx_report(1, 1, 0, name, "job", msg));
    try std.testing.expectEqual(@as(u64, 0), rmx_report(1, 1, 0, name, null, msg));
    try std.testing.expectEqual(@as(u64, 0), rmx_report(1, 1, 1, name, name, msg));
    try std.testing.expectEqual(@as(u64, 0), rmx_report(2, 1, 0, name, name, msg));
    try std.testing.expectEqual(@as(u64, 0), rmx_report(1, 1, 0, "job", name, msg));
    try std.testing.expectEqual(@as(u64, 0), rmx_report(1, 1, 0, name, name, "launchd log queue dropped 7 records extra"));
}
