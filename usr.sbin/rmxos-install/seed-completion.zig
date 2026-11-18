// A completion record belongs to one boot, including reader refusal/no-op.
// Its key is kern.boot_id, random per boot (sys/kern/kern_mib.c
// sysctl_bootid), which a clock step leaves alone; kern.boottime moves on
// every step (tc_setclock). kern.boot_id fails with ENXIO until random(4) is
// seeded, so both sides retry it within the same 60 second bound.
// /var/db/rmxos is a directory on a file-based root and lies under /var's
// link to /private/var on a sealed root; the reader makes it if absent.
const std = @import("std");
const sys = @import("engine").sys;
pub const dir = "/var/db/rmxos";
pub const path = dir ++ "/owner-seed.done";
pub const limit_ms = 60_000;
pub const poll_ms = 100;
// 32 hex digits and a line end.
pub const Id = [33]u8;
extern "c" fn sysctlbyname([*:0]const u8, ?*anyopaque, ?*usize, ?*const anyopaque, usize) c_int;

pub fn boot(buf: *Id) ![]const u8 {
    var raw: [16]u8 = undefined;
    var len: usize = raw.len;
    if (sysctlbyname("kern.boot_id", &raw, &len, null, 0) != 0 or len != raw.len) return error.BootId;
    buf[0..32].* = std.fmt.bytesToHex(raw, .lower);
    buf[32] = '\n';
    return buf;
}
// The bound counts polls of at least poll_ms each, so no clock is needed.
pub fn pause() void {
    _ = sys.c.usleep(poll_ms * 1000);
}
// The live system's key and pause; tests pass their own.
pub const Live = struct {
    pub fn id(_: Live, buf: *Id) ![]const u8 {
        return boot(buf);
    }
    pub fn sleep(_: Live) void {
        pause();
    }
};
pub fn finish() void {
    _ = finishAt(Live{}, dir, path);
}
// Writes this boot's key once it can be read, within limit_ms. The record
// replaces any old one by rename, so a reader sees an old record, none, or
// the whole new one.
pub fn finishAt(src: anytype, d: [:0]const u8, p: [:0]const u8) bool {
    var buf: Id = undefined;
    var polls: i64 = 0;
    const key = while (true) : (polls += 1) {
        if (src.id(&buf)) |k| break k else |_| {}
        if (polls * poll_ms >= limit_ms) return false;
        src.sleep();
    };
    _ = sys.c.mkdir(d, 0o755);
    var name: [256]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&name, "{s}.new", .{p}) catch return false;
    const fd = sys.c.open(tmp, sys.c.O_WRONLY | sys.c.O_CREAT | sys.c.O_TRUNC | sys.c.O_NOFOLLOW | sys.c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return false;
    const ok = if (sys.writeAll(fd, key)) true else |_| false;
    _ = sys.c.close(fd);
    if (!ok or sys.c.rename(tmp, p) != 0) {
        _ = sys.c.unlink(tmp);
        return false;
    }
    return true;
}
// The record's bytes, null when it cannot be read. One byte more than a
// record, so a longer file never compares equal.
pub fn record(p: [:0]const u8, buf: *[@sizeOf(Id) + 1]u8) ?[]const u8 {
    const fd = sys.c.open(p, sys.c.O_RDONLY | sys.c.O_NOFOLLOW | sys.c.O_NONBLOCK | sys.c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = sys.c.close(fd);
    const n = sys.c.read(fd, buf, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else null;
}
