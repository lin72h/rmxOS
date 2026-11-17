// Host unit tests: zig test (see Makefile's test target); no command runs.
const std = @import("std");
const ri = @import("../rmxos-install.zig");
const t = std.testing;
const owner = @import("../owner.zig");
const admin = @import("../rmxos-owner.zig");
const seed = @import("../rmxos-owner-seed.zig");

test "owner options are all supplied or all absent" {
    const bare = [_][]const u8{ "--disk", "md5", "--catalog", "/c", "--console", "efi" };
    try ri.validate(try ri.parse(&bare));
    for ([_][]const u8{ "--hostname", "--user", "--key" }) |name| {
        const partial = bare ++ [_][]const u8{ name, "x" };
        try t.expectError(error.Usage, ri.parse(&partial));
    }
    try t.expectError(error.Usage, ri.parse(&(bare ++ [_][]const u8{ "--hostname", "", "--user", "", "--key", "" })));
    try t.expectError(error.Usage, admin.parse(&.{ "--user", "lin" }));
    try t.expectError(error.InvalidHostname, admin.parse(&.{ "--user", "lin", "--hostname", "-bad", "--key", "/key" }));
    try t.expectError(error.InvalidUser, admin.parse(&.{ "--user", "root", "--hostname", "host", "--key", "/key" }));
    try t.expectError(error.InvalidAltroot, admin.parse(&.{ "--user", "lin", "--hostname", "host", "--key", "/key", "--altroot", "new" }));
    // macOS-style switches are not rmxos-owner options.
    try t.expectError(error.Usage, admin.parse(&.{ "-addUser", "lin", "-hostName", "host", "-sshPublicKey", "/key" }));
    try t.expectEqualStrings("/", (try admin.parse(&.{ "--hostname", "host", "--user", "lin", "--key", "/key" })).altroot);
    // The installer's owner options, in its order, mean the same here.
    const o = try admin.parse(&.{ "--hostname", "host-1.example", "--user", "lin", "--key", "/k.pub", "--altroot", "/new" });
    const i = try ri.parse(&.{ "--disk", "md5", "--catalog", "/c", "--console", "efi", "--hostname", "host-1.example", "--user", "lin", "--key", "/k.pub", "--altroot", "/new" });
    for ([_][2][]const u8{ .{ o.hostname, i.hostname }, .{ o.user, i.user }, .{ o.key, i.key }, .{ o.altroot, i.altroot } }) |pair| try t.expectEqualStrings(pair[1], pair[0]);
}

test "machine state contains no owner and owner formatting preserves installed bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const template = "zfs_enable=\"YES\"\nhostname=\"template\"\nkld_list=\"old\"\n";
    const machine = try owner.machineRcConf(a, template);
    try t.expectEqualStrings("zfs_enable=\"YES\"\nifconfig_DEFAULT=\"DHCP\"\nsshd_enable=\"YES\"\n", machine);
    try t.expectEqualStrings(try ri.rcConf(a, template, "host"), try owner.rcConf(a, machine, "host"));
}

const args = [_][]const u8{ "--disk", "md5", "--catalog", "/c", "--hostname", "host-1.example", "--user", "lin", "--key", "/k.pub", "--console", "comconsole,efi" };

const topology =
    \\0 MD md5 8589934592 512
    \\1 PART md5p1 8589934080 512
    \\2 ELI md5p1.eli 8589933568 512
    \\3 NOP md5p1.eli.nop 8589933568 512
    \\4 LABEL gpt/test 8589933568 512
    \\1 MIRROR mirror/test 8589933568 512
    \\0 MD md50 8589934592 512
    \\1 NOP md50.nop 8589934592 512
;
const lookups = ri.DiskLookups{ .geom = topology, .tables = "", .pools = "", .mounts = "", .swaps = "" };

