// Host md-pool retention case: discover the real fixture ROOT, then fail the
// bootfs lookup with a nonexistent pool while enumerating that real ROOT.
const std = @import("std");
const engine = @import("engine");
pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = init.args.toSlice(a) catch return 2;
    if (args.len != 2) return 2;
    var env = engine.discover(.{ .a = a, .root = args[1], .fixture = true }) catch return 2;
    env.pool = "rmxsu-op345-nonexistent";
    return engine.retain(.{ .a = a, .root = args[1], .fixture = true }, env) catch return 2;
}
