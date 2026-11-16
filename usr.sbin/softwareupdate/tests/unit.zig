// Host unit tests: zig test softwareupdate.zig (catalog, stream header, CLI).
const std = @import("std");
const su = @import("../softwareupdate.zig");
const catalog = @import("../catalog.zig");
const engine = @import("../engine.zig");
const esp = @import("../esp.zig");
const sys = @import("../sys.zig");
const t = std.testing;

const good =
    \\{"format":"rmxos-catalog-v2","updates":[{"label":"rmxos-dc3d572d25db","build":"rmxos-dc3d572d25db",
    \\"snapshot":"rmxos-dc3d572d25db","origin_guid":"18254847806854379667","target_guid":"42",
    \\"stream":"rmxos-dc3d572d25db.zfs","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size":1}]}
;
test "v2 catalog parses with u64 GUID strings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try catalog.parse(arena.allocator(), good);
    try t.expectEqual(@as(usize, 1), v.updates.len);
    try t.expectEqualStrings("18254847806854379667", v.updates[0].origin_guid);
}
test "v1 catalogs and unsafe names are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.MalformedCatalog, catalog.parse(a, "{\"format\":\"rmxos-catalog-v1\",\"updates\":[]}"));
    const bad_stream = try std.mem.replaceOwned(u8, a, good, "rmxos-dc3d572d25db.zfs", "../x.zfs");
    try t.expectError(error.MalformedCatalog, catalog.parse(a, bad_stream));
    const bad_snap = try std.mem.replaceOwned(u8, a, good, "\"snapshot\":\"rmxos-dc3d572d25db\"", "\"snapshot\":\"a@b\"");
    try t.expectError(error.MalformedCatalog, catalog.parse(a, bad_snap));
    const bad_guid = try std.mem.replaceOwned(u8, a, good, "\"target_guid\":\"42\"", "\"target_guid\":\"x\"");
    try t.expectError(error.MalformedCatalog, catalog.parse(a, bad_guid));
}
test "stream header from S1's full stream" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ctx = sys.Ctx{ .a = arena.allocator(), .root = "", .fixture = true };
    const h = try engine.header(ctx, "/Users/me/wip-mach/rmx-implementer/build/op298/final/full.zfs");
    try t.expectEqual(@as(u64, 18254847806854379667), h.to);
    try t.expectEqual(@as(u64, 0), h.from);
    try t.expectEqualStrings("rmxop298/base/main@rmxos-0901dba3a801", h.name);
}
test "macOS surface: short forms, labels, refusals" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try su.parse(a, &.{ "-i", "rmxos-a", "rmxos-b", "-R", "--agree-to-license", "--verbose" });
    try t.expect(o.action == .install and o.restart and o.verbose and o.labels.items.len == 2);
    try t.expect((try su.parse(a, &.{ "-l", "--no-scan", "--product-types", "macOS" })).action == .list);
    try t.expect((try su.parse(a, &.{ "--install", "-a" })).all);
    try t.expect((try su.parse(a, &.{ "rollback", "--restart" })).restart);
    try t.expect((try su.parse(a, &.{"--background"})).action == .background);
    for (su.refused) |r| try t.expectError(error.Refused, su.parse(a, &.{ "-l", r }));
    try t.expectError(error.Usage, su.parse(a, &.{"--install"}));
    try t.expectError(error.Usage, su.parse(a, &.{ "-l", "--restart" }));
    try t.expectError(error.Usage, su.parse(a, &.{ "status", "--no-auto-confirm" }));
    try t.expectError(error.Usage, su.parse(a, &.{ "-l", "-d" }));
}

test "lineage defaults and full stream catalog" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("main", (try catalog.parse(a, good)).lineage);
    const full = "{\"format\":\"rmxos-catalog-v2\",\"lineage\":\"preview\",\"updates\":[],\"full\":{\"label\":\"C\",\"build\":\"C\",\"snapshot\":\"rmxos-cccccccccccc\",\"target_guid\":\"18446744073709551615\",\"stream\":\"c.zfs\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"size\":10}}";
    const v = try catalog.parse(a, full);
    try t.expectEqualStrings("preview", v.lineage);
    try t.expectEqualStrings("0", v.full.?.update().origin_guid);
    for ([_][]const u8{ "../preview", "", "a/b", "a@b" }) |lineage| {
        const bad = try std.mem.replaceOwned(u8, a, full, "preview", lineage);
        try t.expectError(error.MalformedCatalog, catalog.parse(a, bad));
    }
    const bad_stream = try std.mem.replaceOwned(u8, a, full, "c.zfs", "../c.zfs");
    try t.expectError(error.MalformedCatalog, catalog.parse(a, bad_stream));
    const bad_guid = try std.mem.replaceOwned(u8, a, full, "18446744073709551615", "18446744073709551616");
    try t.expectError(error.MalformedCatalog, catalog.parse(a, bad_guid));
}

