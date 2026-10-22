const std = @import("std");
pub const noise: u64 = 8;
pub fn withinNoise(before: u64, after: u64) bool {
    // Allow unrelated port releases and small allocation noise, never the
    // 128 objects left by leaking even one special port per refused pair.
    return after <= before or after - before <= noise;
}
test "one leaked special port per refused pair fails" {
    try std.testing.expect(!withinNoise(279, 279 + 128));
    try std.testing.expect(withinNoise(279, 278));
    try std.testing.expect(withinNoise(279, 279));
    try std.testing.expect(withinNoise(279, 279 + noise));
    try std.testing.expect(!withinNoise(279, 279 + noise + 1));
}
