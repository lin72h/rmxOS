const std = @import("std");
pub const engine = @import("install.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const downloads = @import("download.zig");
pub const seals = @import("seal.zig");
pub const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("sys/file.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/stat.h");
    @cInclude("dirent.h");
    @cInclude("fcntl.h");
});
pub const help =
    \\Usage: softwareupdate --list [--catalog DIR]
    \\       softwareupdate --download [NAME|all] [--catalog DIR]
    \\       softwareupdate --install [--restart] [--no-auto-confirm] [NAME|/path/to/update.tar]
    \\       softwareupdate --history
    \\       softwareupdate status | confirm | cancel
    \\       softwareupdate rollback [--restart]
    \\       softwareupdate verify [--quiet]
    \\       softwareupdate --help
    \\Options: --recommended, --all, --os-only (all updates are OS updates)
    \\Local --install verifies and stages a clone for one boot. Signing is not implemented.
    \\Set catalog_url in /etc/softwareupdate.conf or pass --catalog DIR|URL.
    \\
;
pub const Action = enum { help, list, download, install, history, status, confirm, cancel, rollback, boot_check, verify };
pub const Options = struct { action: Action, catalog: ?[]const u8 = null, operand: ?[]const u8 = null, restart: bool = false, no_auto_confirm: bool = false, quiet: bool = false };
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn parse(args: []const []const u8) !Options {
    var action: ?Action = null;
    var o = Options{ .action = .help };
    var catalog_seen = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        var found: ?Action = null;
        inline for (.{ .{ "--help", Action.help }, .{ "--list", Action.list }, .{ "--download", Action.download }, .{ "--install", Action.install }, .{ "--history", Action.history }, .{ "status", Action.status }, .{ "confirm", Action.confirm }, .{ "cancel", Action.cancel }, .{ "rollback", Action.rollback }, .{ "--boot-check", Action.boot_check }, .{ "verify", Action.verify } }) |entry| {
            if (eq(a, entry[0])) found = entry[1];
        }
        if (found) |f| {
            if (action != null) return error.InvalidArguments;
            action = f;
        } else if (eq(a, "--catalog")) {
            if (catalog_seen or i + 1 == args.len) return error.InvalidArguments;
            i += 1;
            if (args[i].len == 0 or args[i][0] == '-') return error.InvalidArguments;
            o.catalog = args[i];
            catalog_seen = true;
        } else if (eq(a, "--quiet")) {
            if (o.quiet) return error.InvalidArguments;
            o.quiet = true;
        } else if (eq(a, "--restart")) {
            if (o.restart) return error.InvalidArguments;
            o.restart = true;
        } else if (eq(a, "--no-auto-confirm")) {
            if (o.no_auto_confirm) return error.InvalidArguments;
            o.no_auto_confirm = true;
        } else if (eq(a, "--recommended") or eq(a, "--all") or eq(a, "--os-only")) {
            // Every catalog entry updates the OS.
        } else {
            if (a.len == 0 or a[0] == '-' or o.operand != null) return error.InvalidArguments;
            o.operand = a;
        }
    }
    o.action = action orelse return error.InvalidArguments;
    if (o.quiet and o.action != .verify) return error.InvalidArguments;
    if (o.operand != null and o.action != .download and o.action != .install) return error.InvalidArguments;
    if (o.restart and o.action != .install and o.action != .rollback) return error.InvalidArguments;
    if (o.no_auto_confirm and o.action != .install) return error.InvalidArguments;
    if (catalog_seen and o.action != .list and o.action != .download and o.action != .install) return error.InvalidArguments;
    if (o.operand) |v| {
        if (!eq(v, "all") and !validName(v) and !(o.action == .install and std.fs.path.isAbsolute(v))) return error.InvalidArguments;
    }
    return o;
}
pub fn hex(value: []const u8, len: usize) bool {
    if (value.len != len) return false;
    for (value) |ch| if (!(ch >= '0' and ch <= '9') and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}
pub fn validName(value: []const u8) bool {
    return value.len == 18 and std.mem.startsWith(u8, value, "rmxos-") and hex(value[6..], 12);
}
pub const Snapshot = struct { uid: u32, dataset: ?[]const u8, listing: ?[]const u8 };
pub fn refusal(s: Snapshot, target: ?[]const u8) ?[]const u8 {
    if (s.uid != 0) return "root required";
    const ds = s.dataset orelse return "running root is not ZFS";
    var parts = std.mem.splitScalar(u8, ds, '/');
    const pool = parts.next() orelse return "running root is not a boot environment";
    const parent = parts.next() orelse return "running root is not a boot environment";
    const current = parts.next() orelse return "running root is not a boot environment";
    if (pool.len == 0 or !eq(parent, "ROOT") or current.len == 0 or parts.next() != null) return "running root is not a boot environment";
    const listing = s.listing orelse return "cannot read boot environment list";
    var recognized = false;
    var pending = false;
    var exists = false;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, "\t ");
        const name = fields.next() orelse continue;
        const flags = fields.next() orelse return "malformed boot environment list";
        if (eq(name, current) and std.mem.indexOfScalar(u8, flags, 'N') != null) recognized = true;
        if (std.mem.indexOfScalar(u8, flags, 'T') != null) pending = true;
        if (target) |t| {
            if (eq(name, t)) exists = true;
        }
    }
    if (!recognized) return "running root is not recognized by bectl";
    if (pending) return "one-time boot already pending";
    if (target) |t| {
        if (eq(t, current)) return "target is running";
        if (exists) return "target already exists";
    }
    return null;
}
pub const From = struct { commit: []const u8, manifest_sha256: []const u8 };
pub const Update = struct { name: []const u8, commit: []const u8, sha256: []const u8, from: From, date: []const u8, size: u64, restart_required: bool };
pub const Catalog = struct { format: []const u8, updates: []const Update };
pub fn catalog(a: std.mem.Allocator, data: []const u8) !std.json.Parsed(Catalog) {
    const p = try std.json.parseFromSlice(Catalog, a, data, .{ .allocate = .alloc_always });
    errdefer p.deinit();
    if (!eq(p.value.format, "rmxos-catalog-v1")) return error.MalformedCatalog;
    for (p.value.updates, 0..) |u, i| {
        if (!validName(u.name) or !hex(u.commit, 40) or !eq(u.name[6..], u.commit[0..12]) or !hex(u.sha256, 64) or !hex(u.from.commit, 40) or !hex(u.from.manifest_sha256, 64) or u.date.len == 0) return error.MalformedCatalog;
        for (p.value.updates[0..i]) |old| if (eq(old.name, u.name)) return error.MalformedCatalog;
    }
    return p;
}
pub fn applies(u: Update, commit: ?[]const u8, manifest: ?[]const u8) bool {
    return commit != null and manifest != null and eq(u.from.commit, commit.?) and eq(u.from.manifest_sha256, manifest.?);
}
pub const Context = struct {
    allocator: std.mem.Allocator,
    root: []const u8 = "",
    out: c_int = 1,
    err: c_int = 2,
    pub fn path(self: Context, p: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.allocator, "{s}{s}", .{ self.root, p }, 0);
    }
    pub fn print(self: Context, fd: c_int, comptime fmt: []const u8, args: anytype) !void {
        try write(fd, try std.fmt.allocPrint(self.allocator, fmt, args));
    }
    pub fn diagnostic(self: Context, text: []const u8) !u8 {
        try self.print(self.err, "softwareupdate: {s}\n", .{text});
        return 1;
    }
    pub fn read(self: Context, p: []const u8) ![]const u8 {
        return readPath(self.allocator, try self.path(p));
    }
    pub fn optional(self: Context, p: []const u8) !?[]const u8 {
        return self.read(p) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
    }
};
pub fn write(fd: c_int, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        at += @intCast(n);
    }
}
pub fn readFd(a: std.mem.Allocator, fd: c_int, limit: usize) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        const size: usize = @intCast(n);
        if (bytes.items.len + size > limit) return error.InputTooLarge;
        try bytes.appendSlice(a, buf[0..size]);
    }
    return bytes.toOwnedSlice(a);
}
pub fn readPath(a: std.mem.Allocator, path: [:0]const u8) ![]const u8 {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) {
        if (std.c.errno(fd) == .NOENT) return error.FileNotFound;
        return error.OpenFailed;
    }
    defer _ = c.close(fd);
    return readFd(a, fd, 32 * 1024 * 1024);
}
pub fn hashPath(a: std.mem.Allocator, path: [:0]const u8) ![]const u8 {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) {
        if (std.c.errno(fd) == .NOENT) return error.FileNotFound;
        return error.OpenFailed;
    }
    defer _ = c.close(fd);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        h.update(buf[0..@intCast(n)]);
    }
    return a.dupe(u8, &std.fmt.bytesToHex(h.finalResult(), .lower));
}
pub fn capture(a: std.mem.Allocator, argv: []const [:0]const u8) ![]const u8 {
    var pipes: [2]c_int = undefined;
    if (c.pipe(&pipes) != 0) return error.PipeFailed;
    defer _ = c.close(pipes[0]);
    const av = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |v, i| av[i] = v.ptr;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipes[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = c.close(pipes[0]);
        _ = c.dup2(pipes[1], 1);
        _ = c.close(pipes[1]);
        const nullfd = c.open("/dev/null", c.O_WRONLY);
        if (nullfd >= 0) _ = c.dup2(nullfd, 2);
        _ = c.execv(av[0].?, @ptrCast(av.ptr));
        c._exit(127);
    }
    _ = c.close(pipes[1]);
    // Always reap, including a read/size failure.
    var wait_status: c_int = 0;
    const bytes = readFd(a, pipes[0], 32 * 1024 * 1024) catch |err| {
        _ = c.kill(pid, 15);
        _ = c.waitpid(pid, &wait_status, 0);
        return err;
    };
    if (c.waitpid(pid, &wait_status, 0) != pid or wait_status != 0) return error.CommandFailed;
    return bytes;
}
pub fn dataset(mounts: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, "\t ");
        const ds = f.next() orelse continue;
        const mount = f.next() orelse continue;
        const fs = f.next() orelse continue;
        if (eq(mount, "/") and eq(fs, "zfs")) return ds;
    }
    return null;
}
pub fn snapshot(a: std.mem.Allocator) Snapshot {
    const mounts = capture(a, &.{ "/sbin/mount", "-p" }) catch return .{ .uid = c.geteuid(), .dataset = null, .listing = null };
    return .{ .uid = c.geteuid(), .dataset = dataset(mounts), .listing = capture(a, &.{ "/sbin/bectl", "list", "-H" }) catch null };
}
fn trim(v: []const u8) []const u8 {
    return std.mem.trim(u8, v, " \r\n\t");
}
pub fn list(ctx: Context, directory: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}/catalog.json", .{directory}, 0);
    const data = try readPath(ctx.allocator, path);
    const p = try catalog(ctx.allocator, data);
    defer p.deinit();
    // Validate the whole local publication before printing any update.
    for (p.value.updates) |u| {
        const archive = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}/{s}/update.tar", .{ directory, u.name }, 0);
        var st: c.struct_stat = undefined;
        if (c.lstat(archive, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG or st.st_size < 0 or @as(u64, @intCast(st.st_size)) != u.size) return error.InvalidArchive;
        const sidecar = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}.sha256", .{archive}, 0);
        const checksum = trim(try readPath(ctx.allocator, sidecar));
        if (!eq(checksum, u.sha256)) return error.ChecksumSidecarMismatch;
    }
    try renderCatalog(ctx, p.value);
}
pub fn renderCatalog(ctx: Context, value: Catalog) !void {
    const installed = try ctx.optional("/var/db/rmxos/commit");
    const digest = hashPath(ctx.allocator, try ctx.path("/var/db/rmxos/manifest.tsv")) catch |err| if (err == error.FileNotFound) null else return err;
    for (value.updates) |item| try ctx.print(ctx.out, "{s} applies={s} commit={s} from={s} size={d} restart_required={} date={s}\n", .{ item.name, if (applies(item, if (installed) |v| trim(v) else null, digest)) "yes" else "no", item.commit, item.from.commit, item.size, item.restart_required, item.date });
    if (value.updates.len == 0) try write(ctx.out, "No updates in catalog.\n");
}
pub fn history(ctx: Context, tail: bool) !void {
    const path = try ctx.path("/var/db/softwareupdate/history.tsv");
    const file = c.fopen(path, "r") orelse {
        if (std.c.errno(@as(c_int, -1)) == .NOENT) {
            try write(ctx.out, "history=none\n");
            return;
        }
        return error.OpenFailed;
    };
    defer _ = c.fclose(file);
    var buf: [8192]u8 = undefined;
    if (!tail) {
        while (true) {
            const n = c.fread(&buf, 1, buf.len, file);
            if (n == 0) break;
            try write(ctx.out, buf[0..n]);
        }
    } else {
        var rows: [10]?[]const u8 = @splat(null);
        var n: usize = 0;
        var line: std.ArrayList(u8) = .empty;
        while (true) {
            const ch = c.fgetc(file);
            if (ch == c.EOF) break;
            if (line.items.len >= 65536) return error.HistoryLineTooLong;
            try line.append(ctx.allocator, @intCast(ch));
            if (ch == '\n') {
                if (rows[n % 10]) |old| ctx.allocator.free(old);
                rows[n % 10] = try line.toOwnedSlice(ctx.allocator);
                n += 1;
            }
        }
        if (line.items.len != 0) {
            if (rows[n % 10]) |old| ctx.allocator.free(old);
            rows[n % 10] = try line.toOwnedSlice(ctx.allocator);
            n += 1;
        }
        for (n - @min(n, 10)..n) |i| try write(ctx.out, rows[i % 10].?);
    }
    if (c.ferror(file) != 0) return error.ReadFailed;
}
fn sidecars(ctx: Context, relative: []const u8, depth: usize) !usize {
    if (depth > 64) return error.DirectoryTooDeep;
    const path = try ctx.path(relative);
    const dir = c.opendir(path) orelse {
        try ctx.print(ctx.out, "sidecars_unreadable={s}\n", .{relative});
        return 0;
    };
    defer _ = c.closedir(dir);
    var count: usize = 0;
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (eq(name, ".") or eq(name, "..")) continue;
        const child = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ relative, name });
        var st: c.struct_stat = undefined;
        const childz = try ctx.path(child);
        if (c.lstat(childz, &st) != 0) return error.StatFailed;
        if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) count += try sidecars(ctx, child, depth + 1);
        if (std.mem.endsWith(u8, name, ".rmxos-new")) {
            try ctx.print(ctx.out, "sidecar={s}\n", .{child});
            count += 1;
        }
    }
    return count;
}
pub fn status(ctx: Context, s: Snapshot) !void {
    const ds = s.dataset orelse "unavailable";
    try ctx.print(ctx.out, "root_dataset={s}\nrunning_be={s}\n", .{ ds, if (s.dataset != null) std.fs.path.basename(ds) else "unavailable" });
    for ([_][]const u8{ "/boot/RMXOS-RELEASE/kernel", "/boot/RMXOS-RELEASE/mach.ko", "/sbin/launchd" }) |path| {
        const digest = hashPath(ctx.allocator, try ctx.path(path)) catch |err| if (err == error.FileNotFound) "unavailable" else return err;
        try ctx.print(ctx.out, "sha256 {s}={s}\n", .{ path, digest });
    }
    inline for (.{ .{ "commit", "/var/db/rmxos/commit" }, .{ "confirmed", "/var/db/rmxos/confirmed-target" } }) |field| {
        const value = try ctx.optional(field[1]);
        try ctx.print(ctx.out, "{s}={s}\n", .{ field[0], if (value) |v| trim(v) else "none" });
    }
    try lifecycle.status(ctx, s);
    const n = try sidecars(ctx, "/etc", 0);
    try ctx.print(ctx.out, "sidecars={d}\nboot_environments:\n{s}\nhistory_last_10:\n", .{ n, s.listing orelse "unavailable" });
    try history(ctx, true);
}
pub fn run(ctx: Context, args: []const []const u8, s: Snapshot) !u8 {
    return runWithBackend(ctx, args, s, .{});
}
pub fn runWithBackend(ctx: Context, args: []const []const u8, s: Snapshot, backend: engine.Backend) !u8 {
    const o = parse(args) catch return ctx.diagnostic("invalid arguments; use --help");
    if (o.action == .install and o.operand != null) {
        if (refusal(s, null)) |reason| return ctx.diagnostic(reason);
        var local = o;
        if (!std.fs.path.isAbsolute(o.operand.?)) {
            if (refusal(s, o.operand.?)) |reason| return ctx.diagnostic(reason);
            local.operand = try downloads.incoming(ctx, o.operand.?);
        }
        return engine.install(ctx, local, s, backend);
    }
    if (o.action == .list or o.action == .download) {
        if (o.action == .download and s.uid != 0) return ctx.diagnostic("root required");
        const source = downloads.location(ctx, o.catalog) catch |err| {
            if (err == error.MissingCatalogSetting) return ctx.diagnostic("catalog_url is not set in /etc/defaults/softwareupdate.conf or /etc/softwareupdate.conf; use --catalog");
            return err;
        };
        if (o.action == .list) try downloads.list(ctx, source) else try downloads.download(ctx, source, o.operand);
        return 0;
    }
    switch (o.action) {
        .help => try write(ctx.out, help),
        .history => try history(ctx, false),
        .status => {
            try status(ctx, s);
            if (ctx.root.len == 0 or backend.data != null) try seals.status(ctx, s, backend);
        },
        .verify => return seals.verify(ctx, s, backend, o.quiet) catch |err| {
            _ = try ctx.diagnostic(@errorName(err));
            return 2;
        },
        .confirm, .cancel, .rollback => return lifecycle.command(ctx, o.action, s, .{}, o.restart),
        .boot_check => return lifecycle.bootCheck(ctx, .{}),
        else => {
            if (refusal(s, null)) |reason| return ctx.diagnostic(reason);
            // Named updates already specify their future BE. Local archives expose
            // only commit through tar's read-only stdout mode; never extract files.
            if (o.action == .download or o.action == .install) {
                var target: ?[]const u8 = null;
                if (o.operand) |operand| {
                    if (validName(operand)) target = operand else if (std.fs.path.isAbsolute(operand)) {
                        const archive = try ctx.allocator.dupeZ(u8, operand);
                        const raw = try capture(ctx.allocator, &.{ "/usr/bin/tar", "-xOf", archive, "./commit" });
                        const commit = trim(raw);
                        if (!hex(commit, 40)) return ctx.diagnostic("invalid archive commit");
                        target = try std.fmt.allocPrint(ctx.allocator, "rmxos-{s}", .{commit[0..12]});
                    }
                }
                if (refusal(s, target)) |reason| return ctx.diagnostic(reason);
            }
            return ctx.diagnostic("not yet implemented");
        },
    }
    return 0;
}
