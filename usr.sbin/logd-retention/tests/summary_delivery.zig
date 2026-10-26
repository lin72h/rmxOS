const std = @import("std");
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});
const O = ?*anyopaque;
extern fn asl_store_open_write([*:0]const u8, *O) u32;
extern fn asl_store_save(O, O) u32;
extern fn asl_store_close(O) u32;
extern fn asl_msg_new(u32) O;
extern fn asl_msg_release(O) void;
extern fn asl_msg_set_key_val(O, [*:0]const u8, [*:0]const u8) c_int;
extern fn asl_msg_set_key_val_op(O, [*:0]const u8, [*:0]const u8, u32) c_int;
extern fn asl_msg_list_new() O;
extern fn asl_msg_list_append(O, O) void;
extern fn asl_msg_list_count(O) u32;
extern fn asl_msg_list_release(O) void;
extern fn asl_store_open_read([*:0]const u8, *O) u32;
extern fn asl_store_match(O, O, *u64, u64, u32, u32, i32) O;
extern fn rmx_summary_status() u32;
var fixture: [*:0]const u8 = ".";
var mode: u32 = 0;
pub export fn rmx_store_path() [*:0]const u8 {
    return fixture;
}
fn save(message: O) c_int {
    var store: O = null;
    if (asl_store_open_write(fixture, &store) != 0) return -1;
    defer _ = asl_store_close(store);
    return if (asl_store_save(store, message) == 0) 0 else -1;
}
pub export fn rmx_test_send(_: O, message: O) c_int {
    if (mode == 1 or mode == 3) {
        if (save(message) != 0) return -1;
        if (mode == 3 and save(message) != 0) return -1;
    }
    return 0;
}
fn check(selected: u32, expect_ok: bool) !void {
    var path = "op856-summary-XXXXXX".* ++ [_]u8{0};
    try std.testing.expect(c.mkdtemp(@ptrCast(&path)) != null);
    defer std.Io.Dir.cwd().deleteTree(io, std.mem.sliceTo(&path, 0)) catch {};
    fixture = @ptrCast(&path);
    mode = selected;
    if (mode == 2) {
        const prior = asl_msg_new(0);
        defer asl_msg_release(prior);
        try std.testing.expect(prior != null);
        try std.testing.expectEqual(@as(c_int, 0), asl_msg_set_key_val(prior, "Message", "logd-retention run summary"));
        try std.testing.expectEqual(@as(c_int, 0), asl_msg_set_key_val(prior, "org.rmxos.logd.retention.run", "old-run"));
        try std.testing.expectEqual(@as(c_int, 0), save(prior));
    }
    try std.testing.expectEqual(expect_ok, rmx_summary_status() == 0);
}
test "a readable exact run is delivered" {
    try check(1, true);
}
test "queued but absent is not delivered" {
    try check(0, false);
}
test "a stale summary cannot acknowledge a new run" {
    try check(2, false);
}
test "duplicate run records are not one delivery" {
    try check(3, false);
}

fn micros() u64 {
    var now: c.struct_timespec = undefined;
    std.debug.assert(c.clock_gettime(c.CLOCK_MONOTONIC, &now) == 0);
    return @as(u64, @intCast(now.tv_sec)) * 1_000_000 + @as(u64, @intCast(now.tv_nsec)) / 1000;
}

test "a summary delivered last is found beyond a forward scan batch" {
    var path = "op888-large-summary-XXXXXX".* ++ [_]u8{0};
    try std.testing.expect(c.mkdtemp(@ptrCast(&path)) != null);
    defer std.Io.Dir.cwd().deleteTree(io, std.mem.sliceTo(&path, 0)) catch {};
    fixture = @ptrCast(&path);
    mode = 1;
    const filler = asl_msg_new(0);
    defer asl_msg_release(filler);
    try std.testing.expect(filler != null);
    try std.testing.expectEqual(@as(c_int, 0), asl_msg_set_key_val(filler, "Message", "older store record"));
    try std.testing.expectEqual(@as(c_int, 0), asl_msg_set_key_val(filler, "org.rmxos.logd.retention.run", "old-run"));
    const query = asl_msg_new(1);
    defer asl_msg_release(query);
    try std.testing.expect(query != null);
    try std.testing.expectEqual(@as(c_int, 0), asl_msg_set_key_val_op(query, "org.rmxos.logd.retention.run", "absent-run", 1));
    const queries = asl_msg_list_new();
    defer asl_msg_list_release(queries);
    try std.testing.expect(queries != null);
    asl_msg_list_append(queries, query);
    var records: usize = 0;
    var target: usize = 65536;
    var full_us: u64 = 0;
    var full_last: u64 = 0;
    while (true) {
        var writer: O = null;
        try std.testing.expectEqual(@as(u32, 0), asl_store_open_write(fixture, &writer));
        while (records < target) : (records += 1) {
            try std.testing.expectEqual(@as(u32, 0), asl_store_save(writer, filler));
        }
        try std.testing.expectEqual(@as(u32, 0), asl_store_close(writer));
        var reader: O = null;
        try std.testing.expectEqual(@as(u32, 0), asl_store_open_read(fixture, &reader));
        const start = micros();
        const result = asl_store_match(reader, queries, &full_last, 0, 2, 0, 1);
        full_us = micros() - start;
        try std.testing.expectEqual(@as(u32, 0), asl_msg_list_count(result));
        asl_msg_list_release(result);
        _ = asl_store_close(reader);
        if (full_us >= 400_000) break;
        if (target >= 4_194_304) return error.StoreCalibrationTooFast;
        target *= 2;
    }
    // Warm-cache bounded scans must stop before the tail on every calibration
    // attempt. Four full poll budgets give margin against timing variation.
    for (0..3) |_| {
        var reader: O = null;
        try std.testing.expectEqual(@as(u32, 0), asl_store_open_read(fixture, &reader));
        var last: u64 = 0;
        const result = asl_store_match(reader, queries, &last, 0, 2, 100_000, 1);
        try std.testing.expectEqual(@as(u32, 0), asl_msg_list_count(result));
        asl_msg_list_release(result);
        _ = asl_store_close(reader);
        try std.testing.expect(last < full_last);
        std.debug.print("large_store records={d} full_scan_us={d} poll_us=100000 bounded_last={d} full_last={d}\n", .{ records, full_us, last, full_last });
    }
    // The send boundary appends this run's actual token after all older records.
    const start = micros();
    const status = rmx_summary_status();
    std.debug.print("large_summary status={d} elapsed_us={d}\n", .{ status, micros() - start });
    try std.testing.expectEqual(@as(u32, 0), status);
}
