// rmxos-owner(8): the first owner, using the same writer as rmxos-install
// and the installer's option names.
const std = @import("std");
const sys = @import("engine").sys;
pub const owner = @import("owner.zig");
pub const usage = "usage: rmxos-owner --hostname NAME --user NAME --key FILE [--altroot DIR]\n";
pub const Options = struct { hostname: []const u8 = "", user: []const u8 = "", key: []const u8 = "", altroot: []const u8 = "/" };
const names = [_][]const u8{ "--hostname", "--user", "--key", "--altroot" };
pub fn parse(args: []const []const u8) !Options {
    var o = Options{};
    var seen = [_]bool{false} ** names.len;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const k = for (names, 0..) |name, n| {
            if (std.mem.eql(u8, name, args[i])) break n;
        } else return error.Usage;
        if (seen[k] or i + 1 >= args.len or args[i + 1].len == 0) return error.Usage;
        seen[k] = true;
        switch (k) {
            0 => o.hostname = args[i + 1],
            1 => o.user = args[i + 1],
            2 => o.key = args[i + 1],
            else => o.altroot = args[i + 1],
        }
    }
    if (!seen[0] or !seen[1] or !seen[2]) return error.Usage;
    if (o.altroot[0] != '/' or std.mem.indexOf(u8, o.altroot, "..") != null) return error.InvalidAltroot;
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
        sys.writeAll(2, usage) catch {};
        return fail(ctx, err);
    };
    const key = sys.read(ctx.a, ctx.z(o.key) catch return 1) catch |err| return fail(ctx, err);
    owner.apply(ctx, o.altroot, .{ .hostname = o.hostname, .user = o.user, .key = key }) catch |err| return fail(ctx, err);
    ctx.out("rmxos-owner: owner {s} added; root locked\n", .{o.user});
    return 0;
}
fn fail(ctx: sys.Ctx, err: anyerror) u8 {
    const msg = ctx.fmt("rmxos-owner: {s}\n", .{@errorName(err)}) catch return 1;
    sys.writeAll(2, msg) catch {};
    return 1;
}
