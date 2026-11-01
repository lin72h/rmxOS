const std = @import("std");
const c = @cImport({
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/file.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
});
pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = init.args.toSlice(a) catch return 2;
    if (args.len != 3) return 2;
    const root = args[2];
    const pidpath = std.fmt.allocPrintSentinel(a, "{s}/var/run/syslog.pid", .{root}, 0) catch return 2;
    const sockpath = std.fmt.allocPrintSentinel(a, "{s}/var/run/log", .{root}, 0) catch return 2;
    if (std.mem.eql(u8, args[1], "fixture")) {
        const fd = c.open(pidpath, c.O_CREAT | c.O_WRONLY | c.O_TRUNC, @as(c_uint, 0o644));
        if (fd < 0 or c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return 2;
        _ = c.dprintf(fd, "%d\n", c.getpid());
        const sock = c.socket(c.AF_UNIX, c.SOCK_DGRAM, 0);
        var address = std.mem.zeroes(c.struct_sockaddr_un);
        if (sockpath.len >= address.sun_path.len) return 2;
        address.sun_family = c.AF_UNIX;
        address.sun_len = @intCast(@sizeOf(c.struct_sockaddr_un));
        @memcpy(address.sun_path[0..sockpath.len], sockpath);
        if (sock < 0 or c.bind(sock, @ptrCast(&address), address.sun_len) != 0) return 2;
        _ = c.printf("READY pid=%d\n", c.getpid());
        _ = c.fflush(null);
        var byte: u8 = 0;
        _ = c.read(0, &byte, 1);
        return 0;
    }
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const phase = a.dupeZ(u8, args[1]) catch return 2;
    _ = c.printf("OP351_TIME phase=%s sec=%jd nsec=%ld\n", phase.ptr, @as(i64, @intCast(ts.tv_sec)), ts.tv_nsec);
    for ([_][:0]const u8{ pidpath, sockpath }) |path| {
        var st: c.struct_stat = undefined;
        const rc = c.lstat(path, &st);
        if (rc == 0) {
            _ = c.printf("OP351_FILE phase=%s path=%s rc=0 type=%u inode=%ju mtime=%jd.%09ld ctime=%jd.%09ld\n", phase.ptr, path.ptr, @as(c_uint, @intCast(st.st_mode & c.S_IFMT)), @as(u64, st.st_ino), @as(i64, st.st_mtim.tv_sec), st.st_mtim.tv_nsec, @as(i64, st.st_ctim.tv_sec), st.st_ctim.tv_nsec);
        } else _ = c.printf("OP351_FILE phase=%s path=%s rc=-1\n", phase.ptr, path.ptr);
    }
    const file = c.fopen(pidpath, "r");
    var pid: c_int = -1;
    if (file) |f| {
        _ = c.fscanf(f, "%d", &pid);
        _ = c.fclose(f);
    }
    _ = c.printf("OP351_PID phase=%s observed=%d\n", phase.ptr, pid);
    return 0;
}
