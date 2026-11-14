// rmxos-install(8): write a whole fresh disk in the shape every update leaves.
// GPT with an ESP, optional swap and one ZFS partition; the pool as the image
// builder creates its own; softwareupdate's engine receives the full stream,
// clones, holds rmxos-head and sets bootfs; then Data, its seeds and the ESP.
// UEFI only. Runs as root; RMXOS_SU_FIXTURE confines a host run to md disks
// backed below that directory and rmxsu pools.
const std = @import("std");
const engine = @import("engine");
const sys = engine.sys;
const catalog = engine.catalog;
const Ctx = sys.Ctx;
const dirent = @cImport(@cInclude("dirent.h"));

pub const usage =
    \\usage: rmxos-install --disk DISK --catalog DIR|URL --hostname NAME --user NAME
    \\                     --key FILE --console LIST [--pool NAME] [--altroot DIR]
    \\                     [--swap SIZE] [--zone NAME] [--erase]
    \\
;

pub const Options = struct {
    disk: []const u8 = "",
    catalog: []const u8 = "",
    hostname: []const u8 = "",
    user: []const u8 = "",
    key: []const u8 = "",
    console: []const u8 = "",
    pool: []const u8 = "rmxroot",
    altroot: []const u8 = "/mnt",
    swap: ?[]const u8 = null,
    zone: []const u8 = "UTC",
    erase: bool = false,
};

const esp_size = "260m";
// Data as the image builder makes it (sealed_compose.ex receive_and_clone).
pub const data_sets = [_]struct { name: []const u8, mountpoint: []const u8, insensitive: bool = false }{
    .{ .name = "private", .mountpoint = "/private" },
    .{ .name = "Users", .mountpoint = "/Users", .insensitive = true },
    .{ .name = "Library", .mountpoint = "/Library" },
    .{ .name = "local", .mountpoint = "/usr/local" },
};
const consoles = [_][]const u8{ "comconsole", "efi", "vidconsole", "nullconsole", "spinconsole" };

const value_options = [_][]const u8{ "--disk", "--catalog", "--hostname", "--user", "--key", "--console", "--pool", "--altroot", "--zone", "--swap" };

pub fn parse(args: []const []const u8) !Options {
    var o = Options{};
    var seen = [_]bool{false} ** (value_options.len + 1);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (eq(x, "--erase")) {
            if (seen[value_options.len]) return error.Usage;
            seen[value_options.len] = true;
            o.erase = true;
            continue;
        }
        const k = for (value_options, 0..) |name, n| {
            if (eq(x, name)) break n;
        } else return error.Usage;
        if (seen[k] or i + 1 == args.len) return error.Usage;
        seen[k] = true;
        i += 1;
        const v = args[i];
        switch (k) {
            0 => o.disk = v,
            1 => o.catalog = v,
            2 => o.hostname = v,
            3 => o.user = v,
            4 => o.key = v,
            5 => o.console = v,
            6 => o.pool = v,
            7 => o.altroot = v,
            8 => o.zone = v,
            else => o.swap = v,
        }
    }
    for ([_][]const u8{ o.disk, o.catalog, o.hostname, o.user, o.key, o.console }) |v| if (v.len == 0) return error.Usage;
    return o;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// Every check that needs no command and no write.
