const std = @import("std");

pub fn nanoseconds(seconds: i64, nanos: i64) i64 {
    return seconds * std.time.ns_per_s + nanos;
}

test "nanosecond conversion preserves a second boundary" {
    const before = nanoseconds(8, 950000000);
    const after = nanoseconds(9, 50000000);
    try std.testing.expectEqual(@as(i64, 100000000), after - before);
    try std.testing.expectEqual(@as(i64, 2000000000), nanoseconds(2, 0));
}