// gpart show -p and kern.geom.conftxt for two md disks that each have an ESP
// and a ZFS partition; md5p2 carries a geli layer and md5p1 a GPT label.
const two_gpart =
    \\=>     40  409520  md5  GPT  (200M)
    \\       40   81920  md5p1  efi  (40M)
    \\    81960     984  - free -  (492K)
    \\    82944  326616  md5p2  freebsd-zfs  (159M)
    \\
    \\=>     40  262064  md6  GPT  (128M)
    \\       40   81920  md6p1  efi  (40M)
    \\    81960  180144  md6p2  freebsd-zfs  (88M)
    \\
;
const two_conftxt =
    \\0 MD md7 67108864 512 u 7 s 512 f 0 fs 0 l 67108864 t vnode file /x/fat.img
    \\0 MD md6 134217728 512 u 6 s 512 f 0 fs 0 l 134217728 t vnode file /x/second.img
    \\1 PART md6p2 92233728 512 i 2 o 41963520 ty freebsd-zfs xs GPT xt 516e7cba-6ecf-11d6-8ff8-00022d09712b
    \\1 PART md6p1 41943040 512 i 1 o 20480 ty efi xs GPT xt c12a7328-f81f-11d2-ba4b-00a0c93ec93b
    \\0 MD md5 209715200 512 u 5 s 512 f 0 fs 0 l 209715200 t vnode file /x/pool.img
    \\1 PART md5p2 167227392 512 i 2 o 42467328 ty freebsd-zfs xs GPT xt 516e7cba-6ecf-11d6-8ff8-00022d09712b
    \\2 ELI md5p2.eli 167227392 4096
    \\1 PART md5p1 41943040 512 i 1 o 20480 ty efi xs GPT xt c12a7328-f81f-11d2-ba4b-00a0c93ec93b
    \\2 LABEL gpt/efiboot5 41943040 512 i 0 o 0
    \\
;

fn located(a: std.mem.Allocator, gpart: []const u8, conftxt: []const u8, devices: []const []const u8) !esp.Located {
    return (try esp.Disks.parse(a, gpart, conftxt)).locate(a, devices);
}

test "locate: the efi partition on the pool's disk, with two disks that each have one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("md5p1", (try located(a, two_gpart, two_conftxt, &.{"md5p2"})).partition);
    try t.expectEqualStrings("md6p1", (try located(a, two_gpart, two_conftxt, &.{"md6p2"})).partition);
    // A layer above the pool's partition names the same disk.
    try t.expectEqualStrings("md5p1", (try located(a, two_gpart, two_conftxt, &.{"md5p2.eli"})).partition);
    const both = (try located(a, two_gpart, two_conftxt, &.{ "md5p2", "md6p2" })).disks;
    try t.expectEqual(@as(usize, 2), both.len);
    try t.expectEqualStrings("md5", both[0]);
    try t.expectEqualStrings("md6", both[1]);
    // A pool on a whole disk (no partition table): no ESP on its disk.
    try t.expectEqualStrings("md7", (try located(a, two_gpart, two_conftxt, &.{"md7"})).none);
    try t.expectError(error.NoPoolDevice, located(a, two_gpart, two_conftxt, &.{}));
    // Two on the pool's own disk refuse; a second disk's never does.
    const three = std.mem.replaceOwned(u8, a, two_gpart, "    81960     984  - free -  (492K)\n", "    81960     984  md5p3  efi  (492K)\n") catch unreachable;
    try t.expectEqualStrings("md5", (try located(a, three, two_conftxt, &.{"md5p2"})).several);
    try t.expectEqualStrings("md6p1", (try located(a, three, two_conftxt, &.{"md6p2"})).partition);
    const unsafe = std.mem.replaceOwned(u8, a, two_gpart, "md5p1  efi", "../x  efi") catch unreachable;
    try t.expectError(error.InvalidDevice, located(a, unsafe, two_conftxt, &.{"md5p2"}));
    try t.expectEqualStrings("md6p1", (try located(a, unsafe, two_conftxt, &.{"md6p2"})).partition);
}

