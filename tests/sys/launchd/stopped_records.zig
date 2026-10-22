const std = @import("std");

pub fn check(bytes: []const u8, prefix: []const u8, jobs: usize, drops: u64) !u64 {
    const seen = try std.heap.page_allocator.alloc(bool, jobs);
    defer std.heap.page_allocator.free(seen);
    @memset(seen, false);
    const field = try std.fmt.allocPrint(std.heap.page_allocator, "[RefProc {s}", .{prefix});
    defer std.heap.page_allocator.free(field);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var stored: u64 = 0;
    while (lines.next()) |line| {
        const start = (std.mem.indexOf(u8, line, field) orelse continue) + field.len;
        const end = std.mem.indexOfScalarPos(u8, line, start, ']') orelse return error.Format;
        const index = try std.fmt.parseInt(usize, line[start..end], 10);
        if (index >= jobs) return error.Range;
        if (std.mem.count(u8, line, "[Message Exited with code: 73]") != 1) return error.Status;
        if (seen[index]) return error.Duplicate;
        seen[index] = true;
        stored += 1;
    }
    if (drops > jobs or stored != jobs - drops) return error.Accounting;
    for (seen, 0..) |present, index| {
        if (present != (index >= drops)) return error.Gap;
    }
    return stored;
}

test "all retained exits plus drops account for produced jobs" {
    try std.testing.expectEqual(@as(u64, 2), try check("[RefProc job.2] [Message Exited with code: 73]\n[RefProc job.3] [Message Exited with code: 73]\n", "job.", 4, 2));
}
test "newest alone cannot conceal missing retained exits" {
    try std.testing.expectError(error.Accounting, check("[RefProc job.3] [Message Exited with code: 73]\n", "job.", 4, 2));
}
test "duplicate retained exit cannot replace missing exit" {
    try std.testing.expectError(error.Duplicate, check("[RefProc job.3] [Message Exited with code: 73]\n[RefProc job.3] [Message Exited with code: 73]\n", "job.", 4, 2));
}

pub fn attributed(produced: u64, prior: u64, queued: u64, dropped: u64, own_stored: u64, other_stored: u64, other_dropped: u64) bool {
    if (dropped < prior or dropped - prior < other_dropped or own_stored > produced) return false;
    const own_drops = dropped - prior - other_dropped;
    return own_stored + own_drops == produced and own_stored + other_stored == queued;
}
test "an unrelated counted drop cannot cover an uncounted workload loss" {
    try std.testing.expect(!attributed(4, 0, 3, 2, 2, 1, 1));
    try std.testing.expect(attributed(4, 0, 4, 2, 3, 1, 1));
}
test "unrelated exit during stopped workload is accounted separately" {
    try std.testing.expect(attributed(1200, 4, 1000, 205, 999, 1, 0));
    try std.testing.expect(!attributed(1200, 4, 1000, 203, 999, 1, 0));
}

test "a hole inside the retained suffix is not a counted prefix drop" {
    try std.testing.expectError(error.Gap, check("[RefProc job.1] [Message Exited with code: 73]\n[RefProc job.3] [Message Exited with code: 73]\n", "job.", 4, 2));
}
