// The ESP's loader follows the confirmed root's /boot/loader.efi. The ESP is
// the one msdosfs mount, or else the one efi partition, mounted at a temporary
// directory for the confirm. Only the loader and its .prev are written, never
// the ESP's other files (an owner's loader.env).
const std = @import("std");
const sys = @import("sys.zig");
const Ctx = sys.Ctx;

const loaders = [_][]const u8{ "efi/freebsd/loader.efi", "efi/boot/bootx64.efi" };

pub const Esp = struct {
    // The ESP's mount point; null when the machine has none.
    dir: ?[]const u8 = null,
    temporary: ?[:0]const u8 = null,
    // After a refresh: the loader written and what it replaced.
    dest: [:0]const u8 = "",
    old: []const u8 = "",
    old_prev: ?[]const u8 = null,
    detail: []const u8 = "",

    pub fn open(ctx: Ctx) !Esp {
        const mounts = sys.msdosfsMounts(ctx) catch return fail(ctx, "mount list unavailable", .{});
        if (mounts.len > 1) return fail(ctx, "{d} ESPs mounted ({s}, {s})", .{ mounts.len, mounts[0], mounts[1] });
        if (mounts.len == 1) return .{ .dir = mounts[0] };
        const parts = sys.capture(ctx, &.{ "/sbin/gpart", "show", "-p" }) catch return fail(ctx, "gpart show: {s}", .{sys.failure});
        const found = efiPartition(parts) catch |err|
            return fail(ctx, "{s}", .{if (err == error.MultipleEsps) "more than one efi partition" else "efi partition with an unsafe name"});
        const device = found orelse return .{};
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

    // When the root's loader differs from the ESP's: a temporary file beside
    // it, fsync'd and checked against the root's sha256, the old loader kept
    // as <loader>.prev, then the rename over it. False when nothing changed.
    pub fn refresh(self: *Esp, ctx: Ctx) !bool {
        const dir = self.dir orelse {
            ctx.out("ESP: none found; loader not refreshed\n", .{});
            return false;
        };
        const rel = for (loaders) |l| {
            if (sys.exists(try ctx.a.dupeZ(u8, try ctx.fmt("{s}/{s}", .{ dir, l })))) break l;
        } else return fail(ctx, "{s} has no {s} or {s}", .{ dir, loaders[0], loaders[1] });
        self.dest = try ctx.a.dupeZ(u8, try ctx.fmt("{s}/{s}", .{ dir, rel }));
        const new = sys.read(ctx.a, try ctx.path("/boot/loader.efi")) catch return fail(ctx, "/boot/loader.efi unreadable", .{});
        self.old = sys.read(ctx.a, self.dest) catch return fail(ctx, "{s} unreadable", .{rel});
        const want = digest(new);
        const had = digest(self.old);
        if (std.mem.eql(u8, &want, &had)) {
            ctx.out("ESP: {s} is current (sha256 {s})\n", .{ rel, want });
            return false;
        }
        const tmp = try self.sibling(ctx, ".new");
        const prev = try self.sibling(ctx, ".prev");
        const prev_tmp = try self.sibling(ctx, ".prev.new");
        self.old_prev = if (sys.exists(prev)) sys.read(ctx.a, prev) catch return fail(ctx, "{s}.prev unreadable", .{rel}) else null;
        writeChecked(ctx, tmp, new, want) catch return fail(ctx, "{s}.new: {s}", .{ rel, sys.failure });
        errdefer _ = sys.c.unlink(tmp);
        writeChecked(ctx, prev_tmp, self.old, had) catch return fail(ctx, "{s}.prev: {s}", .{ rel, sys.failure });
        if (sys.c.rename(prev_tmp, prev) != 0) {
            const why = sys.lastError(ctx.a);
            _ = sys.c.unlink(prev_tmp);
            return fail(ctx, "rename {s}.prev: {s}", .{ rel, why });
        }
        if (sys.c.rename(tmp, self.dest) != 0) {
            const why = sys.lastError(ctx.a);
            self.putPrev(ctx);
            return fail(ctx, "rename {s}: {s}", .{ rel, why });
        }
        syncDir(self.dest);
        const got = sys.sha256File(self.dest) catch @as([64]u8, @splat('0'));
        if (!std.mem.eql(u8, &got, &want)) {
            self.restore(ctx);
            return fail(ctx, "{s} sha256 {s} after the rename, not {s}", .{ rel, got, want });
        }
        self.detail = try ctx.fmt("{s} sha256 {s}; previous {s} kept as {s}.prev", .{ rel, want, had, std.fs.path.basename(rel) });
        ctx.out("ESP: refreshed {s}\n", .{self.detail});
        return true;
    }

    // Undo a refresh when the confirm fails after it.
    pub fn restore(self: Esp, ctx: Ctx) void {
        replaceChecked(ctx, self.dest, self.old) catch {
            ctx.out("ESP: restoring {s} failed: {s}\n", .{ self.dest, sys.failure });
            return;
        };
        self.putPrev(ctx);
    }

    // <loader>.prev as it was before the refresh.
    fn putPrev(self: Esp, ctx: Ctx) void {
        const prev = self.sibling(ctx, ".prev") catch return;
        if (self.old_prev) |bytes| {
            replaceChecked(ctx, prev, bytes) catch ctx.out("ESP: restoring {s} failed: {s}\n", .{ prev, sys.failure });
        } else _ = sys.c.unlink(prev);
    }

    fn sibling(self: Esp, ctx: Ctx, suffix: []const u8) ![:0]const u8 {
        return ctx.a.dupeZ(u8, try ctx.fmt("{s}{s}", .{ self.dest, suffix }));
    }
};

// The provider of the one efi partition in `gpart show -p` output, if any.
// A GEOM label provider (diskid/DISK-..., gpt/...) names a disk that is
// listed under its device name too, so label providers count only when no
// efi partition is listed under a device name.
pub fn efiPartition(text: []const u8) error{ MultipleEsps, InvalidDevice }!?[]const u8 {
    var device: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    var labels: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t\r");
        const start = f.next() orelse continue;
        if (std.mem.eql(u8, start, "=>")) continue;
        _ = f.next() orelse continue;
        const provider = f.next() orelse continue;
        if (!std.mem.eql(u8, f.next() orelse "", "efi")) continue;
        if (provider[0] == '/' or std.mem.indexOf(u8, provider, "..") != null) return error.InvalidDevice;
        for (provider) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_.-/", ch) == null) return error.InvalidDevice;
        if (std.mem.indexOfScalar(u8, provider, '/') != null) {
            labels += 1;
            label = provider;
        } else {
            if (device != null) return error.MultipleEsps;
            device = provider;
        }
    }
    if (device == null and labels > 1) return error.MultipleEsps;
    return device orelse label;
}

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