test "disk use follows layered providers and exact words" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "md5", "md5p1", "md5p1.eli", "md5p1.eli.nop", "gpt/test", "mirror/test" }) |provider| {
        inline for (.{ .{ "pools", "is in an imported pool" }, .{ "mounts", "is mounted" }, .{ "swaps", "is in use as swap" } }) |field| {
            var inputs = lookups;
            @field(inputs, field[0]) = try std.fmt.allocPrint(a, "before\t/dev/{s}\nafter", .{provider});
            const result = try ri.diskUse(a, "md5", inputs);
            try t.expectEqualStrings(try std.fmt.allocPrint(a, "/dev/{s} {s}", .{ provider, field[1] }), result.refusal.?);
        }
    }
    var inputs = lookups;
    inputs.pools = "/dev/md50 /dev/md50.nop /dev/md5p1.eli.nop.extra prefix/dev/md5 /dev/md5suffix";
    try t.expect((try ri.diskUse(a, "md5", inputs)).refusal == null);
    inputs.geom = "0 MD md5 8192 512\n1 NOP md5.nop 8192 512\n0 MD md50 8192 512\n";
    inputs.pools = "/dev/md5.nop";
    try t.expectEqualStrings("/dev/md5.nop is in an imported pool", (try ri.diskUse(a, "md5", inputs)).refusal.?);
}

test "every failed lookup refuses even if other lookups are empty" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    inline for (.{ .{ "geom", "GEOM tree" }, .{ "tables", "partition tables" }, .{ "pools", "imported pool status" }, .{ "mounts", "mounts" }, .{ "swaps", "swap" } }) |field| {
        var inputs = lookups;
        @field(inputs, field[0]) = null;
        try t.expectEqualStrings("cannot read " ++ field[1], (try ri.diskUse(arena.allocator(), "md5", inputs)).refusal.?);
    }
}

test "GEOM lookup must describe the disk and valid levels" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "0 MD md50 8192 512\n", "broken", "0 MD\n", "0 MD md5 8192 512\n3 NOP md5.nop 8192 512\n" }) |geom| {
        var inputs = lookups;
        inputs.geom = geom;
        try t.expectEqualStrings("cannot read GEOM tree for disk", (try ri.diskUse(arena.allocator(), "md5", inputs)).refusal.?);
    }
}

test "table presence includes an empty GPT and matches the whole disk" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var inputs = lookups;
    inputs.tables = "=> 40 100 md50 GPT (1G)\n40 100 - free -\n";
    try t.expect(!(try ri.diskUse(arena.allocator(), "md5", inputs)).has_table);
    inputs.tables = "=> 40 100 md5 GPT (1G)\n40 100 - free -\n";
    try t.expect((try ri.diskUse(arena.allocator(), "md5", inputs)).has_table);
    inputs.tables = "=> 40 100\n";
    try t.expectEqualStrings("cannot read partition tables", (try ri.diskUse(arena.allocator(), "md5", inputs)).refusal.?);
}

test "options: required, each once, defaults" {
    const o = try ri.parse(&args);
    try t.expectEqualStrings("md5", o.disk);
    try t.expectEqualStrings("rmxroot", o.pool);
    try t.expectEqualStrings("/mnt", o.altroot);
    try t.expectEqualStrings("UTC", o.zone);
    try t.expect(o.swap == null and !o.erase);
    try ri.validate(o);
    try t.expectError(error.Usage, ri.parse(args[0 .. args.len - 2]));
    try t.expectError(error.Usage, ri.parse(&(args ++ [_][]const u8{ "--disk", "md6" })));
    try t.expectError(error.Usage, ri.parse(&(args ++ [_][]const u8{ "--erase", "--erase" })));
    try t.expectError(error.Usage, ri.parse(&(args ++ [_][]const u8{"--pool"})));
    try t.expectError(error.Usage, ri.parse(&(args ++ [_][]const u8{ "--bios", "x" })));
    const e = try ri.parse(&(args ++ [_][]const u8{ "--erase", "--swap", "2g", "--pool", "rmxsu584", "--altroot", "/stage/a" }));
    try t.expect(e.erase and std.mem.eql(u8, e.swap.?, "2g"));
    try ri.validate(e);
}

