const std = @import("std");
extern fn rmx_drain_request(c_int, c_uint) c_int;
extern fn rmx_drain_exit(c_int) void;
extern fn rmx_drain_held() c_uint;
extern fn rmx_drain_sent() c_uint;
test "process exit counts held records and captured drops exactly once" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_queue_add(1010, 20);
    try std.testing.expectEqual(@as(c_int, -305), rmx_drain_request(100, 42));
    try std.testing.expectEqual(@as(u64, 0), facts()[0]);
    rmx_drain_exit(101);
    try std.testing.expectEqual(@as(u64, 0), facts()[2]);
    rmx_drain_exit(100);
    try std.testing.expectEqual(@as(u64, 1010), facts()[2]);
    rmx_drain_exit(100);
    try std.testing.expectEqual(@as(u64, 1010), facts()[2]);
}
test "same process with a different reply name releases held batch uncounted" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_queue_add(10, 20);
    const before = rmx_drain_sent();
    try std.testing.expectEqual(@as(c_int, -305), rmx_drain_request(100, 42));
    try std.testing.expectEqual(@as(c_uint, 10), rmx_drain_held());
    rmx_queue_add(5, 20);
    try std.testing.expectEqual(@as(c_int, -305), rmx_drain_request(100, 43));
    try std.testing.expectEqual(@as(c_uint, 5), rmx_drain_held());
    try std.testing.expectEqual(before + 15, rmx_drain_sent());
    try std.testing.expectEqual(@as(u64, 0), facts()[2]);
    rmx_drain_exit(100);
    try std.testing.expectEqual(@as(u64, 5), facts()[2]);
}
test "another process with a reused reply name cannot take held batch" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_queue_add(10, 20);
    try std.testing.expectEqual(@as(c_int, -305), rmx_drain_request(100, 42));
    const sent = rmx_drain_sent();
    rmx_queue_add(5, 20);
    try std.testing.expectEqual(@as(c_int, 6), rmx_drain_request(101, 42));
    try std.testing.expectEqual(sent, rmx_drain_sent());
    try std.testing.expectEqual(@as(c_uint, 10), rmx_drain_held());
    try std.testing.expectEqual(@as(u64, 5), facts()[0]);
    rmx_drain_exit(100);
    try std.testing.expectEqual(@as(u64, 10), facts()[2]);
    try std.testing.expectEqual(@as(c_int, -305), rmx_drain_request(101, 42));
}
extern fn rmx_bad_forward(c_uint) void;
extern fn rmx_failed_report_send(c_uint) void;
test "invalid forward counts both discarded records" {
    for (0..3) |mode| {
        rmx_queue_clear();
        defer rmx_queue_clear();
        rmx_bad_forward(@intCast(mode));
        try std.testing.expectEqual(@as(u64, 2), facts()[2]);
        try std.testing.expectEqual(@as(u64, 0), facts()[0]);
    }
}
test "failed send counts job text once and restores only the leading report" {
    for ([_]c_uint{ 0, 5 }) |pending| {
        rmx_queue_clear();
        defer rmx_queue_clear();
        rmx_failed_report_send(pending);
        try std.testing.expectEqual(@as(u64, pending + 1), facts()[2]);
    }
}
test "allocation failure counts the entire remaining forward tail" {
    for ([_]c_uint{ 3, 4 }, 0..) |mode, kept| {
        rmx_queue_clear();
        defer rmx_queue_clear();
        rmx_bad_forward(mode);
        try std.testing.expectEqual(@as(u64, 2 - kept), facts()[2]);
        try std.testing.expectEqual(@as(u64, kept), facts()[0]);
    }
}
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
extern fn rmx_route(c_int, c_int) c_int;
extern fn rmx_queue_numbered(c_uint) void;
extern fn rmx_queue_oldest() c_uint;
test "queue retains newest records in insertion order" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_queue_numbered(6000);
    try std.testing.expectEqual(@as(c_uint, 5000), rmx_queue_oldest());
}
test "PID1 retains records for asld through drainer start stop and restart" {
    try std.testing.expectEqual(@as(c_int, 0), rmx_route(0, 0));
    try std.testing.expectEqual(@as(c_int, 0), rmx_route(1, 0));
    try std.testing.expectEqual(@as(c_int, 0), rmx_route(1, 1));
    try std.testing.expectEqual(@as(c_int, 0), rmx_route(1, 0));
    try std.testing.expectEqual(@as(c_int, 0), rmx_route(1, 1));
}

extern fn rmx_queue_pack(*[4]u64) void;
test "drain reports exact losses separately and clears pending losses once" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_queue_numbered(6000);
    var out: [4]u64 = undefined;
    rmx_queue_pack(&out);
    try std.testing.expectEqual(@as(u64, 1000), out[0]);
    try std.testing.expectEqual(@as(u64, 5000), out[1]);
    try std.testing.expectEqual(@as(u64, 0), out[2]);
    try std.testing.expectEqual(@as(u64, 0), out[3]);
    rmx_queue_add(1, 20);
    rmx_queue_pack(&out);
    try std.testing.expectEqual(@as(u64, 1), out[0]);
    try std.testing.expectEqual(@as(u64, 0), out[1]);
}

extern fn rmx_record_valid(*const anyopaque, usize) c_int;
const Record = extern struct {
    link: u64 = 0,
    when: i64 = 0,
    from_pid: i32 = 1,
    about_pid: i32 = 1,
    uid: u32 = 0,
    gid: u32 = 0,
    err: i32 = 0,
    pri: i32 = 5,
    from: u64 = 80,
    about: u64 = 82,
    session: u64 = 84,
    msg: u64 = 86,
    size: u64 = 96,
    data: [16]u8 = .{ 'a', 0, 'b', 0, 'c', 0, 'm', 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};
test "drain wire records reject truncated zero unaligned and bad string offsets" {
    var r = Record{};
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(Record));
    try std.testing.expectEqual(@as(c_int, 1), rmx_record_valid(&r, @sizeOf(Record)));
    try std.testing.expectEqual(@as(c_int, 0), rmx_record_valid(&r, 72));
    for ([_]u64{ 0, 8, 79, 95, 104 }) |n| {
        r.size = n;
        try std.testing.expectEqual(@as(c_int, 0), rmx_record_valid(&r, 96));
    }
    r = .{};
    for ([_]u64{ 0, 72, 96, 4096 }) |n| {
        r.msg = n;
        try std.testing.expectEqual(@as(c_int, 0), rmx_record_valid(&r, 96));
    }
    r = .{};
    r.data = @splat('x');
    try std.testing.expectEqual(@as(c_int, 0), rmx_record_valid(&r, 96));
}

test "invalid forward with an oversized aligned frame counts all three records" {
    rmx_queue_clear();
    defer rmx_queue_clear();
    rmx_bad_forward(5);
    try std.testing.expectEqual(@as(u64, 0), facts()[0]);
    try std.testing.expectEqual(@as(u64, 3), facts()[2]);
}
