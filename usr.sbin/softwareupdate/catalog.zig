// The v2 catalog: catalog.json naming zfs send -i streams, read from a
// directory or URL and cached on Data for --no-scan.
const std = @import("std");
const sys = @import("sys.zig");
const Ctx = sys.Ctx;

pub const format = "rmxos-catalog-v2";
pub const Update = struct {
    label: []const u8,
    build: []const u8,
    snapshot: []const u8,
    // u64 GUIDs as decimal strings (JSON numbers lose precision above 2^53).
    origin_guid: []const u8,
    target_guid: []const u8,
    stream: []const u8,
    sha256: []const u8,
    size: u64,
};
pub const Catalog = struct { format: []const u8, updates: []Update };

pub const state = "/private/var/db/rmxos/softwareupdate";

pub fn parse(a: std.mem.Allocator, data: []const u8) !Catalog {
    const p = std.json.parseFromSlice(Catalog, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.MalformedCatalog;
    const v = p.value;
    if (!std.mem.eql(u8, v.format, format)) return error.MalformedCatalog;
    for (v.updates) |u| {
        if (u.label.len == 0 or u.snapshot.len == 0 or std.mem.indexOfAny(u8, u.snapshot, "/@ \t\n") != null) return error.MalformedCatalog;
        if (std.mem.indexOfAny(u8, u.stream, "/\\\n") != null or u.stream.len == 0) return error.MalformedCatalog;
        _ = std.fmt.parseInt(u64, u.origin_guid, 10) catch return error.MalformedCatalog;
        _ = std.fmt.parseInt(u64, u.target_guid, 10) catch return error.MalformedCatalog;
        if (u.sha256.len != 64) return error.MalformedCatalog;
    }
    return v;
}

pub fn isUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://") or
        std.mem.startsWith(u8, s, "ftp://") or std.mem.startsWith(u8, s, "file://");
}

// --catalog first, then catalog_url from /etc/softwareupdate.conf over
// /etc/defaults/softwareupdate.conf.
pub fn location(ctx: Ctx, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |e| return e;
    if (setting(ctx, "catalog_url")) |v| if (v.len > 0) return v;
    return error.NoCatalog;
}

pub fn setting(ctx: Ctx, key: []const u8) ?[]const u8 {
    var value: ?[]const u8 = null;
    for ([_][]const u8{ "/etc/defaults/softwareupdate.conf", "/etc/softwareupdate.conf" }) |f| {
        const text = sys.read(ctx.a, ctx.path(f) catch return value) catch continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = sys.trim(raw);
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (!std.mem.eql(u8, sys.trim(line[0..eq]), key)) continue;
            value = std.mem.trim(u8, sys.trim(line[eq + 1 ..]), "\"");
        }
    }
    return value;
}

// Copy (directory) or fetch(1) (URL) one catalog member to a local path.
fn obtain(ctx: Ctx, source: []const u8, member: []const u8, dest: [:0]const u8) !void {
    try sys.mkdirs(ctx.a, std.fs.path.dirname(dest).?);
    if (isUrl(source)) {
        const url = try ctx.fmt("{s}/{s}", .{ std.mem.trimEnd(u8, source, "/"), member });
        _ = try sys.capture(ctx, &.{ "/usr/bin/fetch", "-q", "-T", "60", "-o", dest, "--", url });
    } else {
        _ = try sys.capture(ctx, &.{ "/bin/cp", try ctx.fmt("{s}/{s}", .{ source, member }), dest });
    }
}

// Scan: fetch catalog.json and cache it with its source. --no-scan: the cache.
pub fn load(ctx: Ctx, explicit: ?[]const u8, no_scan: bool) !struct { catalog: Catalog, source: []const u8 } {
    const cached = try ctx.path(state ++ "/catalog.json");
    const source_file = try ctx.path(state ++ "/catalog.source");
    if (no_scan) {
        const data = sys.read(ctx.a, cached) catch return error.NoCachedCatalog;
        const source = sys.trim(sys.read(ctx.a, source_file) catch return error.NoCachedCatalog);
        return .{ .catalog = try parse(ctx.a, data), .source = source };
    }
    const source = try location(ctx, explicit);
    const tmp = try ctx.path(state ++ "/catalog.json.fetch");
    _ = sys.c.unlink(tmp);
    obtain(ctx, source, "catalog.json", tmp) catch return error.CatalogUnavailable;
    const data = try sys.read(ctx.a, tmp);
    const v = try parse(ctx.a, data);
    if (sys.c.rename(tmp, cached) != 0) return error.CatalogCache;
    try sys.replace(ctx.a, source_file, try ctx.fmt("{s}\n", .{source}));
    return .{ .catalog = v, .source = source };
}

// The stream as a local file: the directory's own file, or a download.
pub fn stream(ctx: Ctx, source: []const u8, u: Update) ![:0]const u8 {
    if (!isUrl(source)) return ctx.z(try ctx.fmt("{s}/{s}", .{ source, u.stream }));
    const dest = try ctx.path(try ctx.fmt(state ++ "/downloads/{s}", .{u.stream}));
    if (!sys.exists(dest)) try obtain(ctx, source, u.stream, dest);
    return dest;
}

// Download into Data (--download, --background), whatever the source.
pub fn download(ctx: Ctx, source: []const u8, u: Update) ![:0]const u8 {
    const dest = try ctx.path(try ctx.fmt(state ++ "/downloads/{s}", .{u.stream}));
    if (!sys.exists(dest)) try obtain(ctx, source, u.stream, dest);
    return dest;
}