test "validation refuses before any command" {
    const base = try ri.parse(&args);
    const bad = [_]struct { field: []const u8, value: []const u8, err: anyerror }{
        .{ .field = "disk", .value = "md5p1", .err = error.InvalidDisk },
        .{ .field = "disk", .value = "gpt/efiboot0", .err = error.InvalidDisk },
        .{ .field = "disk", .value = "/dev/", .err = error.InvalidDisk },
        .{ .field = "hostname", .value = "-x", .err = error.InvalidHostname },
        .{ .field = "hostname", .value = "a..b", .err = error.InvalidHostname },
        .{ .field = "user", .value = "root", .err = error.InvalidUser },
        .{ .field = "user", .value = "Lin", .err = error.InvalidUser },
        .{ .field = "console", .value = "serial", .err = error.InvalidConsole },
        .{ .field = "pool", .value = "9pool", .err = error.InvalidPool },
        .{ .field = "altroot", .value = "/", .err = error.InvalidAltroot },
        .{ .field = "altroot", .value = "mnt", .err = error.InvalidAltroot },
        .{ .field = "zone", .value = "../etc", .err = error.InvalidZone },
        .{ .field = "swap", .value = "2x", .err = error.InvalidSwap },
    };
    for (bad) |b| {
        var o = base;
        inline for (.{ "disk", "hostname", "user", "console", "pool", "altroot", "zone" }) |f| {
            if (std.mem.eql(u8, b.field, f)) @field(o, f) = b.value;
        }
        if (std.mem.eql(u8, b.field, "swap")) o.swap = b.value;
        try t.expectError(b.err, ri.validate(o));
    }
    try t.expectEqualStrings("ada0", ri.diskName("/dev/ada0"));
}

test "public key: one OpenSSH line" {
    try t.expectEqualStrings("ssh-ed25519 AAAA lin@host", try ri.publicKey("ssh-ed25519 AAAA lin@host\n"));
    try t.expectError(error.InvalidKey, ri.publicKey("ssh-ed25519 AAAA a\nssh-rsa BBBB b\n"));
    try t.expectError(error.InvalidKey, ri.publicKey("-----BEGIN OPENSSH PRIVATE KEY-----\n"));
    try t.expectError(error.InvalidKey, ri.publicKey(""));
}

test "seed texts: loader.env console only, rc.conf, mac_do rule" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("console=comconsole,efi\ncomconsole_speed=115200\n", try ri.loaderEnv(a, "comconsole,efi"));
    try t.expectEqualStrings("console=efi\n", try ri.loaderEnv(a, "efi"));
    const rc = try ri.rcConf(a, "zfs_enable=\"YES\"\nhostname=\"old\"\n", "host-1");
    try t.expectEqualStrings("zfs_enable=\"YES\"\nhostname=\"host-1\"\nifconfig_DEFAULT=\"DHCP\"\nsshd_enable=\"YES\"\nkld_list=\"mac_do\"\n", rc);
    try t.expectEqualStrings("security.mac.do.rules=\"uid=1001>uid=0,gid=*,+gid=*\"\n", try ri.macDoRule(a, "1001"));
}

const engine = @import("engine");
const sys = engine.sys;
const dirent = @cImport(@cInclude("dirent.h"));

// A scratch directory below $TMPDIR (default /tmp); `clear` removes it.
fn scratch(a: std.mem.Allocator) ![:0]const u8 {
    const base = if (sys.c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp";
    const p = try std.fmt.allocPrintSentinel(a, "{s}/rmxos-install-unit-XXXXXX", .{std.mem.trimEnd(u8, base, "/")}, 0);
    if (sys.c.mkdtemp(p.ptr) == null) return error.Scratch;
    return p;
}
fn clear(a: std.mem.Allocator, p: [:0]const u8) void {
    const d = dirent.opendir(p) orelse {
        _ = sys.c.unlink(p);
        return;
    };
    var names: std.ArrayList([:0]const u8) = .empty;
    while (dirent.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        names.append(a, std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ p, name }, 0) catch continue) catch continue;
    }
    _ = dirent.closedir(d);
    for (names.items) |n| clear(a, n);
    _ = sys.c.rmdir(p);
}

