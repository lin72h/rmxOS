// Host unit tests: zig test (see Makefile's test target); no command runs.
const std = @import("std");
const ri = @import("../rmxos-install.zig");
const t = std.testing;

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
