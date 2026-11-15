// The ESP, for both tools: one table of loader paths and loader.env's place.
// rmxos-install populates a fresh ESP; softwareupdate's confirm locates the
// efi partition on the disk that holds the pool (used where it is mounted,
// else mounted at a temporary directory) and refreshes every loader path on
// it. A FAT file system from any other disk is left alone. An update writes
// only the loaders and their .prev, never loader.env (an owner's file).
const std = @import("std");
const sys = @import("sys.zig");
const Ctx = sys.Ctx;

// The path the firmware starts when it has no boot entry (neither tool makes
// one), then FreeBSD's own.
pub const loaders = [_][]const u8{ "EFI/BOOT/BOOTX64.EFI", "efi/freebsd/loader.efi" };
pub const loader_env = "efi/freebsd/loader.env";

// rmxos-install: every loader path and loader.env on the fresh ESP at `dir`,
// each written as a refresh writes a loader.
pub fn populate(ctx: Ctx, dir: []const u8, loader: []const u8, env: []const u8) !void {
    const files = loaders ++ [_][]const u8{loader_env};
    for (files, 0..) |rel, i| {
        const p = try ctx.a.dupeZ(u8, try ctx.fmt("{s}/{s}", .{ dir, rel }));
        sys.mkdirs(ctx.a, std.fs.path.dirname(p).?) catch {
            sys.failure = try ctx.fmt("{s}: mkdir: {s}", .{ rel, sys.lastError(ctx.a) });
            return error.EspFiles;
        };
        replaceChecked(ctx, p, if (i < loaders.len) loader else env) catch {
            sys.failure = try ctx.fmt("{s}: {s}", .{ rel, sys.failure });
            return error.EspFiles;
        };
    }
}

// One loader the refresh wrote: what it replaced, to put back.
pub const Written = struct {
    rel: []const u8,
    dest: [:0]const u8,
    old: []const u8,
    old_prev: ?[]const u8,
};