test "locate: a mounted ESP counts under its device name or a label above it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try esp.Disks.parse(a, two_gpart, two_conftxt);
    const mounts = [_]sys.Mount{
        .{ .on = "/f/fat", .from = "/dev/md7" },
        .{ .on = "/f/second", .from = "/dev/md6p1" },
        .{ .on = "/f/boot/efi", .from = "/dev/gpt/efiboot5" },
    };
    try t.expectEqualStrings("/f/boot/efi", d.mountOf(&mounts, "md5p1").?);
    try t.expectEqualStrings("/f/second", d.mountOf(&mounts, "md6p1").?);
    try t.expectEqual(@as(?[]const u8, null), d.mountOf(mounts[0..2], "md5p1"));
    try t.expectEqual(@as(?[]const u8, null), d.mountOf(&.{.{ .on = "/f/x", .from = "md5p1" }}, "md5p1"));
    // This build host: zroot on nda0p4, /boot/efi from /dev/gpt/efiboot0.
    const host_gpart =
        \\=>        40  1953525088    nda0  GPT  (932G)
        \\          40      532480  nda0p1  efi  (260M)
        \\      532520        1024  nda0p2  freebsd-boot  (512K)
        \\      534528     4194304  nda0p3  freebsd-swap  (2.0G)
        \\     4728832  1948794880  nda0p4  freebsd-zfs  (929G)
        \\
        \\=>        40  2000409184    nda1  GPT  (954G)
        \\          40  2000409184  nda1p1  freebsd-zfs  (954G)
        \\
    ;
    const host_conftxt =
        \\0 DISK nda1 1024209543168 512 hd 0 sc 0
        \\1 PART nda1p1 1024209502208 512 i 1 o 20480 ty freebsd-zfs xs GPT xt 516e7cba-6ecf-11d6-8ff8-00022d09712b
        \\2 LABEL gpt/1ssd-8432-fc803060ecee 1024209502208 512 i 0 o 0
        \\0 DISK nda0 1000204886016 512 hd 0 sc 0
        \\1 PART nda0p4 997782978560 512 i 4 o 2421161984 ty freebsd-zfs xs GPT xt 516e7cba-6ecf-11d6-8ff8-00022d09712b
        \\1 PART nda0p3 2147483648 512 i 3 o 273678336 ty freebsd-swap xs GPT xt 516e7cb5-6ecf-11d6-8ff8-00022d09712b
        \\1 PART nda0p2 524288 512 i 2 o 272650240 ty freebsd-boot xs GPT xt 83bd6b9d-7f41-11dc-be0b-001560b84f0f
        \\2 LABEL gpt/gptboot0 524288 512 i 0 o 0
        \\1 PART nda0p1 272629760 512 i 1 o 20480 ty efi xs GPT xt c12a7328-f81f-11d2-ba4b-00a0c93ec93b
        \\2 LABEL gpt/efiboot0 272629760 512 i 0 o 0
        \\
    ;
    const host = try esp.Disks.parse(a, host_gpart, host_conftxt);
    try t.expectEqualStrings("nda0p1", (try host.locate(a, &.{"nda0p4"})).partition);
    try t.expectEqualStrings("nda1", (try host.locate(a, &.{"nda1p1"})).none);
    try t.expectEqualStrings("/boot/efi", host.mountOf(&.{.{ .on = "/boot/efi", .from = "/dev/gpt/efiboot0" }}, "nda0p1").?);
}

