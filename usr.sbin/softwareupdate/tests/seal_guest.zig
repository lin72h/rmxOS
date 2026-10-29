const std = @import("std");
const u = @import("update");
const f = @import("install_checks.zig");
const c = u.c;
const a = std.heap.page_allocator;
const expect = std.testing.expect;
const base_name = "rmxos-198000000001";
const target = "rmxos-bbbbbbbbbbbb";
const token = "0123456789abcdef0123456789abcdef";
fn fmt(comptime format: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, format, args, 0);
}
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
const Backend = struct {
    force_snapshot: bool = false,
    activated: bool = false,
    fn command(ptr: ?*anyopaque, alloc: std.mem.Allocator, args: []const [:0]const u8) ![]const u8 {
        const self: *Backend = @ptrCast(@alignCast(ptr.?));
        if (eq(args[0], "/sbin/zfs") and eq(args[1], "snapshot") and self.force_snapshot) {
            // Create the exact owned snapshot first, so the real second
            // snapshot command fails with an existing-name error.
            _ = try u.capture(alloc, args);
        }
        if (eq(args[0], "/sbin/bectl") and eq(args[1], "activate")) {
            self.activated = true;
            try expect(!self.force_snapshot);
        }
        return u.capture(alloc, args);
    }
};
fn call(args: []const [:0]const u8) ![]const u8 {
    return u.capture(a, args);
}
fn destroy(parent: []const u8, name: []const u8) !void {
    const ds = try fmt("{s}/{s}", .{ parent, name });
    try u.seals.release(a, .{}, ds);
    _ = try call(&.{ "/sbin/bectl", "destroy", try a.dupeZ(u8, name) });
}
fn create(parent: []const u8, name: []const u8) !void {
    _ = try call(&.{ "/sbin/zfs", "create", "-o", "mountpoint=/", "-o", "canmount=noauto", try fmt("{s}/{s}", .{ parent, name }) });
}
pub fn run() !void {
    try expect(c.geteuid() == 0);
    const original = u.snapshot(a);
    const ds = try u.seals.dataset(original);
    const parent = std.fs.path.dirname(ds).?;
    const fixture = try f.Fixture.init(false);
    defer fixture.deinit();
    // Never edit the booted BE. Start an empty, test-owned BE under this
    // guest's existing ROOT dataset; all installs clone only that owned BE.
    try create(parent, base_name);
    defer {
        _ = call(&.{ "/sbin/bectl", "unmount", base_name }) catch {};
        destroy(parent, base_name) catch {};
    }
    const mount = try fmt("{s}/base", .{fixture.path});
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), mount);
    _ = try call(&.{ "/sbin/bectl", "mount", base_name, mount });
    const root = try u.engine.Root.open(a, mount, true);
    defer root.close();
    const old = [_]f.File{ .{ .path = "/usr/share/op198-changed", .data = "old" }, .{ .path = "/usr/share/op198-missing", .data = "old" }, .{ .path = "/etc/op198-owner", .data = "stock old" } };
    const new = [_]f.File{ .{ .path = "/usr/share/op198-changed", .data = "built" }, .{ .path = "/usr/share/op198-missing", .data = "built" }, .{ .path = "/etc/op198-owner", .data = "stock new" } };
    for (old) |file| try root.write(file.path, file.data, 0o644);
    try root.write("/etc/op198-owner", "owner before update", 0o644);
    try root.write("/var/db/rmxos/manifest.tsv", try f.manifest(&old), 0o444);
    try root.write("/var/db/rmxos/commit", "a" ** 40 ++ "\n", 0o444);
    try root.createDirectory(.{ .path = "/boot/RMXOS-RELEASE", .mode = 0o755, .uid = 0, .gid = 0 });
    const dirs = "rmx-directories-v1\n0755\t0\t0\t/usr/lib/op198-type\n";
    try f.packDirectories(fixture.archive, &old, &new, false, dirs);
    const context = u.Context{ .allocator = a, .root = mount };
    const snapshot = u.Snapshot{ .uid = 0, .dataset = try fmt("{s}/{s}", .{ parent, base_name }), .listing = base_name ++ "\tNR\t/\n" };
    const options = u.Options{ .action = .install, .operand = fixture.archive, .no_auto_confirm = true };
    var failed = Backend{ .force_snapshot = true };
    const failed_result = u.engine.install(context, options, snapshot, .{ .data = &failed, .execute = Backend.command });
    if (failed_result) |_| return error.SnapshotFailureAccepted else |_| {}
    try expect(!failed.activated);
    try expect(std.mem.indexOf(u8, try call(&.{ "/sbin/bectl", "list", "-H" }), target ++ "\tT") == null);
    try destroy(parent, target);
    try u.write(1, "op198 snapshot_failure=refused activated=no\n");
    var successful = Backend{};
    try expect(try u.engine.install(context, options, snapshot, .{ .data = &successful, .execute = Backend.command }) == 0);
    defer {
        _ = call(&.{ "/sbin/bectl", "activate", "-T" }) catch {};
        destroy(parent, target) catch {};
    }
    try expect(successful.activated);
    const seal = ((try u.seals.info(a, .{}, try fmt("{s}/{s}", .{ parent, target }))) orelse return error.SealAbsent).name;
    const holds = try call(&.{ "/sbin/zfs", "holds", "-H", seal });
    try expect(std.mem.indexOf(u8, holds, "softwareupdate") != null);
    try u.write(1, holds);
    const hand_destroy = u.capture(a, &.{ "/sbin/zfs", "destroy", seal });
    if (hand_destroy) |_| return error.HeldSealDestroyed else |_| {}
    try u.write(1, "op198 manual_destroy=refused hold=softwareupdate\n");
    const candidate = try fmt("{s}/candidate", .{fixture.path});
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), candidate);
    _ = try call(&.{ "/sbin/bectl", "mount", target, candidate });
    var mounted = true;
    defer if (mounted) {
        _ = call(&.{ "/sbin/bectl", "unmount", target }) catch {};
    };
    const candidate_root = try u.engine.Root.open(a, candidate, true);
    var opened = true;
    defer if (opened) candidate_root.close();
    const candidate_context = u.Context{ .allocator = a, .root = candidate };
    const candidate_snapshot = u.Snapshot{ .uid = 0, .dataset = try fmt("{s}/{s}", .{ parent, target }), .listing = target ++ "\tN\n" };
    try expect(try u.run(candidate_context, &.{"verify"}, candidate_snapshot) == 0);
    try u.write(1, "op198 verify_clean=0\n");
    try candidate_root.write("/usr/share/op198-changed", "drift", 0o644);
    try candidate_root.remove("/usr/share/op198-missing");
    try expect(c.rmdir(try fmt("{s}/usr/lib/op198-type", .{candidate})) == 0);
    try candidate_root.write("/usr/lib/op198-type", "wrong type", 0o644);
    try candidate_root.write("/etc/op198-owner", "owner after update", 0o644);
    try candidate_root.write("/var/db/op198-runtime", "not base", 0o644);
    try u.write(1, "op198 verify_drift_begin\n");
    try expect(try u.run(candidate_context, &.{"verify"}, candidate_snapshot) == 1);
    try expect(try u.run(candidate_context, &.{ "verify", "--quiet" }, candidate_snapshot) == 1);
    try u.write(1, "op198 verify_drift_end exit=1\n");
    try u.seals.status(candidate_context, candidate_snapshot, .{});
    candidate_root.close();
    opened = false;
    _ = try call(&.{ "/sbin/bectl", "unmount", target });
    mounted = false;
    // The mounted owned base supplies the registry written by install.
    var cancel_snapshot = snapshot;
    cancel_snapshot.listing = base_name ++ "\tNR\n" ++ target ++ "\tT\n";
    try expect(try u.lifecycle.command(context, .cancel, cancel_snapshot, .{}, false) == 0);
    try expect(std.mem.indexOf(u8, try call(&.{ "/sbin/bectl", "list", "-H" }), target) == null);
    try expect(std.mem.indexOf(u8, try call(&.{ "/sbin/zfs", "list", "-H", "-t", "snapshot", "-o", "name", "-r", try a.dupeZ(u8, parent) }), seal) == null);
    try u.write(1, "op198 cancel=destroyed seal=gone rollback=non-destructive\n");
    const names = [_][]const u8{ "rmxos-198000000011", "rmxos-198000000012", "rmxos-198000000013", "rmxos-198000000014", "rmxos-198000000015" };
    defer for (names) |name| {
        destroy(parent, name) catch {};
    };
    var registry: std.ArrayList(u8) = .empty;
    for (names) |name| {
        try create(parent, name);
        const at = try fmt("{s}/retention", .{fixture.path});
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), at);
        _ = try call(&.{ "/sbin/bectl", "mount", try a.dupeZ(u8, name), at });
        const other = try u.engine.Root.open(a, at, true);
        try other.write("/var/db/softwareupdate/created-by", try fmt("{s}\t{s}\n", .{ name, token }), 0o444);
        other.close();
        _ = try call(&.{ "/sbin/bectl", "unmount", try a.dupeZ(u8, name) });
        try u.seals.create(a, .{}, try fmt("{s}/{s}", .{ parent, name }));
        try registry.appendSlice(a, try fmt("{s}\t{s}\n", .{ name, token }));
    }
    try root.write("/var/db/softwareupdate/environments.tsv", registry.items, 0o444);
    try u.lifecycle.prune(context, root, .{}, snapshot.dataset.?, names[0]);
    const remaining = try call(&.{ "/sbin/bectl", "list", "-H" });
    var count: usize = 0;
    for (names) |name| if (std.mem.indexOf(u8, remaining, name) != null) {
        count += 1;
    };
    try expect(count == 3);
    try u.write(1, "op198 retention=passed remaining=3 pruned=2 seals=gone\nop198 complete\n");
}