pub fn validate(o: Options) !void {
    if (!wholeDisk(diskName(o.disk))) return error.InvalidDisk;
    if (!hostname(o.hostname)) return error.InvalidHostname;
    if (!userName(o.user)) return error.InvalidUser;
    if (!consoleList(o.console)) return error.InvalidConsole;
    if (o.pool.len == 0 or o.pool.len > 64 or !std.ascii.isAlphabetic(o.pool[0])) return error.InvalidPool;
    for (o.pool) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return error.InvalidPool;
    if (o.altroot.len < 2 or o.altroot[0] != '/' or std.mem.trimEnd(u8, o.altroot, "/").len == 0 or std.mem.indexOf(u8, o.altroot, "..") != null) return error.InvalidAltroot;
    if (o.zone.len == 0 or o.zone[0] == '/' or std.mem.indexOf(u8, o.zone, "..") != null) return error.InvalidZone;
    for (o.zone) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "/_+-", ch) == null) return error.InvalidZone;
    if (o.swap) |s| {
        if (s.len < 2) return error.InvalidSwap;
        for (s[0 .. s.len - 1]) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidSwap;
        if (std.mem.indexOfScalar(u8, "kmgKMG", s[s.len - 1]) == null) return error.InvalidSwap;
    }
}
pub fn diskName(d: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, d, "/dev/")) d[5..] else d;
}
// A whole disk (md0, ada0, nda1, vtbd0), never a partition or label.
fn wholeDisk(d: []const u8) bool {
    var i: usize = 0;
    while (i < d.len and std.ascii.isLower(d[i])) i += 1;
    if (i == 0 or i == d.len) return false;
    for (d[i..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}
pub fn hostname(h: []const u8) bool {
    if (h.len == 0 or h.len > 253) return false;
    var labels = std.mem.splitScalar(u8, h, '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63 or l[0] == '-' or l[l.len - 1] == '-') return false;
        for (l) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}
pub fn userName(u: []const u8) bool {
    if (u.len == 0 or u.len > 32 or !(std.ascii.isLower(u[0]) or u[0] == '_')) return false;
    for (u) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_' and ch != '-') return false;
    return !eq(u, "root") and !eq(u, "toor");
}
fn consoleList(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |p| {
        var known = false;
        for (consoles) |k| known = known or eq(p, k);
        if (!known) return false;
    }
    return true;
}
// One OpenSSH public key line.
pub fn publicKey(text: []const u8) ![]const u8 {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidKey;
    for (line) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidKey;
    for ([_][]const u8{ "ssh-", "ecdsa-sha2-", "sk-" }) |p| if (std.mem.startsWith(u8, line, p) and std.mem.indexOfScalar(u8, line, ' ') != null) return line;
    return error.InvalidKey;
}

// The ESP's loader.env: the machine's console lines and nothing else.
pub fn loaderEnv(a: std.mem.Allocator, console: []const u8) ![]const u8 {
    const serial = std.mem.indexOf(u8, console, "comconsole") != null;
    return std.fmt.allocPrint(a, "console={s}\n{s}", .{ console, if (serial) "comconsole_speed=115200\n" else "" });
}
// rc.conf: the template's lines, ours replacing any of the same name.
pub fn rcConf(a: std.mem.Allocator, template: []const u8, host: []const u8) ![]const u8 {
    const keys = [_][]const u8{ "hostname", "ifconfig_DEFAULT", "sshd_enable", "kld_list" };
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var ours = false;
        for (keys) |k| ours = ours or (std.mem.startsWith(u8, line, k) and line.len > k.len and line[k.len] == '=');
        if (!ours) try out.print(a, "{s}\n", .{line});
    }
    // mac_do lets the first user become root with mdo(1); sysctl.conf holds its rule.
    try out.print(a, "hostname=\"{s}\"\nifconfig_DEFAULT=\"DHCP\"\nsshd_enable=\"YES\"\nkld_list=\"mac_do\"\n", .{host});
    return out.items;
}
pub fn macDoRule(a: std.mem.Allocator, uid: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "security.mac.do.rules=\"uid={s}>uid=0,gid=*,+gid=*\"\n", .{uid});
}

const Run = struct {
    ctx: Ctx,
    o: Options,
    disk: []const u8,
    has_table: bool,
    made: std.ArrayList([]const u8) = .empty,
    esp: []const u8 = "",
    pool_created: bool = false,
    esp_mounted: ?[]const u8 = null,

    fn did(self: *Run, comptime f: []const u8, args: anytype) !void {
        try self.made.append(self.ctx.a, try self.ctx.fmt(f, args));
    }
    fn cmd(self: *Run, argv: []const []const u8) ![]const u8 {
        return sys.capture(self.ctx, argv);
    }
    fn at(self: *Run, p: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.ctx.a, "{s}{s}", .{ std.mem.trimEnd(u8, self.o.altroot, "/"), p }, 0);
    }
};

pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = Ctx.init(a);
    const argv = init.args.toSlice(a) catch return 1;
    const o = parse(argv[1..]) catch {
        sys.writeAll(2, usage) catch {};
        sys.writeAll(2, "rmxos-install: invalid arguments; nothing written\n") catch {};
        return 2;
    };
    validate(o) catch |err| return refuse(ctx, "{s}; nothing written", .{@errorName(err)});
    return install(ctx, o) catch |err| refuse(ctx, "{s}{s}{s}; nothing written", .{ @errorName(err), if (sys.failure.len > 0) ": " else "", sys.failure });
}
fn refuse(ctx: Ctx, comptime f: []const u8, args: anytype) u8 {
    sys.writeAll(2, std.fmt.allocPrint(ctx.a, "rmxos-install: " ++ f ++ "\n", args) catch return 1) catch {};
    return 1;
}

fn install(ctx: Ctx, o: Options) !u8 {
    // Refusals before any write.
    const key = publicKey(sys.read(ctx.a, try ctx.z(o.key)) catch return refuse(ctx, "{s}: unreadable; nothing written", .{o.key})) catch
        return refuse(ctx, "{s}: not one OpenSSH public key line; nothing written", .{o.key});
    const loaded = catalog.load(ctx, o.catalog, false) catch |err| return refuse(ctx, "catalog {s}: {s}; nothing written", .{ o.catalog, @errorName(err) });
    const full = loaded.catalog.full orelse return refuse(ctx, "catalog {s} has no full stream; nothing written", .{o.catalog});
    const disk = diskName(o.disk);
    const checked = try diskRefusal(ctx, o, disk);
    if (checked.refusal) |why| return refuse(ctx, "{s}: {s}; nothing written", .{ disk, why });
    const pools = sys.capture(ctx, &.{ "/sbin/zpool", "list", "-H", "-o", "name" }) catch
        return refuse(ctx, "cannot read imported pool names; nothing written", .{});
    var names = std.mem.tokenizeAny(u8, pools, " \t\r\n");
    while (names.next()) |n| if (eq(n, o.pool)) return refuse(ctx, "a pool named {s} is already imported; nothing written", .{o.pool});
    if (ctx.fixture and !std.mem.startsWith(u8, o.pool, "rmxsu")) return refuse(ctx, "{s}: a host run acts only on rmxsu pools; nothing written", .{o.pool});
    if (ctx.fixture and !std.mem.startsWith(u8, o.altroot, try ctx.fmt("{s}/", .{ctx.root}))) return refuse(ctx, "{s}: a host run's alternate root lies below {s}; nothing written", .{ o.altroot, ctx.root });
    for ([_][]const u8{ o.altroot, try espDir(ctx, o) }) |d| if (!emptyOrAbsent(try ctx.z(d))) return refuse(ctx, "{s} is not an empty directory; nothing written", .{d});

    var r = Run{ .ctx = ctx, .o = o, .disk = disk, .has_table = checked.has_table };
    const clone = try ctx.fmt("{s}/ROOT/{s}", .{ o.pool, full.snapshot });
    steps(&r, key, loaded.source, loaded.catalog.lineage, full, clone) catch |err| {
        const cause = sys.failure;
        settle(&r);
        const list = try std.mem.join(ctx.a, ", ", r.made.items);
        return refuse(ctx, "{s}{s}{s}; made: {s}; left on {s} (rerun with --erase)", .{ @errorName(err), if (cause.len > 0) ": " else "", cause, if (list.len > 0) list else "nothing", disk });
    };
    ctx.out("Installed {s} on {s}: pool {s} boots {s}; first user {s}; console {s}.\n", .{ full.label, disk, o.pool, clone, o.user, o.console });
    return 0;
}

fn espDir(ctx: Ctx, o: Options) ![]const u8 {
    return ctx.fmt("{s}.esp", .{std.mem.trimEnd(u8, o.altroot, "/")});
}
fn emptyOrAbsent(p: [:0]const u8) bool {
    const dir = dirent.opendir(p) orelse return !sys.exists(p);
    defer _ = dirent.closedir(dir);
    while (dirent.readdir(dir)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!eq(name, ".") and !eq(name, "..")) return false;
    }
    return true;
}

pub const DiskCheck = struct { refusal: ?[]const u8 = null, has_table: bool = false };

// A failed command is null, distinct from a successful empty result.
pub const DiskLookups = struct {
    geom: ?[]const u8,
    tables: ?[]const u8,
    pools: ?[]const u8,
    mounts: ?[]const u8,
    swaps: ?[]const u8,
};