// Replaces op-484's "one efi partition in gpart show -p" (:82-91): one ESP is
// now looked for on the pool's disk, not across every disk; the same
// listings give the same answers there, and another disk's ESP is ignored.
test "locate: GEOM labels list a disk twice; its ESP counts once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // op-484 BOOT2's gpart show -p (kern.geom.label.disk_ident in the guest),
    // and its GEOM tree as glabel status listed it.
    const guest =
        \\=>      34  25165824    diskid/DISK-BHYVE-EB8D-698C-B98D  GPT  (12G)
        \\        34  25165824  diskid/DISK-BHYVE-EB8D-698C-B98Dp1  freebsd-zfs  (12G)
        \\
        \\=>    34  131072    vtbd1  GPT  (64M)
        \\      34  131072  vtbd1p1  efi  (64M)
        \\
        \\=>    34  131072    diskid/DISK-BHYVE-BFE6-E874-293C  GPT  (64M)
        \\      34  131072  diskid/DISK-BHYVE-BFE6-E874-293Cp1  efi  (64M)
        \\
    ;
    const tree =
        \\0 DISK vtbd1 67108864 512 hd 0 sc 0
        \\1 LABEL diskid/DISK-BHYVE-BFE6-E874-293C 67108864 512 i 0 o 0
        \\2 PART diskid/DISK-BHYVE-BFE6-E874-293Cp1 67091968 512 i 1 o 17408 ty efi xs GPT
        \\1 PART vtbd1p1 67091968 512 i 1 o 17408 ty efi xs GPT
        \\2 LABEL gptid/8bcb05ca-da60-11f1-067b-ff9d86f8dced 67091968 512 i 0 o 0
        \\0 DISK vtbd0 12884901888 512 hd 0 sc 0
        \\1 LABEL diskid/DISK-BHYVE-EB8D-698C-B98D 12884901888 512 i 0 o 0
        \\2 PART diskid/DISK-BHYVE-EB8D-698C-B98Dp1 12884884992 512 i 1 o 17408 ty freebsd-zfs xs GPT
        \\
    ;
    // The pool is on vtbd0, which has no ESP; vtbd1's is another disk's.
    try t.expectEqualStrings("vtbd0", (try located(a, guest, tree, &.{"diskid/DISK-BHYVE-EB8D-698C-B98Dp1"})).none);
    // A pool on the ESP's disk: listed under vtbd1 and its diskid label, once.
    const same =
        \\=>    34  131072    vtbd1  GPT  (64M)
        \\      34   65536  vtbd1p1  efi  (32M)
        \\   65570   65536  vtbd1p2  freebsd-zfs  (32M)
        \\
        \\=>    34  131072    diskid/DISK-BHYVE-BFE6-E874-293C  GPT  (64M)
        \\      34   65536  diskid/DISK-BHYVE-BFE6-E874-293Cp1  efi  (32M)
        \\   65570   65536  diskid/DISK-BHYVE-BFE6-E874-293Cp2  freebsd-zfs  (32M)
        \\
    ;
    const same_tree =
        \\0 DISK vtbd1 67108864 512 hd 0 sc 0
        \\1 LABEL diskid/DISK-BHYVE-BFE6-E874-293C 67108864 512 i 0 o 0
        \\2 PART diskid/DISK-BHYVE-BFE6-E874-293Cp2 33554432 512 i 2 o 33571840 ty freebsd-zfs xs GPT
        \\2 PART diskid/DISK-BHYVE-BFE6-E874-293Cp1 33554432 512 i 1 o 17408 ty efi xs GPT
        \\1 PART vtbd1p2 33554432 512 i 2 o 33571840 ty freebsd-zfs xs GPT
        \\1 PART vtbd1p1 33554432 512 i 1 o 17408 ty efi xs GPT
        \\
    ;
    for ([_][]const u8{ "vtbd1p2", "diskid/DISK-BHYVE-BFE6-E874-293Cp2" }) |pool|
        try t.expectEqualStrings("vtbd1p1", (try located(a, same, same_tree, &.{pool})).partition);
    // Only the label's table listed (vtbd1's own withered): the label's partition.
    const label_only = same[std.mem.indexOf(u8, same, "=>    34  131072    diskid").?..];
    try t.expectEqualStrings("diskid/DISK-BHYVE-BFE6-E874-293Cp1", (try located(a, label_only, same_tree, &.{"diskid/DISK-BHYVE-BFE6-E874-293Cp2"})).partition);
    // Two label partitions and no device name: which one is not known.
    const two_labels = try std.mem.concat(a, u8, &.{ label_only, "      34  2048  gpt/efiboot1  efi  (1.0M)\n" });
    try t.expectEqualStrings("vtbd1", (try located(a, two_labels, same_tree, &.{"diskid/DISK-BHYVE-BFE6-E874-293Cp2"})).several);
}