pub const Esp = struct {
    // The ESP's mount point; null when there is none to refresh.
    dir: ?[]const u8 = null,
    temporary: ?[:0]const u8 = null,
    // Why there is none.
    skip: []const u8 = "none found",
    // After a refresh: each loader written, in table order.
    written: []const Written = &.{},
    detail: []const u8 = "",

    // The efi partition on the disk that holds `pool`.
    pub fn open(ctx: Ctx, pool: []const u8) !Esp {
        const status = sys.capture(ctx, &.{ "/sbin/zpool", "status", "-P", pool }) catch return fail(ctx, "zpool status {s}: {s}", .{ pool, sys.failure });
        const tree = sys.capture(ctx, &.{ "/sbin/sysctl", "-n", "kern.geom.conftxt" }) catch return fail(ctx, "GEOM tree: {s}", .{sys.failure});
        const parts = sys.capture(ctx, &.{ "/sbin/gpart", "show", "-p" }) catch return fail(ctx, "gpart show: {s}", .{sys.failure});
        const disks = Disks.parse(ctx.a, parts, tree) catch return fail(ctx, "unreadable gpart show or GEOM tree", .{});
        const devices = try poolDevices(ctx.a, status);
        const found = disks.locate(ctx.a, devices) catch |err| return fail(ctx, "{s}", .{switch (err) {
            error.NoPoolDevice => try ctx.fmt("no device of pool {s} in zpool status", .{pool}),
            error.InvalidDevice => "efi partition with an unsafe name",
            else => return err,
        }});
        const device = switch (found) {
            .none => return .{},
            .disks => |list| return .{ .skip = try ctx.fmt("pool {s} is on {d} disks ({s})", .{ pool, list.len, try std.mem.join(ctx.a, ", ", list) }) },
            .several => |disk| return fail(ctx, "more than one efi partition on {s}", .{disk}),
            .partition => |p| p,
        };
        const mounts = sys.msdosfsMounts(ctx) catch return fail(ctx, "mount list unavailable", .{});
        if (disks.mountOf(mounts, device)) |on| return .{ .dir = on };
        const tmp = try ctx.a.dupeZ(u8, try ctx.path("/tmp/softwareupdate-esp-XXXXXX"));
        if (sys.c.mkdtemp(tmp.ptr) == null) return fail(ctx, "temporary ESP mount point: {s}", .{sys.lastError(ctx.a)});
        _ = sys.capture(ctx, &.{ "/sbin/mount_msdosfs", try ctx.fmt("/dev/{s}", .{device}), tmp }) catch {
            const why = sys.failure;
            _ = sys.c.rmdir(tmp);
            return fail(ctx, "mount /dev/{s}: {s}", .{ device, why });
        };
        return .{ .dir = tmp, .temporary = tmp };
    }

    pub fn close(self: Esp, ctx: Ctx) void {
        const t = self.temporary orelse return;
        const r = sys.run(ctx.a, &.{ "/sbin/umount", t }, null) catch return;
        if (r.status == 0) {
            _ = sys.c.rmdir(t);
        } else ctx.out("ESP: umount {s}: {s}\n", .{ t, sys.firstLine(r.stderr) });
    }

    // Every loader path on the ESP (at least one must be there) that differs
    // from the root's: a temporary file beside it, fsync'd and checked against
    // the root's sha256, the old loader kept as <loader>.prev, then the rename
    // over it. A failure puts back what this refresh wrote. False when
    // nothing changed.
    pub fn refresh(self: *Esp, ctx: Ctx) !bool {
        const dir = self.dir orelse {
            ctx.out("ESP: {s}; loader not refreshed\n", .{self.skip});
            return false;
        };
        const new = sys.read(ctx.a, try ctx.path("/boot/loader.efi")) catch return fail(ctx, "/boot/loader.efi unreadable", .{});
        const want = digest(new);
        var done: std.ArrayList(Written) = .empty;
        try done.ensureTotalCapacity(ctx.a, loaders.len);
        var lines: std.ArrayList([]const u8) = .empty;
        var present: usize = 0;
        for (loaders) |rel| {
            const dest = try ctx.a.dupeZ(u8, try ctx.fmt("{s}/{s}", .{ dir, rel }));
            if (!sys.exists(dest)) continue;
            present += 1;
            const changed = refreshOne(ctx, rel, dest, new, want) catch |err| {
                self.written = done.items;
                self.restore(ctx);
                self.written = &.{};
                return err;
            };
            const w = changed orelse {
                try lines.append(ctx.a, try ctx.fmt("ESP: {s} is current (sha256 {s})\n", .{ rel, want }));
                continue;
            };
            done.appendAssumeCapacity(w);
        }
        if (present == 0) return fail(ctx, "{s} has no {s} or {s}", .{ dir, loaders[0], loaders[1] });
        self.written = done.items;
        var details: std.ArrayList([]const u8) = .empty;
        for (done.items) |w| {
            const d = try ctx.fmt("{s} sha256 {s}, previous {s} kept as {s}.prev", .{ w.rel, want, digest(w.old), std.fs.path.basename(w.rel) });
            try details.append(ctx.a, d);
            try lines.append(ctx.a, try ctx.fmt("ESP: refreshed {s}\n", .{d}));
        }
        for (lines.items) |l| ctx.out("{s}", .{l});
        self.detail = try std.mem.join(ctx.a, "; ", details.items);
        return done.items.len > 0;
    }

    // Undo a refresh when the confirm fails after it: every loader it wrote,
    // and each one's .prev, as they were.
    pub fn restore(self: Esp, ctx: Ctx) void {
        var i = self.written.len;
        while (i > 0) {
            i -= 1;
            restoreOne(ctx, self.written[i]);
        }
    }
};

// Null when the loader at `dest` is the root's already.
fn refreshOne(ctx: Ctx, rel: []const u8, dest: [:0]const u8, new: []const u8, want: [64]u8) !?Written {
    const old = sys.read(ctx.a, dest) catch return fail(ctx, "{s} unreadable", .{rel});
    const had = digest(old);
    if (std.mem.eql(u8, &want, &had)) return null;
    const tmp = try sibling(ctx, dest, ".new");
    const prev = try sibling(ctx, dest, ".prev");
    const prev_tmp = try sibling(ctx, dest, ".prev.new");
    const w = Written{
        .rel = rel,
        .dest = dest,
        .old = old,
        .old_prev = if (sys.exists(prev)) sys.read(ctx.a, prev) catch return fail(ctx, "{s}.prev unreadable", .{rel}) else null,
    };
    writeChecked(ctx, tmp, new, want) catch return fail(ctx, "{s}.new: {s}", .{ rel, sys.failure });
    errdefer _ = sys.c.unlink(tmp);
    writeChecked(ctx, prev_tmp, old, had) catch return fail(ctx, "{s}.prev: {s}", .{ rel, sys.failure });
    if (sys.c.rename(prev_tmp, prev) != 0) {
        const why = sys.lastError(ctx.a);
        _ = sys.c.unlink(prev_tmp);
        return fail(ctx, "rename {s}.prev: {s}", .{ rel, why });
    }
    if (sys.c.rename(tmp, dest) != 0) {
        const why = sys.lastError(ctx.a);
        putPrev(ctx, w);
        return fail(ctx, "rename {s}: {s}", .{ rel, why });
    }
    syncDir(dest);
    const got = sys.sha256File(dest) catch @as([64]u8, @splat('0'));
    if (!std.mem.eql(u8, &got, &want)) {
        restoreOne(ctx, w);
        return fail(ctx, "{s} sha256 {s} after the rename, not {s}", .{ rel, got, want });
    }
    return w;
}

