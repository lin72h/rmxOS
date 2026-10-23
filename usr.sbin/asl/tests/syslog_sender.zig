const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});
extern fn rmx_sender_path([*:0]const u8) void;
extern fn rmx_sender_syslog(c_int, [*:0]const u8, ...) void;
extern fn rmx_sender_closelog() void;
extern fn rmx_sender_openlog([*:0]const u8, c_int, c_int) void;
extern fn rmx_sender_buffer(c_int) c_int;

test "full local socket accounts for every application message exactly once" {
    try fullSocket();
}

pub fn fullSocket() !void {
    var path: [100]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&path, "/tmp/rmx-sender-{d}.sock", .{c.getpid()});
    _ = c.unlink(name);
    defer _ = c.unlink(name);
    const fd = c.socket(c.AF_UNIX, c.SOCK_DGRAM, 0);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    var address = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    address.sun_len = @sizeOf(c.struct_sockaddr_un);
    @memcpy(address.sun_path[0..name.len], name);
    try std.testing.expectEqual(@as(c_int, 0), c.bind(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)));
    var small: c_int = 2048;
    try std.testing.expectEqual(@as(c_int, 0), c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVBUF, &small, @sizeOf(c_int)));
    rmx_sender_path(name);
    rmx_sender_openlog("rmx_sender", 8, 8);
    try std.testing.expectEqual(@as(c_int, 0), rmx_sender_buffer(2048));
    defer rmx_sender_closelog();
    for (0..1000) |i| rmx_sender_syslog(14, "numbered %u", @as(c_uint, @intCast(i)));
    var received: u64 = 0;
    var reported: u64 = 0;
    try drain(fd, &received, &reported);
    try std.testing.expect(received > 0 and received < 1000);
    // The child inherits pending state but must never report its parent's loss.
    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        rmx_sender_syslog(14, "numbered child");
        c._exit(0);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
    try std.testing.expectEqual(@as(c_int, 0), status);
    var child_received: u64 = 0;
    var child_reported: u64 = 0;
    try drain(fd, &child_received, &child_reported);
    try std.testing.expectEqual(@as(u64, 1), child_received);
    try std.testing.expectEqual(@as(u64, 0), child_reported);
    _ = c.sleep(1);
    rmx_sender_syslog(14, "numbered %u", @as(c_uint, 1000));
    try drain(fd, &received, &reported);
    try std.testing.expect(reported > 0);
    try std.testing.expectEqual(@as(u64, 1001), received + reported);
}

fn drain(fd: c_int, received: *u64, reported: *u64) !void {
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = c.recv(fd, &buffer, buffer.len, c.MSG_DONTWAIT);
        if (n < 0) break;
        const wire = buffer[0..@intCast(n)];
        if (std.mem.indexOf(u8, wire, "[rmxos-loss@0 count=\"")) |start| {
            const digits = wire[start + "[rmxos-loss@0 count=\"".len ..];
            const end = std.mem.indexOfScalar(u8, digits, '"') orelse return error.BadReport;
            reported.* += try std.fmt.parseInt(u64, digits[0..end], 10);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, wire, "numbered ") != null);
            received.* += 1;
        }
    }
}
