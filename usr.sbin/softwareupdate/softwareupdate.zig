const std = @import("std");
const update = @import("update.zig");
pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ctx = update.Context{ .allocator = arena.allocator() };
    const argv = init.args.toSlice(ctx.allocator) catch return 1;
    const args = ctx.allocator.alloc([]const u8, argv.len - 1) catch return 1;
    for (argv[1..], 0..) |v, i| args[i] = v;
    // --help does not need a boot environment or subprocess.
    const o = update.parse(args) catch {
        return ctx.diagnostic("invalid arguments; use --help") catch 1;
    };
    const s: update.Snapshot = if (o.action == .help or o.action == .list or o.action == .history) .{ .uid = update.c.geteuid(), .dataset = null, .listing = null } else update.snapshot(ctx.allocator);
    return update.run(ctx, args, s) catch |err| ctx.diagnostic(@errorName(err)) catch 1;
}