test "ESP files: the engine's populate writes every loader path and loader.env" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const top = try scratch(a);
    defer clear(a, top);
    const ctx = sys.Ctx{ .a = a, .root = "", .fixture = true };
    const dir = try std.fmt.allocPrint(a, "{s}/esp", .{top});
    try engine.esp.populate(ctx, dir, "the root's loader\n", try ri.loaderEnv(a, "comconsole"));
    try t.expectEqualStrings("EFI/BOOT/BOOTX64.EFI", engine.esp.loaders[0]);
    try t.expectEqualStrings("efi/freebsd/loader.efi", engine.esp.loaders[1]);
    for (engine.esp.loaders ++ [_][]const u8{engine.esp.loader_env}, 0..) |rel, i| {
        const p = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, rel }, 0);
        const want = if (i < engine.esp.loaders.len) "the root's loader\n" else "console=comconsole\ncomconsole_speed=115200\n";
        try t.expectEqualStrings(want, try sys.read(a, p));
        try t.expect(!sys.exists(try std.fmt.allocPrintSentinel(a, "{s}.new", .{p}, 0)));
    }
    // A path that cannot be written names itself.
    const blocked = try std.fmt.allocPrint(a, "{s}/blocked", .{top});
    try sys.replace(a, try std.fmt.allocPrintSentinel(a, "{s}/EFI", .{blocked}, 0), "a file where a directory goes\n");
    try t.expectError(error.EspFiles, engine.esp.populate(ctx, blocked, "x", "y"));
    try t.expect(std.mem.startsWith(u8, sys.failure, "EFI/BOOT/BOOTX64.EFI: mkdir: "));
}

// Stands in for every command owner.applyWith runs: records each argv, fails
// the program named, answers usershow with this process's ids (so chown works
// unprivileged) and locks root in the scratch master.passwd as pw would.
const Recorder = struct {
    a: std.mem.Allocator,
    root: []const u8,
    fail: ?[]const u8 = null,
    calls: std.ArrayList([]const u8) = .empty,
    config: ?[]const u8 = null,
    pub fn capture(self: *Recorder, argv: []const []const u8) ![]const u8 {
        try self.calls.append(self.a, try std.mem.join(self.a, " ", argv));
        if (self.fail) |f| if (std.mem.eql(u8, argv[0], f)) return error.CommandFailed;
        const verb = if (argv.len > 3) argv[3] else "";
        if (std.mem.eql(u8, verb, "useradd")) {
            for (argv, 0..) |x, i| if (std.mem.eql(u8, x, "-C")) {
                self.config = try sys.read(self.a, try self.a.dupeZ(u8, argv[i + 1]));
            };
        }
        if (std.mem.eql(u8, verb, "usershow")) return std.fmt.allocPrint(self.a, "owner:*:{d}:{d}::0:0:owner:/Users/owner:/bin/sh\n", .{ sys.c.getuid(), sys.c.getgid() });
        if (std.mem.eql(u8, verb, "lock")) {
            const pw = try std.fmt.allocPrintSentinel(self.a, "{s}/private/etc/master.passwd", .{self.root}, 0);
            const text = try sys.read(self.a, pw);
            try t.expect(std.mem.startsWith(u8, text, "root::"));
            try sys.replace(self.a, pw, try std.fmt.allocPrint(self.a, "root:*LOCKED*:{s}", .{text["root:".len..]}));
        }
        return "";
    }
};
const root_line = "root::0:0::0:0:Charlie &:/root:/bin/sh\n";
const template_passwd = root_line ++ "toor:*:0:0::0:0:Bourne-again Superuser:/root:\n";
fn ownerRoot(a: std.mem.Allocator) ![:0]const u8 {
    const top = try scratch(a);
    for ([_][]const u8{ "/private/etc", "/Users", "/private/var/run", "/private/var/db/rmxos" }) |d| try sys.mkdirs(a, try std.fmt.allocPrint(a, "{s}{s}", .{ top, d }));
    try sys.replace(a, try std.fmt.allocPrintSentinel(a, "{s}/private/etc/master.passwd", .{top}, 0), template_passwd);
    try sys.replace(a, try std.fmt.allocPrintSentinel(a, "{s}/private/etc/rc.conf", .{top}, 0), "zfs_enable=\"YES\"\n");
    return top;
}
fn file(a: std.mem.Allocator, top: []const u8, rel: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ top, rel }, 0);
}

