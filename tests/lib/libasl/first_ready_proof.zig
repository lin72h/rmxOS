// The boot identity is independent of wall-clock changes. Saved timestamps
// always describe the first observation, never the current restart's marker.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("stdio.h");
});
pub const Proof = extern struct {
    boot_id: [16]u8,
    boot_sec: i64,
    boot_usec: i64,
    marker_sec: i64,
    marker_nsec: i64,
    ready_sec: i64,
    ready_nsec: i64,

    pub fn belongsTo(self: Proof, boot_id: [16]u8) bool {
        return std.mem.eql(u8, &self.boot_id, &boot_id);
    }
};
pub fn read(fp: anytype, boot_id: [16]u8) !Proof {
    var proof: Proof = undefined;
    if (c.fread(&proof, @sizeOf(Proof), 1, @ptrCast(fp)) != 1 or
        c.fgetc(@ptrCast(fp)) != c.EOF or c.ferror(@ptrCast(fp)) != 0 or
        !proof.belongsTo(boot_id)) return error.StaleProof;
    return proof;
}
pub fn identity() ![16]u8 {
    var id: [16]u8 = undefined;
    var size: usize = id.len;
    if (c.sysctlbyname("kern.boot_id", &id, &size, null, 0) != 0 or size != id.len) return error.BootIdentity;
    return id;
}
fn fixture() Proof {
    return .{ .boot_id = @splat(1), .boot_sec = 100, .boot_usec = 123, .marker_sec = 101, .marker_nsec = 0, .ready_sec = 101, .ready_nsec = 900000000 };
}
test "same boot accepts its first proof" {
    const proof = fixture();
    try std.testing.expect(proof.belongsTo(@splat(1)));
}
test "every byte of the boot identity participates in validation" {
    const proof = fixture();
    for (0..16) |i| {
        var other = proof.boot_id;
        other[i] ^= 1;
        try std.testing.expect(!proof.belongsTo(other));
    }
}
test "prior boot refused even with identical wall clock timestamps" {
    const proof = fixture();
    var other = proof.boot_id;
    other[15] = 2;
    try std.testing.expect(!proof.belongsTo(other));
}

test "repeated reads preserve the saved boot window and first readiness" {
    const fp = c.tmpfile() orelse return error.TemporaryFile;
    defer _ = c.fclose(fp);
    const original = fixture();
    try std.testing.expectEqual(@as(usize, 1), c.fwrite(&original, @sizeOf(Proof), 1, fp));
    for (0..3) |_| {
        c.rewind(fp);
        const proof = try read(fp, original.boot_id);
        try std.testing.expectEqualDeep(original, proof);
    }
    c.rewind(fp);
    try std.testing.expectError(error.StaleProof, read(fp, @splat(2)));
}
test "truncated and extended proof files are refused" {
    const fp = c.tmpfile() orelse return error.TemporaryFile;
    defer _ = c.fclose(fp);
    const proof = fixture();
    try std.testing.expectEqual(@as(usize, 1), c.fwrite(&proof, @sizeOf(Proof) - 1, 1, fp));
    c.rewind(fp);
    try std.testing.expectError(error.StaleProof, read(fp, proof.boot_id));
    c.rewind(fp);
    try std.testing.expectEqual(@as(usize, 1), c.fwrite(&proof, @sizeOf(Proof), 1, fp));
    try std.testing.expect(c.fputc(0, fp) != c.EOF);
    c.rewind(fp);
    try std.testing.expectError(error.StaleProof, read(fp, proof.boot_id));
}
