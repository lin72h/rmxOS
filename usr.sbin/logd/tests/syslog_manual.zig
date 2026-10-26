const std = @import("std");
extern fn getenv([*:0]const u8) ?[*:0]const u8;
extern fn rmx_manual_load([*:0]const u8) c_uint;
extern fn rmx_manual_destination(c_uint) ?[*:0]const u8;
extern fn rmx_manual_match(c_uint, [*:0]const u8, [*:0]const u8, [*:0]const u8) c_int;
extern fn rmx_manual_kernel_text() ?[*:0]u8;
extern fn free(?*anyopaque) void;

test "kernel text keeps the ASL sender and PID prefix" {
    const text = rmx_manual_kernel_text() orelse return error.NoKernelText;
    defer free(text);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(text), "kernel[0]: kernel format check") != null);
}

test "manual examples parse and route through logd" {
    const config = getenv("RMX_MANUAL_CONFIG") orelse return error.MissingConfig;
    try std.testing.expectEqual(@as(c_uint, 8), rmx_manual_load(config));
    const sinks = [_][]const u8{ "/var/log/errors", "/var/log/kernel", "/var/log/daemon.debug", "/var/log/spoolerr", "/var/log/ftpd", "/var/log/bird", "/var/log/quiet", "/var/log/secure" };
    const facilities = [_][*:0]const u8{ "auth", "authpriv", "console", "cron", "daemon", "ftp", "kern", "lpr", "mail", "news", "ntp", "security", "syslog", "user", "uucp", "launchd", "local0", "local1", "local2", "local3", "local4", "local5", "local6", "local7" };
    const levels = [_][*:0]const u8{ "0", "1", "2", "3", "4", "5", "6", "7" };
    const senders = [_][*:0]const u8{ "app", "ftpd", "bird", "bird6", "noisy", "kernel", "FTPD" };
    for (sinks, 0..) |sink, route| {
        try std.testing.expectEqualStrings(sink, std.mem.span(rmx_manual_destination(@intCast(route)).?));
        for (facilities) |facility| {
            const f = std.mem.span(facility);
            for (levels, 0..) |level, severity| {
                for (senders) |sender| {
                    const s = std.mem.span(sender);
                    const expected = switch (route) {
                        0 => severity <= 3 and !std.mem.eql(u8, f, "authpriv"),
                        1 => std.mem.eql(u8, f, "kern"),
                        2 => std.mem.eql(u8, f, "daemon") and severity == 7,
                        3 => (std.mem.eql(u8, f, "mail") or std.mem.eql(u8, f, "news")) and severity <= 3,
                        4 => std.mem.eql(u8, s, "ftpd"),
                        5 => (std.mem.eql(u8, s, "bird") or std.mem.eql(u8, s, "bird6")) and std.mem.eql(u8, f, "local0") and severity <= 6,
                        6 => !std.mem.eql(u8, s, "noisy") and std.mem.eql(u8, f, "user") and severity <= 5,
                        7 => std.mem.eql(u8, f, "authpriv"),
                        else => unreachable,
                    };
                    try std.testing.expectEqual(@as(c_int, if (expected) 1 else 0), rmx_manual_match(@intCast(route), facility, level, sender));
                }
            }
        }
    }
}