test "zpool status -P: the pool's leaf devices" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const text =
        \\  pool: rmxsu484
        \\ state: ONLINE
        \\config:
        \\
        \\    NAME                 STATE     READ WRITE CKSUM
        \\    rmxsu484             ONLINE       0     0     0
        \\      mirror-0           ONLINE       0     0     0
        \\        /dev/md5p2       ONLINE       0     0     0
        \\        /dev/gpt/zfs1    ONLINE       0     0     0
        \\    logs
        \\      /dev/md6p2.eli     ONLINE       0     0     0
        \\
        \\errors: No known data errors /dev/md9
        \\
    ;
    const d = try esp.poolDevices(arena.allocator(), text);
    try t.expectEqual(@as(usize, 3), d.len);
    try t.expectEqualStrings("md5p2", d[0]);
    try t.expectEqualStrings("gpt/zfs1", d[1]);
    try t.expectEqualStrings("md6p2.eli", d[2]);
}

const dirent = @cImport(@cInclude("dirent.h"));

// A scratch directory below $TMPDIR (default /tmp); `clear` removes it.
fn scratch(a: std.mem.Allocator) ![:0]const u8 {
    const base = if (sys.c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp";
    const p = try std.fmt.allocPrintSentinel(a, "{s}/softwareupdate-unit-XXXXXX", .{std.mem.trimEnd(u8, base, "/")}, 0);
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
fn at(a: std.mem.Allocator, dir: []const u8, rel: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, rel }, 0);
}
fn hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

const new_loader = "the root's loader\n";
const owner_env = "# the owner's\nboot_verbose=\"YES\"\n";
// A root with /boot/loader.efi and an ESP directory with the given old bytes
// at each loader path (null: absent) and the owner's loader.env.
const Fixture = struct { ctx: sys.Ctx, dir: []const u8, out: [:0]const u8 };
fn fixture(a: std.mem.Allocator, top: []const u8, old: [esp.loaders.len]?[]const u8) !Fixture {
    const root = try std.fmt.allocPrint(a, "{s}/root", .{top});
    try sys.replace(a, try at(a, root, "boot/loader.efi"), new_loader);
    const dir = try std.fmt.allocPrint(a, "{s}/esp", .{top});
    for (esp.loaders, old) |rel, bytes| if (bytes) |b| try sys.replace(a, try at(a, dir, rel), b);
    try sys.replace(a, try at(a, dir, esp.loader_env), owner_env);
    return .{ .ctx = .{ .a = a, .root = root, .fixture = true }, .dir = dir, .out = try at(a, top, "stdout") };
}
fn read(a: std.mem.Allocator, dir: []const u8, rel: []const u8) []const u8 {
    return sys.read(a, at(a, dir, rel) catch return "") catch "(absent)";
}
// refresh with its stdout lines in f.out.
fn refreshed(f: Fixture, e: *esp.Esp) !bool {
    const fd = sys.c.open(f.out, sys.c.O_WRONLY | sys.c.O_CREAT | sys.c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.Capture;
    const saved = sys.c.dup(1);
    _ = sys.c.dup2(fd, 1);
    _ = sys.c.close(fd);
    const r = e.refresh(f.ctx);
    _ = sys.c.dup2(saved, 1);
    _ = sys.c.close(saved);
    return r;
}

test "ESP refresh writes every loader path, each with its .prev" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const top = try scratch(a);
    defer clear(a, top);
    const f = try fixture(a, top, .{ "old removable\n", "old freebsd\n" });
    var e = esp.Esp{ .dir = f.dir };
    try t.expect(try refreshed(f, &e));
    for (esp.loaders, [_][]const u8{ "old removable\n", "old freebsd\n" }) |rel, old| {
        try t.expectEqual(hex(new_loader), try sys.sha256File(try at(a, f.dir, rel)));
        try t.expectEqualStrings(old, read(a, f.dir, try std.fmt.allocPrint(a, "{s}.prev", .{rel})));
        for ([_][]const u8{ ".new", ".prev.new" }) |s| try t.expect(!sys.exists(try at(a, f.dir, try std.fmt.allocPrint(a, "{s}{s}", .{ rel, s }))));
    }
    try t.expectEqualStrings(owner_env, read(a, f.dir, esp.loader_env));
    const want = try std.fmt.allocPrint(a, "EFI/BOOT/BOOTX64.EFI sha256 {s}, previous {s} kept as BOOTX64.EFI.prev; efi/freebsd/loader.efi sha256 {s}, previous {s} kept as loader.efi.prev", .{ hex(new_loader), hex("old removable\n"), hex(new_loader), hex("old freebsd\n") });
    try t.expectEqualStrings(want, e.detail);
    try t.expectEqual(@as(usize, 2), e.written.len);
    const lines = try std.fmt.allocPrint(a, "ESP: refreshed EFI/BOOT/BOOTX64.EFI sha256 {s}, previous {s} kept as BOOTX64.EFI.prev\nESP: refreshed efi/freebsd/loader.efi sha256 {s}, previous {s} kept as loader.efi.prev\n", .{ hex(new_loader), hex("old removable\n"), hex(new_loader), hex("old freebsd\n") });
    try t.expectEqualStrings(lines, sys.read(a, f.out) catch "");
    // A second confirm finds both current and writes nothing.
    var again = esp.Esp{ .dir = f.dir };
    try t.expect(!try refreshed(f, &again));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "ESP: EFI/BOOT/BOOTX64.EFI is current (sha256 {s})\nESP: efi/freebsd/loader.efi is current (sha256 {s})\n", .{ hex(new_loader), hex(new_loader) }), sys.read(a, f.out) catch "");
    try t.expectEqualStrings("old freebsd\n", read(a, f.dir, "efi/freebsd/loader.efi.prev"));
}

