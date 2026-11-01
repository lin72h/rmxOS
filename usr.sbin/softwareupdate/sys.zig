// Process, file and environment helpers for softwareupdate.
//
// Host fixtures set RMXOS_SU_FIXTURE=DIR: Data and configuration paths are
// read below DIR, the running environment is DIR/running, the pool must be an
// rmxsu* fixture pool, and a restart writes DIR/rebooted instead of rebooting.
const std = @import("std");
pub const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/param.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("signal.h");
});

pub const Ctx = struct {
    a: std.mem.Allocator,
    // "" on a real system; the fixture directory under RMXOS_SU_FIXTURE.
    root: []const u8,
    fixture: bool,
    verbose: bool = false,

    pub fn init(a: std.mem.Allocator) Ctx {
        const f = c.getenv("RMXOS_SU_FIXTURE");
        if (f) |p| return .{ .a = a, .root = std.mem.span(p), .fixture = true };
        return .{ .a = a, .root = "", .fixture = false };
    }
    pub fn path(self: Ctx, p: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.a, "{s}{s}", .{ self.root, p }, 0);
    }
    pub fn fmt(self: Ctx, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.a, f, args);
    }
    pub fn z(self: Ctx, s: []const u8) ![:0]const u8 {
        return self.a.dupeZ(u8, s);
    }
    pub fn out(self: Ctx, comptime f: []const u8, args: anytype) void {
        writeAll(1, std.fmt.allocPrint(self.a, f, args) catch return) catch {};
    }
    // One line on stderr, exit status 1.
    pub fn refuse(self: Ctx, comptime f: []const u8, args: anytype) u8 {
        writeAll(2, std.fmt.allocPrint(self.a, "softwareupdate: " ++ f ++ "\n", args) catch return 1) catch {};
        return 1;
    }
};

pub fn writeAll(fd: c_int, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return error.Write;
        rest = rest[@intCast(n)..];
    }
}

pub fn readFd(a: std.mem.Allocator, fd: c_int, limit: usize) ![]const u8 {
    var list: std.Io.Writer.Allocating = .init(a);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.Read;
        if (n == 0) break;
        if (list.written().len + @as(usize, @intCast(n)) > limit) return error.TooLarge;
        try list.writer.writeAll(buf[0..@intCast(n)]);
    }
    return list.written();
}

pub fn read(a: std.mem.Allocator, p: [:0]const u8) ![]const u8 {
    const fd = c.open(p, c.O_RDONLY);
    if (fd < 0) return error.Open;
    defer _ = c.close(fd);
    return readFd(a, fd, 64 * 1024 * 1024);
}

pub fn exists(p: [:0]const u8) bool {
    var st: c.struct_stat = undefined;
    return c.lstat(p, &st) == 0;
}

pub fn size(p: [:0]const u8) ?u64 {
    var st: c.struct_stat = undefined;
    if (c.stat(p, &st) != 0) return null;
    return @intCast(st.st_size);
}

pub fn mkdirs(a: std.mem.Allocator, p: []const u8) !void {
    var i: usize = 1;
    while (i <= p.len) : (i += 1) {
        if (i == p.len or p[i] == '/') {
            const part = try a.dupeZ(u8, p[0..i]);
            if (c.mkdir(part, 0o755) != 0 and !exists(part)) return error.Mkdir;
        }
    }
}

// Write a file by temporary name, fsync and rename.
pub fn replace(a: std.mem.Allocator, p: [:0]const u8, bytes: []const u8) !void {
    try mkdirs(a, std.fs.path.dirname(p) orelse "/");
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.new", .{p}, 0);
    _ = c.unlink(tmp);
    const fd = c.open(tmp, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW, @as(c_uint, 0o644));
    if (fd < 0) return error.Create;
    errdefer _ = c.unlink(tmp);
    {
        defer _ = c.close(fd);
        try writeAll(fd, bytes);
        if (c.fsync(fd) != 0) return error.Sync;
    }
    if (c.rename(tmp, p) != 0) return error.Rename;
}

