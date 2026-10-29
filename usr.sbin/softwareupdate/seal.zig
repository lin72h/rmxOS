const std = @import("std");
const u = @import("update.zig");
const e = u.engine;
const c = u.c;
const A = std.mem.Allocator;
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn fmt(a: A, comptime format: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, format, args, 0);
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
pub fn dataset(s: u.Snapshot) ![]const u8 {
    const ds = s.dataset orelse return error.NotBootEnvironment;
    var parts = std.mem.splitScalar(u8, ds, '/');
    const pool = parts.next() orelse return error.NotBootEnvironment;
    const parent = parts.next() orelse return error.NotBootEnvironment;
    const name = parts.next() orelse return error.NotBootEnvironment;
    if (pool.len == 0 or !eq(parent, "ROOT") or name.len == 0 or parts.next() != null) return error.NotBootEnvironment;
    for ([_][]const u8{ pool, name }) |part| {
        if (part[0] == '-' or eq(part, ".") or eq(part, "..")) return error.NotBootEnvironment;
        for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_.-", ch) == null) return error.NotBootEnvironment;
    }
    return ds;
}
pub fn create(a: A, backend: e.Backend, ds: []const u8) !void {
    var random: [16]u8 = undefined;
    c.arc4random_buf(&random, random.len);
    const temporary = try fmt(a, "{s}@seal-pending-{s}", .{ ds, std.fmt.bytesToHex(random, .lower) });
    _ = try backend.command(a, &.{ "/sbin/zfs", "snapshot", temporary });
    const id = try guid(a, backend, temporary);
    const name = try fmt(a, "{s}@sealed-{s}", .{ ds, id });
    _ = try backend.command(a, &.{ "/sbin/zfs", "hold", "softwareupdate", temporary });
    try remember(a, backend, ds, id);
    _ = try backend.command(a, &.{ "/sbin/zfs", "rename", temporary, name });
}
const property = "org.rmxos:seal-guid";
pub const Info = struct { name: [:0]const u8, created: []const u8, guid: []const u8 };
fn validGuid(id: []const u8) !void {
    if ((std.fmt.parseInt(u64, id, 10) catch return error.InvalidSealGUID) == 0) return error.InvalidSealGUID;
    for (id) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidSealGUID;
}
fn guid(a: A, backend: e.Backend, name: [:0]const u8) ![]const u8 {
    const id = trim(try backend.command(a, &.{ "/sbin/zfs", "get", "-H", "-p", "-o", "value", "guid", name }));
    try validGuid(id);
    return id;
}
fn remember(a: A, backend: e.Backend, ds: []const u8, id: []const u8) !void {
    _ = try backend.command(a, &.{ "/sbin/zfs", "set", try fmt(a, property ++ "={s}", .{id}), try a.dupeZ(u8, ds) });
}
fn legacy(a: A, backend: e.Backend, ds: []const u8) !?Info {
    const name = try fmt(a, "{s}@sealed", .{ds});
    const text = try backend.command(a, &.{ "/sbin/zfs", "list", "-H", "-p", "-t", "snapshot", "-o", "name,guid,creation", "-d", "1", try a.dupeZ(u8, ds) });
    return find(a, text, name, null);
}
fn find(a: A, text: []const u8, name: ?[]const u8, id: ?[]const u8) !?Info {
    var result: ?Info = null;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, '\t');
        const path = fields.next() orelse return error.InvalidSealListing;
        const identifier = fields.next() orelse return error.InvalidSealListing;
        const stamp = fields.next() orelse return error.InvalidSealListing;
        if (fields.next() != null) return error.InvalidSealListing;
        if ((name != null and eq(path, name.?)) or (id != null and eq(identifier, id.?))) {
            if (result != null) return error.DuplicateSealIdentity;
            try validGuid(identifier);
            _ = std.fmt.parseInt(u64, stamp, 10) catch return error.InvalidSealCreation;
            result = .{ .name = try a.dupeZ(u8, path), .created = stamp, .guid = identifier };
        }
    }
    return result;
}
pub fn info(a: A, backend: e.Backend, ds: []const u8) !?Info {
    const id = trim(try backend.command(a, &.{ "/sbin/zfs", "get", "-H", "-p", "-o", "value", "-s", "local", property, try a.dupeZ(u8, ds) }));
    if (id.len == 0 or eq(id, "-")) return legacy(a, backend, ds);
    try validGuid(id);
    const parent = std.fs.path.dirname(ds) orelse return error.NotBootEnvironment;
    const text = try backend.command(a, &.{ "/sbin/zfs", "list", "-H", "-p", "-t", "snapshot", "-o", "name,guid,creation", "-r", try a.dupeZ(u8, parent) });
    return find(a, text, null, id);
}
// Bind legacy seals before promotion can move them. This also handles an
// update staged by an older installer: its newly installed confirmer sees
// @sealed on both the pending environment and its confirmed predecessor.
pub fn migrate(a: A, backend: e.Backend, ds: []const u8) !void {
    const old = try legacy(a, backend, ds);
    const seal = old orelse (try info(a, backend, ds)) orelse return;
    if (old != null) {
        var ours = false;
        const held = try backend.command(a, &.{ "/sbin/zfs", "holds", "-H", seal.name });
        var lines = std.mem.tokenizeScalar(u8, held, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            if (eq(fields.next() orelse "", seal.name) and eq(fields.next() orelse "", "softwareupdate")) ours = true;
        }
        if (!ours) return;
    }
    const at = std.mem.indexOfScalar(u8, seal.name, '@') orelse return error.InvalidSealListing;
    const name = try fmt(a, "{s}@sealed-{s}", .{ seal.name[0..at], seal.guid });
    try remember(a, backend, ds, seal.guid);
    if (!eq(name, seal.name)) _ = try backend.command(a, &.{ "/sbin/zfs", "rename", seal.name, name });
}
pub fn release(a: A, backend: e.Backend, ds: []const u8) !void {
    if (try info(a, backend, ds)) |seal| {
        // Only release our tag. Other holds still prevent destruction.
        const held = try backend.command(a, &.{ "/sbin/zfs", "holds", "-H", seal.name });
        var lines = std.mem.tokenizeScalar(u8, held, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            if (eq(fields.next() orelse "", seal.name) and eq(fields.next() orelse "", "softwareupdate")) {
                _ = try backend.command(a, &.{ "/sbin/zfs", "release", "softwareupdate", seal.name });
                break;
            }
        }
        // Promotion can leave this environment's snapshot in another BE.
        // Destroy that snapshot explicitly, without affecting its dataset.
        _ = try backend.command(a, &.{ "/sbin/zfs", "destroy", seal.name });
    }
}
pub fn status(ctx: u.Context, s: u.Snapshot, backend: e.Backend) !void {
    const ds = dataset(s) catch {
        try ctx.print(ctx.out, "seal=none\n", .{});
        return;
    };
    if (try info(ctx.allocator, backend, ds)) |seal| {
        try ctx.print(ctx.out, "seal={s}\nseal_taken_unix={s}\n", .{ seal.name, seal.created });
    } else try ctx.print(ctx.out, "seal=none\n", .{});
}
fn stat(root: e.Root, path: []const u8) !?c.struct_stat {
    if (eq(path, "/")) {
        var st: c.struct_stat = undefined;
        if (c.fstat(root.fd, &st) != 0) return error.StatFailed;
        return st;
    }
    const parent = (try root.parent(path, false)) orelse return null;
    defer _ = c.close(parent);
    var st: c.struct_stat = undefined;
    const rc = c.fstatat(parent, try root.a.dupeZ(u8, std.fs.path.basename(path)), &st, c.AT_SYMLINK_NOFOLLOW);
    if (rc != 0) {
        if (std.c.errno(rc) == .NOENT) return null;
        return error.StatFailed;
    }
    if (@as(u64, @intCast(st.st_dev)) != root.device) return error.OtherDataset;
    return st;
}
fn digest(root: e.Root, path: []const u8) ![]const u8 {
    const parent = (try root.parent(path, false)) orelse return error.FileNotFound;
    defer _ = c.close(parent);
    const fd = c.openat(parent, try root.a.dupeZ(u8, std.fs.path.basename(path)), c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        sha.update(buffer[0..@intCast(n)]);
    }
    var bytes: [32]u8 = undefined;
    sha.final(&bytes);
    return root.a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}
