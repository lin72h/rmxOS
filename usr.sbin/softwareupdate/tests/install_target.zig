// Host driver for install_is_update: the engine's named target as
// rmxos-install calls it, onto a pool that is already imported, no disk.
// usage: install_target CATALOG POOL ALTROOT (RMXOS_SU_FIXTURE for host runs)
const std = @import("std");
const engine = @import("engine");

pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = init.args.toSlice(a) catch return 2;
    if (args.len != 4) return 2;
    const ctx = engine.sys.Ctx.init(a);
    const loaded = engine.catalog.load(ctx, args[1], false) catch |err| return ctx.refuse("catalog: {s}", .{@errorName(err)});
    const full = loaded.catalog.full orelse return ctx.refuse("the catalog has no full stream", .{});
    const env = engine.open(ctx, .{ .pool = .{ .name = args[2], .altroot = args[3] } }) catch |err|
        return ctx.refuse("{s}: {s}", .{ @errorName(err), engine.sys.failure });
    return engine.installTarget(ctx, env, full.update(), loaded.source, loaded.catalog.lineage) catch |err|
        ctx.refuse("{s}: {s}", .{ @errorName(err), engine.sys.failure });
}