pub fn append(a: std.mem.Allocator, p: [:0]const u8, bytes: []const u8) !void {
    try mkdirs(a, std.fs.path.dirname(p) orelse "/");
    const fd = c.open(p, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_NOFOLLOW, @as(c_uint, 0o644));
    if (fd < 0) return error.Create;
    defer _ = c.close(fd);
    try writeAll(fd, bytes);
    if (c.fsync(fd) != 0) return error.Sync;
}

pub const Result = struct { status: c_int, stdout: []const u8, stderr: []const u8 };

// Run argv with stdin from `input` (or /dev/null); stdout and stderr captured
// (stderr through an unlinked temporary file, so two pipes cannot deadlock).
pub fn run(a: std.mem.Allocator, argv: []const []const u8, input: ?[:0]const u8) !Result {
    const errors = c.tmpfile() orelse return error.TemporaryFile;
    defer _ = c.fclose(errors);
    var pipes: [2]c_int = undefined;
    if (c.pipe(&pipes) != 0) return error.Pipe;
    defer _ = c.close(pipes[0]);
    const av = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |v, i| av[i] = (try a.dupeZ(u8, v)).ptr;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipes[1]);
        return error.Fork;
    }
    if (pid == 0) {
        const in = c.open(if (input) |p| p.ptr else "/dev/null", c.O_RDONLY);
        if (in < 0) c._exit(126);
        _ = c.dup2(in, 0);
        _ = c.close(pipes[0]);
        _ = c.dup2(pipes[1], 1);
        _ = c.close(pipes[1]);
        _ = c.dup2(c.fileno(errors), 2);
        _ = c.execv(av[0].?, @ptrCast(av.ptr));
        c._exit(127);
    }
    _ = c.close(pipes[1]);
    var status: c_int = 0;
    const stdout = readFd(a, pipes[0], 32 * 1024 * 1024) catch |err| {
        _ = c.kill(pid, 15);
        _ = c.waitpid(pid, &status, 0);
        return err;
    };
    while (c.waitpid(pid, &status, 0) != pid) {}
    if (c.lseek(c.fileno(errors), 0, c.SEEK_SET) < 0) return error.Seek;
    const stderr = try readFd(a, c.fileno(errors), 1024 * 1024);
    return .{ .status = status, .stdout = stdout, .stderr = stderr };
}

// Stdout of a command that must succeed; its first stderr line otherwise.
pub fn capture(ctx: Ctx, argv: []const []const u8) ![]const u8 {
    const r = try run(ctx.a, argv, null);
    if (r.status != 0) {
        failure = firstLine(r.stderr);
        return error.CommandFailed;
    }
    return r.stdout;
}
pub var failure: []const u8 = "";

pub fn firstLine(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn now(a: std.mem.Allocator) ![]const u8 {
    var t: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.gmtime_r(&t, &tm);
    var buf: [32]u8 = undefined;
    const n = c.strftime(&buf, buf.len, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return a.dupe(u8, buf[0..n]);
}

pub fn sha256File(p: [:0]const u8) ![64]u8 {
    const fd = c.open(p, c.O_RDONLY);
    if (fd < 0) return error.Open;
    defer _ = c.close(fd);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.Read;
        if (n == 0) break;
        h.update(buf[0..@intCast(n)]);
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d, .lower);
}

// The ZFS dataset mounted at / (fixture: DIR/running).
pub fn running(ctx: Ctx) ![]const u8 {
    if (ctx.fixture) return trim(try read(ctx.a, try ctx.path("/running")));
    var s: c.struct_statfs = undefined;
    if (c.statfs("/", &s) != 0) return error.Statfs;
    if (!std.mem.eql(u8, std.mem.sliceTo(&s.f_fstypename, 0), "zfs")) return error.NotZfsRoot;
    return ctx.a.dupe(u8, std.mem.sliceTo(&s.f_mntfromname, 0));
}

pub fn restart(ctx: Ctx) !void {
    if (ctx.fixture) return replace(ctx.a, try ctx.path("/rebooted"), "reboot\n");
    // reboot(8) stops processes and calls reboot(2) itself, as poweroff did.
    _ = try capture(ctx, &.{"/sbin/reboot"});
}
