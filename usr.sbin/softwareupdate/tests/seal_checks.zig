const std = @import("std");
const u = @import("update");
const f = @import("install_checks.zig");
const c = u.c;
const a = std.heap.page_allocator;
const io = std.Io.Threaded.global_single_threaded.io();
const expect = std.testing.expect;
const snap = u.Snapshot{ .uid = 0, .dataset = "zroot/ROOT/rmxos-aaaaaaaaaaaa", .listing = "rmxos-aaaaaaaaaaaa\tNR\t/\n" };
fn fmt(comptime format: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, format, args, 0);
}
const Fake = struct {
    inner: f.Fake,
    fail_snapshot: bool = false,
    snapshot: bool = false,
    held: bool = false,
    fn command(ptr: ?*anyopaque, alloc: std.mem.Allocator, args: []const [:0]const u8) ![]const u8 {
        const self: *Fake = @ptrCast(@alignCast(ptr.?));
        if (std.mem.eql(u8, args[0], "/sbin/zfs")) {
            if (std.mem.eql(u8, args[1], "snapshot")) {
                try expect(!self.inner.activated);
                if (self.fail_snapshot) return error.ForcedSnapshotFailure;
                self.snapshot = true;
            } else if (std.mem.eql(u8, args[1], "hold")) {
                try expect(self.snapshot and !self.inner.activated);
                self.held = true;
            }
            if (std.mem.eql(u8, args[1], "get")) return "1234567890\n";
            return "";
        }
        if (std.mem.eql(u8, args[0], "/sbin/bectl") and std.mem.eql(u8, args[1], "activate")) try expect(self.held);
        return f.Fake.command(&self.inner, alloc, args);
    }
};
pub fn arguments() !void {
    if (!@hasField(u.Options, "quiet")) return error.SealImplementationMissing;
    const options = try u.parse(&.{ "verify", "--quiet" });
    try expect(options.quiet);
    try std.testing.expectError(error.InvalidArguments, u.parse(&.{ "status", "--quiet" }));
    try std.testing.expectError(error.InvalidArguments, u.parse(&.{ "verify", "--restart" }));
}
pub fn installation(fail: bool) !void {
    const fixture = try f.Fixture.init(false);
    defer fixture.deinit();
    const ctx = try fixture.output();
    defer _ = c.close(ctx.out);
    var fake = Fake{ .inner = .{ .f = fixture }, .fail_snapshot = fail };
    const result = u.engine.install(ctx, .{ .action = .install, .operand = fixture.archive }, snap, .{ .data = &fake, .execute = Fake.command });
    if (fail) try std.testing.expectError(error.ForcedSnapshotFailure, result) else try expect(try result == 0);
    try expect(fake.inner.activated == !fail);
    if (!fail) try expect(fake.snapshot and fake.held);
}
fn hash(bytes: []const u8) [64]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return std.fmt.bytesToHex(result, .lower);
}
pub fn comparison() !void {
    if (!@hasDecl(u, "seals")) return error.SealImplementationMissing;
    const fixture = try f.Fixture.init(false);
    defer fixture.deinit();
    const ctx = try fixture.output();
    defer _ = c.close(ctx.out);
    const root = try u.engine.Root.open(a, fixture.root, false);
    defer root.close();
    try root.write("/usr/bin/changed", "built", 0o555);
    try root.write("/usr/bin/missing", "built", 0o555);
    try root.write("/etc/owner", "owner before install", 0o644);
    try root.write("/etc/owner.rmxos-new", "stock", 0o644);
    try root.write("/var/db/rmxos/manifest.tsv", try fmt("rmx-overlay-v1\nbase={s}\n{s}\t0555\t/usr/bin/changed\n{s}\t0555\t/usr/bin/missing\n{s}\t0644\t/etc/owner\n", .{ "a" ** 64, hash("built"), hash("built"), hash("stock") }), 0o444);
    try root.write("/var/db/rmxos/directories.tsv", "rmx-directories-v1\n0755\t0\t0\t/usr/lib/seal-empty\n", 0o444);
    try root.write("/var/db/rmxos/conflicts.tsv", "/etc/owner\t/etc/owner.rmxos-new\n", 0o444);
    try root.createDirectory(.{ .path = "/usr/lib/seal-empty", .mode = 0o755, .uid = 0, .gid = 0 });
    const path = try fmt("{s}/sealed-copy", .{fixture.path});
    _ = try u.capture(a, &.{ "/bin/cp", "-a", fixture.root, path });
    const sealed = try u.engine.Root.open(a, path, false);
    defer sealed.close();
    try expect(try u.seals.compare(ctx, root, sealed, false) == 0);
    try root.write("/usr/bin/changed", "drift", 0o555);
    try root.remove("/usr/bin/missing");
    try expect(c.rmdir(try fmt("{s}/usr/lib/seal-empty", .{fixture.root})) == 0);
    try root.write("/usr/lib/seal-empty", "wrong type", 0o644);
    try root.write("/etc/owner", "later owner edit", 0o644);
    try root.write("/var/db/runtime-only", "runtime", 0o644);
    try expect(try u.seals.compare(ctx, root, sealed, false) == 1);
    const output = try u.readPath(a, try fmt("{s}/output", .{fixture.path}));
    for ([_][]const u8{ "modified /usr/bin/changed", "missing /usr/bin/missing", "type-changed /usr/lib/seal-empty", "expected-owner-change /etc/owner", "drift=3 expected_owner_changes=1" }) |needle| try expect(std.mem.indexOf(u8, output, needle) != null);
    try expect(std.mem.indexOf(u8, output, "runtime-only") == null);
    const quiet = try fmt("{s}/quiet", .{fixture.path});
    const fd = c.open(quiet, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    try expect(fd >= 0);
    defer _ = c.close(fd);
    var qctx = ctx;
    qctx.out = fd;
    try expect(try u.seals.compare(qctx, root, sealed, true) == 1);
    try expect(std.mem.eql(u8, try u.readPath(a, quiet), "3\n"));
}
test "verify arguments" {
    try arguments();
}
test "seal held before activation" {
    try installation(false);
}
test "snapshot failure prevents activation" {
    try installation(true);
}
test "seal comparison clean drift owner edits quiet and runtime scope" {
    try comparison();
}

const Metadata = struct {
    present: bool = true,
    released: bool = false,
    destroyed: bool = false,
    fn command(ptr: ?*anyopaque, _: std.mem.Allocator, args: []const [:0]const u8) ![]const u8 {
        const self: *Metadata = @ptrCast(@alignCast(ptr.?));
        try expect(std.mem.eql(u8, args[0], "/sbin/zfs"));
        if (std.mem.eql(u8, args[1], "list")) return if (self.present) "zroot/ROOT/rmxos-aaaaaaaaaaaa@sealed\t1234567890\t1234567890\n" else "";
        if (std.mem.eql(u8, args[1], "get")) return if (std.mem.eql(u8, args[args.len - 2], "org.rmxos:seal-guid")) "-\n" else "1234567890\n";
        if (std.mem.eql(u8, args[1], "holds")) return "zroot/ROOT/rmxos-aaaaaaaaaaaa@sealed\tsoftwareupdate\tdate\n";
        if (std.mem.eql(u8, args[1], "release")) {
            self.released = true;
            return "";
        }
        if (std.mem.eql(u8, args[1], "destroy")) {
            try expect(self.released);
            self.destroyed = true;
            self.present = false;
            return "";
        }
        return error.UnexpectedCommand;
    }
};
pub fn metadata() !void {
    if (!@hasDecl(u, "seals")) return error.SealImplementationMissing;
    const fixture = try f.Fixture.init(false);
    defer fixture.deinit();
    const ctx = try fixture.output();
    defer _ = c.close(ctx.out);
    var fake = Metadata{};
    const backend = u.engine.Backend{ .data = &fake, .execute = Metadata.command };
    try u.seals.status(ctx, snap, backend);
    try expect(std.mem.indexOf(u8, try u.readPath(a, try fmt("{s}/output", .{fixture.path})), "seal_taken_unix=1234567890") != null);
    try u.seals.release(a, backend, snap.dataset.?);
    try expect(fake.released and fake.destroyed);
    fake.present = false;
    try expect(try u.seals.verify(ctx, snap, backend, false) == 3);
    var nonroot = snap;
    nonroot.uid = 501;
    try expect(try u.seals.verify(ctx, nonroot, backend, false) == 2);
    var candidates = try u.seals.directoryCandidates(a, "M\tF\t/tmp/root/usr/bin/a\t(+1)\nR\t/\t/tmp/root/usr/lib/old\t/tmp/root/usr/lib/new\n", "/tmp/root");
    defer candidates.deinit();
    try expect(candidates.contains("/usr/bin/a") and candidates.get("/usr/lib/old").?);
    try std.testing.expectError(error.InvalidZFSDiff, u.seals.directoryCandidates(a, "garbled", ""));
}
test "seal status timestamp release legacy absence and root refusal" {
    try metadata();
}