test "ESP refresh with one loader path present changes only it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..esp.loaders.len) |only| {
        const top = try scratch(a);
        defer clear(a, top);
        var old: [esp.loaders.len]?[]const u8 = @splat(null);
        old[only] = "old\n";
        const f = try fixture(a, top, old);
        var e = esp.Esp{ .dir = f.dir };
        try t.expect(try refreshed(f, &e));
        for (esp.loaders, 0..) |rel, i| {
            const prev = try std.fmt.allocPrint(a, "{s}.prev", .{rel});
            if (i == only) {
                try t.expectEqualStrings(new_loader, read(a, f.dir, rel));
                try t.expectEqualStrings("old\n", read(a, f.dir, prev));
            } else {
                try t.expect(!sys.exists(try at(a, f.dir, rel)) and !sys.exists(try at(a, f.dir, prev)));
            }
        }
        try t.expectEqual(@as(usize, 1), e.written.len);
        try t.expect(std.mem.startsWith(u8, e.detail, esp.loaders[only]) and std.mem.indexOf(u8, e.detail, ";") == null);
    }
    // Neither: the confirm is refused.
    const top = try scratch(a);
    defer clear(a, top);
    const f = try fixture(a, top, .{ null, null });
    var e = esp.Esp{ .dir = f.dir };
    try t.expectError(error.EspRefresh, refreshed(f, &e));
    try t.expect(std.mem.endsWith(u8, sys.failure, "/esp has no EFI/BOOT/BOOTX64.EFI or efi/freebsd/loader.efi"));
}

test "a failed bootfs move restores every loader and .prev" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const top = try scratch(a);
    defer clear(a, top);
    const f = try fixture(a, top, .{ "old removable\n", "old freebsd\n" });
    // An earlier refresh left efi/freebsd/loader.efi.prev; none for BOOTX64.EFI.
    try sys.replace(a, try at(a, f.dir, "efi/freebsd/loader.efi.prev"), "older freebsd\n");
    var e = esp.Esp{ .dir = f.dir };
    try t.expect(try refreshed(f, &e));
    try t.expectEqualStrings("old freebsd\n", read(a, f.dir, "efi/freebsd/loader.efi.prev"));
    // What confirmRunning does when zpool set bootfs fails.
    e.restore(f.ctx);
    try t.expectEqualStrings("old removable\n", read(a, f.dir, "EFI/BOOT/BOOTX64.EFI"));
    try t.expect(!sys.exists(try at(a, f.dir, "EFI/BOOT/BOOTX64.EFI.prev")));
    try t.expectEqualStrings("old freebsd\n", read(a, f.dir, "efi/freebsd/loader.efi"));
    try t.expectEqualStrings("older freebsd\n", read(a, f.dir, "efi/freebsd/loader.efi.prev"));
    for (esp.loaders) |rel| try t.expect(!sys.exists(try at(a, f.dir, try std.fmt.allocPrint(a, "{s}.new", .{rel}))));
    try t.expectEqualStrings(owner_env, read(a, f.dir, esp.loader_env));
}

