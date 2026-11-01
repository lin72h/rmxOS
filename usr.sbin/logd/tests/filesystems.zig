// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
// ATF callbacks have no process.Init; their file operations are synchronous.
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/stat.h");
    @cInclude("sys/time.h");
    @cInclude("sys/param.h");
    @cInclude("sys/mount.h");
    @cInclude("unistd.h");
});
extern fn rmx_fs_wait() c_int;
extern fn rmx_fs_sealed() c_int;
var boot = c.struct_timeval{ .tv_sec = 100, .tv_usec = 0 };
var boot_id: [16]u8 = @splat(1);
var sleeps: usize = 0;
var marker: [:0]u8 = undefined;
var identity: [:0]u8 = undefined;
pub export fn rmx_fs_path(path: [*:0]const u8) [*:0]const u8 {
    return if (std.mem.endsWith(u8, std.mem.span(path), "boot-id")) identity.ptr else marker.ptr;
}
pub export fn rmx_fs_stat(fd: c_int, st: *c.struct_stat) c_int {
    const rc = c.fstat(fd, st);
    st.st_uid = 0;
    return rc;
}
pub export fn rmx_fs_sysctl(name: [*:0]const u8, out: [*]u8, size: *usize, _: ?*const anyopaque, _: usize) c_int {
    const data: []const u8 = if (std.mem.eql(u8, std.mem.span(name), "kern.boot_id")) &boot_id else std.mem.asBytes(&boot);
    if (size.* < data.len) return -1;
    @memcpy(out[0..data.len], data);
    size.* = data.len;
    return 0;
}
// Mount table seen by logd's layout decision (default: a legacy rw root).
const Mount = struct { kind: []const u8, point: []const u8, ro: bool, present: bool = true };
var root_mount = Mount{ .kind = "ufs", .point = "/", .ro = false };
var private_mount = Mount{ .kind = "ufs", .point = "/", .ro = false };
pub export fn rmx_fs_statfs(path: [*:0]const u8, out: *c.struct_statfs) c_int {
    const m = if (std.mem.eql(u8, std.mem.span(path), "/")) root_mount else private_mount;
    if (!m.present) return -1;
    out.* = std.mem.zeroes(c.struct_statfs);
    out.f_flags = if (m.ro) c.MNT_RDONLY else 0;
    @memcpy(out.f_fstypename[0..m.kind.len], m.kind);
    @memcpy(out.f_mntonname[0..m.point.len], m.point);
    return 0;
}
test "logd waits for rc's marker except on the sealed layout" {
    defer {
        root_mount = .{ .kind = "ufs", .point = "/", .ro = false };
        private_mount = .{ .kind = "ufs", .point = "/", .ro = false };
    }
    // Sealed: read-only ZFS root, /private its own writable ZFS or tmpfs mount.
    root_mount = .{ .kind = "zfs", .point = "/", .ro = true };
    for ([_][]const u8{ "zfs", "tmpfs" }) |kind| {
        private_mount = .{ .kind = kind, .point = "/private", .ro = false };
        try std.testing.expectEqual(@as(c_int, 1), rmx_fs_sealed());
    }
    // Not sealed: /private not mounted, read-only, or absent.
    private_mount = .{ .kind = "zfs", .point = "/", .ro = true };
    try std.testing.expectEqual(@as(c_int, 0), rmx_fs_sealed());
    private_mount = .{ .kind = "zfs", .point = "/private", .ro = true };
    try std.testing.expectEqual(@as(c_int, 0), rmx_fs_sealed());
    private_mount.present = false;
    try std.testing.expectEqual(@as(c_int, 0), rmx_fs_sealed());
    // Legacy roots: read-write (ZFS or UFS), or UFS still read-only before rc.
    private_mount = .{ .kind = "zfs", .point = "/private", .ro = false };
    root_mount = .{ .kind = "zfs", .point = "/", .ro = false };
    try std.testing.expectEqual(@as(c_int, 0), rmx_fs_sealed());
    root_mount = .{ .kind = "ufs", .point = "/", .ro = true };
    try std.testing.expectEqual(@as(c_int, 0), rmx_fs_sealed());
}
pub export fn rmx_fs_sleep(_: ?*const anyopaque, _: ?*anyopaque) c_int {
    sleeps += 1;
    return 0;
}
test "filesystem gate survives boottime adjustment but rejects a prior boot identity" {
    const a = std.testing.allocator;
    marker = try std.fmt.allocPrintSentinel(a, "/tmp/op021-fs-{d}", .{c.getpid()}, 0);
    defer a.free(marker);
    identity = try std.fmt.allocPrintSentinel(a, "/tmp/op021-fs-{d}.boot-id", .{c.getpid()}, 0);
    defer a.free(identity);
    defer std.Io.Dir.cwd().deleteFile(io, marker) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, identity) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = std.mem.asBytes(&boot), .flags = .{ .permissions = .fromMode(0o600) } });
    try std.testing.expectEqual(@as(c_int, 0), rmx_fs_wait());
    boot.tv_usec = 1; // a clock correction changes kern.boottime, not the boot
    try std.testing.expectEqual(@as(c_int, 0), rmx_fs_wait());
    try std.testing.expectEqual(@as(usize, 0), sleeps);
    boot_id[0] = 2;
    try std.testing.expectEqual(@as(c_int, -1), rmx_fs_wait());
    try std.testing.expect(sleeps > 0);
}
