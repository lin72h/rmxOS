// Preserve the boot's first readiness observation before any test restarts
// asld or repeats the compatibility onestart command. Missing proof fails.
const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/stat.h");
    @cInclude("sys/time.h");
    @cInclude("sys/sysctl.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const saved = @import("first_ready_proof.zig");
const Proof = saved.Proof;
const path = "/var/run/op942-first-asld-ready";
pub fn valid(ms: i64) bool {
    return ms >= 0 and ms < 1000;
}
pub fn observe() !i64 {
    var boot: c.struct_timeval = undefined;
    var size: usize = @sizeOf(c.struct_timeval);
    if (c.sysctlbyname("kern.boottime", &boot, &size, null, 0) != 0 or size != @sizeOf(c.struct_timeval)) return error.BootTime;
    const boot_id = try saved.identity();
    var proof: Proof = undefined;
    if (c.fopen(path, "rb")) |fp| {
        defer _ = c.fclose(fp);
        proof = try saved.read(fp, boot_id);
    } else {
        const fp = c.fopen("/var/run/asld.boot-service.log", "r") orelse return error.BootLog;
        defer _ = c.fclose(fp);
        var line: [1024]u8 = undefined;
        var first: c_int = 0;
        while (c.fgets(&line, line.len, fp) != null) {
            if (c.sscanf(&line, "asld: compatibility service ready pid=%d", &first) == 1) break;
        }
        const ready_fp = c.fopen("/var/run/asld.service-ready", "r") orelse return error.Ready;
        defer _ = c.fclose(ready_fp);
        var current: c_int = 0;
        if (first <= 1 or c.fscanf(ready_fp, "%d", &current) != 1 or first != current) return error.FirstReadyNotCaptured;
        var marker: c.struct_stat = undefined;
        var ready: c.struct_stat = undefined;
        if (c.stat("/var/run/asld.filesystems-ready", &marker) != 0 or c.stat("/var/run/asld.service-ready", &ready) != 0) return error.Stat;
        proof = .{ .boot_id = boot_id, .boot_sec = boot.tv_sec, .boot_usec = boot.tv_usec, .marker_sec = marker.st_mtim.tv_sec, .marker_nsec = marker.st_mtim.tv_nsec, .ready_sec = ready.st_mtim.tv_sec, .ready_nsec = ready.st_mtim.tv_nsec };
        const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o600));
        if (fd < 0) return error.ProofCreate;
        defer _ = c.close(fd);
        if (c.write(fd, &proof, @sizeOf(Proof)) != @sizeOf(Proof)) return error.ProofWrite;
    }
    return (proof.ready_sec - proof.marker_sec) * 1000 + @divTrunc(proof.ready_nsec - proof.marker_nsec, 1000000);
}
test "a slow first start stays a failure after later restarts" {
    try std.testing.expect(valid(499));
    try std.testing.expect(!valid(1000));
    try std.testing.expect(!valid(1977144));
    try std.testing.expect(!valid(-1));
}