// conftxt is depth-first. A disk's subtree includes every layered provider,
// not just PART and LABEL; names outside that subtree must not match it.
fn diskProviders(a: std.mem.Allocator, disk: []const u8, text: []const u8) ![]const []const u8 {
    var providers: std.ArrayList([]const u8) = .empty;
    var root: ?usize = null;
    var previous: usize = 0;
    var rows = std.mem.tokenizeScalar(u8, text, '\n');
    while (rows.next()) |row| {
        var words = std.mem.tokenizeAny(u8, row, " \t\r");
        const first = words.next() orelse continue;
        const level = try std.fmt.parseInt(usize, first, 10);
        _ = words.next() orelse return error.GeomOutput;
        const name = words.next() orelse return error.GeomOutput;
        if (level > previous + 1) return error.GeomOutput;
        previous = level;
        if (root) |r| {
            if (level <= r) root = null;
        }
        if (eq(name, disk)) root = level;
        if (root != null) try providers.append(a, name);
    }
    if (providers.items.len == 0) return error.GeomOutput;
    return providers.items;
}

// Pure lookup check: unit tests supply successful text or failed lookups.
pub fn diskUse(a: std.mem.Allocator, disk: []const u8, lookups: DiskLookups) !DiskCheck {
    inline for (.{ .{ "geom", "GEOM tree" }, .{ "tables", "partition tables" }, .{ "pools", "imported pool status" }, .{ "mounts", "mounts" }, .{ "swaps", "swap" } }) |lookup| {
        if (@field(lookups, lookup[0]) == null) return .{ .refusal = "cannot read " ++ lookup[1] };
    }
    const providers = diskProviders(a, disk, lookups.geom.?) catch return .{ .refusal = "cannot read GEOM tree for disk" };
    var result = DiskCheck{};
    // Query all tables: successful absence is normal for a blank disk.
    // Querying a named blank disk instead returns a command failure.
    var rows = std.mem.splitScalar(u8, lookups.tables.?, '\n');
    while (rows.next()) |row| {
        var words = std.mem.tokenizeAny(u8, row, " \t\r");
        if (!eq(words.next() orelse continue, "=>")) continue;
        for (0..2) |_| _ = words.next() orelse return .{ .refusal = "cannot read partition tables" };
        const name = words.next() orelse return .{ .refusal = "cannot read partition tables" };
        _ = words.next() orelse return .{ .refusal = "cannot read partition tables" };
        if (eq(name, disk)) result.has_table = true;
    }
    for (providers) |p| {
        const path = try std.fmt.allocPrint(a, "/dev/{s}", .{p});
        const reason = if (hasWord(lookups.pools.?, path)) "is in an imported pool" else if (hasWord(lookups.mounts.?, path)) "is mounted" else if (hasWord(lookups.swaps.?, path)) "is in use as swap" else continue;
        result.refusal = try std.fmt.allocPrint(a, "{s} {s}", .{ path, reason });
        return result;
    }
    return result;
}

fn diskRefusal(ctx: Ctx, o: Options, disk: []const u8) !DiskCheck {
    const dev = try ctx.fmt("/dev/{s}", .{disk});
    if (!sys.exists(try ctx.z(dev))) return .{ .refusal = "no such disk" };
    if (ctx.fixture) {
        if (!std.mem.startsWith(u8, disk, "md")) return .{ .refusal = "a host run writes only md disks" };
        const list = sys.capture(ctx, &.{ "/sbin/mdconfig", "-l", "-v", "-u", disk[2..] }) catch return .{ .refusal = "cannot read attached md" };
        // md0  vnode  8192M  /path/disk.img  <label>
        var cols = std.mem.tokenizeAny(u8, list, " \t\r\n");
        for (0..3) |_| _ = cols.next();
        const backing = cols.next() orelse "";
        if (!std.mem.startsWith(u8, backing, try ctx.fmt("{s}/", .{ctx.root}))) return .{ .refusal = "a host run writes only an md backed below its fixture directory" };
    }
    const checked = try diskUse(ctx.a, disk, .{
        .geom = sys.capture(ctx, &.{ "/sbin/sysctl", "-n", "kern.geom.conftxt" }) catch null,
        .tables = sys.capture(ctx, &.{ "/sbin/gpart", "show", "-p" }) catch null,
        .pools = sys.capture(ctx, &.{ "/sbin/zpool", "status", "-P" }) catch null,
        .mounts = sys.capture(ctx, &.{ "/sbin/mount", "-p" }) catch null,
        .swaps = sys.capture(ctx, &.{ "/sbin/swapctl", "-l" }) catch null,
    });
    if (checked.refusal != null) return checked;
    if (!o.erase) {
        if (checked.has_table) return .{ .refusal = "holds a partition table (--erase to overwrite it)" };
        if (!try zeroEnds(ctx, dev)) return .{ .refusal = "is not empty (--erase to overwrite it)" };
    }
    return checked;
}
fn hasWord(text: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |w| if (eq(w, word)) return true;
    return false;
}