fn ownerChange(conflicts: []const u8, path: []const u8) bool {
    if (!e.ownerConfiguration(path)) return false;
    var lines = std.mem.tokenizeScalar(u8, conflicts, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const original = fields.next() orelse continue;
        const side = fields.next() orelse continue;
        if (eq(original, path) and std.mem.startsWith(u8, side, path) and eq(side[path.len..], ".rmxos-new") and fields.next() == null) return true;
    }
    return false;
}
fn difference(live: e.Root, sealed: e.Root, path: []const u8) !?[]const u8 {
    const old = (try stat(sealed, path)) orelse return error.SealedBasePathMissing;
    const now = (stat(live, path) catch |err| {
        if (err == error.UnsafeParent or err == error.OtherDataset) return "type-changed";
        return err;
    }) orelse return "missing";
    if (old.st_mode & c.S_IFMT != now.st_mode & c.S_IFMT) return "type-changed";
    if (old.st_mode & 0o7777 != now.st_mode & 0o7777 or old.st_uid != now.st_uid or old.st_gid != now.st_gid) return "modified";
    if (old.st_mode & c.S_IFMT == c.S_IFREG and !eq(try digest(live, path), try digest(sealed, path))) return "modified";
    return null;
}
pub fn compare(ctx: u.Context, live: e.Root, sealed: e.Root, quiet: bool) !u8 {
    return comparePaths(ctx, live, sealed, quiet, null);
}
fn comparePaths(ctx: u.Context, live: e.Root, sealed: e.Root, quiet: bool, directory_changes: ?std.StringHashMap(bool)) !u8 {
    // The sealed manifest defines the complete base path set. No timestamp or
    // diff search budget can hide content changes, including restored mtimes.
    const manifest = try e.manifest(ctx.allocator, (try sealed.read("/var/db/rmxos/manifest.tsv")) orelse return error.MissingManifest, false);
    const conflicts = (try sealed.read("/var/db/rmxos/conflicts.tsv")) orelse "";
    var drift: usize = 0;
    var owner: usize = 0;
    for (manifest.rows) |row| if (!row.deleted) {
        const change = try difference(live, sealed, row.path);
        // An owner file can already differ from stock at sealing, and may be
        // edited again later. Only conflicts recorded in the seal qualify.
        if (ownerChange(conflicts, row.path) and (change == null or eq(change.?, "modified"))) {
            owner += 1;
            if (!quiet) try ctx.print(ctx.out, "expected-owner-change {s}\n", .{row.path});
        } else if (change) |kind| {
            drift += 1;
            if (!quiet) try ctx.print(ctx.out, "{s} {s}\n", .{ kind, row.path });
        }
    };
    if (try sealed.read("/var/db/rmxos/directories.tsv")) |bytes| {
        for (try e.directories(ctx.allocator, bytes)) |dir| {
            if (directory_changes) |changes| {
                var found = changes.contains(dir.path);
                var ancestors = std.fs.path.dirname(dir.path);
                while (!found and ancestors != null) {
                    found = changes.get(ancestors.?) orelse false;
                    if (eq(ancestors.?, "/")) break;
                    ancestors = std.fs.path.dirname(ancestors.?);
                }
                if (!found) continue;
            }
            // A directory at or below another filesystem's mount point is
            // outside the sealed boot environment and is not drift.
            if (try live.outside(dir.path)) continue;
            if (try difference(live, sealed, dir.path)) |kind| {
                drift += 1;
                if (!quiet) try ctx.print(ctx.out, "{s} {s}\n", .{ kind, dir.path });
            }
        }
    }
    if (quiet) try ctx.print(ctx.out, "{d}\n", .{drift}) else try ctx.print(ctx.out, "drift={d} expected_owner_changes={d}\n", .{ drift, owner });
    return if (drift == 0) 0 else 1;
}
pub fn verify(ctx: u.Context, s: u.Snapshot, backend: e.Backend, quiet: bool) !u8 {
    if (s.uid != 0) {
        _ = try ctx.diagnostic("root required");
        return 2;
    }
    const ds = try dataset(s);
    const seal = (try info(ctx.allocator, backend, ds)) orelse {
        if (!quiet) try ctx.print(ctx.out, "softwareupdate: no seal for {s}\n", .{ds});
        return 3;
    };
    const live = try e.inspectRunning(ctx.allocator, ctx.root);
    defer live.close();
    const at = std.mem.indexOfScalar(u8, seal.name, '@') orelse return error.InvalidSealListing;
    const owner = seal.name[0..at];
    const owner_name = try ctx.allocator.dupeZ(u8, std.fs.path.basename(owner));
    var mounted: ?[:0]const u8 = null;
    var base = ctx.root;
    defer if (mounted) |path| {
        _ = backend.command(ctx.allocator, &.{ "/sbin/bectl", "unmount", owner_name }) catch {};
        _ = c.rmdir(path);
    };
    if (!eq(owner, ds)) {
        const mounts = try backend.command(ctx.allocator, &.{ "/sbin/mount", "-p" });
        var lines = std.mem.tokenizeScalar(u8, mounts, '\n');
        var found = false;
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            if (!eq(fields.next() orelse "", owner)) continue;
            base = fields.next() orelse return error.InvalidMountListing;
            if (!eq(fields.next() orelse "", "zfs")) return error.InvalidMountListing;
            found = true;
            break;
        }
        if (!found) {
            const path = try ctx.allocator.dupeZ(u8, "/tmp/softwareupdate-seal-XXXXXX");
            if (c.mkdtemp(path) == null) return error.TemporaryDirectory;
            errdefer _ = c.rmdir(path);
            _ = try backend.command(ctx.allocator, &.{ "/sbin/bectl", "mount", owner_name, path });
            mounted = path;
            base = path;
        }
    }
    const path = try fmt(ctx.allocator, "{s}/.zfs/snapshot/{s}", .{ std.mem.trimEnd(u8, base, "/"), seal.name[at + 1 ..] });
    const sealed = try e.Root.open(ctx.allocator, path, false);
    var opened = true;
    defer if (opened) sealed.close();
    // ZFS supplies underlying-dataset directory candidates, avoiding false
    // drift from devfs/tmpfs mounted over unchanged base directories. Regular
    // files are always hashed, independent of diff timestamps or candidates.
    // A moved seal's owner is not the live environment being verified. Its
    // default zfs diff would therefore compare the wrong live dataset.
    const result = if (!eq(owner, ds)) try comparePaths(ctx, live, sealed, quiet, null) else blk: {
        const diff = try backend.command(ctx.allocator, &.{ "/sbin/zfs", "diff", "-FH", seal.name });
        var changed = try directoryCandidates(ctx.allocator, diff, ctx.root);
        defer changed.deinit();
        break :blk try comparePaths(ctx, live, sealed, quiet, changed);
    };
    sealed.close();
    opened = false;
    if (mounted) |mount| {
        _ = try backend.command(ctx.allocator, &.{ "/sbin/bectl", "unmount", owner_name });
        mounted = null;
        if (c.rmdir(mount) != 0) return error.TemporaryDirectoryCleanup;
    }
    return result;
}
pub fn directoryCandidates(a: A, diff: []const u8, prefix: []const u8) !std.StringHashMap(bool) {
    var changed = std.StringHashMap(bool).init(a);
    errdefer changed.deinit();
    var lines = std.mem.tokenizeScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const operation = fields.next() orelse return error.InvalidZFSDiff;
        if (operation.len != 1 or std.mem.indexOfScalar(u8, "+-MR", operation[0]) == null) return error.InvalidZFSDiff;
        _ = fields.next() orelse return error.InvalidZFSDiff;
        var paths: usize = 0;
        while (fields.next()) |raw| {
            // OpenZFS appends a signed link-count delta to an M record.
            if (eq(operation, "M") and paths == 1 and raw.len >= 4 and raw[0] == '(' and raw[raw.len - 1] == ')') {
                _ = std.fmt.parseInt(i64, raw[1 .. raw.len - 1], 10) catch return error.InvalidZFSDiff;
                if (fields.next() != null) return error.InvalidZFSDiff;
                break;
            }
            var relative = raw;
            if (prefix.len != 0) {
                if (!std.mem.startsWith(u8, raw, prefix) or raw.len <= prefix.len or raw[prefix.len] != '/') return error.InvalidZFSDiff;
                relative = raw[prefix.len..];
            }
            if (relative.len == 0 or relative[0] != '/') return error.InvalidZFSDiff;
            try changed.put(relative, eq(operation, "R") or eq(operation, "-"));
            paths += 1;
        }
        if (paths != (if (eq(operation, "R")) @as(usize, 2) else 1)) return error.InvalidZFSDiff;
    }
    return changed;
}
