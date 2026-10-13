// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/user.h");
    @cInclude("unistd.h");
});
pub fn countPorts(bytes: []const u8) !usize {
    // kern_descrip.c:pack_kinfo trims kf_path and rounds each record to 8.
    const minimum = @offsetOf(c.kinfo_file, "kf_type") + @sizeOf(c_int);
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < minimum) return error.TruncatedRecord;
        const f: *align(1) const c.kinfo_file = @ptrCast(&bytes[offset]);
        if (f.kf_structsize < minimum or f.kf_structsize > bytes.len - offset) return error.InvalidExtent;
        // ipc_entry.c exports KF_TYPE_PORT/KF_TYPE_PORTSET as 17/18.
        if (f.kf_type == 17 or f.kf_type == 18) count += 1;
        offset += @intCast(f.kf_structsize);
    }
    return count;
}
test "packed file records count Mach ports and reject bad extents" {
    const size = comptime std.mem.alignForward(usize, @offsetOf(c.kinfo_file, "kf_path") + 1, 8);
    var bytes: [size * 3]u8 = @splat(0);
    for (0..3) |i| {
        const f: *align(1) c.kinfo_file = @ptrCast(&bytes[i * size]);
        f.kf_structsize = size;
        f.kf_type = if (i == 0) @as(c_int, 1) else if (i == 1) @as(c_int, 17) else @as(c_int, 18);
    }
    try std.testing.expect(size < @sizeOf(c.kinfo_file));
    try std.testing.expectEqual(@as(usize, 2), try countPorts(&bytes));
    try std.testing.expectError(error.InvalidExtent, countPorts(bytes[0 .. size - 1]));
    const f: *align(1) c.kinfo_file = @ptrCast(&bytes[0]);
    f.kf_structsize = 0;
    try std.testing.expectError(error.InvalidExtent, countPorts(&bytes));
}
test "host kern.proc.filedesc packed records parse" {
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_FILEDESC, c.getpid() };
    var bytes: [65536]u8 align(@alignOf(c.kinfo_file)) = undefined;
    var size: usize = bytes.len;
    try std.testing.expectEqual(@as(c_int, 0), c.sysctl(&mib, mib.len, &bytes, &size, null, 0));
    try std.testing.expect(size > 0);
    _ = try countPorts(bytes[0..size]);
}