const mib = 1024 * 1024;
fn mediaSize(ctx: Ctx, dev: []const u8) !u64 {
    const text = try sys.capture(ctx, &.{ "/usr/sbin/diskinfo", dev });
    var cols = std.mem.tokenizeAny(u8, text, " \t\r\n");
    _ = cols.next();
    _ = cols.next();
    return std.fmt.parseInt(u64, cols.next() orelse return error.DiskInfo, 10);
}
// True when the first and last MiB of `dev` read as zeros.
fn zeroEnds(ctx: Ctx, dev: []const u8) !bool {
    const size = try mediaSize(ctx, dev);
    const fd = sys.c.open(try ctx.z(dev), sys.c.O_RDONLY);
    if (fd < 0) return error.OpenDisk;
    defer _ = sys.c.close(fd);
    const buf = try ctx.a.alloc(u8, mib);
    for ([_]u64{ 0, if (size > mib) size - mib else 0 }) |off| {
        const n = sys.c.pread(fd, buf.ptr, buf.len, @intCast(off));
        if (n < 0) return error.ReadDisk;
        for (buf[0..@intCast(n)]) |b| if (b != 0) return false;
    }
    return true;
}
// Zero the first and last MiB: no partition table or pool label survives.
fn wipeEnds(ctx: Ctx, dev: []const u8) !void {
    const size = try mediaSize(ctx, dev);
    const fd = sys.c.open(try ctx.z(dev), sys.c.O_WRONLY);
    if (fd < 0) return error.OpenDisk;
    defer _ = sys.c.close(fd);
    const buf = try ctx.a.alloc(u8, mib);
    @memset(buf, 0);
    for ([_]u64{ 0, if (size > mib) size - mib else 0 }) |off| {
        if (sys.c.pwrite(fd, buf.ptr, @min(buf.len, size), @intCast(off)) < 0) return error.WipeDisk;
    }
}

