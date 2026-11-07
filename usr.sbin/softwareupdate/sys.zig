// Process, file and environment helpers for softwareupdate.
//
// Host fixtures set RMXOS_SU_FIXTURE=DIR: Data and configuration paths are
// read below DIR, the running environment is DIR/running, the pool must be an
// rmxsu* fixture pool, and a restart writes DIR/rebooted instead of rebooting.
// The fixture boot happened at the time(3) second in DIR/booted (without it,
// when the host booted), and only msdosfs mounts below DIR are ESPs.
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
    @cInclude("sys/file.h");
    @cInclude("sys/wait.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
    @cInclude("string.h");
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

pub const OperationLock = struct {
    fd: c_int,
    pub fn release(self: OperationLock) void {
        _ = c.close(self.fd);
    }
};

// Keep the inode: unlinking a flock file would permit two different locks.
// O_CLOEXEC prevents a command invoked during the operation retaining it.
// A held lock is refused, or with `wait` (the boot check) waited for.
pub fn operationLock(ctx: Ctx, wait: bool) !?OperationLock {
    const p = try ctx.path("/private/var/db/rmxos/softwareupdate.lock");
    try mkdirs(ctx.a, std.fs.path.dirname(p).?);
    const fd = c.open(p, c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return error.OperationLock;
    errdefer _ = c.close(fd);
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        var buf: [32]u8 = undefined;
        var n: isize = 0;
        // The holder writes its PID immediately after acquiring flock.
        for (0..20) |_| {
            n = c.pread(fd, &buf, buf.len, 0);
            if (n > 0) break;
            _ = c.usleep(1000);
        }
        const holder = if (n > 0) trim(buf[0..@intCast(n)]) else "unknown";
        if (!wait) {
            _ = ctx.refuse("operation held by PID {s}", .{holder});
            _ = c.close(fd);
            return null;
        }
        ctx.out("Waiting for the operation held by PID {s}.\n", .{holder});
        while (c.flock(fd, c.LOCK_EX) != 0) if (c.__error().* != c.EINTR) return error.OperationLock;
    }
    const pid = try ctx.fmt("{d}\n", .{c.getpid()});
    if (c.ftruncate(fd, 0) != 0) return error.OperationLock;
    try writeAll(fd, pid);
    if (c.fsync(fd) != 0) return error.OperationLock;
    return .{ .fd = fd };
}

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

// A setting file: a regular file owned by root and writable by nobody else.
pub fn readOwned(a: std.mem.Allocator, p: [:0]const u8) ![]const u8 {
    const fd = c.open(p, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return error.UnsafeSetting;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG or st.st_uid != 0 or st.st_mode & 0o022 != 0)
        return error.UnsafeSetting;
    return readFd(a, fd, 1024 * 1024);
}

// The current errno's text.
pub fn lastError(a: std.mem.Allocator) []const u8 {
    return a.dupe(u8, std.mem.span(c.strerror(c.__error().*))) catch "error";
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
    const dir = try a.dupeZ(u8, std.fs.path.dirname(p) orelse "/");
    const dfd = c.open(dir, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (dfd < 0) return error.Sync;
    defer _ = c.close(dfd);
    if (c.fsync(dfd) != 0) return error.Sync;
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

// Seconds since boot.
pub fn uptime(ctx: Ctx) !u64 {
    if (ctx.fixture) if (read(ctx.a, try ctx.path("/booted"))) |text| {
        const booted = std.fmt.parseInt(i64, trim(text), 10) catch return error.Clock;
        return @intCast(@max(0, c.time(null) - booted));
    } else |_| {};
    var t: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_UPTIME, &t) != 0 or t.tv_sec < 0) return error.Clock;
    return @intCast(t.tv_sec);
}

// Wait up to `seconds`; true when SIGTERM, SIGINT or SIGHUP (a shutdown)
// arrives first. The signals are blocked only while waiting.
pub fn shutdownWithin(seconds: u64) !bool {
    var set: c.sigset_t = undefined;
    var old: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    for ([_]c_int{ c.SIGTERM, c.SIGINT, c.SIGHUP }) |s| _ = c.sigaddset(&set, s);
    if (c.sigprocmask(c.SIG_BLOCK, &set, &old) != 0) return error.Signal;
    defer _ = c.sigprocmask(c.SIG_SETMASK, &old, null);
    const ts = c.struct_timespec{ .tv_sec = @intCast(seconds), .tv_nsec = 0 };
    return c.sigtimedwait(&set, null, &ts) > 0;
}

// Mount points of msdosfs file systems.
pub fn msdosfsMounts(ctx: Ctx) ![]const []const u8 {
    const n = c.getfsstat(null, 0, c.MNT_NOWAIT);
    if (n < 0) return error.MountList;
    const buf = try ctx.a.alloc(c.struct_statfs, @as(usize, @intCast(n)) + 8);
    const got = c.getfsstat(buf.ptr, @intCast(buf.len * @sizeOf(c.struct_statfs)), c.MNT_NOWAIT);
    if (got < 0) return error.MountList;
    var list: std.ArrayList([]const u8) = .empty;
    for (buf[0..@intCast(got)]) |*s| {
        if (!std.mem.eql(u8, std.mem.sliceTo(&s.f_fstypename, 0), "msdosfs")) continue;
        const on = std.mem.sliceTo(&s.f_mntonname, 0);
        // A host fixture never sees the host's own ESP.
        if (ctx.fixture and !(std.mem.startsWith(u8, on, ctx.root) and on.len > ctx.root.len and on[ctx.root.len] == '/')) continue;
        try list.append(ctx.a, try ctx.a.dupe(u8, on));
    }
    return list.items;
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
