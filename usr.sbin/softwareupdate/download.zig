const std = @import("std");
const u = @import("update.zig");
const c = u.c;
const e = u.engine;
const A = std.mem.Allocator;
const io = std.Io.Threaded.global_single_threaded.io();
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn trim(x: []const u8) []const u8 {
    return std.mem.trim(u8, x, " \t\r\n");
}
fn fmt(a: A, comptime f: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, f, args, 0);
}
fn setting(bytes: []const u8, value: *[]const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "catalog_url=")) return error.InvalidCatalogConfiguration;
        var v = trim(line[12..]);
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        if (std.mem.indexOfAny(u8, v, "\r\n\t\"\\") != null) return error.InvalidCatalogConfiguration;
        value.* = v;
    }
}
pub fn location(ctx: u.Context, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |v| return v;
    var value: []const u8 = "";
    if (try ctx.optional("/etc/defaults/softwareupdate.conf")) |v| try setting(v, &value);
    if (try ctx.optional("/etc/softwareupdate.conf")) |v| try setting(v, &value);
    if (value.len == 0) return error.MissingCatalogSetting;
    return value;
}
fn base(a: A, source: []const u8) ![:0]const u8 {
    if (source.len == 0 or std.mem.indexOfAny(u8, source, "\r\n\t ") != null) return error.InvalidCatalogLocation;
    if (std.mem.startsWith(u8, source, "https://") or std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "file://")) {
        var s = std.mem.trimEnd(u8, source, "/");
        if (std.mem.endsWith(u8, s, "/catalog.json")) s = s[0 .. s.len - 13];
        return a.dupeZ(u8, s);
    }
    if (std.mem.indexOf(u8, source, "://") != null) return error.InvalidCatalogLocation;
    const path = try a.dupeZ(u8, source);
    var resolved: [4096]u8 = undefined;
    if (c.realpath(path, &resolved) == null) return error.CatalogDirectoryMissing;
    return fmt(a, "file://{s}", .{std.mem.sliceTo(&resolved, 0)});
}
fn fetch(a: A, url: [:0]const u8, destination: [:0]const u8) !void {
    _ = try u.capture(a, &.{ "/usr/bin/fetch", "-q", "-T", "30", "-o", destination, "--", url });
}
fn temporary(a: A) ![:0]const u8 {
    const path = try a.dupeZ(u8, "/tmp/softwareupdate-fetch-XXXXXX");
    if (c.mkdtemp(path) == null) return error.TemporaryDirectory;
    return path;
}
pub fn readCatalog(ctx: u.Context, source: []const u8) !std.json.Parsed(u.Catalog) {
    const b = try base(ctx.allocator, source);
    const dir = try temporary(ctx.allocator);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try fmt(ctx.allocator, "{s}/catalog.json", .{dir});
    try fetch(ctx.allocator, try fmt(ctx.allocator, "{s}/catalog.json", .{b}), path);
    return u.catalog(ctx.allocator, try u.readPath(ctx.allocator, path));
}
pub fn list(ctx: u.Context, source: []const u8) !void {
    const p = try readCatalog(ctx, source);
    defer p.deinit();
    const b = try base(ctx.allocator, source);
    // Preserve U1's stronger local-publication checks. Remote listing reads only
    // the catalog; archives are validated when downloaded, before final names.
    if (std.mem.startsWith(u8, b, "file://")) return u.list(ctx, b[7..]);
    try u.renderCatalog(ctx, p.value);
}
fn verified(a: A, directory: [:0]const u8, update: u.Update) !void {
    const archive = try fmt(a, "{s}/update.tar", .{directory});
    const side = try fmt(a, "{s}/update.tar.sha256", .{directory});
    var st: c.struct_stat = undefined;
    if (c.lstat(archive, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG or st.st_size < 0 or @as(u64, @intCast(st.st_size)) != update.size) return error.DownloadSizeMismatch;
    if (c.lstat(side, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) return error.InvalidDownloadSidecar;
    if (!eq(trim(try u.readPath(a, side)), update.sha256)) return error.ChecksumSidecarMismatch;
    if (!eq(try u.hashPath(a, archive), update.sha256)) return error.DownloadChecksumMismatch;
}
pub fn download(ctx: u.Context, source: []const u8, selection: ?[]const u8) !void {
    const a = ctx.allocator;
    const p = try readCatalog(ctx, source);
    defer p.deinit();
    const b = try base(a, source);
    const name = selection orelse "all";
    var found = false;
    for (p.value.updates) |item| if (eq(name, "all") or eq(name, item.name)) {
        found = true;
    };
    if (!found) return error.UpdateNotInCatalog;
    const root = try e.inspectRunning(a, ctx.root);
    defer root.close();
    const lock = try u.lifecycle.operationLock(root);
    defer _ = c.close(lock);
    const parent = (try root.parent("/var/db/softwareupdate/incoming/.check", true)).?;
    defer _ = c.close(parent);
    var parent_stat: c.struct_stat = undefined;
    if (c.fstat(parent, &parent_stat) != 0) return error.StatFailed;
    if (root.ownership and (parent_stat.st_uid != 0 or parent_stat.st_mode & 0o022 != 0)) return error.UnsafeIncomingDirectory;
    for (p.value.updates) |item| {
        if (!eq(name, "all") and !eq(name, item.name)) continue;
        const target = try fmt(a, "/var/db/softwareupdate/incoming/{s}", .{item.name});
        const final = try ctx.path(target);
        if (try root.directory(target)) |st| {
            if (root.ownership and (st.st_uid != 0 or st.st_mode & 0o022 != 0)) return error.UnsafeIncomingDirectory;
            try verified(a, final, item);
            try ctx.print(ctx.out, "downloaded={s} unchanged=yes\n", .{item.name});
            continue;
        }
        var random: [12]u8 = undefined;
        c.arc4random_buf(&random, random.len);
        const short = try fmt(a, ".partial-{s}", .{std.fmt.bytesToHex(random, .lower)});
        if (c.mkdirat(parent, short, 0o700) != 0) return error.CreateDirectory;
        const scratch = try ctx.path(try fmt(a, "/var/db/softwareupdate/incoming/{s}", .{short}));
        defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
        const archive = try fmt(a, "{s}/update.tar", .{scratch});
        const side = try fmt(a, "{s}/update.tar.sha256", .{scratch});
        try fetch(a, try fmt(a, "{s}/{s}/update.tar.sha256", .{ b, item.name }), side);
        if (!eq(trim(try u.readPath(a, side)), item.sha256)) return error.ChecksumSidecarMismatch;
        try fetch(a, try fmt(a, "{s}/{s}/update.tar", .{ b, item.name }), archive);
        try verified(a, scratch, item);
        // Both files appear under the final directory in one atomic rename.
        // No fetch writes to an installable final path.
        for ([_][:0]const u8{ archive, side }) |file| {
            const fd = c.open(file, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (fd < 0) return error.OpenFailed;
            defer _ = c.close(fd);
            if (c.fsync(fd) != 0) return error.SyncFailed;
        }
        if (c.renameat(parent, short, parent, try a.dupeZ(u8, item.name)) != 0 or c.fsync(parent) != 0) return error.FinalizeDownload;
        try ctx.print(ctx.out, "downloaded={s} sha256={s}\n", .{ item.name, item.sha256 });
    }
}
pub fn incoming(ctx: u.Context, name: []const u8) ![:0]const u8 {
    if (!u.validName(name)) return error.InvalidUpdateName;
    const root = try e.inspectRunning(ctx.allocator, ctx.root);
    defer root.close();
    const path = try fmt(ctx.allocator, "/var/db/softwareupdate/incoming/{s}/update.tar", .{name});
    if (try root.stat(path) == null or try root.stat(try fmt(ctx.allocator, "{s}.sha256", .{path})) == null) return error.UpdateNotDownloaded;
    return ctx.path(path);
}