fn steps(r: *Run, key: []const u8, source: []const u8, lineage: []const u8, full: catalog.Full, clone: []const u8) !void {
    const ctx = r.ctx;
    const o = r.o;
    const disk = r.disk;
    if (o.erase) {
        if (r.has_table) _ = try r.cmd(&.{ "/sbin/gpart", "destroy", "-F", disk });
        try wipeEnds(ctx, try ctx.fmt("/dev/{s}", .{disk}));
        try r.did("erased {s}", .{disk});
    }
    // GPT, the ESP, optional swap and one ZFS partition. UEFI only.
    _ = try r.cmd(&.{ "/sbin/gpart", "create", "-s", "gpt", disk });
    try r.did("GPT on {s}", .{disk});
    const esp = try added(ctx, try r.cmd(&.{ "/sbin/gpart", "add", "-a", "1m", "-s", esp_size, "-t", "efi", disk }));
    r.esp = esp;
    try r.did("ESP {s}", .{esp});
    if (o.swap) |size| {
        const swap = try added(ctx, try r.cmd(&.{ "/sbin/gpart", "add", "-a", "1m", "-s", size, "-t", "freebsd-swap", disk }));
        try r.did("swap {s}", .{swap});
    }
    const part = try added(ctx, try r.cmd(&.{ "/sbin/gpart", "add", "-a", "1m", "-t", "freebsd-zfs", disk }));
    try r.did("ZFS partition {s}", .{part});
    try wipeEnds(ctx, try ctx.fmt("/dev/{s}", .{part}));
    _ = try r.cmd(&.{ "/sbin/newfs_msdos", "-F", "32", "-c", "1", try ctx.fmt("/dev/{s}", .{esp}) });
    try r.did("FAT32 filesystem on ESP {s}", .{esp});

    // The pool as the image builder creates its own.
    try sys.mkdirs(ctx.a, o.altroot);
    _ = try r.cmd(&.{ "/sbin/zpool", "create", "-R", o.altroot, "-o", "cachefile=none", "-O", "mountpoint=none", "-O", "atime=off", "-O", "compression=lz4", o.pool, try ctx.fmt("/dev/{s}", .{part}) });
    r.pool_created = true;
    try r.did("pool {s}", .{o.pool});

    // One engine: receive, clone, hold rmxos-head and bootfs.
    const env = try engine.open(ctx, .{ .pool = .{ .name = o.pool, .altroot = o.altroot } });
    if (try engine.installTarget(ctx, env, full.update(), source, lineage) != 0) {
        sys.failure = "the engine's install refused (its line above)";
        return error.EngineInstall;
    }
    try r.did("boot environment {s} (bootfs)", .{clone});

    // Data as the image builder makes it, populated from the base's template.
    _ = try r.cmd(&.{ "/sbin/zfs", "mount", clone });
    _ = try r.cmd(&.{ "/sbin/zfs", "create", "-o", "mountpoint=none", "-o", "canmount=off", try ctx.fmt("{s}/data", .{o.pool}) });
    for (data_sets) |d| {
        const ds = try ctx.fmt("{s}/data/{s}", .{ o.pool, d.name });
        const mp = try ctx.fmt("mountpoint={s}", .{d.mountpoint});
        if (d.insensitive)
            _ = try r.cmd(&.{ "/sbin/zfs", "create", "-o", "canmount=noauto", "-o", mp, "-o", "casesensitivity=insensitive", ds })
        else
            _ = try r.cmd(&.{ "/sbin/zfs", "create", "-o", "canmount=noauto", "-o", mp, ds });
        _ = try r.cmd(&.{ "/sbin/zfs", "mount", ds });
    }
    try r.did("Data {s}/data", .{o.pool});
    _ = try r.cmd(&.{ try r.at("/usr/libexec/rmxos-datasync"), "--template", try r.at("/System/Library/Templates/Data"), "--data", std.mem.trimEnd(u8, o.altroot, "/") });
    try r.did("Data populated", .{});

    try seeds(r, key, full.label, clone);
    try r.did("seeds", .{});
    try espFiles(r);
    try r.did("ESP files", .{});

    // Nothing stays mounted; the next import is the machine's own.
    _ = try r.cmd(&.{ "/sbin/zpool", "export", o.pool });
    r.pool_created = false;
    for ([_][]const u8{ o.altroot, try espDir(ctx, o) }) |d| _ = sys.c.rmdir(try ctx.z(d));
}

// gpart add prints "<provider> added".
fn added(ctx: Ctx, out: []const u8) ![]const u8 {
    var words = std.mem.tokenizeAny(u8, out, " \t\r\n");
    const name = words.next() orelse return error.GpartOutput;
    if (!eq(words.next() orelse "", "added")) return error.GpartOutput;
    return ctx.a.dupe(u8, name);
}

