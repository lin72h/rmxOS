const std = @import("std");
extern fn rmx_manual_report([*:0]const u8) ?*anyopaque;
extern fn rmx_manual_sender_dropped() u64;
extern fn rmx_manual_native_report([*:0]const u8) ?*anyopaque;
extern fn asl_msg_release(*anyopaque) void;
extern fn asl_msg_get_val_for_key(*anyopaque, [*:0]const u8) ?[*:0]const u8;
extern fn asl_file_open_write([*:0]const u8, u32, u32, u32, *?*anyopaque) u32;
extern fn asl_file_open_read([*:0]const u8, *?*anyopaque) u32;
extern fn asl_file_save(*anyopaque, *anyopaque, *u64) u32;
extern fn asl_file_fetch_next(*anyopaque, *?*anyopaque) u32;
extern fn asl_file_close(*anyopaque) u32;
extern fn getpid() c_int;
extern fn unlink([*:0]const u8) c_int;

test "native ASL loss report uses the same telemetry counter" {
    const before = rmx_manual_sender_dropped();
    const m = rmx_manual_native_report("[Sender syslog] [Message refused] [com.rmxos.syslog.sender_dropped 11]") orelse return error.Parse;
    defer asl_msg_release(m);
    try std.testing.expectEqual(before + 11, rmx_manual_sender_dropped());
    try std.testing.expectEqualStrings("refused", std.mem.span(asl_msg_get_val_for_key(m, "Message").?));
}

test "sender report increments telemetry and remains a stored record" {
    try storedReport();
}

pub fn storedReport() !void {
    const before = rmx_manual_sender_dropped();
    const m = rmx_manual_report("<44>1 - localhost syslog 42 - [rmxos-loss@0 count=\"37\"] syslog: local socket refused 37 messages") orelse return error.Parse;
    defer asl_msg_release(m);
    try std.testing.expectEqual(before + 37, rmx_manual_sender_dropped());
    var path: [100]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&path, "/tmp/rmx-report-{d}.asl", .{getpid()});
    _ = unlink(name);
    defer _ = unlink(name);
    var file: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), asl_file_open_write(name, 0o600, 0xffffffff, 0xffffffff, &file));
    var id: u64 = 1;
    try std.testing.expectEqual(@as(u32, 0), asl_file_save(file.?, m, &id));
    try std.testing.expectEqual(@as(u32, 0), asl_file_close(file.?));
    try std.testing.expectEqual(@as(u32, 0), asl_file_open_read(name, &file));
    defer _ = asl_file_close(file.?);
    var stored: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), asl_file_fetch_next(file.?, &stored));
    defer asl_msg_release(stored.?);
    try std.testing.expectEqualStrings("37", std.mem.span(asl_msg_get_val_for_key(stored.?, "RFC5424.SD.12:rmxos-loss@0.count").?));
    try std.testing.expectEqualStrings("syslog: local socket refused 37 messages", std.mem.span(asl_msg_get_val_for_key(stored.?, "Message").?));
}

test "invalid sender counts never change telemetry" {
    try invalidCounts();
}

pub fn invalidCounts() !void {
    const before = rmx_manual_sender_dropped();
    for ([_][*:0]const u8{
        "<44>1 - localhost syslog 42 - [rmxos-loss@0 count=\"-1\"] invalid",
        "<44>1 - localhost syslog 42 - [rmxos-loss@0 count=\"18446744073709551616\"] invalid",
        "<44>1 - localhost syslog 42 - [rmxos-loss@0 count=\"37x\"] invalid",
        "<44>1 - localhost syslog 42 - [rmxos-loss@0 count=\"\"] invalid",
    }) |wire| {
        const m = rmx_manual_report(wire) orelse return error.Parse;
        asl_msg_release(m);
    }
    try std.testing.expectEqual(before, rmx_manual_sender_dropped());
}