test "owner: live only on the running root, after the files and before the lock; pw logs nowhere elsewhere" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = sys.Ctx{ .a = a, .root = "", .fixture = false };
    // The exact root rmxos-owner defaults to and rmxos-owner-seed passes.
    try t.expect(owner.live(ctx, "/"));
    for ([_][]const u8{ "//", "/.", "/mnt", "/Users/me/wip-mach/stage/op647/fixture/mnt" }) |r| try t.expect(!owner.live(ctx, r));
    try t.expect(!owner.live(.{ .a = a, .root = "", .fixture = true }, "/"));
    try t.expectEqualStrings("logfile = no\n", try owner.pwConfig(a, ""));
    try t.expectEqualStrings("defaultclass = staff\nlogfile = no\n", try owner.pwConfig(a, "defaultclass = staff"));
    try t.expectEqualStrings("defaultclass = staff\nlogfile = no\n", try owner.pwConfig(a, "defaultclass = staff\n"));

    const v = owner.Values{ .hostname = "op647", .user = "owner", .key = "ssh-ed25519 AAAAC3Nza owner@op647\n" };
    const uid = try std.fmt.allocPrint(a, "{d}", .{sys.c.getuid()});
    const rule = try owner.ruleValue(a, uid);
    const live = try owner.liveCommands(a, "op647", uid);
    try t.expectEqualStrings("/bin/hostname op647", try std.mem.join(a, " ", live[0]));
    try t.expectEqualStrings("/sbin/kldload -n mac_do", try std.mem.join(a, " ", live[1]));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "/sbin/sysctl security.mac.do.rules={s}", .{rule}), try std.mem.join(a, " ", live[2]));

    // The running system: every command, in order.
    {
        const top = try ownerRoot(a);
        defer clear(a, top);
        const etc = try std.fmt.allocPrint(a, "{s}/private/etc", .{top});
        var r = Recorder{ .a = a, .root = top };
        try owner.applyWith(ctx, top, v, true, &r);
        const want = [_][]const u8{
            try std.fmt.allocPrint(a, "/usr/sbin/pw -V {s} useradd -n owner -d /Users/owner -s /bin/sh -c owner -w no", .{etc}),
            try std.fmt.allocPrint(a, "/usr/sbin/pw -V {s} usershow -n owner", .{etc}),
            "/bin/hostname op647",
            "/sbin/kldload -n mac_do",
            try std.fmt.allocPrint(a, "/sbin/sysctl security.mac.do.rules={s}", .{rule}),
            try std.fmt.allocPrint(a, "/usr/sbin/pw -V {s} lock root", .{etc}),
            try std.fmt.allocPrint(a, "/usr/sbin/pwd_mkdb -d {s} -p {s}/master.passwd", .{ etc, etc }),
        };
        try t.expectEqual(want.len, r.calls.items.len);
        for (want, r.calls.items) |w, got| try t.expectEqualStrings(w, got);
        try t.expect(r.config == null);
        // The live value is the line sysctl.conf now holds.
        try t.expectEqualStrings(try owner.macDoRule(a, uid), try sys.read(a, try file(a, top, "/private/etc/sysctl.conf")));
        try t.expect(std.mem.startsWith(u8, try sys.read(a, try file(a, top, "/private/etc/master.passwd")), "root:*LOCKED*:"));
        try t.expectEqualStrings("owner\n", try sys.read(a, try file(a, top, "/private/var/db/rmxos/owner")));
    }
    // Any other root: files only; useradd logs nowhere, keeping the root's pw.conf.
    {
        const top = try ownerRoot(a);
        defer clear(a, top);
        const etc = try std.fmt.allocPrint(a, "{s}/private/etc", .{top});
        try sys.replace(a, try file(a, top, "/private/etc/pw.conf"), "defaultclass = staff");
        var r = Recorder{ .a = a, .root = top };
        try owner.applyWith(ctx, top, v, false, &r);
        const want = [_][]const u8{
            try std.fmt.allocPrint(a, "/usr/sbin/pw -V {s} useradd -n owner -d /Users/owner -s /bin/sh -c owner -w no -C {s}{s}", .{ etc, top, owner.pw_config }),
            try std.fmt.allocPrint(a, "/usr/sbin/pw -V {s} usershow -n owner", .{etc}),
            try std.fmt.allocPrint(a, "/usr/sbin/pw -V {s} lock root", .{etc}),
            try std.fmt.allocPrint(a, "/usr/sbin/pwd_mkdb -d {s} -p {s}/master.passwd", .{ etc, etc }),
        };
        try t.expectEqual(want.len, r.calls.items.len);
        for (want, r.calls.items) |w, got| try t.expectEqualStrings(w, got);
        try t.expectEqualStrings("defaultclass = staff\nlogfile = no\n", r.config.?);
        try t.expect(!sys.exists(try file(a, top, owner.pw_config)));
        try t.expectEqualStrings("defaultclass = staff", try sys.read(a, try file(a, top, "/private/etc/pw.conf")));
        try t.expectEqualStrings("owner\n", try sys.read(a, try file(a, top, "/private/var/db/rmxos/owner")));
    }
    // A failure of each live command: the files are written, root is as it was.
    for (live, 0..) |argv, i| {
        const top = try ownerRoot(a);
        defer clear(a, top);
        var r = Recorder{ .a = a, .root = top, .fail = argv[0] };
        try t.expectError(error.CommandFailed, owner.applyWith(ctx, top, v, true, &r));
        try t.expectEqual(3 + i, r.calls.items.len);
        try t.expect(std.mem.startsWith(u8, r.calls.items[r.calls.items.len - 1], argv[0]));
        for (r.calls.items) |c| try t.expect(std.mem.indexOf(u8, c, " lock root") == null and !std.mem.startsWith(u8, c, "/usr/sbin/pwd_mkdb"));
        try t.expectEqualStrings(template_passwd, try sys.read(a, try file(a, top, "/private/etc/master.passwd")));
        try t.expect(!sys.exists(try file(a, top, "/private/var/db/rmxos/owner")));
        try t.expectEqualStrings(v.key, try sys.read(a, try file(a, top, "/Users/owner/.ssh/authorized_keys")));
        try t.expectEqualStrings(try owner.macDoRule(a, uid), try sys.read(a, try file(a, top, "/private/etc/sysctl.conf")));
    }
}