fn seeds(r: *Run, key: []const u8, label: []const u8, clone: []const u8) !void {
    const ctx = r.ctx;
    const o = r.o;
    const etc = try r.at("/private/etc");
    const rc = try r.at("/private/etc/rc.conf");
    try sys.replace(ctx.a, rc, try rcConf(ctx.a, sys.read(ctx.a, rc) catch "", o.hostname));

    // The first user: a key, no password; root locked.
    _ = try r.cmd(&.{ "/usr/sbin/pw", "-V", etc, "useradd", "-n", o.user, "-d", try ctx.fmt("/Users/{s}", .{o.user}), "-s", "/bin/sh", "-c", o.user, "-w", "no" });
    const shown = sys.trim(try r.cmd(&.{ "/usr/sbin/pw", "-V", etc, "usershow", "-n", o.user }));
    var fields = std.mem.splitScalar(u8, shown, ':');
    _ = fields.next();
    _ = fields.next();
    const uid = fields.next() orelse return error.UserShow;
    const gid = fields.next() orelse return error.UserShow;
    _ = try r.cmd(&.{ "/usr/sbin/pw", "-V", etc, "lock", "root" });
    _ = try r.cmd(&.{ "/usr/sbin/pwd_mkdb", "-d", etc, "-p", try r.at("/private/etc/master.passwd") });
    try r.did("user {s} (uid {s}), root locked", .{ o.user, uid });

    const u = try std.fmt.parseInt(u32, uid, 10);
    const g = try std.fmt.parseInt(u32, gid, 10);
    const home = try r.at(try ctx.fmt("/Users/{s}", .{o.user}));
    const ssh = try ctx.z(try ctx.fmt("{s}/.ssh", .{home}));
    const keys = try ctx.z(try ctx.fmt("{s}/.ssh/authorized_keys", .{home}));
    for ([_]struct { p: [:0]const u8, mode: sys.c.mode_t }{ .{ .p = home, .mode = 0o755 }, .{ .p = ssh, .mode = 0o700 } }) |d| {
        if (sys.c.mkdir(d.p, d.mode) != 0 and !sys.exists(d.p)) return error.Home;
        if (sys.c.chown(d.p, u, g) != 0 or sys.c.chmod(d.p, d.mode) != 0) return error.Home;
    }
    try sys.replace(ctx.a, keys, try ctx.fmt("{s}\n", .{key}));
    if (sys.c.chown(keys, u, g) != 0 or sys.c.chmod(keys, 0o600) != 0) return error.Home;

    // mdo(1) as root for the first user: mac_do (rc.conf kld_list) and its rule.
    const sysctl = try r.at("/private/etc/sysctl.conf");
    try sys.replace(ctx.a, sysctl, try ctx.fmt("{s}{s}", .{ sys.read(ctx.a, sysctl) catch "", try macDoRule(ctx.a, uid) }));

    const zone = sys.read(ctx.a, try r.at(try ctx.fmt("/usr/share/zoneinfo/{s}", .{o.zone}))) catch return error.UnknownZone;
    const localtime = try r.at("/private/etc/localtime");
    try sys.replace(ctx.a, localtime, zone);
    if (sys.c.chmod(localtime, 0o444) != 0) return error.Localtime;
    try sys.replace(ctx.a, try r.at("/private/var/db/zoneinfo"), try ctx.fmt("{s}\n", .{o.zone}));

    // The lifecycle state's first line, on the new Data.
    try engine.recordInstalled(.{ .a = ctx.a, .root = std.mem.trimEnd(u8, o.altroot, "/"), .fixture = ctx.fixture }, label, clone);
}

fn espFiles(r: *Run) !void {
    const ctx = r.ctx;
    const dir = try espDir(ctx, r.o);
    try sys.mkdirs(ctx.a, dir);
    _ = try r.cmd(&.{ "/sbin/mount_msdosfs", try ctx.fmt("/dev/{s}", .{r.esp}), dir });
    r.esp_mounted = dir;
    const loader = try sys.read(ctx.a, try r.at("/boot/loader.efi"));
    for ([_][]const u8{ "/EFI/BOOT/BOOTX64.EFI", "/efi/freebsd/loader.efi" }) |p|
        try sys.replace(ctx.a, try ctx.z(try ctx.fmt("{s}{s}", .{ dir, p })), loader);
    try sys.replace(ctx.a, try ctx.z(try ctx.fmt("{s}/efi/freebsd/loader.env", .{dir})), try loaderEnv(ctx.a, r.o.console));
    _ = try r.cmd(&.{ "/sbin/umount", dir });
    r.esp_mounted = null;
}

// After a failure: unmount and export, so the disk can be inspected or rerun.
fn settle(r: *Run) void {
    if (r.esp_mounted) |dir| _ = sys.run(r.ctx.a, &.{ "/sbin/umount", dir }, null) catch {};
    if (r.pool_created) {
        const out = sys.run(r.ctx.a, &.{ "/sbin/zpool", "export", "-f", r.o.pool }, null) catch null;
        if (out != null and out.?.status == 0) r.did("pool {s} exported", .{r.o.pool}) catch {};
    }
}

test {
    _ = @import("tests/unit.zig");
}
