// A completion record belongs to one boot, including reader refusal/no-op.
const std = @import("std");
const sys = @import("engine").sys;
pub const path = "/private/var/db/rmxos/owner-seed.done";
extern "c" fn sysctlbyname([*:0]const u8, ?*anyopaque, ?*usize, ?*const anyopaque, usize) c_int;

pub fn boot(buf: []u8) ![]const u8 {
    var tv: sys.c.struct_timeval = undefined;
    var len: usize = @sizeOf(@TypeOf(tv));
    if (sysctlbyname("kern.boottime", &tv, &len, null, 0) != 0 or len != @sizeOf(@TypeOf(tv))) return error.BootTime;
    return std.fmt.bufPrint(buf, "{d}:{d}\n", .{ tv.tv_sec, tv.tv_usec });
}
pub fn finish() void {
    var buf: [80]u8 = undefined;
    const value = boot(&buf) catch return;
    const fd = sys.c.open(path, sys.c.O_WRONLY | sys.c.O_CREAT | sys.c.O_TRUNC | sys.c.O_NOFOLLOW | sys.c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return;
    defer _ = sys.c.close(fd);
    sys.writeAll(fd, value) catch {};
}
pub fn matches(expected: []const u8, observed: []const u8) bool {
    return std.mem.eql(u8, expected, observed);
}
pub fn done(expected: []const u8) bool {
    const fd = sys.c.open(path, sys.c.O_RDONLY | sys.c.O_NOFOLLOW | sys.c.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = sys.c.close(fd);
    var buf: [81]u8 = undefined;
    const n = sys.c.read(fd, &buf, buf.len);
    return n > 0 and matches(expected, buf[0..@intCast(n)]);
}