fn restoreOne(ctx: Ctx, w: Written) void {
    replaceChecked(ctx, w.dest, w.old) catch {
        ctx.out("ESP: restoring {s} failed: {s}\n", .{ w.dest, sys.failure });
        return;
    };
    putPrev(ctx, w);
}

// <loader>.prev as it was before the refresh.
fn putPrev(ctx: Ctx, w: Written) void {
    const prev = sibling(ctx, w.dest, ".prev") catch return;
    if (w.old_prev) |bytes| {
        replaceChecked(ctx, prev, bytes) catch ctx.out("ESP: restoring {s} failed: {s}\n", .{ prev, sys.failure });
    } else _ = sys.c.unlink(prev);
}

fn sibling(ctx: Ctx, dest: []const u8, suffix: []const u8) ![:0]const u8 {
    return ctx.a.dupeZ(u8, try ctx.fmt("{s}{s}", .{ dest, suffix }));
}

// The pool's leaf devices in `zpool status -P` output, without /dev/.
pub fn poolDevices(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var config = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = f.next() orelse continue;
        if (std.mem.eql(u8, first, "config:")) {
            config = true;
        } else if (std.mem.eql(u8, first, "errors:")) {
            config = false;
        } else if (config and std.mem.startsWith(u8, first, "/dev/") and first.len > 5) {
            try list.append(a, first[5..]);
        }
    }
    return list.items;
}

pub const Located = union(enum) {
    // The efi partition on the pool's disk.
    partition: []const u8,
    // The pool's disk, which has no efi partition.
    none: []const u8,
    // The pool's disk, which has more than one.
    several: []const u8,
    // The pool is on more than one disk.
    disks: []const []const u8,
};

// `gpart show -p` (the partitions and their types) with the GEOM tree from
// kern.geom.conftxt, which places every provider on its disk: a label
// (gpt/efiboot0, diskid/DISK-...) or a layer such as .eli above a partition
// or disk names the same disk as its device name.
pub const Disks = struct {
    nodes: []const Node,
    rows: []const Row,

    const Node = struct { name: []const u8, parent: ?usize };
    const Row = struct { table: []const u8, provider: []const u8, kind: []const u8 };

    pub fn parse(a: std.mem.Allocator, gpart: []const u8, conftxt: []const u8) !Disks {
        var nodes: std.ArrayList(Node) = .empty;
        // The last node at each level: conftxt lists the tree depth first.
        var path: std.ArrayList(usize) = .empty;
        var lines = std.mem.tokenizeScalar(u8, conftxt, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeAny(u8, line, " \t\r");
            const level = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch return error.GeomOutput;
            _ = f.next() orelse return error.GeomOutput;
            const name = f.next() orelse return error.GeomOutput;
            if (level > path.items.len) return error.GeomOutput;
            path.shrinkRetainingCapacity(level);
            try nodes.append(a, .{ .name = name, .parent = if (level == 0) null else path.items[level - 1] });
            try path.append(a, nodes.items.len - 1);
        }
        var rows: std.ArrayList(Row) = .empty;
        var table: ?[]const u8 = null;
        var gl = std.mem.splitScalar(u8, gpart, '\n');
        while (gl.next()) |line| {
            var f = std.mem.tokenizeAny(u8, line, " \t\r");
            const first = f.next() orelse continue;
            if (std.mem.eql(u8, first, "=>")) {
                for (0..2) |_| _ = f.next() orelse return error.GpartOutput;
                table = f.next() orelse return error.GpartOutput;
                continue;
            }
            _ = f.next() orelse continue;
            const provider = f.next() orelse continue;
            const kind = f.next() orelse continue;
            if (std.mem.eql(u8, provider, "-")) continue;
            try rows.append(a, .{ .table = table orelse return error.GpartOutput, .provider = provider, .kind = kind });
        }
        return .{ .nodes = nodes.items, .rows = rows.items };
    }

    // The partition row a provider is, or lies above.
    fn partitionOf(self: Disks, name: []const u8) ?Row {
        for (self.rows) |r| if (std.mem.eql(u8, r.provider, name)) return r;
        var i = self.node(name) orelse return null;
        while (self.nodes[i].parent) |p| : (i = p) {
            for (self.rows) |r| if (std.mem.eql(u8, r.provider, self.nodes[p].name)) return r;
        }
        return null;
    }

    fn node(self: Disks, name: []const u8) ?usize {
        for (self.nodes, 0..) |n, i| if (std.mem.eql(u8, n.name, name)) return i;
        return null;
    }

    // The disk a provider is on (its top of the GEOM tree), or the provider
    // itself when the tree does not list it.
    fn diskOf(self: Disks, name: []const u8) []const u8 {
        const base = if (self.partitionOf(name)) |r| r.table else name;
        var i = self.node(base) orelse return base;
        while (self.nodes[i].parent) |p| i = p;
        return self.nodes[i].name;
    }

    // The efi partition on the one disk that holds every device. A partition
    // listed under a GEOM label (diskid/DISK-...) as well as under its device
    // name counts once: labels count only when no device name is listed.
    pub fn locate(self: Disks, a: std.mem.Allocator, devices: []const []const u8) !Located {
        if (devices.len == 0) return error.NoPoolDevice;
        var disks: std.ArrayList([]const u8) = .empty;
        for (devices) |d| {
            const disk = self.diskOf(d);
            for (disks.items) |x| {
                if (std.mem.eql(u8, x, disk)) break;
            } else try disks.append(a, disk);
        }
        if (disks.items.len > 1) return .{ .disks = disks.items };
        const disk = disks.items[0];
        var device: ?[]const u8 = null;
        var label: ?[]const u8 = null;
        var labels: usize = 0;
        for (self.rows) |r| {
            if (!std.mem.eql(u8, r.kind, "efi") or !std.mem.eql(u8, self.diskOf(r.table), disk)) continue;
            const p = r.provider;
            if (p[0] == '/' or std.mem.indexOf(u8, p, "..") != null) return error.InvalidDevice;
            for (p) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_.-/", ch) == null) return error.InvalidDevice;
            if (std.mem.indexOfScalar(u8, p, '/') != null) {
                labels += 1;
                label = p;
            } else {
                if (device != null) return .{ .several = disk };
                device = p;
            }
        }
        if (device == null and labels > 1) return .{ .several = disk };
        return if (device orelse label) |p| .{ .partition = p } else .{ .none = disk };
    }

    // Where `partition` is mounted, under its own name or a label above it
    // (FreeBSD mounts /boot/efi from /dev/gpt/efiboot0).
    pub fn mountOf(self: Disks, mounts: []const sys.Mount, partition: []const u8) ?[]const u8 {
        for (mounts) |m| {
            if (!std.mem.startsWith(u8, m.from, "/dev/")) continue;
            const r = self.partitionOf(m.from[5..]) orelse continue;
            if (std.mem.eql(u8, r.provider, partition)) return m.on;
        }
        return null;
    }
};

