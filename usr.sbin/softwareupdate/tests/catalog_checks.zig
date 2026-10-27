const std = @import("std");
const u = @import("update");
const c = u.c;
const a = std.heap.page_allocator;
const fixture = @import("install_checks.zig");
fn fmt(comptime f: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, f, args, 0);
}
fn check(b: bool) !void {
    try std.testing.expect(b);
}
fn put(path: [:0]const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), std.fs.path.dirname(path).?);
    _ = c.unlink(path);
    const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try u.write(fd, bytes);
}
const snap = u.Snapshot{ .uid = 0, .dataset = "zroot/ROOT/rmxos-aaaaaaaaaaaa", .listing = "rmxos-aaaaaaaaaaaa\tNR\n" };
fn local(f: fixture.Fixture) ![:0]const u8 {
    const path = try fmt("{s}/published", .{f.path});
    const archive = try fmt("{s}/rmxos-bbbbbbbbbbbb/update.tar", .{path});
    try put(archive, "fixture archive");
    const hash = try u.hashPath(a, archive);
    try put(try fmt("{s}.sha256", .{archive}), hash);
    const text = try fmt("{{\"format\":\"rmxos-catalog-v1\",\"updates\":[{{\"name\":\"rmxos-bbbbbbbbbbbb\",\"commit\":\"{s}\",\"sha256\":\"{s}\",\"from\":{{\"commit\":\"{s}\",\"manifest_sha256\":\"{s}\"}},\"date\":\"2026-10-27T00:00:00Z\",\"size\":15,\"restart_required\":true}}]}}", .{ "b" ** 40, hash, "a" ** 40, "a" ** 64 });
    try put(try fmt("{s}/catalog.json", .{path}), text);
    return path;
}
pub fn missing() !void {
    const f = try fixture.Fixture.init(false);
    defer f.deinit();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    try check(try u.run(ctx, &.{"--list"}, snap) != 0);
    const text = try u.readPath(a, try fmt("{s}/output", .{f.path}));
    try check(std.mem.indexOf(u8, text, "catalog_url") != null);
}
pub fn fileURL() !void {
    const f = try fixture.Fixture.init(false);
    defer f.deinit();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    const path = try local(f);
    try check(try u.run(ctx, &.{ "--list", "--catalog", try fmt("file://{s}", .{path}) }, snap) == 0);
}
pub fn download() !void {
    const f = try fixture.Fixture.init(false);
    defer f.deinit();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    const path = try local(f);
    try check(try u.run(ctx, &.{ "--download", "rmxos-bbbbbbbbbbbb", "--catalog", path }, snap) == 0);
    const incoming = try fmt("{s}/var/db/softwareupdate/incoming/rmxos-bbbbbbbbbbbb/update.tar", .{f.root});
    try check(std.mem.eql(u8, try u.readPath(a, incoming), "fixture archive"));
    var before: c.struct_stat = undefined;
    try check(c.stat(incoming, &before) == 0);
    try check(try u.run(ctx, &.{ "--download", "all", "--catalog", path }, snap) == 0);
    var after: c.struct_stat = undefined;
    try check(c.stat(incoming, &after) == 0);
    try check(before.st_ino == after.st_ino);
}
pub fn nonroot() !void {
    const f = try fixture.Fixture.init(false);
    defer f.deinit();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    var s = snap;
    s.uid = 501;
    try check(try u.run(ctx, &.{ "--download", "all" }, s) != 0);
    try check(c.access(try fmt("{s}/var/db/softwareupdate/incoming", .{f.root}), c.F_OK) != 0);
}
test "missing catalog setting names catalog_url" {
    try missing();
}
test "list accepts file URL" {
    try fileURL();
}
test "download named and all finalize once" {
    try download();
}
test "nonroot download refuses without incoming" {
    try nonroot();
}
fn configured(name: [:0]const u8) ?[:0]const u8 {
    const value = c.getenv(name);
    return if (value == null) null else std.mem.span(value);
}
pub fn published() !void {
    const tree = configured("SOFTWAREUPDATE_TEST_TREE") orelse return error.SkipZigTest;
    const http = configured("SOFTWAREUPDATE_TEST_URL") orelse return error.SkipZigTest;
    const f = try fixture.Fixture.init(false);
    defer f.deinit();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    const previous = try u.capture(a, &.{ "/usr/bin/tar", "-xOf", try fmt("{s}/rmxos-bbbbbbbbbbbb/update.tar", .{tree}), "./previous.tsv" });
    try put(try fmt("{s}/var/db/rmxos/manifest.tsv", .{f.root}), previous);
    try put(try fmt("{s}/usr/share/softwareupdate-fixture", .{f.root}), "old");
    for ([_][]const u8{ tree, try fmt("file://{s}", .{tree}), http }) |source| {
        try check(try u.run(ctx, &.{ "--list", "--catalog", source }, snap) == 0);
    }
    const text = try u.readPath(a, try fmt("{s}/output", .{f.path}));
    try check(std.mem.count(u8, text, "rmxos-bbbbbbbbbbbb applies=yes") == 3);
    try check(std.mem.count(u8, text, "rmxos-cccccccccccc applies=no") == 3);
    try check(try u.run(ctx, &.{ "--download", "rmxos-bbbbbbbbbbbb", "--catalog", http }, snap) == 0);
    try check(try u.run(ctx, &.{ "--download", "all", "--catalog", http }, snap) == 0);
    var fake = fixture.Fake{ .f = f };
    const rc = if (@hasDecl(u, "runWithBackend")) try u.runWithBackend(ctx, &.{ "--install", "rmxos-bbbbbbbbbbbb" }, snap, .{ .data = &fake, .execute = fixture.Fake.command }) else try u.run(ctx, &.{ "--install", "rmxos-bbbbbbbbbbbb" }, snap);
    try check(rc == 0 and fake.activated);
    const clone = try u.engine.Root.open(a, fake.clone.?, false);
    defer clone.close();
    try check(std.mem.eql(u8, (try clone.read("/usr/share/softwareupdate-fixture")).?, "one"));
    try check(try clone.directory("/usr/lib/swift") != null);
    try check(std.mem.eql(u8, try u.readPath(a, try fmt("{s}/usr/share/softwareupdate-fixture", .{f.root})), "old"));
    try u.write(1, "op197 published=2 applicability=yes,no routes=directory,file,http download=one,all install_named=clone-only passed\n");
}
pub fn cut() !void {
    const url = configured("SOFTWAREUPDATE_CUT_URL") orelse return error.SkipZigTest;
    const f = try fixture.Fixture.init(false);
    defer f.deinit();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    const result = u.run(ctx, &.{ "--download", "rmxos-bbbbbbbbbbbb", "--catalog", url }, snap);
    if (result) |rc| try check(rc != 0) else |_| {}
    try check(c.access(try fmt("{s}/var/db/softwareupdate/incoming/rmxos-bbbbbbbbbbbb/update.tar", .{f.root}), c.F_OK) != 0);
    try u.write(1, "op197 cut-transfer=refused final_archive=absent\n");
}
pub fn disagreements() !void {
    for (0..2) |i| {
        const f = try fixture.Fixture.init(false);
        defer f.deinit();
        const ctx = try f.output();
        defer _ = c.close(ctx.out);
        const path = try local(f);
        if (i == 0) try put(try fmt("{s}/rmxos-bbbbbbbbbbbb/update.tar.sha256", .{path}), "bad") else try put(try fmt("{s}/rmxos-bbbbbbbbbbbb/update.tar", .{path}), "short");
        const result = u.run(ctx, &.{ "--download", "all", "--catalog", path }, snap);
        if (result) |rc| try check(rc != 0) else |_| {}
        try check(c.access(try fmt("{s}/var/db/softwareupdate/incoming/rmxos-bbbbbbbbbbbb/update.tar", .{f.root}), c.F_OK) != 0);
    }
}
pub fn config() !void {
    const f = try fixture.Fixture.init(false);
    defer f.deinit();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    const path = try local(f);
    try put(try fmt("{s}/etc/defaults/softwareupdate.conf", .{f.root}), "catalog_url=\"\"\n");
    try put(try fmt("{s}/etc/softwareupdate.conf", .{f.root}), try fmt("catalog_url=\"file://{s}/catalog.json\"\n", .{path}));
    try check(try u.run(ctx, &.{"--list"}, snap) == 0);
}
test "published directory file HTTP applicability download and named install" {
    try published();
}
test "cut HTTP transfer leaves no final archive" {
    try cut();
}
test "catalog sidecar and size disagreements leave no installable file" {
    try disagreements();
}
test "owner catalog configuration overrides empty default" {
    try config();
}
