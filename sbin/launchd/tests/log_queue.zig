const std = @import("std");
extern fn rmx_queue_clear() void;
extern fn rmx_queue_add(c_uint, c_uint) void;
extern fn rmx_queue_facts(*[3]u64) void;
fn facts() [3]u64 {
    var out: [3]u64 = undefined;
    rmx_queue_facts(&out);
    return out;
}
test "queue retains at most 1000 messages and counts removals" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_queue_add(6000, 20);
    const out = facts();
    try std.testing.expectEqual(@as(u64, 1000), out[0]);
    try std.testing.expect(out[1] <= 256 * 1024);
    try std.testing.expectEqual(@as(u64, 5000), out[2]);
}
test "byte bound applies before the message count bound" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_queue_add(500, 4096);
    const out = facts();
    try std.testing.expect(out[0] > 0 and out[0] < 1000);
    try std.testing.expect(out[1] <= 256 * 1024);
    try std.testing.expectEqual(@as(u64, 500), out[0] + out[2]);
}
test "oversized record is dropped without discarding retained messages" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_queue_add(1, 20);
    const before = facts();
    rmx_queue_add(1, 300 * 1024);
    const after = facts();
    try std.testing.expectEqual(before[0], after[0]);
    try std.testing.expectEqual(before[1], after[1]);
    try std.testing.expectEqual(@as(u64, 1), after[2]);
}
