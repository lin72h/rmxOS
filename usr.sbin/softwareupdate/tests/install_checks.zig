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
    return packDirectories(path, old, new, baseline, null);
}
fn packDirectories(path: [:0]const u8, old: []const File, new: []const File, baseline: bool, dirs: ?[]const u8) !void {
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
    if (dirs) |bytes| try addArchive(w, "./directories.tsv", bytes, 0o444, null);
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
pub const Fixture = struct {
    path: [:0]const u8,
    root: [:0]const u8,
    archive: [:0]const u8,
    pub fn init(baseline: bool) !Fixture {
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
    pub fn deinit(f: Fixture) void {
        std.Io.Dir.cwd().deleteTree(io, f.path) catch {};
    }
    pub fn output(f: Fixture) !u.Context {
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
pub const Fake = struct {
    f: Fixture,
    commands: std.ArrayList([]const u8) = .empty,
    clone: ?[:0]const u8 = null,
    fail_hints: bool = false,
    activated: bool = false,
    pub fn command(data: ?*anyopaque, alloc: std.mem.Allocator, argv: []const [:0]const u8) anyerror![]const u8 {
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
pub fn declaredDirectories() !void {
    const f = try Fixture.init(false);
    defer f.deinit();
    const custom = try fmt("{s}/usr/lib/owner-made", .{f.root});
    const changed = try fmt("{s}/usr/lib/owner-mode", .{f.root});
    try std.Io.Dir.cwd().createDirPath(io, custom);
    try std.Io.Dir.cwd().createDirPath(io, changed);
    try check(c.chmod(custom, 0o710) == 0 and c.chmod(changed, 0o700) == 0);
    var before: c.struct_stat = undefined;
    try check(c.stat(custom, &before) == 0);
    try packDirectories(f.archive, &old_files, &new_files, false, "rmx-directories-v1\n0755\t0\t0\t/usr/lib/swift\n0755\t0\t0\t/usr/lib/owner-made\n0755\t0\t0\t/usr/lib/owner-mode\n");
    var fake = Fake{ .f = f };
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    try check(try e.install(ctx, .{ .action = .install, .operand = f.archive }, snap, .{ .data = &fake, .execute = Fake.command }) == 0);
    try check(c.access(try fmt("{s}/usr/lib/swift", .{f.root}), c.F_OK) != 0);
    var created: c.struct_stat = undefined;
    try check(c.stat(try fmt("{s}/usr/lib/swift", .{fake.clone.?}), &created) == 0);
    try check(created.st_mode & c.S_IFMT == c.S_IFDIR and created.st_mode & 0o7777 == 0o755);
    // Owned host fixtures suppress privileged ownership just as U2's tests do;
    // the installed ATF case runs as root and checks the native root:wheel result.
    try check(created.st_uid == c.geteuid() and created.st_gid == before.st_gid);
    for ([_]struct { path: []const u8, mode: u32 }{ .{ .path = "/usr/lib/owner-made", .mode = 0o710 }, .{ .path = "/usr/lib/owner-mode", .mode = 0o700 } }) |row| {
        var st: c.struct_stat = undefined;
        try check(c.stat(try fmt("{s}{s}", .{ fake.clone.?, row.path }), &st) == 0);
        try check(st.st_mode & 0o7777 == row.mode and st.st_uid == before.st_uid and st.st_gid == before.st_gid);
    }
    // root:wheel is the declared identity even on an unprivileged fixture host.
    const saved = try u.readPath(a, try fmt("{s}/var/db/rmxos/directories.tsv", .{fake.clone.?}));
    try check(std.mem.indexOf(u8, saved, "0755\t0\t0\t/usr/lib/swift\n") != null);
    if (c.geteuid() == 0) try check(created.st_uid == 0 and created.st_gid == 0);
}
pub fn systemEtc() !void {
    const f = try Fixture.init(false);
    defer f.deinit();
    const old = [_]File{ .{ .path = "/etc/mtree/BSD.usr.dist", .data = "old mtree" }, .{ .path = "/etc/defaults/rc.conf", .data = "old defaults" }, .{ .path = "/etc/rc.conf", .data = "old owner config" } };
    const new = [_]File{ .{ .path = "/etc/mtree/BSD.usr.dist", .data = "new mtree" }, .{ .path = "/etc/defaults/rc.conf", .data = "new defaults" }, .{ .path = "/etc/rc.conf", .data = "new owner config" } };
    for (old) |row| try put(try fmt("{s}{s}", .{ f.root, row.path }), "owner different", 0o644);
    try put(try fmt("{s}/var/db/rmxos/manifest.tsv", .{f.root}), try manifest(&old), 0o444);
    try pack(f.archive, &old, &new, false);
    var fake = Fake{ .f = f };
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    try check(try e.install(ctx, .{ .action = .install, .operand = f.archive }, snap, .{ .data = &fake, .execute = Fake.command }) == 0);
    const clone = try e.Root.open(a, fake.clone.?, false);
    defer clone.close();
    try check(eq((try clone.read("/etc/mtree/BSD.usr.dist")).?, "new mtree"));
    try check(eq((try clone.read("/etc/defaults/rc.conf")).?, "new defaults"));
    try check(try clone.stat("/etc/mtree/BSD.usr.dist.rmxos-new") == null);
    try check(try clone.stat("/etc/defaults/rc.conf.rmxos-new") == null);
    try check(eq((try clone.read("/etc/rc.conf")).?, "owner different"));
    try check(eq((try clone.read("/etc/rc.conf.rmxos-new")).?, "new owner config"));
    const running = try f.rootOpen();
    defer running.close();
    try check(eq((try running.read("/etc/mtree/BSD.usr.dist")).?, "owner different"));
}
test "declared missing directories created only in clone existing directories unchanged" {
    try declaredDirectories();
}
test "system etc subtrees replaced owner etc remains a sidecar" {
    try systemEtc();
}
pub fn directoryValidation() !void {
    const valid = try e.directories(a, "rmx-directories-v1\n01777\t0\t0\t/var/tmp\n0755\t0\t0\t/\n");
    try check(valid.len == 2 and eq(valid[0].path, "/") and valid[1].mode == 0o1777);
    for ([_][]const u8{
        "unknown\n",                                                                  "rmx-directories-v1\n0755\t0\t0\t/usr/../etc\n",
        "rmx-directories-v1\n0755\t-1\t0\t/usr/lib/swift\n",                          "rmx-directories-v1\n0755\t0\t4294967295\t/usr/lib/swift\n",
        "rmx-directories-v1\n07777\t0\t0\t/usr/lib/swift\textra\n",                   "rmx-directories-v1\n8888\t0\t0\t/usr/lib/swift\n",
        "rmx-directories-v1\n0755\t0\t0\t/usr/lib/swift\n\n0755\t0\t0\t/var/empty\n",
    }) |bad| try std.testing.expectError(error.InvalidDirectories, e.directories(a, bad));
    try std.testing.expectError(error.DuplicateDirectory, e.directories(a, "rmx-directories-v1\n0755\t0\t0\t/usr/lib/swift\n0755\t0\t0\t/usr/lib/swift\n"));
    const f = try Fixture.init(false);
    defer f.deinit();
    const ctx = try f.output();
    defer _ = c.close(ctx.out);
    try packDirectories(f.archive, &old_files, &new_files, false, "rmx-directories-v1\n0755\t0\t0\t/usr/bin/keep\n");
    var fake = Fake{ .f = f };
    try std.testing.expectError(error.DirectoryFileCollision, e.install(ctx, .{ .action = .install, .operand = f.archive }, snap, .{ .data = &fake, .execute = Fake.command }));
    try check(fake.commands.items.len == 0);
    // Explicit directories cannot traverse a symlink or overwrite a file.
    try std.Io.Dir.cwd().createDirPath(io, try fmt("{s}/usr/lib", .{f.root}));
    try check(c.symlink("/tmp", try fmt("{s}/usr/lib/swift", .{f.root})) == 0);
    try packDirectories(f.archive, &old_files, &new_files, false, "rmx-directories-v1\n0755\t0\t0\t/usr/lib/swift\n");
    try std.testing.expectError(error.NondirectoryDestination, e.install(ctx, .{ .action = .install, .operand = f.archive }, snap, .{ .data = &fake, .execute = Fake.command }));
    try check(fake.commands.items.len == 0);
}
pub fn directoryMetadata() !void {
    const f = try Fixture.init(false);
    defer f.deinit();
    const native = try e.Root.open(a, f.root, true);
    defer native.close();
    const dir = e.Directory{ .path = "/usr/lib/metadata-check", .mode = 0o750, .uid = c.geteuid(), .gid = c.getegid() };
    try native.createDirectory(dir);
    const st = (try native.directory(dir.path)).?;
    try check(st.st_uid == dir.uid and st.st_gid == dir.gid and st.st_mode & 0o7777 == dir.mode);
    try native.createDirectory(.{ .path = dir.path, .mode = 0o700, .uid = 0, .gid = 0 });
    const after = (try native.directory(dir.path)).?;
    try check(st.st_ino == after.st_ino and st.st_uid == after.st_uid and st.st_gid == after.st_gid and st.st_mode == after.st_mode);
}
test "directory metadata grammar and unsafe destinations refuse before clone" {
    try directoryValidation();
}
test "native directory metadata applied only to newly created directories" {
    try directoryMetadata();
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
/// Explicit disposable-guest flow, separate from the installed whole plan.
pub fn guestStageRestart() !void {
    try check(c.geteuid() == 0);
    const s = u.snapshot(a);
    try check(u.refusal(s, null) == null);
    try check(!eq(std.fs.path.basename(s.dataset.?), "rmxos-bbbbbbbbbbbb"));
    const marker_path = "/usr/share/softwareupdate-op190";
    var old: std.ArrayList(File) = .empty;
    var new: std.ArrayList(File) = .empty;
    // A fixture update records the real boot identities, without modifying them.
    for ([_][:0]const u8{ "/boot/RMXOS-RELEASE/kernel", "/boot/RMXOS-RELEASE/mach.ko", "/sbin/launchd" }) |path| {
        var st: c.struct_stat = undefined;
        try check(c.stat(path, &st) == 0);
        const row = File{ .path = path, .data = try u.readPath(a, path), .mode = @intCast(st.st_mode & 0o7777) };
        try old.append(a, row);
        try new.append(a, row);
    }
    try put(marker_path, "running original", 0o444);
    try old.append(a, .{ .path = marker_path, .data = "running original", .mode = 0o444 });
    try new.append(a, .{ .path = marker_path, .data = "confirmed candidate", .mode = 0o444 });
    try put("/var/db/rmxos/manifest.tsv", try manifest(old.items), 0o444);
    try put("/var/db/rmxos/commit", initial ++ "\n", 0o444);
    try put("/var/db/softwareupdate/confirm-delay", "15\n", 0o444);
    try put("/var/db/softwareupdate/op190-previous", std.fs.path.basename(s.dataset.?), 0o444);
    const archive: [:0]const u8 = "/var/tmp/op190-update.tar";
    try pack(archive, old.items, new.items, false);
    _ = try observed(&.{ "/usr/sbin/softwareupdate", "status" });
    _ = try observed(&.{ "/sbin/bectl", "list" });
    try u.write(1, "op190 boot=1 fixture=ready restart_via=softwareupdate\n");
    const args = [_:null]?[*:0]const u8{ "/usr/sbin/softwareupdate", "--install", archive, "--restart", null };
    _ = c.execv(args[0].?, @ptrCast(@constCast(&args)));
    return error.RestartExecFailed;
}
pub fn guestVerifyConfirmed() !void {
    try check(c.geteuid() == 0);
    const s = u.snapshot(a);
    try check(s.dataset != null and eq(std.fs.path.basename(s.dataset.?), "rmxos-bbbbbbbbbbbb"));
    for (0..120) |_| {
        if (c.access("/var/db/rmxos/pending-target", c.F_OK) != 0) break;
        _ = c.usleep(500000);
    }
    try check(c.access("/var/db/rmxos/pending-target", c.F_OK) != 0);
    try check(eq(std.mem.trim(u8, try u.readPath(a, "/var/db/rmxos/confirmed-target"), "\n"), "rmxos-bbbbbbbbbbbb"));
    try check(eq(try u.readPath(a, "/usr/share/softwareupdate-op190"), "confirmed candidate"));
    const bes = try u.lifecycle.listing(a, try u.capture(a, &.{ "/sbin/bectl", "list", "-H" }));
    const prev = try u.readPath(a, "/var/db/softwareupdate/op190-previous");
    var persistent = false;
    var kept = false;
    for (bes) |be| {
        try check(std.mem.indexOfScalar(u8, be.flags, 'T') == null);
        if (eq(be.name, "rmxos-bbbbbbbbbbbb")) persistent = std.mem.indexOfScalar(u8, be.flags, 'N') != null and std.mem.indexOfScalar(u8, be.flags, 'R') != null;
        if (eq(be.name, prev)) kept = true;
    }
    try check(persistent and kept);
    const trail = try u.readPath(a, "/var/db/softwareupdate/history.tsv");
    try check(std.mem.indexOf(u8, trail, "\tconfirmed\t") != null);
    try check(std.mem.indexOf(u8, trail, "good-boot-failed") == null);
    try check(c.access("/var/db/softwareupdate/boot-check-failed", c.F_OK) != 0);
    try u.write(1, "op190 boot=2 current=rmxos-bbbbbbbbbbbb persistent=yes pending=none previous=kept good_boot=passed auto_confirm=passed\n");
    _ = try observed(&.{ "/usr/sbin/softwareupdate", "status" });
    _ = try observed(&.{ "/sbin/bectl", "list" });
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
