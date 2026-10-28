const std = @import("std");
const checks = @import("checks.zig");
extern fn codec_asan_control([*c]u8, usize) void;
extern fn codec_ubsan_control(c_int) c_int;
pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = init.args.toSlice(arena.allocator()) catch return 1;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--asan-control")) {
        const p = checks.c.malloc(1) orelse return 1;
        codec_asan_control(@ptrCast(p), 1);
        checks.c.free(p);
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--ubsan-control")) {
        _ = codec_ubsan_control(std.math.maxInt(c_int));
        return 0;
    }
    checks.malformed() catch return 1;
    return 0;
}
