// The first owner, using the same writer as rmxos-install.
const std = @import("std");
const sys = @import("engine").sys;
pub const owner = @import("owner.zig");
pub const Options = struct { hostname: []const u8 = "", user: []const u8 = "", key: []const u8 = "", root: []const u8 = "/" };
pub fn parse(args: []const []const u8) !Options {
    var o = Options{};
    var seen = [_]bool{false} ** 4;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const k = for ([_][]const u8{ "-hostName", "-addUser", "-sshPublicKey", "-altRoot" }, 0..) |name, n| {
            if (std.mem.eql(u8, name, args[i])) break n;
        } else return error.Usage;
        if (seen[k] or i + 1 >= args.len or args[i + 1].len == 0) return error.Usage;
        seen[k] = true;
        switch (k) {
            0 => o.hostname = args[i + 1],
            1 => o.user = args[i + 1],
            2 => o.key = args[i + 1],
            else => o.root = args[i + 1],
        }
    }
    if (!seen[0] or !seen[1] or !seen[2]) return error.Usage;
    if (o.root.len == 0 or o.root[0] != '/' or std.mem.indexOf(u8, o.root, "..") != null) return error.InvalidAltroot;
    if (!owner.hostname(o.hostname)) return error.InvalidHostname;
    if (!owner.userName(o.user)) return error.InvalidUser;
    return o;
}
pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const ctx = sys.Ctx.init(arena.allocator());
    const args = init.args.toSlice(ctx.a) catch return 1;
    const o = parse(args[1..]) catch |err| {
        sys.writeAll(2, "usage: sysadminctl -addUser USER -hostName HOST -sshPublicKey FILE [-altRoot DIR]\n") catch {};
        return fail(ctx, err);
    };
    const key = sys.read(ctx.a, ctx.z(o.key) catch return 1) catch |err| return fail(ctx, err);
    owner.apply(ctx, o.root, .{ .hostname = o.hostname, .user = o.user, .key = key }) catch |err| return fail(ctx, err);
    ctx.out("sysadminctl: owner {s} added; root locked\n", .{o.user});
    return 0;
}
fn fail(ctx: sys.Ctx, err: anyerror) u8 {
    const msg = ctx.fmt("sysadminctl: {s}\n", .{@errorName(err)}) catch return 1;
    sys.writeAll(2, msg) catch {};
    return 1;
}