test "owner seed: a mount directory left by an earlier run is reused; anything else refuses" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const top = try scratch(a);
    defer clear(a, top);
    const mode = struct {
        fn of(p: [:0]const u8) !sys.c.mode_t {
            var st: sys.c.struct_stat = undefined;
            if (sys.c.lstat(p, &st) != 0) return error.Stat;
            return st.st_mode;
        }
    }.of;
    const dir = try file(a, top, "/m");
    try seed.mountDirectory(dir);
    try t.expectEqual(@as(sys.c.mode_t, sys.c.S_IFDIR | 0o700), try mode(dir));
    try t.expectEqual(@as(c_int, 0), sys.c.chmod(dir, 0o755));
    try seed.mountDirectory(dir);
    try t.expectEqual(@as(sys.c.mode_t, sys.c.S_IFDIR | 0o700), try mode(dir));
    const plain = try file(a, top, "/f");
    try sys.replace(a, plain, "not a directory\n");
    try t.expectError(error.MountDirectory, seed.mountDirectory(plain));
    try t.expectEqualStrings("not a directory\n", try sys.read(a, plain));
    const link = try file(a, top, "/l");
    try t.expectEqual(@as(c_int, 0), sys.c.symlink(dir, link));
    try t.expectError(error.MountDirectory, seed.mountDirectory(link));
    try t.expectEqual(@as(sys.c.mode_t, sys.c.S_IFLNK), (try mode(link)) & sys.c.S_IFMT);
}

// PID 1 starts launchd with no open descriptors, so launchd opens /dev/null
// for its own stdio (sbin/launchd/launchd.c testfd_or_openfd) and a job
// without StandardErrorPath inherits it. The reader's one diagnostic line is
// its stderr: the job sends stderr to the console, once, at load.
test "owner seed job: stderr is the console; one run at load" {
    const plist = @embedFile("../org.rmxos.owner-seed.plist");
    for ([_][]const u8{
        "<key>Label</key><string>org.rmxos.owner-seed</string>",
        "<array><string>/usr/sbin/rmxos-owner-seed</string></array>",
        "<key>StandardErrorPath</key><string>/dev/console</string>",
        "<key>RunAtLoad</key><true/>",
        "<key>KeepAlive</key><false/>",
        "<key>LaunchOnlyOnce</key><true/>",
    }) |line| try t.expect(std.mem.indexOf(u8, plist, line) != null);
    try t.expect(std.mem.indexOf(u8, plist, "StandardOutPath") == null);
}