fn digest(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn fail(ctx: Ctx, comptime f: []const u8, args: anytype) error{EspRefresh} {
    sys.failure = ctx.fmt(f, args) catch "ESP refresh failed";
    return error.EspRefresh;
}

fn failed(ctx: Ctx, what: []const u8) error{EspRefresh} {
    return fail(ctx, "{s}: {s}", .{ what, sys.lastError(ctx.a) });
}

// Create p (O_EXCL), write, fsync and read it back against `want`.
fn writeChecked(ctx: Ctx, p: [:0]const u8, bytes: []const u8, want: [64]u8) !void {
    _ = sys.c.unlink(p);
    const fd = sys.c.open(p, sys.c.O_WRONLY | sys.c.O_CREAT | sys.c.O_EXCL | sys.c.O_NOFOLLOW | sys.c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return failed(ctx, "create");
    errdefer _ = sys.c.unlink(p);
    {
        defer _ = sys.c.close(fd);
        sys.writeAll(fd, bytes) catch return failed(ctx, "write");
        if (sys.c.fsync(fd) != 0) return failed(ctx, "fsync");
    }
    const got = sys.sha256File(p) catch return failed(ctx, "read back");
    if (!std.mem.eql(u8, &got, &want)) return fail(ctx, "sha256 {s}, not {s}", .{ got, want });
}

fn replaceChecked(ctx: Ctx, p: [:0]const u8, bytes: []const u8) !void {
    const tmp = try ctx.a.dupeZ(u8, try ctx.fmt("{s}.new", .{p}));
    try writeChecked(ctx, tmp, bytes, digest(bytes));
    if (sys.c.rename(tmp, p) != 0) {
        const why = sys.lastError(ctx.a);
        _ = sys.c.unlink(tmp);
        return fail(ctx, "rename {s}: {s}", .{ p, why });
    }
    syncDir(p);
}

fn syncDir(p: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&buf, "{s}", .{std.fs.path.dirname(p) orelse "/"}) catch return;
    const fd = sys.c.open(dir, sys.c.O_RDONLY | sys.c.O_DIRECTORY | sys.c.O_CLOEXEC);
    if (fd < 0) return;
    _ = sys.c.fsync(fd);
    _ = sys.c.close(fd);
}