fn oomFixture(a: std.mem.Allocator, top: []const u8) !Fixture {
    const f = try fixture(a, top, .{ "old removable\n", "old freebsd\n" });
    try sys.replace(a, try at(a, f.dir, "efi/freebsd/loader.efi.prev"), "older freebsd\n");
    return f;
}

fn unchangedEsp(a: std.mem.Allocator, f: Fixture) !bool {
    var same = std.mem.eql(u8, read(a, f.dir, esp.loader_env), owner_env);
    for (esp.loaders, [_][]const u8{ "old removable\n", "old freebsd\n" }, 0..) |rel, old, i| {
        same = same and std.mem.eql(u8, read(a, f.dir, rel), old);
        const prev = try std.fmt.allocPrint(a, "{s}.prev", .{rel});
        same = same and if (i == 0) !sys.exists(try at(a, f.dir, prev)) else std.mem.eql(u8, read(a, f.dir, prev), "older freebsd\n");
        for ([_][]const u8{ ".new", ".prev.new" }) |suffix|
            same = same and !sys.exists(try at(a, f.dir, try std.fmt.allocPrint(a, "{s}{s}", .{ rel, suffix })));
    }
    return same;
}

test "ESP allocation failures leave both loaders and prior states unchanged; restore allocates nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const top = try scratch(a);
    defer clear(a, top);
    var f = try oomFixture(a, top);
    var count_alloc = t.FailingAllocator.init(a, .{});
    f.ctx.a = count_alloc.allocator();
    var e = esp.Esp{ .dir = f.dir };
    try t.expect(try refreshed(f, &e));
    const count = count_alloc.alloc_index;
    std.debug.print("ESP_OOM passing_allocations={d}\n", .{count});

    var failures: usize = 0;
    for (0..count + 1) |n| {
        var trial = std.heap.ArenaAllocator.init(t.allocator);
        defer trial.deinit();
        const alloc = trial.allocator();
        const dir = try scratch(alloc);
        defer clear(alloc, dir);
        var fx = try oomFixture(alloc, dir);
        var failing = t.FailingAllocator.init(alloc, .{ .fail_index = n });
        fx.ctx.a = failing.allocator();
        var current = esp.Esp{ .dir = fx.dir };
        const result = refreshed(fx, &current);
        if (n < count) {
            const errored = if (result) |_| false else |_| true;
            const same = try unchangedEsp(alloc, fx);
            std.debug.print("ESP_OOM N={d} error={s} unchanged={any}\n", .{ n, if (result) |_| "none" else |err| @errorName(err), same });
            if (!errored or !same) {
                failures += 1;
                if (failing.has_induced_failure) {
                    const trace = failing.getStackTrace();
                    std.debug.dumpStackTrace(&trace);
                }
            }
        } else {
            try t.expect(try result);
            try t.expect(!failing.has_induced_failure);
            for (esp.loaders, [_][]const u8{ "old removable\n", "old freebsd\n" }) |rel, old| {
                try t.expectEqualStrings(new_loader, read(alloc, fx.dir, rel));
                try t.expectEqualStrings(old, read(alloc, fx.dir, try std.fmt.allocPrint(alloc, "{s}.prev", .{rel})));
                for ([_][]const u8{ ".new", ".prev.new" }) |suffix|
                    try t.expect(!sys.exists(try at(alloc, fx.dir, try std.fmt.allocPrint(alloc, "{s}{s}", .{ rel, suffix }))));
            }
            try t.expectEqualStrings(owner_env, read(alloc, fx.dir, esp.loader_env));
            std.debug.print("ESP_OOM N={d} refreshed=true\n", .{n});
            var exhausted = t.FailingAllocator.init(alloc, .{ .fail_index = 0 });
            fx.ctx.a = exhausted.allocator();
            current.restore(fx.ctx);
            const same = try unchangedEsp(alloc, fx);
            const no_allocations = !exhausted.has_induced_failure and exhausted.alloc_index == 0;
            std.debug.print("ESP_OOM restore fail_index=0 unchanged={any} no_allocations={any}\n", .{ same, no_allocations });
            if (!same or !no_allocations) failures += 1;
        }
    }
    std.debug.print("ESP_OOM failures={d}\n", .{failures});
    try t.expectEqual(@as(usize, 0), failures);
}

