const std = @import("std");
extern fn rmx_asl_anchor() ?*anyopaque;
extern fn rmx_native_log_library() [*:0]const u8;
test "fallback resolves to libc with libasl loaded before libc" {
    std.mem.doNotOptimizeAway(rmx_asl_anchor());
    const library = std.mem.span(rmx_native_log_library());
    std.debug.print("resolved syslog library: {s}\n", .{library});
    try std.testing.expect(std.mem.endsWith(u8, library, "/libc.so.7"));
}
