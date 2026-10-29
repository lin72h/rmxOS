const std = @import("std");
const u = @import("update");
const e = u.engine;
const c = u.c;
const a = std.heap.page_allocator;
const io = std.Io.Threaded.global_single_threaded.io();
const expect = std.testing.expect;
const names = [_][:0]const u8{ "rmxos-242000000001", "rmxos-242000000002", "rmxos-242000000003" };
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn fmt(comptime format: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, format, args, 0);
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n\t");
}
const Fixture = struct {
    path: [:0]const u8,
    pool: [:0]const u8,
    parent: [:0]const u8,
    md: [:0]const u8,
    fn init() !Fixture {
        const commissioned = c.getenv("OP242_REAL_ZFS") orelse return error.SkipZigTest;
        if (!eq(std.mem.span(commissioned), "1")) return error.SkipZigTest;
        try expect(c.geteuid() == 0);
        const path = try a.dupeZ(u8, "/tmp/softwareupdate-lineage-XXXXXX");
        try expect(c.mkdtemp(path) != null);
        errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        const md = try a.dupeZ(u8, trim(try u.capture(a, &.{ "/sbin/mdconfig", "-a", "-t", "swap", "-s", "256m" })));
        errdefer _ = u.capture(a, &.{ "/sbin/mdconfig", "-d", "-u", md }) catch {};
        var random: [8]u8 = undefined;
        c.arc4random_buf(&random, random.len);
        const pool = try fmt("op242_{s}", .{std.fmt.bytesToHex(random, .lower)});
        _ = try u.capture(a, &.{ "/sbin/zpool", "create", "-f", "-o", "cachefile=none", "-O", "mountpoint=none", pool, try fmt("/dev/{s}", .{md}) });
        errdefer _ = u.capture(a, &.{ "/sbin/zpool", "destroy", "-f", pool }) catch {};
        const parent = try fmt("{s}/ROOT", .{pool});
        _ = try u.capture(a, &.{ "/sbin/zfs", "create", "-o", "mountpoint=none", parent });
        return .{ .path = path, .pool = pool, .parent = parent, .md = md };
    }
    fn deinit(f: Fixture) !void {
        _ = try u.capture(a, &.{ "/sbin/zpool", "destroy", "-f", f.pool });
        _ = try u.capture(a, &.{ "/sbin/mdconfig", "-d", "-u", f.md });
        try std.Io.Dir.cwd().deleteTree(io, f.path);
    }
    fn ds(f: Fixture, i: usize) ![:0]const u8 {
        return fmt("{s}/{s}", .{ f.parent, names[i] });
    }
    fn mount(f: *Fixture, i: usize) ![:0]const u8 {
        const path = try fmt("{s}/{s}", .{ f.path, names[i] });
        try std.Io.Dir.cwd().createDirPath(io, path);
        _ = try f.backend().command(a, &.{ "/sbin/bectl", "mount", names[i], path });
        return path;
    }
    fn backend(f: *Fixture) e.Backend {
        return .{ .data = f, .execute = execute };
    }
    fn execute(ptr: ?*anyopaque, alloc: std.mem.Allocator, args: []const [:0]const u8) ![]const u8 {
        const f: *Fixture = @ptrCast(@alignCast(ptr.?));
        if (!eq(args[0], "/sbin/bectl")) return u.capture(alloc, args);
        var routed: std.ArrayList([:0]const u8) = .empty;
        try routed.appendSlice(alloc, &.{ args[0], "-r", f.parent });
        try routed.appendSlice(alloc, args[1..]);
        return u.capture(alloc, routed.items);
    }
    fn legacySeal(f: Fixture, i: usize) !void {
        const seal = try fmt("{s}@sealed", .{try f.ds(i)});
        _ = try u.capture(a, &.{ "/sbin/zfs", "snapshot", seal });
        _ = try u.capture(a, &.{ "/sbin/zfs", "hold", "softwareupdate", seal });
    }
    fn content(f: Fixture, path: []const u8, i: usize) !void {
        _ = f;
        const root = try e.Root.open(a, try a.dupeZ(u8, path), false);
        defer root.close();
        const bytes = try fmt("environment-{d}", .{i});
        try root.write("/usr/bin/lineage-fixture", bytes, 0o555);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        try root.write("/var/db/rmxos/manifest.tsv", try fmt("rmx-overlay-v1\nbase={s}\n{s}\t0555\t/usr/bin/lineage-fixture\n", .{ "a" ** 64, std.fmt.bytesToHex(digest, .lower) }), 0o444);
        try root.createDirectory(.{ .path = "/usr/lib/lineage-empty", .mode = 0o755, .uid = 0, .gid = 0 });
        try root.write("/var/db/rmxos/directories.tsv", "rmx-directories-v1\n0755\t0\t0\t/usr/lib/lineage-empty\n", 0o444);
    }
};
pub fn run(rollback: bool) !void {
    var f = try Fixture.init();
    var active = true;
    defer if (active) {
        f.deinit() catch |err| u.write(2, fmt("op242 cleanup=failed reason={s}\n", .{@errorName(err)}) catch "op242 cleanup=failed\n") catch {};
    };
    _ = try u.capture(a, &.{ "/sbin/zfs", "create", "-o", "mountpoint=/", "-o", "canmount=noauto", try f.ds(0) });
    const first = try f.mount(0);
    try f.content(first, 0);
    const to_second = try fmt("{s}@to-second", .{try f.ds(0)});
    _ = try u.capture(a, &.{ "/sbin/zfs", "snapshot", to_second });
    _ = try u.capture(a, &.{ "/sbin/zfs", "clone", "-o", "mountpoint=/", "-o", "canmount=noauto", to_second, try f.ds(1) });
    const middle = try f.mount(1);
    try f.content(middle, 1);
    // Reproduce the first old-version confirmation: its parent had no seal.
    try f.legacySeal(1);
    _ = try u.capture(a, &.{ "/sbin/zpool", "set", try fmt("bootfs={s}", .{try f.ds(0)}), f.pool });
    _ = try f.backend().command(a, &.{ "/sbin/bectl", "activate", names[1] });
    // All three environments are sealed by the time the newest is confirmed.
    try f.legacySeal(0);
    const clone_point = try fmt("{s}@to-newest", .{try f.ds(1)});
    _ = try u.capture(a, &.{ "/sbin/zfs", "snapshot", clone_point });
    _ = try u.capture(a, &.{ "/sbin/zfs", "clone", "-o", "mountpoint=/", "-o", "canmount=noauto", clone_point, try f.ds(2) });
    const newest = try f.mount(2);
    try f.content(newest, 2);
    {
        const root = try e.Root.open(a, newest, false);
        defer root.close();
        try root.write("/var/db/rmxos/previous-be", names[1], 0o444);
        try root.write("/var/db/rmxos/pending-target", names[2], 0o444);
    }
    if (rollback) {
        try u.seals.create(a, f.backend(), try f.ds(2));
        const seal = (try u.seals.info(a, f.backend(), try f.ds(2))) orelse return error.NewestSealAbsent;
        // Remove the collision independently, so the base reaches the moved
        // seal lookup instead of failing for the first case's reason.
        _ = try u.capture(a, &.{ "/sbin/zfs", "rename", seal.name, try fmt("{s}@fixture-newest-unique", .{try f.ds(2)}) });
    } else {
        // An update installed by the old binary arrives with @sealed and
        // no identity, even though its payload contains the new confirmer.
        try f.legacySeal(2);
    }
    const ctx = u.Context{ .allocator = a, .root = newest };
    const snap = u.Snapshot{ .uid = 0, .dataset = try f.ds(2), .listing = names[0] ++ "\t-\n" ++ names[1] ++ "\tR\n" ++ names[2] ++ "\tN\n" };
    try u.write(1, try fmt("op242 real_zfs case={s} environments=3 stage=before_confirm pool={s}\n", .{ if (rollback) "sealFoundAfterPromote" else "secondUpdateConfirms", f.pool }));
    try expect(try u.lifecycle.command(ctx, .confirm, snap, f.backend(), false) == 0);
    try expect(eq(trim(try u.capture(a, &.{ "/sbin/zpool", "get", "-H", "-o", "value", "bootfs", f.pool })), try f.ds(2)));
    if (!rollback) {
        var ids: [3][]const u8 = undefined;
        for (names, 0..) |name, i| {
            const seal = (try u.seals.info(a, f.backend(), try f.ds(i))) orelse return error.EnvironmentSealLost;
            const id = trim(try u.capture(a, &.{ "/sbin/zfs", "get", "-H", "-p", "-o", "value", "guid", seal.name }));
            const recorded = trim(try u.capture(a, &.{ "/sbin/zfs", "get", "-H", "-p", "-o", "value", "-s", "local", "org.rmxos:seal-guid", try f.ds(i) }));
            try expect(eq(id, recorded) and std.mem.endsWith(u8, seal.name, try fmt("@sealed-{s}", .{id})));
            const holds = try u.capture(a, &.{ "/sbin/zfs", "holds", "-H", seal.name });
            try expect(std.mem.indexOf(u8, holds, "\tsoftwareupdate\t") != null);
            for (ids[0..i]) |other| try expect(!eq(other, id));
            ids[i] = id;
            try u.write(1, try fmt("op242 seal environment={s} snapshot={s} guid={s}\n", .{ name, seal.name, id }));
        }
    }
    if (rollback) {
        const moved = (try u.seals.info(a, f.backend(), try f.ds(1))) orelse return error.PreviousSealLost;
        try expect(std.mem.startsWith(u8, moved.name, try fmt("{s}@", .{try f.ds(2)})));
        try u.write(1, try fmt("op242 moved_seal environment={s} snapshot={s}\n", .{ names[1], moved.name }));
        _ = try f.backend().command(a, &.{ "/sbin/bectl", "unmount", names[2] });
        const previous_ctx = u.Context{ .allocator = a, .root = middle };
        const previous_snap = u.Snapshot{ .uid = 0, .dataset = try f.ds(1), .listing = names[1] ++ "\tN\n" };
        try expect(try u.seals.verify(previous_ctx, previous_snap, f.backend(), false) == 0);
        const empty = try fmt("{s}/usr/lib/lineage-empty", .{middle});
        try expect(c.chmod(empty, 0o700) == 0);
        try expect(try u.seals.verify(previous_ctx, previous_snap, f.backend(), false) == 1);
        try expect(c.chmod(empty, 0o755) == 0);
        _ = try f.backend().command(a, &.{ "/sbin/bectl", "mount", names[2], newest });
        try expect(try u.lifecycle.command(ctx, .rollback, snap, f.backend(), false) == 0);
        try expect(eq(trim(try u.capture(a, &.{ "/sbin/zpool", "get", "-H", "-o", "value", "bootfs", f.pool })), try f.ds(1)));
        try expect(try u.seals.verify(previous_ctx, previous_snap, f.backend(), false) == 0);
    }
    try u.write(1, try fmt("op242 real_zfs case={s} environments=3 result=passed\n", .{if (rollback) "sealFoundAfterPromote" else "secondUpdateConfirms"}));
    try f.deinit();
    active = false;
}
pub fn clean() !void {
    var count: usize = 0;
    const dir = c.opendir("/tmp") orelse return error.OpenFailed;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (std.mem.startsWith(u8, name, "softwareupdate-")) count += 1;
    }
    const pools = try u.capture(a, &.{ "/sbin/zpool", "list", "-H", "-o", "name" });
    var lines = std.mem.tokenizeAny(u8, pools, "\r\n");
    while (lines.next()) |name| if (std.mem.startsWith(u8, name, "op242_")) {
        count += 1;
    };
    try u.write(1, try fmt("op242_leftovers={d}\n", .{count}));
    try expect(count == 0);
}
test "secondUpdateConfirms" {
    try run(false);
}
test "sealFoundAfterPromote" {
    try run(true);
}