test "GEOM parser refuses a level jump" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.GeomOutput, esp.Disks.parse(arena.allocator(), "", "0 DISK md0 4096 512\n2 PART md0p1 4096 512\n"));
}

test "gpart parser refuses a partition without a table header" {
    try t.expectError(error.GpartOutput, esp.Disks.parse(t.allocator, "40 81920 md0p1 efi (40M)\n", ""));
}

test "a failure at the second loader puts back the first" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const top = try scratch(a);
    defer clear(a, top);
    const f = try fixture(a, top, .{ "old removable\n", "old freebsd\n" });
    // A directory where the second loader's temporary file goes.
    try t.expectEqual(@as(c_int, 0), sys.c.mkdir(try at(a, f.dir, "efi/freebsd/loader.efi.new"), 0o755));
    var e = esp.Esp{ .dir = f.dir };
    try t.expectError(error.EspRefresh, refreshed(f, &e));
    try t.expectEqualStrings("efi/freebsd/loader.efi.new: create: File exists", sys.failure);
    try t.expectEqualStrings("old removable\n", read(a, f.dir, "EFI/BOOT/BOOTX64.EFI"));
    try t.expect(!sys.exists(try at(a, f.dir, "EFI/BOOT/BOOTX64.EFI.prev")));
    try t.expect(!sys.exists(try at(a, f.dir, "EFI/BOOT/BOOTX64.EFI.new")));
    try t.expectEqualStrings("old freebsd\n", read(a, f.dir, "efi/freebsd/loader.efi"));
    try t.expect(!sys.exists(try at(a, f.dir, "efi/freebsd/loader.efi.prev")));
    try t.expectEqual(@as(usize, 0), e.written.len);
    try t.expectEqualStrings("", sys.read(a, f.out) catch "x");
}

test "setting lines: last value wins, quotes and comments" {
    try t.expectEqualStrings("60", catalog.lookup("confirm_delay=600\n# confirm_delay=1\n confirm_delay = \"60\"\n", "confirm_delay").?);
    try t.expectEqual(@as(?[]const u8, null), catalog.lookup("retain=3\n", "confirm_delay"));
}

test "installing onto another pool is rmxos-install's, not softwareupdate's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.Usage, su.parse(a, &.{ "--install", "-a", "--pool", "rmxsu581", "--altroot", "/mnt" }));
    try t.expectError(error.Usage, su.parse(a, &.{ "--install", "-a", "--altroot", "/mnt" }));
}

test "named target refusals come before any pool command" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // fixture=true and no command backend: each of these would fail on a run.
    const ctx = sys.Ctx{ .a = arena.allocator(), .root = "/nonexistent-rmxsu-unit", .fixture = true };
    const cases = [_]struct { pool: []const u8, altroot: []const u8, err: anyerror }{
        .{ .pool = "zroot", .altroot = "/mnt", .err = error.FixturePool },
        .{ .pool = "rmxsu581", .altroot = "/", .err = error.AltrootIsRoot },
        .{ .pool = "rmxsu581", .altroot = "///", .err = error.AltrootIsRoot },
        .{ .pool = "rmxsu581", .altroot = "mnt", .err = error.InvalidAltroot },
        .{ .pool = "rmxsu581", .altroot = "", .err = error.InvalidAltroot },
        .{ .pool = "rmxsu581", .altroot = "/mnt/../", .err = error.InvalidAltroot },
        .{ .pool = "rmxsu/581", .altroot = "/mnt", .err = error.InvalidPool },
        .{ .pool = "5rmxsu", .altroot = "/mnt", .err = error.InvalidPool },
        .{ .pool = "", .altroot = "/mnt", .err = error.InvalidPool },
    };
    for (cases) |x| try t.expectError(x.err, engine.open(ctx, .{ .pool = .{ .name = x.pool, .altroot = x.altroot } }));
}
