//! Local-archive install. No candidate executable is ever run.
const std = @import("std");
const u = @import("update.zig");
const c = u.c;
pub const ar = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});
const A = std.mem.Allocator;
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn trim(x: []const u8) []const u8 {
    return std.mem.trim(u8, x, "\r\n \t");
}
fn z(a: A, x: []const u8) ![:0]const u8 {
    return a.dupeZ(u8, x);
}
fn fmt(a: A, comptime f: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, f, args, 0);
}
const io = std.Io.Threaded.global_single_threaded.io();
const metadata = [_][]const u8{ "manifest.tsv", "previous.tsv", "METALOG", "commit", "removals.json", "report.json", "baseline.tsv", "directories.tsv" };
pub const Directory = struct { path: []const u8, mode: u32, uid: u32, gid: u32 };
fn safeDirectory(path: []const u8) bool {
    if (eq(path, "/")) return true;
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/') return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or eq(part, ".") or eq(part, "..")) return false;
        for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_.+@-", ch) == null) return false;
    }
    return true;
}
pub fn directories(a: A, bytes: []const u8) ![]Directory {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.InvalidDirectories;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!eq(lines.next() orelse "", "rmx-directories-v1")) return error.InvalidDirectories;
    var rows: std.ArrayList(Directory) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.next() != null) return error.InvalidDirectories;
            break;
        }
        var f = std.mem.splitScalar(u8, line, '\t');
        const mode = f.next() orelse return error.InvalidDirectories;
        const uid = f.next() orelse return error.InvalidDirectories;
        const gid = f.next() orelse return error.InvalidDirectories;
        const path = f.next() orelse return error.InvalidDirectories;
        if (f.next() != null or !safeDirectory(path) or mode.len < 4 or mode.len > 5 or mode[0] != '0') return error.InvalidDirectories;
        for (mode) |ch| if (ch < '0' or ch > '7') return error.InvalidDirectories;
        for (uid) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidDirectories;
        for (gid) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidDirectories;
        const m = std.fmt.parseInt(u32, mode, 8) catch return error.InvalidDirectories;
        const user = std.fmt.parseInt(u32, uid, 10) catch return error.InvalidDirectories;
        const group = std.fmt.parseInt(u32, gid, 10) catch return error.InvalidDirectories;
        if (m > 0o7777 or user == std.math.maxInt(u32) or group == std.math.maxInt(u32)) return error.InvalidDirectories;
        for (rows.items) |old| if (eq(path, old.path)) return error.DuplicateDirectory;
        try rows.append(a, .{ .path = path, .mode = m, .uid = user, .gid = group });
    }
    std.mem.sort(Directory, rows.items, {}, struct {
        fn less(_: void, x: Directory, y: Directory) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    return rows.toOwnedSlice(a);
}
pub fn safePath(p: []const u8) bool {
    if (p.len == 0 or p[0] != '/' or p[p.len - 1] == '/') return false;
    var allowed = false;
    for ([_][]const u8{ "/etc/", "/boot/", "/bin/", "/sbin/", "/lib/", "/libexec/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/lib32/", "/usr/libexec/", "/usr/libdata/", "/usr/include/", "/usr/share/", "/usr/tests/" }) |prefix| if (std.mem.startsWith(u8, p, prefix)) {
        allowed = true;
    };
    if (!allowed) return false;
    for (p) |ch| if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_./+-", ch) != null)) return false;
    var parts = std.mem.splitScalar(u8, p[1..], '/');
    while (parts.next()) |part| if (part.len == 0 or eq(part, ".") or eq(part, "..")) return false;
    return true;
}
pub const Row = struct { hash: []const u8, mode: u32, path: []const u8, deleted: bool = false, link: ?[]const u8 = null, use: []const u8 = "" };
pub const Manifest = struct { bytes: []const u8, base: []const u8, rows: []Row };
pub fn manifest(a: A, bytes: []const u8, baseline: bool) !Manifest {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!eq(lines.next() orelse "", "rmx-overlay-v1")) return error.InvalidManifest;
    const base = lines.next() orelse return error.InvalidManifest;
    if (!std.mem.startsWith(u8, base, "base=") or !u.hex(base[5..], 64)) return error.InvalidManifest;
    var rows: std.ArrayList(Row) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.next() != null) return error.InvalidManifest;
            break;
        }
        var f = std.mem.splitScalar(u8, line, '\t');
        const hash = f.next() orelse return error.InvalidManifest;
        const mode = f.next() orelse return error.InvalidManifest;
        const path = f.next() orelse return error.InvalidManifest;
        if (f.next() != null or !u.hex(hash, 64) or !safePath(path)) return error.InvalidManifest;
        for (rows.items) |old| if (eq(path, old.path)) return error.DuplicatePath;
        if (baseline and !std.mem.startsWith(u8, path, "/etc/")) return error.InvalidBaseline;
        const deleted = eq(mode, "delete");
        var numeric: u32 = 0;
        if (!deleted) {
            if (mode.len != 4 or mode[0] != '0') return error.InvalidMode;
            numeric = std.fmt.parseInt(u32, mode, 8) catch return error.InvalidMode;
            if (numeric > 0o777 or (!baseline and numeric != 0o444 and numeric != 0o555 and numeric != 0o644 and numeric != 0o600)) return error.InvalidMode;
        } else if (baseline) return error.InvalidBaseline;
        try rows.append(a, .{ .hash = hash, .mode = numeric, .path = path, .deleted = deleted, .use = path });
    }
    if (rows.items.len == 0) return error.EmptyManifest;
    return .{ .bytes = bytes, .base = base, .rows = try rows.toOwnedSlice(a) };
}
fn find(rows: []Row, p: []const u8) ?*Row {
    for (rows) |*row| if (eq(row.path, p)) return row;
    return null;
}
const Member = struct { name: []const u8, link: ?[]const u8, mode: u32 };
pub const Bundle = struct {
    a: A,
    directory: [:0]const u8,
    new: Manifest,
    old: Manifest,
    baseline: ?Manifest,
    removals: []const []const u8,
    commit: []const u8,
    digest: []const u8,
    dirs: []Directory = &.{},
    directory_bytes: ?[]const u8 = null,
    pub fn deinit(self: Bundle) void {
        std.Io.Dir.cwd().deleteTree(io, self.directory) catch {};
    }
    fn read(self: Bundle, name: []const u8) ![]const u8 {
        return u.readPath(self.a, try fmt(self.a, "{s}/{s}", .{ self.directory, name }));
    }
    pub fn payload(self: Bundle, p: []const u8) ![:0]const u8 {
        return fmt(self.a, "{s}/files{s}", .{ self.directory, p });
    }
};
fn normalized(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "./")) name[2..] else name;
}
fn memberAllowed(name: []const u8) bool {
    for (metadata) |m| if (eq(name, m)) return true;
    return std.mem.startsWith(u8, name, "files/") and safePath(name[5..]);
}
fn fdHash(a: A, fd: c_int) ![]const u8 {
    if (c.lseek(fd, 0, c.SEEK_SET) != 0) return error.SeekFailed;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        hash.update(buf[0..@intCast(n)]);
    }
    return a.dupe(u8, &std.fmt.bytesToHex(hash.finalResult(), .lower));
}
pub fn load(a: A, archive: [:0]const u8) !Bundle {
    const fd = c.open(archive, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return error.ArchiveNotRegular;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) return error.ArchiveNotRegular;
    const side = c.open(try fmt(a, "{s}.sha256", .{archive}), c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (side < 0) return error.MissingChecksum;
    defer _ = c.close(side);
    if (c.fstat(side, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) return error.InvalidChecksum;
    const expected = trim(try u.readFd(a, side, 1024));
    const digest = try fdHash(a, fd);
    if (!u.hex(expected, 64) or !eq(expected, digest)) return error.ArchiveChecksumMismatch;
    if (c.lseek(fd, 0, c.SEEK_SET) != 0) return error.SeekFailed;
    const template = try z(a, "/tmp/softwareupdate-input-XXXXXX");
    if (c.mkdtemp(@constCast(template)) == null) return error.TemporaryDirectory;
    errdefer std.Io.Dir.cwd().deleteTree(io, template) catch {};
    var members: std.ArrayList(Member) = .empty;
    const reader = ar.archive_read_new() orelse return error.ArchiveOpen;
    defer _ = ar.archive_read_free(reader);
    _ = ar.archive_read_support_filter_all(reader);
    _ = ar.archive_read_support_format_tar(reader);
    if (ar.archive_read_open_fd(reader, fd, 65536) != ar.ARCHIVE_OK) return error.ArchiveOpen;
    var entry: ?*ar.struct_archive_entry = null;
    while (true) {
        const rc = ar.archive_read_next_header(reader, &entry);
        if (rc == ar.ARCHIVE_EOF) break;
        if (rc != ar.ARCHIVE_OK) return error.InvalidArchiveHeader;
        const e = entry orelse return error.InvalidArchiveHeader;
        const raw = ar.archive_entry_pathname(e);
        if (raw == null) return error.InvalidArchivePath;
        const name = normalized(std.mem.span(raw));
        if (!memberAllowed(name)) return error.InvalidArchivePath;
        for (members.items) |m| if (eq(m.name, name)) return error.DuplicateArchiveMember;
        const hard = ar.archive_entry_hardlink(e);
        const link = if (hard != null) normalized(std.mem.span(hard)) else null;
        if (ar.archive_entry_symlink(e) != null or (ar.archive_entry_filetype(e) != c.S_IFREG and link == null) or ar.archive_entry_uid(e) != 0 or ar.archive_entry_gid(e) != 0) return error.NonregularArchiveMember;
        const mode = ar.archive_entry_perm(e);
        if (mode & ~@as(u32, 0o777) != 0) return error.InvalidArchiveMode;
        if (link) |l| {
            if (!std.mem.startsWith(u8, name, "files/") or !std.mem.startsWith(u8, l, "files/") or !memberAllowed(l) or eq(l, name)) return error.InvalidArchiveHardlink;
        } else {
            const dest = try fmt(a, "{s}/{s}", .{ template, name });
            try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dest).?);
            const out = c.open(dest, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW, @as(c_uint, 0o600));
            if (out < 0) return error.ExtractFailed;
            defer _ = c.close(out);
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = ar.archive_read_data(reader, &buf, buf.len);
                if (n < 0) return error.ExtractFailed;
                if (n == 0) break;
                try u.write(out, buf[0..@intCast(n)]);
            }
            if (c.fchmod(out, @intCast(mode)) != 0) return error.ExtractFailed;
        }
        try members.append(a, .{ .name = try a.dupe(u8, name), .link = if (link) |v| try a.dupe(u8, v) else null, .mode = @intCast(mode) });
    }
    for (metadata[0..6]) |required| {
        var present = false;
        for (members.items) |m| {
            if (eq(m.name, required) and m.link == null) present = true;
        }
        if (!present) return error.MissingMetadata;
    }
    for (members.items) |m| if (m.link) |l| {
        var canonical = false;
        for (members.items) |other| {
            if (eq(other.name, l) and other.link == null) canonical = true;
        }
        if (!canonical) return error.InvalidArchiveHardlink;
        if (c.link(try fmt(a, "{s}/{s}", .{ template, l }), try fmt(a, "{s}/{s}", .{ template, m.name })) != 0) return error.ExtractFailed;
    };
    var b = Bundle{ .a = a, .directory = template, .new = undefined, .old = undefined, .baseline = null, .removals = undefined, .commit = undefined, .digest = digest };
    b.new = try manifest(a, try b.read("manifest.tsv"), false);
    b.old = try manifest(a, try b.read("previous.tsv"), false);
    for (members.items) |m| if (eq(m.name, "directories.tsv")) {
        if (m.link != null or (m.mode != 0o444 and m.mode != 0o644)) return error.InvalidDirectories;
        b.directory_bytes = try b.read("directories.tsv");
        b.dirs = try directories(a, b.directory_bytes.?);
    };
    for (b.dirs) |dir| {
        for (b.new.rows) |row| {
            if (eq(row.path, dir.path) or std.mem.startsWith(u8, dir.path, try fmt(a, "{s}/", .{row.path}))) return error.DirectoryFileCollision;
        }
    }
    b.commit = trim(try b.read("commit"));
    if (!u.hex(b.commit, 40)) return error.InvalidCommit;
    const report = try std.json.parseFromSlice(std.json.Value, a, try b.read("report.json"), .{});
    defer report.deinit();
    if (report.value != .object) return error.InvalidReport;
    const removal = try std.json.parseFromSlice([]const []const u8, a, try b.read("removals.json"), .{ .allocate = .alloc_always });
    b.removals = removal.value;
    for (b.removals, 0..) |p, i| {
        if (!safePath(p)) return error.UnsafeRemoval;
        for (b.dirs) |dir| {
            if (eq(p, dir.path) or std.mem.startsWith(u8, dir.path, try fmt(a, "{s}/", .{p}))) return error.DirectoryFileCollision;
        }
        for (b.removals[0..i]) |prior| if (eq(prior, p)) return error.UnsafeRemoval;
        if (find(b.new.rows, p)) |row| {
            if (!row.deleted) return error.RemovalPayloadCollision;
        }
    }
    for (members.items) |m| if (eq(m.name, "baseline.tsv")) {
        b.baseline = try manifest(a, try b.read("baseline.tsv"), true);
        if (!eq(b.baseline.?.base, b.old.base)) return error.BaselineBuildMismatch;
    };
    try validateMetalog(&b);
    for (members.items) |m| {
        if (std.mem.startsWith(u8, m.name, "files/")) {
            const row = find(b.new.rows, m.name[5..]) orelse return error.UnexpectedPayload;
            if (row.deleted or row.mode != m.mode) return error.PayloadModeMismatch;
            if (row.link) |p| {
                if (m.link == null or !eq(m.link.?, try std.fmt.allocPrint(a, "files{s}", .{p}))) return error.SharedPayloadMismatch;
            } else if (m.link != null) return error.UnexpectedArchiveHardlink;
        }
    }
    for (b.new.rows) |row| if (!row.deleted) {
        const source = try b.payload(row.path);
        const actual = try u.hashPath(a, source);
        if (!eq(row.hash, actual)) return error.PayloadHashMismatch;
    };
    if (!eq(try fdHash(a, fd), digest)) return error.ArchiveChangedDuringRead;
    return b;
}
fn validateMetalog(b: *Bundle) !void {
    var seen = std.StringHashMap(void).init(b.a);
    var lines = std.mem.tokenizeScalar(u8, try b.read("METALOG"), '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const path = fields.next() orelse continue;
        var attrs = std.StringHashMap([]const u8).init(b.a);
        while (fields.next()) |attr| {
            const at = std.mem.indexOfScalar(u8, attr, '=') orelse return error.InvalidMetalog;
            const key = attr[0..at];
            if (attrs.contains(key)) return error.InvalidMetalog;
            try attrs.put(key, attr[at + 1 ..]);
        }
        if (!std.mem.startsWith(u8, path, "./files/")) continue;
        const rel = path[7..];
        if (seen.contains(rel)) return error.InvalidMetalog;
        try seen.put(rel, {});
        const row = find(b.new.rows, rel) orelse {
            if (eq(attrs.get("type") orelse "", "dir")) continue;
            return error.InvalidMetalog;
        };
        if (row.deleted or !eq(attrs.get("type") orelse "", "file") or !eq(attrs.get("uname") orelse "", "root") or !eq(attrs.get("gname") orelse "", "wheel")) return error.InvalidMetalog;
        const mode = try std.fmt.allocPrint(b.a, "0{o}", .{row.mode});
        if (!eq(attrs.get("mode") orelse "", mode)) return error.InvalidMetalog;
        if (attrs.get("contents")) |ref| {
            if (!std.mem.startsWith(u8, ref, "./files/")) return error.InvalidSharedContents;
            row.link = ref[7..];
        }
    }
    for (b.new.rows) |row| if (!row.deleted) {
        if (!seen.contains(row.path)) return error.InvalidMetalog;
        if (row.link) |p| {
            const canonical = find(b.new.rows, p) orelse return error.InvalidSharedContents;
            if (canonical.deleted or canonical.link != null or eq(p, row.path) or canonical.mode != row.mode or !eq(canonical.hash, row.hash)) return error.InvalidSharedContents;
        }
    };
}
/// Anchored openat traversal refuses symlink parents and other mounted datasets.
/// No pathname operation below can escape this root through a replaced parent.
pub const Root = struct {
    a: A,
    fd: c_int,
    device: u64,
    path: [:0]const u8,
    ownership: bool,
    pub fn open(a: A, path: [:0]const u8, ownership: bool) !Root {
        if (eq(path, "/") or path.len == 0) return error.OfflineRootRequired;
        var resolved: [4096]u8 = undefined;
        if (c.realpath(path, &resolved) == null or !eq(std.mem.sliceTo(&resolved, 0), path)) return error.CanonicalRootRequired;
        const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return error.OfflineRootRequired;
        errdefer _ = c.close(fd);
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) return error.StatFailed;
        return .{ .a = a, .fd = fd, .device = @intCast(st.st_dev), .path = path, .ownership = ownership };
    }
    pub fn close(self: Root) void {
        _ = c.close(self.fd);
    }
    pub fn directory(self: Root, path: []const u8) !?c.struct_stat {
        if (!safeDirectory(path)) return error.UnsafePath;
        var st: c.struct_stat = undefined;
        if (eq(path, "/")) {
            if (c.fstat(self.fd, &st) != 0) return error.StatFailed;
        } else {
            const fd = (try self.parent(path, false)) orelse return null;
            defer _ = c.close(fd);
            const rc = c.fstatat(fd, try z(self.a, std.fs.path.basename(path)), &st, c.AT_SYMLINK_NOFOLLOW);
            if (rc != 0) {
                if (std.c.errno(rc) == .NOENT) return null;
                return error.StatFailed;
            }
        }
        if (st.st_mode & c.S_IFMT != c.S_IFDIR) return error.NondirectoryDestination;
        // An existing mountpoint is also left alone. parent() still refuses
        // traversal into another dataset when inspecting/creating children.
        return st;
    }
    pub fn createDirectory(self: Root, dir: Directory) !void {
        if (try self.directory(dir.path) != null) return;
        const parent_fd = (try self.parent(dir.path, true)).?;
        defer _ = c.close(parent_fd);
        const name = try z(self.a, std.fs.path.basename(dir.path));
        if (c.mkdirat(parent_fd, name, 0o700) != 0) {
            if (std.c.errno(-1) == .EXIST and try self.directory(dir.path) != null) return;
            return error.CreateDirectory;
        }
        const fd = c.openat(parent_fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return error.CreateDirectory;
        defer _ = c.close(fd);
        var opened: c.struct_stat = undefined;
        if (c.fstat(fd, &opened) != 0 or @as(u64, @intCast(opened.st_dev)) != self.device) return error.OtherDataset;
        if (self.ownership and c.fchown(fd, dir.uid, dir.gid) != 0) return error.DirectoryOwnership;
        if (c.fchmod(fd, @intCast(dir.mode)) != 0 or c.fsync(fd) != 0 or c.fsync(parent_fd) != 0) return error.CreateDirectory;
        const st = (try self.directory(dir.path)) orelse return error.CreateDirectory;
        if (st.st_mode & 0o7777 != dir.mode or (self.ownership and (st.st_uid != dir.uid or st.st_gid != dir.gid))) return error.DirectoryMetadata;
    }
    pub fn parent(self: Root, path: []const u8, create: bool) !?c_int {
        if (path.len < 2 or path[0] != '/') return error.UnsafePath;
        var fd = c.dup(self.fd);
        if (fd < 0) return error.OpenFailed;
        errdefer _ = c.close(fd);
        var parts = std.mem.splitScalar(u8, path[1..], '/');
        while (parts.next()) |part| {
            if (part.len == 0 or eq(part, ".") or eq(part, "..")) return error.UnsafePath;
            if (parts.peek() == null) break;
            const name = try z(self.a, part);
            var nextfd = c.openat(fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (nextfd < 0 and std.c.errno(nextfd) == .NOENT) {
                if (!create) {
                    _ = c.close(fd);
                    return null;
                }
                if (c.mkdirat(fd, name, 0o755) != 0) return error.CreateDirectory;
                nextfd = c.openat(fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            }
            if (nextfd < 0) return error.UnsafeParent;
            var st: c.struct_stat = undefined;
            if (c.fstat(nextfd, &st) != 0 or @as(u64, @intCast(st.st_dev)) != self.device) {
                _ = c.close(nextfd);
                return error.OtherDataset;
            }
            _ = c.close(fd);
            fd = nextfd;
        }
        return fd;
    }
    pub fn stat(self: Root, path: []const u8) !?c.struct_stat {
        const fd = (try self.parent(path, false)) orelse return null;
        defer _ = c.close(fd);
        var st: c.struct_stat = undefined;
        const rc = c.fstatat(fd, try z(self.a, std.fs.path.basename(path)), &st, c.AT_SYMLINK_NOFOLLOW);
        if (rc != 0) {
            if (std.c.errno(rc) == .NOENT) return null;
            return error.StatFailed;
        }
        if ((st.st_mode & c.S_IFMT) != c.S_IFREG or @as(u64, @intCast(st.st_dev)) != self.device) return error.NonregularDestination;
        return st;
    }
    pub fn read(self: Root, path: []const u8) !?[]const u8 {
        _ = (try self.stat(path)) orelse return null;
        const fd = (try self.parent(path, false)).?;
        defer _ = c.close(fd);
        const input = c.openat(fd, try z(self.a, std.fs.path.basename(path)), c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (input < 0) return error.OpenFailed;
        defer _ = c.close(input);
        return try u.readFd(self.a, input, 32 * 1024 * 1024);
    }
    pub fn matches(self: Root, path: []const u8, hash: []const u8, mode: u32, owner: bool) !bool {
        const st = (try self.stat(path)) orelse return false;
        if (st.st_mode & 0o7777 != mode or (owner and self.ownership and (st.st_uid != 0 or st.st_gid != 0))) return false;
        const fd = (try self.parent(path, false)).?;
        defer _ = c.close(fd);
        const input = c.openat(fd, try z(self.a, std.fs.path.basename(path)), c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (input < 0) return error.OpenFailed;
        defer _ = c.close(input);
        return eq(try fdHash(self.a, input), hash);
    }
    pub fn write(self: Root, path: []const u8, bytes: []const u8, mode: u32) !void {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        if (try self.matches(path, &std.fmt.bytesToHex(hash, .lower), mode, true)) return;
        const fd = (try self.parent(path, true)).?;
        defer _ = c.close(fd);
        const name = try z(self.a, std.fs.path.basename(path));
        var random: [12]u8 = undefined;
        c.arc4random_buf(&random, random.len);
        const tmp = try fmt(self.a, ".softwareupdate-{s}", .{std.fmt.bytesToHex(random, .lower)});
        const out = c.openat(fd, tmp, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (out < 0) return error.WriteFailed;
        defer _ = c.close(out);
        defer _ = c.unlinkat(fd, tmp, 0);
        try u.write(out, bytes);
        if (c.fchmod(out, @intCast(mode)) != 0 or (self.ownership and c.fchown(out, 0, 0) != 0) or c.fsync(out) != 0) return error.WriteFailed;
        if (c.renameat(fd, tmp, fd, name) != 0 or c.fsync(fd) != 0) return error.RenameFailed;
    }
    pub fn copy(self: Root, path: []const u8, source: [:0]const u8, row: Row) !void {
        if (try self.matches(path, row.hash, row.mode, true)) return;
        const input = c.open(source, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (input < 0) return error.OpenFailed;
        defer _ = c.close(input);
        const fd = (try self.parent(path, true)).?;
        defer _ = c.close(fd);
        var random: [12]u8 = undefined;
        c.arc4random_buf(&random, random.len);
        const tmp = try fmt(self.a, ".softwareupdate-{s}", .{std.fmt.bytesToHex(random, .lower)});
        const out = c.openat(fd, tmp, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (out < 0) return error.WriteFailed;
        defer _ = c.close(out);
        defer _ = c.unlinkat(fd, tmp, 0);
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = c.read(input, &buf, buf.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            try u.write(out, buf[0..@intCast(n)]);
        }
        if (c.fchmod(out, @intCast(row.mode)) != 0 or (self.ownership and c.fchown(out, 0, 0) != 0) or c.fsync(out) != 0) return error.WriteFailed;
        if (!eq(try fdHash(self.a, input), row.hash)) return error.PayloadHashMismatch;
        if (c.renameat(fd, tmp, fd, try z(self.a, std.fs.path.basename(path))) != 0 or c.fsync(fd) != 0) return error.RenameFailed;
    }
    pub fn remove(self: Root, path: []const u8) !void {
        _ = (try self.stat(path)) orelse return;
        const fd = (try self.parent(path, false)).?;
        defer _ = c.close(fd);
        if (c.unlinkat(fd, try z(self.a, std.fs.path.basename(path)), 0) != 0 or c.fsync(fd) != 0) return error.RemoveFailed;
    }
    fn hardlink(self: Root, path: []const u8, target: []const u8) !void {
        const target_st = (try self.stat(target)) orelse return error.MissingLinkTarget;
        if (try self.stat(path)) |st| if (st.st_dev == target_st.st_dev and st.st_ino == target_st.st_ino) {
            return;
        };
        const dst = (try self.parent(path, true)).?;
        defer _ = c.close(dst);
        const src = (try self.parent(target, false)).?;
        defer _ = c.close(src);
        var random: [12]u8 = undefined;
        c.arc4random_buf(&random, random.len);
        const tmp = try fmt(self.a, ".softwareupdate-{s}", .{std.fmt.bytesToHex(random, .lower)});
        defer _ = c.unlinkat(dst, tmp, 0);
        if (c.linkat(src, try z(self.a, std.fs.path.basename(target)), dst, tmp, 0) != 0 or c.renameat(dst, tmp, dst, try z(self.a, std.fs.path.basename(path))) != 0 or c.fsync(dst) != 0) return error.LinkFailed;
    }
};
const Planned = struct { rows: []Row, conflicts: []const u8, deletes: []const []const u8, old_remove: []const []const u8, keeps: []const []const u8 };
pub fn preflight(b: Bundle, root: Root) !Planned {
    const installed = try root.read("/var/db/rmxos/manifest.tsv");
    if (installed) |value| {
        if (!eq(value, b.old.bytes) and !eq(value, b.new.bytes)) return error.InstalledManifestMismatch;
    } else if (b.baseline == null) return error.FirstUpdateRequiresBaseline;
    const rows = try b.a.dupe(Row, b.new.rows);
    var conflicts: std.ArrayList(u8) = .empty;
    var deletes: std.ArrayList([]const u8) = .empty;
    var old_remove: std.ArrayList([]const u8) = .empty;
    var keeps: std.ArrayList([]const u8) = .empty;
    for (b.dirs) |dir| _ = try root.directory(dir.path);
    for (rows) |*row| {
        const st = try root.stat(row.path);
        if (row.deleted) {
            try deletes.append(b.a, row.path);
            continue;
        }
        if (ownerConfiguration(row.path) and st != null and !try root.matches(row.path, row.hash, row.mode, false)) {
            const previous = if (installed == null and b.baseline != null) find(b.baseline.?.rows, row.path) else find(b.old.rows, row.path);
            if (previous == null or previous.?.deleted or !try root.matches(row.path, previous.?.hash, previous.?.mode, false)) {
                row.use = try std.fmt.allocPrint(b.a, "{s}.rmxos-new", .{row.path});
                if (try root.stat(row.use) != null and !try root.matches(row.use, row.hash, row.mode, false)) return error.SidecarDiffers;
                try conflicts.appendSlice(b.a, try std.fmt.allocPrint(b.a, "{s}\t{s}\n", .{ row.path, row.use }));
            }
        }
        _ = try root.stat(row.use);
    }
    for (b.removals) |p| {
        _ = try root.stat(p);
        if (!contains(deletes.items, p)) try deletes.append(b.a, p);
    }
    for (b.old.rows) |row| {
        _ = try root.stat(row.path);
        if (!row.deleted and find(rows, row.path) == null and !contains(deletes.items, row.path)) {
            if (try root.matches(row.path, row.hash, row.mode, false)) {
                try old_remove.append(b.a, row.path);
            } else if (try root.stat(row.path) != null) try keeps.append(b.a, row.path);
        }
    }
    // All metadata and derived paths must be safe before the first file change.
    for ([_][]const u8{ "/var/db/rmxos/manifest.tsv", "/var/db/rmxos/directories.tsv", "/var/db/rmxos/commit", "/var/db/rmxos/conflicts.tsv", "/var/db/rmxos/archive.sha256", "/var/db/rmxos/previous-be", "/var/db/rmxos/pending-target", "/var/db/softwareupdate/no-auto-confirm", "/var/db/softwareupdate/history.tsv", "/boot/loader.conf.local" }) |p| _ = try root.stat(p);
    return .{ .rows = rows, .conflicts = try conflicts.toOwnedSlice(b.a), .deletes = try deletes.toOwnedSlice(b.a), .old_remove = try old_remove.toOwnedSlice(b.a), .keeps = try keeps.toOwnedSlice(b.a) };
}
fn ownerConfiguration(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/etc/") and !std.mem.startsWith(u8, path, "/etc/mtree/") and !std.mem.startsWith(u8, path, "/etc/defaults/");
}
fn contains(paths: []const []const u8, p: []const u8) bool {
    for (paths) |v| if (eq(v, p)) return true;
    return false;
}
pub fn apply(b: Bundle, root: Root, p: Planned, ctx: u.Context) !void {
    for (b.dirs) |dir| try root.createDirectory(dir);
    for (p.keeps) |path| try ctx.print(ctx.out, "KEEP local {s}\n", .{path});
    for (p.old_remove) |path| {
        try root.remove(path);
        try ctx.print(ctx.out, "REMOVE previous {s}\n", .{path});
    }
    for (p.deletes) |path| {
        if (try root.stat(path) != null) {
            try root.remove(path);
            try ctx.print(ctx.out, "REMOVE obsolete {s}\n", .{path});
        }
    }
    for (p.rows) |row| if (!row.deleted and row.link == null) {
        const changed = !try root.matches(row.use, row.hash, row.mode, true);
        try root.copy(row.use, try b.payload(row.path), row);
        if (changed) try ctx.print(ctx.out, "WRITE {s}\n", .{row.use});
    };
    for (p.rows) |row| if (!row.deleted) {
        if (row.link) |target| {
            const canonical = find(p.rows, target) orelse return error.MissingLinkTarget;
            const old = try root.stat(row.use);
            const new = (try root.stat(canonical.use)).?;
            const changed = old == null or old.?.st_dev != new.st_dev or old.?.st_ino != new.st_ino;
            try root.hardlink(row.use, canonical.use);
            if (changed) try ctx.print(ctx.out, "LINK {s} -> {s}\n", .{ row.use, canonical.use });
        }
    };
    try verify(b, root, p);
    try ctx.print(ctx.out, "{s}VERIFIED files={d} conflicts={d}\n", .{ p.conflicts, p.rows.len, std.mem.count(u8, p.conflicts, "\n") });
}
pub fn saveState(b: Bundle, root: Root, p: Planned) !void {
    if (b.directory_bytes) |bytes| try root.write("/var/db/rmxos/directories.tsv", bytes, 0o444);
    try root.write("/var/db/rmxos/manifest.tsv", b.new.bytes, 0o444);
    try root.write("/var/db/rmxos/commit", try std.fmt.allocPrint(b.a, "{s}\n", .{b.commit}), 0o444);
    try root.write("/var/db/rmxos/conflicts.tsv", p.conflicts, 0o444);
    try root.write("/var/db/rmxos/archive.sha256", try std.fmt.allocPrint(b.a, "{s}\n", .{b.digest}), 0o444);
}
pub fn verify(_: Bundle, root: Root, p: Planned) !void {
    for (p.rows) |row| if (!row.deleted) {
        if (!try root.matches(row.use, row.hash, row.mode, true)) return error.FinalMismatch;
        if (row.link) |target| {
            const canonical = find(p.rows, target).?;
            const x = (try root.stat(row.use)).?;
            const y = (try root.stat(canonical.use)).?;
            if (x.st_dev != y.st_dev or x.st_ino != y.st_ino) return error.FinalLinkMismatch;
        } else {
            var count: usize = 1;
            for (p.rows) |alias| {
                if (alias.link != null and eq(alias.link.?, row.path)) count += 1;
            }
            if (count > 1 and (try root.stat(row.use)).?.st_nlink != count) return error.FinalLinkCount;
        }
    };
    for (p.deletes) |path| if (try root.stat(path) != null) return error.ObsoleteRemains;
    for (p.old_remove) |path| if (try root.stat(path) != null) return error.PreviousRemains;
}
/// Only tests inject an executor; the product constructs this with native argv.
pub const Backend = struct {
    data: ?*anyopaque = null,
    execute: *const fn (?*anyopaque, A, []const [:0]const u8) anyerror![]const u8 = native,
    fn native(_: ?*anyopaque, a: A, argv: []const [:0]const u8) ![]const u8 {
        return u.capture(a, argv);
    }
    pub fn command(self: Backend, a: A, argv: []const [:0]const u8) ![]const u8 {
        return self.execute(self.data, a, argv);
    }
};
fn history(ctx: u.Context, root_path: []const u8, action: []const u8, previous: []const u8, target: []const u8, b: Bundle, conflicts: usize) !void {
    const root = try inspectRunning(b.a, root_path);
    defer root.close();
    const parent_fd = (try root.parent("/var/db/softwareupdate/history.tsv", true)).?;
    defer _ = c.close(parent_fd);
    const fd = c.openat(parent_fd, "history.tsv", c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return error.HistoryFailed;
    defer _ = c.close(fd);
    var time: c.time_t = 0;
    _ = c.time(&time);
    var utc: c.struct_tm = undefined;
    if (c.gmtime_r(&time, &utc) == null) return error.TimeFailed;
    var stamp: [64]u8 = undefined;
    const n = c.strftime(&stamp, stamp.len, "%Y-%m-%dT%H:%M:%SZ", &utc);
    if (n == 0) return error.TimeFailed;
    const from = (try root.read("/var/db/rmxos/commit")) orelse "-";
    try u.write(fd, try std.fmt.allocPrint(b.a, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{ stamp[0..n], action, trim(from), b.commit, previous, target, conflicts }));
    if (c.fsync(fd) != 0) return error.HistoryFailed;
    _ = ctx;
}
pub fn install(ctx: u.Context, o: u.Options, s: u.Snapshot, backend: Backend) !u8 {
    if (u.refusal(s, null)) |reason| return ctx.diagnostic(reason);
    const archive = o.operand orelse return ctx.diagnostic("local archive required");
    if (!std.fs.path.isAbsolute(archive)) return ctx.diagnostic("local archive required");
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try load(a, try z(a, archive));
    defer b.deinit();
    const target = try fmt(a, "rmxos-{s}", .{b.commit[0..12]});
    if (u.refusal(s, target)) |reason| return ctx.diagnostic(reason);
    const current = std.fs.path.basename(s.dataset.?);
    const parent = std.fs.path.dirname(s.dataset.?).?;
    // Read-only running-root inspection, using the same anchored checks. A root
    // descriptor for / is permitted only here, never passed to apply().
    const running = try inspectRunning(a, ctx.root);
    defer running.close();
    _ = try preflight(b, running);
    const operation = try u.lifecycle.operationLock(running);
    defer _ = c.close(operation);
    if (ctx.root.len == 0) {
        const fresh = u.snapshot(a);
        if (fresh.dataset == null or !eq(fresh.dataset.?, s.dataset.?)) return error.RunningBootEnvironmentChanged;
        if (u.refusal(fresh, target)) |reason| return ctx.diagnostic(reason);
    }
    const scratch = try z(a, "/tmp/softwareupdate-mount-XXXXXX");
    if (c.mkdtemp(@constCast(scratch)) == null) return error.TemporaryDirectory;
    // Never recursively remove a mount point: unmount may fail, leaving the
    // clone attached. rmdir then refuses the busy/nonempty directory.
    defer _ = c.rmdir(scratch);
    _ = try backend.command(a, &.{ "/sbin/bectl", "create", "-e", try z(a, current), target });
    try history(ctx, ctx.root, "create", current, target, b, 0);
    var mounted = false;
    defer if (mounted) {
        _ = backend.command(a, &.{ "/sbin/bectl", "unmount", target }) catch {};
    };
    _ = try backend.command(a, &.{ "/sbin/bectl", "mount", target, scratch });
    mounted = true;
    if (ctx.root.len == 0) {
        const mounts = try backend.command(a, &.{ "/sbin/mount", "-p" });
        const expected = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, target });
        var lines = std.mem.tokenizeScalar(u8, mounts, '\n');
        var found = false;
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const ds = fields.next() orelse continue;
            const at = fields.next() orelse continue;
            const kind = fields.next() orelse continue;
            if (eq(ds, expected) and eq(at, scratch) and eq(kind, "zfs")) found = true;
        }
        if (!found) return error.CloneMountMismatch;
    }
    const root = try Root.open(a, scratch, ctx.root.len == 0);
    var root_open = true;
    defer if (root_open) root.close();
    const p = try preflight(b, root);
    try apply(b, root, p, ctx);
    try ctx.print(ctx.out, "kldxref: begin /boot/RMXOS-RELEASE in mounted clone\n", .{});
    // Both directory levels must belong to this clone, with no symlink or
    // dataset crossing. Opening a fictitious child exercises the parent walk.
    const kernel_fd = (try root.parent("/boot/RMXOS-RELEASE/.softwareupdate-check", false)) orelse return error.KernelDirectoryMissing;
    _ = c.close(kernel_fd);
    _ = try backend.command(a, &.{ "/usr/sbin/kldxref", try fmt(a, "{s}/boot/RMXOS-RELEASE", .{scratch}) });
    try ctx.print(ctx.out, "kldxref: complete /boot/RMXOS-RELEASE in mounted clone\n", .{});
    try saveState(b, root, p);
    try root.write("/var/db/rmxos/previous-be", try std.fmt.allocPrint(a, "{s}\n", .{current}), 0o444);
    try root.write("/var/db/rmxos/pending-target", try std.fmt.allocPrint(a, "{s}\n", .{target}), 0o444);
    try root.write("/var/db/softwareupdate/no-auto-confirm", if (o.no_auto_confirm) "yes\n" else "no\n", 0o444);
    const loader = (try root.read("/boot/loader.conf.local")) orelse "";
    const loader_stat = try root.stat("/boot/loader.conf.local");
    const loader_mode: u32 = if (loader_stat) |st| @intCast(st.st_mode & 0o777) else 0o644;
    try root.write("/boot/loader.conf.local", try std.fmt.allocPrint(a, "{s}\n# softwareupdate target\nvfs.root.mountfrom=\"zfs:{s}/{s}\"\n", .{ loader, parent, target }), loader_mode);
    // kldxref alone may regenerate derived linker.hints. Every other candidate
    // remains byte/mode/owner exact. Verify hints before refresh via apply().
    var final = p;
    final.rows = try a.dupe(Row, p.rows);
    for (final.rows) |*row| {
        if (eq(row.path, "/boot/RMXOS-RELEASE/linker.hints") or eq(row.path, "/boot/loader.conf.local")) {
            // Derived bytes are generated by trusted base tools/this command;
            // check their final hash, mode and root owner below as well.
            row.hash = try u.hashPath(a, try fmt(a, "{s}{s}", .{ scratch, row.path }));
            row.mode = @intCast((try root.stat(row.path)).?.st_mode & 0o7777);
        }
    }
    try verify(b, root, final);
    const state_checks = [_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = "/var/db/rmxos/manifest.tsv", .bytes = b.new.bytes },
        .{ .path = "/var/db/rmxos/commit", .bytes = try std.fmt.allocPrint(a, "{s}\n", .{b.commit}) },
        .{ .path = "/var/db/rmxos/conflicts.tsv", .bytes = p.conflicts },
        .{ .path = "/var/db/rmxos/archive.sha256", .bytes = try std.fmt.allocPrint(a, "{s}\n", .{b.digest}) },
        .{ .path = "/var/db/rmxos/previous-be", .bytes = try std.fmt.allocPrint(a, "{s}\n", .{current}) },
        .{ .path = "/var/db/rmxos/pending-target", .bytes = try std.fmt.allocPrint(a, "{s}\n", .{target}) },
        .{ .path = "/var/db/softwareupdate/no-auto-confirm", .bytes = if (o.no_auto_confirm) "yes\n" else "no\n" },
    };
    for (state_checks) |state| {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(state.bytes, &h, .{});
        if (!try root.matches(state.path, &std.fmt.bytesToHex(h, .lower), 0o444, true)) return error.FinalStateMismatch;
    }
    if (b.directory_bytes) |bytes| {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
        if (!try root.matches("/var/db/rmxos/directories.tsv", &std.fmt.bytesToHex(h, .lower), 0o444, true)) return error.FinalStateMismatch;
    }
    const conflict_count = std.mem.count(u8, p.conflicts, "\n");
    try history(ctx, ctx.root, "apply", current, target, b, conflict_count);
    // The clone inherits the running trail, including creation and application.
    const trail = try u.readPath(a, try fmt(a, "{s}/var/db/softwareupdate/history.tsv", .{ctx.root}));
    try root.write("/var/db/softwareupdate/history.tsv", trail, 0o644);
    var efi_changed = false;
    for (b.new.rows) |row| if (eq(row.path, "/boot/loader.efi") and !row.deleted) {
        efi_changed = !try running.matches(row.path, row.hash, row.mode, true);
    };
    try u.lifecycle.register(ctx, running, root, target, b.commit, efi_changed);
    root.close();
    root_open = false;
    _ = try backend.command(a, &.{ "/sbin/bectl", "unmount", target });
    mounted = false;
    if (ctx.root.len == 0) {
        const fresh = u.snapshot(a);
        if (fresh.dataset == null or !eq(fresh.dataset.?, s.dataset.?)) return error.RunningBootEnvironmentChanged;
        if (u.refusal(fresh, null)) |reason| return ctx.diagnostic(reason);
    }
    _ = try backend.command(a, &.{ "/sbin/bectl", "activate", "-t", target });
    try history(ctx, ctx.root, "staged", current, target, b, conflict_count);
    _ = try backend.command(a, &.{ "/usr/bin/logger", "-t", "softwareupdate", try fmt(a, "staged={s} commit={s} conflicts={d}", .{ target, b.commit, conflict_count }) });
    try ctx.print(ctx.out, "staged={s}; reboot with: shutdown -r now\n", .{target});
    if (o.restart) {
        _ = try backend.command(a, &.{ "/sbin/shutdown", "-r", "now" });
    }
    return 0;
}
pub fn inspectRunning(a: A, path: []const u8) !Root {
    if (path.len != 0) return Root.open(a, try z(a, path), false);
    const fd = c.open("/", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFailed;
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) {
        _ = c.close(fd);
        return error.StatFailed;
    }
    return .{ .a = a, .fd = fd, .device = @intCast(st.st_dev), .path = "/", .ownership = true };
}
