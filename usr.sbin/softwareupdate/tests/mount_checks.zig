//! Declared directories on a running root with real mounts. Each case mounts
//! tmpfs inside its own fixture and needs root, so it runs in a guest.
const std = @import("std");
const u = @import("update");
const f = @import("install_checks.zig");
const e = u.engine;
const c = u.c;
const a = std.heap.page_allocator;
const io = std.Io.Threaded.global_single_threaded.io();
const snap = u.Snapshot{ .uid = 0, .dataset = "zroot/ROOT/rmxos-aaaaaaaaaaaa", .listing = "rmxos-aaaaaaaaaaaa\tNR\t/\n" };
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn check(b: bool) !void {
    try std.testing.expect(b);
}
fn fmt(comptime format: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, format, args, 0);
}
const Mount = struct {
    path: [:0]const u8,
    fn init(path: [:0]const u8, files: []const []const u8) !Mount {
        try std.Io.Dir.cwd().createDirPath(io, path);
        _ = try u.capture(a, &.{ "/sbin/mount", "-t", "tmpfs", "tmpfs", path });
        errdefer _ = u.capture(a, &.{ "/sbin/umount", path }) catch "";
        for (files) |name| {
            const fd = c.open(try fmt("{s}/{s}", .{ path, name }), c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o644));
            if (fd < 0) return error.OpenFailed;
            defer _ = c.close(fd);
            try u.write(fd, name);
        }
        return .{ .path = path };
    }
    fn deinit(m: Mount) void {
        _ = u.capture(a, &.{ "/sbin/umount", m.path }) catch "";
    }
    /// Names, modes and sizes of everything on the mounted filesystem.
    fn listing(m: Mount) ![]const u8 {
        return u.capture(a, &.{ "/usr/bin/find", m.path, "-xdev", "-exec", "/usr/bin/stat", "-f", "%N %p %z", "{}", "+" });
    }
};
/// An existing directory keeps its mode; one the install creates gets the
/// declared mode.
fn declared(clone: []const u8, path: []const u8, mode: ?u32) !void {
    var st: c.struct_stat = undefined;
    try check(c.lstat(try fmt("{s}{s}", .{ clone, path }), &st) == 0);
    try check(st.st_mode & c.S_IFMT == c.S_IFDIR);
    if (mode) |m| try check(st.st_mode & 0o7777 == m);
}
/// Installs with the fake bectl and checks the running root's mounted
/// filesystem is unchanged while the clone gets every declared directory.
fn mountedInstall(mountpoint: []const u8, files: []const []const u8, dirs: []const e.Directory) !void {
    const fixture = try f.Fixture.init(false);
    defer fixture.deinit();
    const m = try Mount.init(try fmt("{s}{s}", .{ fixture.root, mountpoint }), files);
    defer m.deinit();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "rmx-directories-v1\n");
    for (dirs) |dir| try text.appendSlice(a, try fmt("0{o}\t0\t0\t{s}\n", .{ dir.mode, dir.path }));
    try f.packDirectories(fixture.archive, &f.old_files, &f.new_files, false, text.items);
    const before = try m.listing();
    var fake = f.Fake{ .f = fixture };
    const ctx = try fixture.output();
    defer _ = c.close(ctx.out);
    try check(try e.install(ctx, .{ .action = .install, .operand = fixture.archive }, snap, .{ .data = &fake, .execute = f.Fake.command }) == 0);
    try check(fake.activated);
    try check(eq(try m.listing(), before));
    for (dirs) |dir| try declared(fake.clone.?, dir.path, if (eq(dir.path, mountpoint)) null else dir.mode);
}
fn part(name: []const u8, result: anyerror!void) !void {
    result catch |err| {
        u.write(2, try fmt("mount_checks part={s} error={s}\n", .{ name, @errorName(err) })) catch {};
        return err;
    };
}
/// FreeBSD's layout: zroot/var has canmount=off and zroot/var/tmp is mounted
/// at /var/tmp, below which the build declares vi.recover.
pub fn freebsdLayout() !void {
    try part("var-tmp", mountedInstall("/var/tmp", &.{"owner-temporary"}, &.{
        .{ .path = "/var/tmp", .mode = 0o1777, .uid = 0, .gid = 0 },
        .{ .path = "/var/tmp/vi.recover", .mode = 0o1777, .uid = 0, .gid = 0 },
    }));
}
/// A filesystem with files mounted on a declared directory: a carrier on
/// /mnt, and zroot/var/audit on /var/audit with its declared children.
pub fn mountOnDeclared() !void {
    try part("mnt", mountedInstall("/mnt", &.{ "carrier-catalog.json", "carrier-update.tar" }, &.{
        .{ .path = "/mnt", .mode = 0o755, .uid = 0, .gid = 0 },
    }));
    try part("var-audit", mountedInstall("/var/audit", &.{"current"}, &.{
        .{ .path = "/var/audit", .mode = 0o750, .uid = 0, .gid = 0 },
        .{ .path = "/var/audit/dist", .mode = 0o770, .uid = 0, .gid = 0 },
        .{ .path = "/var/audit/remote", .mode = 0o700, .uid = 0, .gid = 0 },
    }));
}
const Seal = struct {
    root: []const u8,
    fn command(data: ?*anyopaque, alloc: std.mem.Allocator, argv: []const [:0]const u8) anyerror![]const u8 {
        const self: *Seal = @ptrCast(@alignCast(data.?));
        try check(eq(argv[0], "/sbin/zfs"));
        if (eq(argv[1], "list")) {
            for (argv) |arg| if (eq(arg, "name,guid,creation")) return "zroot/ROOT/rmxos-aaaaaaaaaaaa@sealed\t1793000000\t1793000000\n";
            return "zroot/ROOT/rmxos-aaaaaaaaaaaa@sealed\n";
        }
        if (eq(argv[1], "get")) return if (eq(argv[argv.len - 2], "org.rmxos:seal-guid")) "-\n" else "1793000000\n";
        // zfs diff names each mount point directory and the hidden child, as
        // it does when they changed on the underlying dataset after sealing.
        if (eq(argv[1], "diff")) return std.fmt.allocPrint(alloc, "M\t/\t{0s}/mnt\nM\t/\t{0s}/var/tmp\nM\t/\t{0s}/var/tmp/vi.recover\n-\t/\t{0s}/usr/lib/op231-control\n", .{self.root});
        return error.UnexpectedCommand;
    }
};
fn verifyOnce(fixture: f.Fixture, fake: *Seal, name: []const u8) !struct { rc: u8, text: []const u8 } {
    var ctx = try fixture.output();
    _ = c.close(ctx.out);
    const path = try fmt("{s}/{s}", .{ fixture.path, name });
    ctx.out = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (ctx.out < 0) return error.OpenFailed;
    defer _ = c.close(ctx.out);
    const rc = try u.seals.verify(ctx, snap, .{ .data = fake, .execute = Seal.command }, false);
    return .{ .rc = rc, .text = try u.readPath(a, path) };
}
pub fn acrossMount() !void {
    const fixture = try f.Fixture.init(false);
    defer fixture.deinit();
    const root = try e.Root.open(a, fixture.root, false);
    defer root.close();
    const dirs = [_]e.Directory{
        .{ .path = "/mnt", .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "/usr/lib/op231-control", .mode = 0o755, .uid = 0, .gid = 0 },
        .{ .path = "/var/tmp", .mode = 0o1777, .uid = 0, .gid = 0 },
        .{ .path = "/var/tmp/vi.recover", .mode = 0o1777, .uid = 0, .gid = 0 },
    };
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "rmx-directories-v1\n");
    for (dirs) |dir| {
        try root.createDirectory(dir);
        try text.appendSlice(a, try fmt("0{o}\t0\t0\t{s}\n", .{ dir.mode, dir.path }));
    }
    try root.write("/var/db/rmxos/directories.tsv", text.items, 0o444);
    const copy = try fmt("{s}/sealed", .{fixture.path});
    _ = try u.capture(a, &.{ "/bin/cp", "-a", fixture.root, copy });
    try std.Io.Dir.cwd().createDirPath(io, try fmt("{s}/.zfs/snapshot", .{fixture.root}));
    try check(c.rename(copy, try fmt("{s}/.zfs/snapshot/sealed", .{fixture.root})) == 0);
    const carrier = try Mount.init(try fmt("{s}/mnt", .{fixture.root}), &.{"carrier-update.tar"});
    defer carrier.deinit();
    const temporary = try Mount.init(try fmt("{s}/var/tmp", .{fixture.root}), &.{"owner-temporary"});
    defer temporary.deinit();
    var fake = Seal{ .root = fixture.root };
    const clean = try verifyOnce(fixture, &fake, "verify-clean");
    if (clean.rc != 0 or !eq(clean.text, "drift=0 expected_owner_changes=0\n")) {
        u.write(2, clean.text) catch {};
        return error.MountReportedAsDrift;
    }
    // A declared directory outside any mount is still compared.
    try check(c.rmdir(try fmt("{s}/usr/lib/op231-control", .{fixture.root})) == 0);
    const drift = try verifyOnce(fixture, &fake, "verify-control");
    if (drift.rc != 1 or !eq(drift.text, "missing /usr/lib/op231-control\ndrift=1 expected_owner_changes=0\n")) {
        u.write(2, drift.text) catch {};
        return error.ControlDriftMismatch;
    }
}
test "FreeBSD dataset layout below a declared directory" {
    if (c.geteuid() != 0) return error.SkipZigTest;
    try freebsdLayout();
}
test "filesystem mounted on a declared directory" {
    if (c.geteuid() != 0) return error.SkipZigTest;
    try mountOnDeclared();
}
test "verify across a mount" {
    if (c.geteuid() != 0) return error.SkipZigTest;
    try acrossMount();
}
