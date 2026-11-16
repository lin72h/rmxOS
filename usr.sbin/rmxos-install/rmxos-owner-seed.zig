// One RunAtLoad invocation. Only an explicitly labelled FAT volume is read.
const std = @import("std");
const sys = @import("engine").sys;
const owner = @import("owner.zig");
extern fn rmxos_owner_log([*:0]const u8) void;
pub const label = "RMXOWNER";
fn report(ctx: sys.Ctx, text: []const u8) void {
    const z = ctx.z(text) catch return;
    rmxos_owner_log(z);
    // One diagnostic line also reaches launchd's console, including before logd.
    sys.writeAll(2, text) catch {};
    sys.writeAll(2, "\n") catch {};
}
pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ctx = sys.Ctx.init(arena.allocator());
    const args = init.args.toSlice(ctx.a) catch return 1;
    var root: []const u8 = "/";
    if (args.len != 1) {
        if (args.len != 3 or !std.mem.eql(u8, args[1], "-altRoot") or args[2].len == 0 or args[2][0] != '/' or std.mem.indexOf(u8, args[2], "..") != null) {
            report(ctx, "owner-seed: Usage");
            return 1;
        }
        root = args[2];
    }
    run(ctx, root) catch |err| {
        report(ctx, ctx.fmt("owner-seed: {s}", .{@errorName(err)}) catch "owner-seed: error");
        return 1;
    };
    return 0;
}
fn run(ctx: sys.Ctx, root: []const u8) !void {
    if (ctx.fixture and !std.mem.startsWith(u8, root, try ctx.fmt("{s}/", .{ctx.root}))) return error.FixtureRoot;
    if (try owner.present(ctx, root)) return;
    const device: []const u8 = "/dev/msdosfs/" ++ label;
    if (!sys.exists(try ctx.z(device))) return;
    var command: []const u8 = "/usr/sbin/sysadminctl";
    if (ctx.fixture) {
        // Exercise real label discovery, but never use a host disk in a fixture.
        const labels = try sys.capture(ctx, &.{ "/sbin/glabel", "status", "-s" });
        var rows = std.mem.splitScalar(u8, labels, '\n');
        var provider: ?[]const u8 = null;
        while (rows.next()) |row| {
            var words = std.mem.tokenizeAny(u8, row, " \t\r");
            if (!std.mem.eql(u8, words.next() orelse continue, "msdosfs/" ++ label)) continue;
            _ = words.next() orelse return error.FixtureDevice;
            provider = words.next() orelse return error.FixtureDevice;
        }
        const md_name = provider orelse return error.FixtureDevice;
        if (!std.mem.startsWith(u8, md_name, "md")) return error.FixtureDevice;
        const number = md_name[2..];
        if (number.len == 0) return error.FixtureDevice;
        for (number) |ch| if (!std.ascii.isDigit(ch)) return error.FixtureDevice;
        const md = try sys.capture(ctx, &.{ "/sbin/mdconfig", "-lv", "-u", md_name });
        var fields = std.mem.tokenizeAny(u8, md, " \t\r\n");
        var own = false;
        while (fields.next()) |field| if (std.mem.startsWith(u8, field, try ctx.fmt("{s}/", .{ctx.root}))) {
            own = true;
        };
        if (!own) return error.FixtureDevice;
        command = std.mem.span(sys.c.getenv("RMXOS_OWNER_COMMAND") orelse return error.FixtureCommand);
        if (!std.mem.startsWith(u8, command, try ctx.fmt("{s}/", .{ctx.root}))) return error.FixtureCommand;
    }
    const mountpoint = try owner.at(ctx, root, "/private/var/run/rmxos-owner-seed");
    if (sys.c.mkdir(mountpoint, 0o700) != 0) return error.MountDirectory;
    defer _ = sys.c.rmdir(mountpoint);
    _ = try sys.capture(ctx, &.{ "/sbin/mount_msdosfs", "-o", "ro", device, mountpoint });
    var mounted = true;
    defer if (mounted) {
        _ = sys.capture(ctx, &.{ "/sbin/umount", mountpoint }) catch {};
    };
    const host = read(ctx, mountpoint, "hostname") catch return error.MissingHostname;
    const user = read(ctx, mountpoint, "user") catch return error.MissingUser;
    const key = read(ctx, mountpoint, "authorized_keys") catch return error.MissingAuthorizedKeys;
    try owner.validate(.{ .hostname = std.mem.trim(u8, host, "\r\n"), .user = std.mem.trim(u8, user, "\r\n"), .key = key });
    const keyfile = try ctx.fmt("{s}/authorized_keys", .{mountpoint});
    _ = try sys.capture(ctx, &.{ command, "-hostName", std.mem.trim(u8, host, "\r\n"), "-addUser", std.mem.trim(u8, user, "\r\n"), "-sshPublicKey", keyfile, "-altRoot", root });
    _ = try sys.capture(ctx, &.{ "/sbin/umount", mountpoint });
    mounted = false;
    report(ctx, "owner-seed: owner applied; root locked");
}
fn read(ctx: sys.Ctx, dir: []const u8, name: []const u8) ![]const u8 {
    const path = try ctx.z(try ctx.fmt("{s}/{s}", .{ dir, name }));
    const fd = sys.c.open(path, sys.c.O_RDONLY | sys.c.O_NOFOLLOW | sys.c.O_CLOEXEC);
    if (fd < 0) return error.SeedFile;
    defer _ = sys.c.close(fd);
    var st: sys.c.struct_stat = undefined;
    if (sys.c.fstat(fd, &st) != 0 or st.st_mode & sys.c.S_IFMT != sys.c.S_IFREG) return error.SeedFile;
    return sys.readFd(ctx.a, fd, 65536);
}
