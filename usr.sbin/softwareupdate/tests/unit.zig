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

test "the one efi partition in gpart show -p" {
    const root = "=>      40  25165744  vtbd0  GPT  (12G)\n        40  25165744  vtbd0p1  freebsd-zfs  (12G)\n";
    const one = root ++ "\n=>     40  131008  vtbd1  GPT  (64M)\n       40  131008  vtbd1p1  efi  (64M)\n";
    try t.expectEqual(@as(?[]const u8, null), try esp.efiPartition(root));
    try t.expectEqualStrings("vtbd1p1", (try esp.efiPartition(one)).?);
    try t.expectError(error.MultipleEsps, esp.efiPartition(one ++ "    131048  2048  vtbd1p2  efi  (1.0M)\n"));
    try t.expectError(error.InvalidDevice, esp.efiPartition("  40  2048  ../x  efi  (1.0M)\n"));
    try t.expectEqual(@as(?[]const u8, null), try esp.efiPartition("  40  2048  -  free  -  (1.0M)\n"));
    // The guest's kern.geom.label.disk_ident lists the same ESP twice.
    const diskid = "=>  34  131072  diskid/DISK-BHYVE-6A2B-0E1C-4F01  GPT  (64M)\n  34  131072  diskid/DISK-BHYVE-6A2B-0E1C-4F01p1  efi  (64M)\n";
    try t.expectEqualStrings("vtbd1p1", (try esp.efiPartition(one ++ diskid)).?);
    try t.expectEqualStrings("diskid/DISK-BHYVE-6A2B-0E1C-4F01p1", (try esp.efiPartition(root ++ diskid)).?);
    try t.expectError(error.MultipleEsps, esp.efiPartition(diskid ++ "  34  131072  gpt/efiboot1  efi  (64M)\n"));
}

test "setting lines: last value wins, quotes and comments" {
    try t.expectEqualStrings("60", catalog.lookup("confirm_delay=600\n# confirm_delay=1\n confirm_delay = \"60\"\n", "confirm_delay").?);
    try t.expectEqual(@as(?[]const u8, null), catalog.lookup("retain=3\n", "confirm_delay"));
}
