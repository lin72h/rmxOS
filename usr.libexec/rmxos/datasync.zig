const std = @import("std");
const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("stdio.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("unistd.h");
});
const canonical = "/System/Library/Templates/Data";
const Sync = struct {
    a: std.mem.Allocator,
    template: []const u8,
    data: []const u8,
    patterns: []const u8,
    fn z(s: Sync, text: []const u8) ![:0]const u8 {
        return s.a.dupeZ(u8, text);
    }
    fn path(s: Sync, base: []const u8, rel: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(s.a, "{s}/{s}", .{ base, rel }, 0);
    }
    fn child(s: Sync, rel: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(s.a, "{s}{s}{s}", .{ rel, if (rel.len == 0) "" else "/", name });
    }
    fn local(s: Sync, rel: []const u8) bool {
        if (!std.mem.startsWith(u8, rel, "private/etc/")) return true;
        const name = rel[12..];
        var lines = std.mem.splitScalar(u8, s.patterns, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.eql(u8, line, name)) return true;
            if (line[line.len - 1] == '/' and (std.mem.startsWith(u8, name, line) or std.mem.eql(u8, name, line[0 .. line.len - 1]))) return true;
        }
        return false;
    }
    fn stat(pathname: [:0]const u8) ?c.struct_stat {
        var st: c.struct_stat = undefined;
        if (c.lstat(pathname, &st) == 0) return st;
        return null;
    }
    fn metadata(pathname: [:0]const u8, st: c.struct_stat) !void {
        // Numeric IDs only; this program must never consult passwd or nsswitch.
        if (c.geteuid() == 0 and c.chown(pathname, st.st_uid, st.st_gid) != 0) return error.Owner;
        if (c.chmod(pathname, st.st_mode & 0o7777) != 0) return error.Mode;
    }
    fn read(s: Sync, path_: [:0]const u8) ![]const u8 {
        const fd = c.open(path_, c.O_RDONLY | c.O_NOFOLLOW);
        if (fd < 0) return error.Open;
        defer _ = c.close(fd);
        var list: std.Io.Writer.Allocating = .init(s.a);
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n < 0) return error.Read;
            if (n == 0) break;
            try list.writer.writeAll(buf[0..@intCast(n)]);
        }
        return list.written();
    }
    fn write(fd: c_int, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.write(fd, rest.ptr, rest.len);
            if (n <= 0) return error.Write;
            rest = rest[@intCast(n)..];
        }
    }
    fn copy(s: Sync, source: [:0]const u8, dest: [:0]const u8, st: c.struct_stat) !void {
        const fd = c.open(dest, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return error.Create;
        defer _ = c.close(fd);
        errdefer _ = c.unlink(dest);
        try write(fd, try s.read(source));
        if (c.geteuid() == 0 and c.fchown(fd, st.st_uid, st.st_gid) != 0) return error.Owner;
        if (c.fchmod(fd, st.st_mode & 0o7777) != 0) return error.Mode;
    }
    fn prune(s: Sync, rel: []const u8) anyerror!void {
        const dest = try s.path(s.data, rel);
        const st = stat(dest) orelse return;
        if (st.st_mode & c.S_IFMT == c.S_IFLNK) {
            var buf: [4096]u8 = undefined;
            const n = c.readlink(dest, &buf, buf.len);
            if (n < 0 or n == buf.len) return error.Link;
            const target = buf[0..@intCast(n)];
            if (std.mem.startsWith(u8, target, canonical ++ "/")) {
                const source = try s.path(s.template, target[canonical.len + 1 ..]);
                if (stat(source) == null and c.unlink(dest) != 0) return error.Unlink;
            }
            return;
        }
        if (st.st_mode & c.S_IFMT != c.S_IFDIR) return;
        const dir = c.opendir(dest) orelse return error.OpenDir;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            try s.prune(try s.child(rel, name));
        }
    }
    fn walk(s: Sync, rel: []const u8) anyerror!void {
        const source = try s.path(s.template, rel);
        const st = stat(source) orelse return error.TemplateEntry;
        const dest = try s.path(s.data, rel);
        const existing = stat(dest);
        const kind = st.st_mode & c.S_IFMT;
        // These trees are wholly build-owned; pam.d remains a real directory so
        // cp -f can replace an individual link without writing a sealed parent.
        const whole = std.mem.eql(u8, rel, "private/etc/rc.d") or std.mem.eql(u8, rel, "private/etc/defaults") or
            std.mem.eql(u8, rel, "private/etc/mtree") or std.mem.eql(u8, rel, "private/etc/periodic");
        if (kind == c.S_IFDIR and !whole) {
            if (existing) |old| {
                if (old.st_mode & c.S_IFMT != c.S_IFDIR) return; // owner override
            } else {
                if (c.mkdir(dest, 0o700) != 0) return error.Mkdir;
                try metadata(dest, st);
            }
            const dir = c.opendir(source) orelse return error.OpenDir;
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |ent| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                try s.walk(try s.child(rel, name));
            }
            return;
        }
        if (existing != null) return;
        if (kind == c.S_IFLNK) {
            // Stock relative links were written relative to /etc, not the
            // template or /private/etc. Normalize them against that logical path.
            var buf: [4096]u8 = undefined;
            const n = c.readlink(source, &buf, buf.len);
            if (n < 0 or n == buf.len) return error.Link;
            const target = buf[0..@intCast(n)];
            const logical = if (std.mem.startsWith(u8, rel, "private/etc/")) try s.path("/etc", rel[12..]) else try s.path("", rel);
            const resolved = try std.fs.path.resolve(s.a, &.{ std.fs.path.dirname(logical).?, target });
            if (c.symlink(try s.z(resolved), dest) != 0) return error.Link;
        } else if (s.local(rel)) {
            if (kind != c.S_IFREG) return error.TemplateType;
            try s.copy(source, dest, st);
        } else {
            if (c.symlink(try s.path(canonical, rel), dest) != 0) return error.Link;
        }
    }
    fn populate(s: Sync) !void {
        try s.prune("private/etc");
        try s.walk("");
        const dir = try s.path(s.data, "private/var/db/rmxos");
        if (stat(dir) == null and c.mkdir(dir, 0o755) != 0) return error.Mkdir;
        const identity = try s.read(try s.z(try std.fmt.allocPrint(s.a, "{s}.build", .{s.template})));
        const marker = try s.path(s.data, "private/var/db/rmxos/populated");
        // Do not rewrite an already-current marker: a second run is identical.
        if (s.read(marker)) |old| {
            if (std.mem.eql(u8, old, identity)) return;
        } else |_| {}
        const tmp = try s.path(s.data, "private/var/db/rmxos/populated.new");
        const fd = c.open(tmp, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW, @as(c_uint, 0o644));
        if (fd < 0) return error.Create;
        defer _ = c.close(fd);
        errdefer _ = c.unlink(tmp);
        try write(fd, identity);
        if (c.fsync(fd) != 0 or c.rename(tmp, marker) != 0) return error.Marker;
    }
};
pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = init.args.toSlice(a) catch return 1;
    var template: []const u8 = canonical;
    var data: []const u8 = "/";
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) return 2;
        if (std.mem.eql(u8, argv[i], "--template")) template = argv[i + 1] else if (std.mem.eql(u8, argv[i], "--data")) data = argv[i + 1] else return 2;
    }
    var sync = Sync{ .a = a, .template = template, .data = data, .patterns = "" };
    const list = std.fmt.allocPrintSentinel(a, "{s}.local-patterns", .{template}, 0) catch return 1;
    sync.patterns = sync.read(list) catch return 1;
    sync.populate() catch |err| {
        const msg = std.fmt.allocPrint(a, "rmxos-datasync: {s}\n", .{@errorName(err)}) catch return 1;
        Sync.write(2, msg) catch {};
        return 1;
    };
    return 0;
}
