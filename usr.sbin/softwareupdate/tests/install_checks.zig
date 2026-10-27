const std = @import("std");
const u = @import("update");
const e = u.engine;
const c = u.c;
const ar = e.ar;
const io = std.Io.Threaded.global_single_threaded.io();
const a = std.heap.page_allocator;
const base = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const initial = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const snap = u.Snapshot{ .uid = 0, .dataset = "zroot/ROOT/rmxos-aaaaaaaaaaaa", .listing = "rmxos-aaaaaaaaaaaa\tNR\t/\n" };
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn check(b: bool) !void {
    try std.testing.expect(b);
}
fn fmt(comptime f: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, f, args, 0);
}
fn hash(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}
const File = struct { path: []const u8, data: []const u8, mode: u32 = 0o644, link: ?[]const u8 = null, deleted: bool = false };
const old_files = [_]File{ .{ .path = "/etc/stock", .data = "old stock" }, .{ .path = "/etc/owner", .data = "old config" }, .{ .path = "/usr/bin/drop", .data = "drop", .mode = 0o555 }, .{ .path = "/usr/bin/local", .data = "old local", .mode = 0o555 }, .{ .path = "/usr/bin/keep", .data = "old keep", .mode = 0o555 } };
const new_files = [_]File{ .{ .path = "/etc/stock", .data = "new stock" }, .{ .path = "/etc/owner", .data = "new config" }, .{ .path = "/etc/absent", .data = "absent", .mode = 0o444 }, .{ .path = "/usr/bin/keep", .data = "new keep", .mode = 0o555 }, .{ .path = "/usr/bin/alias", .data = "new keep", .mode = 0o555, .link = "/usr/bin/keep" }, .{ .path = "/usr/sbin/obsolete", .data = "", .deleted = true } };
fn manifest(files: []const File) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, "rmx-overlay-v1\nbase=" ++ base ++ "\n");
    for (files) |f| {
        const mode = if (f.deleted) "delete" else try fmt("0{o}", .{f.mode});
        try bytes.appendSlice(a, try fmt("{s}\t{s}\t{s}\n", .{ hash(f.data), mode, f.path }));
    }
    return bytes.toOwnedSlice(a);
}
fn metalog(files: []const File) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, "#mtree\n");
    for (files) |f| {
        if (f.deleted) continue;
        try bytes.appendSlice(a, try fmt("./files{s} type=file uname=root gname=wheel mode=0{o}{s}\n", .{ f.path, f.mode, if (f.link) |p| try fmt(" contents=./files{s}", .{p}) else "" }));
    }
    return bytes.toOwnedSlice(a);
}
fn addArchive(w: ?*ar.struct_archive, name: []const u8, data: []const u8, mode: u32, link: ?[]const u8) !void {
    const entry = ar.archive_entry_new() orelse return error.ArchiveWrite;
    defer ar.archive_entry_free(entry);
    ar.archive_entry_set_pathname(entry, try a.dupeZ(u8, name));
    ar.archive_entry_set_filetype(entry, c.S_IFREG);
    ar.archive_entry_set_perm(entry, @intCast(mode));
    ar.archive_entry_set_uid(entry, 0);
    ar.archive_entry_set_gid(entry, 0);
    if (link) |p| {
        ar.archive_entry_set_hardlink(entry, try a.dupeZ(u8, p));
        ar.archive_entry_set_size(entry, 0);
    } else ar.archive_entry_set_size(entry, @intCast(data.len));
    try check(ar.archive_write_header(w, entry) == ar.ARCHIVE_OK);
    if (link == null) try check(ar.archive_write_data(w, data.ptr, data.len) == data.len);
}
pub fn pack(path: [:0]const u8, old: []const File, new: []const File, baseline: bool) !void {
    const w = ar.archive_write_new() orelse return error.ArchiveWrite;
    defer _ = ar.archive_write_free(w);
    try check(ar.archive_write_set_format_pax_restricted(w) == ar.ARCHIVE_OK);
    try check(ar.archive_write_open_filename(w, path) == ar.ARCHIVE_OK);
    try addArchive(w, "./manifest.tsv", try manifest(new), 0o444, null);
    try addArchive(w, "./previous.tsv", try manifest(old), 0o444, null);
    try addArchive(w, "./METALOG", try metalog(new), 0o444, null);
    try addArchive(w, "./commit", commit ++ "\n", 0o444, null);
    try addArchive(w, "./removals.json", "[\"/usr/sbin/obsolete\"]", 0o444, null);
    try addArchive(w, "./report.json", "{}\n", 0o444, null);
    if (baseline) try addArchive(w, "./baseline.tsv", try manifest(old_files[0..2]), 0o444, null);
    for (new) |f| if (!f.deleted and f.link == null) {
        try addArchive(w, try fmt("./files{s}", .{f.path}), f.data, f.mode, null);
    };
    for (new) |f| if (!f.deleted) {
        if (f.link) |p| try addArchive(w, try fmt("./files{s}", .{f.path}), "", f.mode, try fmt("./files{s}", .{p}));
    };
    try check(ar.archive_write_close(w) == ar.ARCHIVE_OK);
    try put(try fmt("{s}.sha256", .{path}), try u.hashPath(a, path), 0o644);
}
fn put(path: [:0]const u8, bytes: []const u8, mode: u32) !void {
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    _ = c.unlink(path);
    const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try u.write(fd, bytes);
    try check(c.fchmod(fd, @intCast(mode)) == 0);
}
const Fixture = struct {
    path: [:0]const u8,
    root: [:0]const u8,
    archive: [:0]const u8,
    fn init(baseline: bool) !Fixture {
        const path = try a.dupeZ(u8, "/tmp/softwareupdate-apply-XXXXXX");
        try check(c.mkdtemp(path) != null);
        errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        const root = try fmt("{s}/root", .{path});
        try std.Io.Dir.cwd().createDirPath(io, root);
        const f = Fixture{ .path = path, .root = root, .archive = try fmt("{s}/update.tar", .{path}) };
        try pack(f.archive, &old_files, &new_files, baseline);
        for (old_files) |row| try put(try fmt("{s}{s}", .{ root, row.path }), row.data, row.mode);
        try put(try fmt("{s}/etc/owner", .{root}), "owner edit", 0o644);
        try put(try fmt("{s}/usr/bin/local", .{root}), "local edit", 0o555);
        try put(try fmt("{s}/usr/bin/alias", .{root}), "new keep", 0o555);
        try put(try fmt("{s}/usr/sbin/obsolete", .{root}), "obsolete owner edit", 0o555);
        try put(try fmt("{s}/usr/local/bin/package", .{root}), "package", 0o755);
        try put(try fmt("{s}/home/owner/data", .{root}), "owner", 0o600);
        try std.Io.Dir.cwd().createDirPath(io, try fmt("{s}/boot/RMXOS-RELEASE", .{root}));
        try put(try fmt("{s}/boot/loader.conf.local", .{root}), "owner_setting=YES\n", 0o644);
        if (!baseline) try put(try fmt("{s}/var/db/rmxos/manifest.tsv", .{root}), try manifest(&old_files), 0o444);
        try put(try fmt("{s}/var/db/rmxos/commit", .{root}), initial ++ "\n", 0o444);
        return f;
    }
    fn deinit(f: Fixture) void {
        std.Io.Dir.cwd().deleteTree(io, f.path) catch {};
    }
    fn output(f: Fixture) !u.Context {
        const out = c.open(try fmt("{s}/output", .{f.path}), c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o600));
        if (out < 0) return error.OpenFailed;
        return .{ .allocator = a, .root = f.root, .out = out, .err = out };
    }
    fn rootOpen(f: Fixture) !e.Root {
        return e.Root.open(a, f.root, false);
    }
};
fn verifyFiles(root: e.Root) !void {
    try check(eq((try root.read("/etc/stock")).?, "new stock"));
    try check(eq((try root.read("/etc/owner")).?, "owner edit"));
    try check(eq((try root.read("/etc/owner.rmxos-new")).?, "new config"));
    try check(eq((try root.read("/usr/bin/local")).?, "local edit"));
    try check(try root.stat("/usr/bin/drop") == null);
    try check(try root.stat("/usr/sbin/obsolete") == null);
    const x = (try root.stat("/usr/bin/keep")).?;
    const y = (try root.stat("/usr/bin/alias")).?;
    try check(x.st_ino == y.st_ino and x.st_dev == y.st_dev and x.st_nlink == 2);
}
pub fn fileRules(baseline: bool) !void {
    const f = try Fixture.init(baseline);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const b = try e.load(arena.allocator(), f.archive);
    defer b.deinit();
    const root = try f.rootOpen();
    defer root.close();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    const p = try e.preflight(b, root);
    try e.apply(b, root, p, ctx);
    try e.saveState(b, root, p);
    try verifyFiles(root);
    try check(eq((try root.read("/var/db/rmxos/manifest.tsv")).?, b.new.bytes));
    // Exact repeat preserves bytes, inode, link count and mtimes, including state.
    const before = (try root.stat("/usr/bin/keep")).?;
    const state = (try root.stat("/var/db/rmxos/manifest.tsv")).?;
    const again = try e.preflight(b, root);
    try e.apply(b, root, again, ctx);
    try e.saveState(b, root, again);
    const after = (try root.stat("/usr/bin/keep")).?;
    const state_after = (try root.stat("/var/db/rmxos/manifest.tsv")).?;
    try check(before.st_ino == after.st_ino and before.st_mtim.tv_sec == after.st_mtim.tv_sec and before.st_nlink == after.st_nlink and state.st_ino == state_after.st_ino);
    const package = try u.readPath(a, try fmt("{s}/usr/local/bin/package", .{f.root}));
    try check(eq(package, "package"));
}
pub fn negative() !void {
    const f = try Fixture.init(false);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const b = try e.load(arena.allocator(), f.archive);
    defer b.deinit();
    const root = try f.rootOpen();
    defer root.close();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    var fake = Fake{ .f = f };
    try put(try fmt("{s}/etc/owner.rmxos-new", .{f.root}), "foreign sidecar", 0o644);
    try std.testing.expectError(error.SidecarDiffers, e.preflight(b, root));
    try std.testing.expectError(error.SidecarDiffers, e.install(ctx, .{ .action = .install, .operand = f.archive }, snap, .{ .data = &fake, .execute = Fake.command }));
    try check(fake.commands.items.len == 0);
    try check(eq((try root.read("/usr/bin/keep")).?, "old keep"));
    try check(try root.stat("/usr/bin/drop") != null);
    try root.remove("/etc/owner.rmxos-new");
    try root.write("/var/db/rmxos/manifest.tsv", "wrong previous\n", 0o444);
    try std.testing.expectError(error.InstalledManifestMismatch, e.preflight(b, root));
    try std.testing.expectError(error.InstalledManifestMismatch, e.install(ctx, .{ .action = .install, .operand = f.archive }, snap, .{ .data = &fake, .execute = Fake.command }));
    try check(fake.commands.items.len == 0);
    try put(try fmt("{s}.sha256", .{f.archive}), "0000000000000000000000000000000000000000000000000000000000000000", 0o644);
    try std.testing.expectError(error.ArchiveChecksumMismatch, e.load(arena.allocator(), f.archive));
    try std.testing.expectError(error.ArchiveChecksumMismatch, e.install(ctx, .{ .action = .install, .operand = f.archive }, snap, .{ .data = &fake, .execute = Fake.command }));
    try check(fake.commands.items.len == 0);
    try check(eq((try root.read("/usr/bin/keep")).?, "old keep"));
    try std.testing.expectError(error.OfflineRootRequired, e.Root.open(a, "/", false));
}
pub fn unsafe() !void {
    for ([_][]const u8{ "/etc/../passwd", "/usr/bin//bad", "/home/owner/data", "/usr/local/bin/pkg", "/etc/./bad", "/etc/trailing/" }) |p| try check(!e.safePath(p));
    const f = try Fixture.init(false);
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const b = try e.load(arena.allocator(), f.archive);
    defer b.deinit();
    const self_link = [_]File{.{ .path = "/usr/bin/self", .data = "bytes", .link = "/usr/bin/self" }};
    try pack(f.archive, &old_files, &self_link, false);
    try std.testing.expectError(error.InvalidArchiveHardlink, e.load(arena.allocator(), f.archive));
    const missing_link = [_]File{.{ .path = "/usr/bin/alias", .data = "bytes", .link = "/usr/bin/missing" }};
    try pack(f.archive, &old_files, &missing_link, false);
    try std.testing.expectError(error.InvalidArchiveHardlink, e.load(arena.allocator(), f.archive));
    const traversal = [_]File{.{ .path = "/etc/../escape", .data = "bytes" }};
    try pack(f.archive, &old_files, &traversal, false);
    try std.testing.expectError(error.InvalidArchivePath, e.load(arena.allocator(), f.archive));
    const bad_mode = [_]File{.{ .path = "/usr/bin/mode", .data = "bytes", .mode = 0o777 }};
    try pack(f.archive, &old_files, &bad_mode, false);
    try std.testing.expectError(error.InvalidMode, e.load(arena.allocator(), f.archive));
    try check(c.rename(try fmt("{s}/etc", .{f.root}), try fmt("{s}/real-etc", .{f.root})) == 0);
    try check(c.symlink("real-etc", try fmt("{s}/etc", .{f.root})) == 0);
    const root = try f.rootOpen();
    defer root.close();
    try std.testing.expectError(error.UnsafeParent, e.preflight(b, root));
}
const Fake = struct {
    f: Fixture,
    commands: std.ArrayList([]const u8) = .empty,
    clone: ?[:0]const u8 = null,
    fail_hints: bool = false,
    activated: bool = false,
    fn command(data: ?*anyopaque, alloc: std.mem.Allocator, argv: []const [:0]const u8) anyerror![]const u8 {
        const self: *Fake = @ptrCast(@alignCast(data.?));
        const args = try alloc.alloc([]const u8, argv.len);
        for (argv, 0..) |v, i| args[i] = v;
        try self.commands.append(a, try std.mem.join(a, " ", args));
        if (eq(argv[0], "/sbin/bectl")) {
            if (eq(argv[1], "create")) {
                const dir = try fmt("{s}/clone", .{self.f.path});
                try std.Io.Dir.cwd().createDirPath(io, dir);
                _ = try u.capture(alloc, &.{ "/bin/cp", "-a", try fmt("{s}/.", .{self.f.root}), dir });
                self.clone = dir;
            }
            if (eq(argv[1], "mount")) {
                try check(c.rmdir(argv[3]) == 0);
                try check(c.rename(self.clone.?, argv[3]) == 0);
                self.clone = try a.dupeZ(u8, argv[3]);
            }
            if (eq(argv[1], "unmount")) {
                const dir = try fmt("{s}/clone", .{self.f.path});
                try check(c.rename(self.clone.?, dir) == 0);
                self.clone = dir;
            }
            if (eq(argv[1], "activate")) {
                try check(eq(argv[2], "-t"));
                self.activated = true;
            }
        } else if (eq(argv[0], "/usr/sbin/kldxref") and self.fail_hints) return error.FakeHintsFailed;
        return "";
    }
};
pub fn orchestration(fail: bool) !void {
    const f = try Fixture.init(false);
    defer f.deinit();
    var fake = Fake{ .f = f, .fail_hints = fail };
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    const options = u.Options{ .action = .install, .operand = f.archive, .no_auto_confirm = true };
    if (fail) try std.testing.expectError(error.FakeHintsFailed, e.install(ctx, options, snap, .{ .data = &fake, .execute = Fake.command })) else try check(try e.install(ctx, options, snap, .{ .data = &fake, .execute = Fake.command }) == 0);
    try check(fake.activated == !fail);
    const running = try f.rootOpen();
    defer running.close();
    try check(eq((try running.read("/usr/bin/keep")).?, "old keep"));
    try check(try running.stat("/var/db/rmxos/pending-target") == null);
    const clone = try e.Root.open(a, fake.clone.?, false);
    defer clone.close();
    try verifyFiles(clone);
    if (fail) try check(eq((try clone.read("/var/db/rmxos/manifest.tsv")).?, try manifest(&old_files)));
    if (!fail) {
        try check(eq((try clone.read("/var/db/rmxos/pending-target")).?, "rmxos-bbbbbbbbbbbb\n"));
        try check(eq((try clone.read("/var/db/softwareupdate/no-auto-confirm")).?, "yes\n"));
        const loader = (try clone.read("/boot/loader.conf.local")).?;
        try check(std.mem.startsWith(u8, loader, "owner_setting=YES\n") and std.mem.indexOf(u8, loader, "zfs:zroot/ROOT/rmxos-bbbbbbbbbbbb") != null);
    }
    const joined = try std.mem.join(a, "\n", fake.commands.items);
    try check(std.mem.indexOf(u8, joined, "create -e rmxos-aaaaaaaaaaaa") != null and std.mem.indexOf(u8, joined, "kldxref") != null and std.mem.indexOf(u8, joined, "unmount") != null);
    if (!fail) try check(std.mem.indexOf(u8, joined, "activate -t") != null);
    const create = std.mem.indexOf(u8, joined, "create -e").?;
    const mount = std.mem.indexOf(u8, joined, "bectl mount").?;
    const hints = std.mem.indexOf(u8, joined, "kldxref").?;
    const unmount = std.mem.indexOf(u8, joined, "bectl unmount").?;
    try check(create < mount and mount < hints and hints < unmount);
    if (!fail) try check(unmount < std.mem.indexOf(u8, joined, "activate -t").?);
}
fn observed(argv: []const [:0]const u8) ![]const u8 {
    var pipes: [2]c_int = undefined;
    try check(c.pipe(&pipes) == 0);
    const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |v, i| args[i] = v.ptr;
    const pid = c.fork();
    try check(pid >= 0);
    if (pid == 0) {
        _ = c.close(pipes[0]);
        _ = c.dup2(pipes[1], 1);
        _ = c.dup2(pipes[1], 2);
        _ = c.close(pipes[1]);
        _ = c.execv(args[0].?, @ptrCast(args.ptr));
        c._exit(127);
    }
    _ = c.close(pipes[1]);
    defer _ = c.close(pipes[0]);
    const out = try u.readFd(a, pipes[0], 1024 * 1024);
    var code: c_int = 0;
    try check(c.waitpid(pid, &code, 0) == pid);
    try u.write(1, out);
    try check(code == 0);
    return out;
}
/// This case is explicitly selected only for the commissioned guest install.
pub fn guestInstall() !void {
    try check(c.geteuid() == 0);
    const f = try Fixture.init(false);
    defer f.deinit();
    const marker_path = "/usr/share/softwareupdate-op185";
    const before = File{ .path = marker_path, .data = "running original", .mode = 0o444 };
    const after = File{ .path = marker_path, .data = "candidate clone", .mode = 0o444 };
    var identities: [3][]const u8 = undefined;
    const core = [_][:0]const u8{ "/boot/RMXOS-RELEASE/kernel", "/boot/RMXOS-RELEASE/mach.ko", "/sbin/launchd" };
    for (core, 0..) |path, i| identities[i] = try u.hashPath(a, path);
    // The image currently has no installed identity. Establish this fixture's
    // own tiny manifest; no existing product file is listed for deletion.
    try put(marker_path, before.data, before.mode);
    try put("/var/db/rmxos/manifest.tsv", try manifest(&.{before}), 0o444);
    try put("/var/db/rmxos/commit", initial ++ "\n", 0o444);
    try pack(f.archive, &.{before}, &.{after}, false);
    _ = try observed(&.{ "/usr/sbin/softwareupdate", "--install", f.archive, "--no-auto-confirm" });
    const listing = try u.capture(a, &.{ "/sbin/bectl", "list", "-H" });
    try u.write(1, listing);
    try check(std.mem.indexOf(u8, listing, "rmxos-bbbbbbbbbbbb") != null);
    var rows = std.mem.tokenizeScalar(u8, listing, '\n');
    var temporary = false;
    while (rows.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        if (eq(fields.next() orelse "", "rmxos-bbbbbbbbbbbb")) {
            const flags = fields.next() orelse "";
            temporary = std.mem.indexOfScalar(u8, flags, 'T') != null and std.mem.indexOfScalar(u8, flags, 'N') == null;
        }
    }
    try check(temporary);
    const live = try u.readPath(a, marker_path);
    try check(eq(live, before.data));
    for (core, 0..) |path, i| try check(eq(try u.hashPath(a, path), identities[i]));
    try check(eq(try u.readPath(a, "/var/db/rmxos/manifest.tsv"), try manifest(&.{before})));
    const mount = try fmt("{s}/inspection", .{f.path});
    try std.Io.Dir.cwd().createDirPath(io, mount);
    _ = try u.capture(a, &.{ "/sbin/bectl", "mount", "rmxos-bbbbbbbbbbbb", mount });
    defer {
        _ = u.capture(a, &.{ "/sbin/bectl", "unmount", "rmxos-bbbbbbbbbbbb" }) catch {};
    }
    const root = try e.Root.open(a, mount, true);
    defer root.close();
    try check(eq((try root.read(marker_path)).?, after.data));
    try check(eq((try root.read("/var/db/rmxos/pending-target")).?, "rmxos-bbbbbbbbbbbb\n"));
    try check(eq((try root.read("/var/db/softwareupdate/no-auto-confirm")).?, "yes\n"));
    for ([_][]const u8{ "/var/db/rmxos/manifest.tsv", "/var/db/rmxos/commit", "/var/db/rmxos/conflicts.tsv", "/var/db/rmxos/archive.sha256", "/var/db/rmxos/previous-be", "/var/db/softwareupdate/history.tsv" }) |path| {
        const st = (try root.stat(path)).?;
        try check(st.st_uid == 0 and st.st_gid == 0);
    }
    try check(eq((try root.read("/var/db/rmxos/manifest.tsv")).?, try manifest(&.{after})));
    try check(eq((try root.read("/var/db/rmxos/commit")).?, commit ++ "\n"));
    try check(std.mem.indexOf(u8, (try root.read("/boot/loader.conf.local")).?, "rmxos-bbbbbbbbbbbb") != null);
    try u.write(1, "op185 guest clone=rmxos-bbbbbbbbbbbb selected=temporary candidate=verified state=verified running=unchanged\n");
    const status = try u.capture(a, &.{ "/usr/sbin/softwareupdate", "status" });
    try u.write(1, status);
}
test "first update baseline sidecars removals hardlinks exact repeat" {
    try fileRules(true);
}
test "second update sidecars removals hardlinks exact repeat" {
    try fileRules(false);
}
test "sidecar checksum previous refusals before mutation" {
    try negative();
}
test "unsafe paths and symlink parents" {
    try unsafe();
}
test "fake bectl clone apply hints activate order" {
    try orchestration(false);
}
test "failed kldxref retains clone and never activates" {
    try orchestration(true);
}
