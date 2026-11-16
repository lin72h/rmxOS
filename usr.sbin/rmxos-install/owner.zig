// Shared owner validation and the only writer of owner state.
const std = @import("std");
const sys = @import("engine").sys;
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn hostname(h: []const u8) bool {
    if (h.len == 0 or h.len > 253) return false;
    var labels = std.mem.splitScalar(u8, h, '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63 or l[0] == '-' or l[l.len - 1] == '-') return false;
        for (l) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}
pub fn userName(u: []const u8) bool {
    if (u.len == 0 or u.len > 32 or !(std.ascii.isLower(u[0]) or u[0] == '_')) return false;
    for (u) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_' and ch != '-') return false;
    return !eq(u, "root") and !eq(u, "toor");
}
pub fn publicKey(text: []const u8) ![]const u8 {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidKey;
    for (line) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidKey;
    for ([_][]const u8{ "ssh-", "ecdsa-sha2-", "sk-" }) |p| if (std.mem.startsWith(u8, line, p) and std.mem.indexOfScalar(u8, line, ' ') != null) return line;
    return error.InvalidKey;
}

pub fn rcConf(a: std.mem.Allocator, template: []const u8, host: []const u8) ![]const u8 {
    const keys = [_][]const u8{ "hostname", "ifconfig_DEFAULT", "sshd_enable", "kld_list" };
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var ours = false;
        for (keys) |k| ours = ours or (std.mem.startsWith(u8, line, k) and line.len > k.len and line[k.len] == '=');
        if (!ours) try out.print(a, "{s}\n", .{line});
    }
    // mac_do lets the first user become root with mdo(1); sysctl.conf holds its rule.
    try out.print(a, "hostname=\"{s}\"\nifconfig_DEFAULT=\"DHCP\"\nsshd_enable=\"YES\"\nkld_list=\"mac_do\"\n", .{host});
    return out.items;
}
pub fn macDoRule(a: std.mem.Allocator, uid: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "security.mac.do.rules=\"uid={s}>uid=0,gid=*,+gid=*\"\n", .{uid});
}

pub const Values = struct { hostname: []const u8, user: []const u8, key: []const u8 };
pub fn optionSet(host: []const u8, user: []const u8, key: []const u8) !void {
    const count = @as(u8, @intFromBool(host.len != 0)) + @as(u8, @intFromBool(user.len != 0)) + @as(u8, @intFromBool(key.len != 0));
    if (count != 0 and count != 3) return error.Usage;
}
pub fn validate(v: Values) !void {
    if (!hostname(v.hostname)) return error.InvalidHostname;
    if (!userName(v.user)) return error.InvalidUser;
    _ = try publicKey(v.key);
}
pub fn at(ctx: sys.Ctx, root: []const u8, path: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(ctx.a, "{s}{s}", .{ std.mem.trimEnd(u8, root, "/"), path }, 0);
}
pub fn present(ctx: sys.Ctx, root: []const u8) !bool {
    if (sys.exists(try at(ctx, root, "/private/var/db/rmxos/owner"))) return true;
    const settings = sys.read(ctx.a, try at(ctx, root, "/private/etc/sysctl.conf")) catch |err| {
        if (err != error.Open) return err;
        return legacyLocked(ctx, root);
    };
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "security.mac.do.rules=")) return true;
    return legacyLocked(ctx, root);
}
fn legacyLocked(ctx: sys.Ctx, root: []const u8) !bool {
    const passwd = try sys.read(ctx.a, try at(ctx, root, "/private/etc/master.passwd"));
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "root:*LOCKED*")) return true;
    return false;
}
pub fn machineRcConf(a: std.mem.Allocator, template: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var ours = false;
        for ([_][]const u8{ "hostname", "ifconfig_DEFAULT", "sshd_enable", "kld_list" }) |k| ours = ours or (std.mem.startsWith(u8, line, k) and line.len > k.len and line[k.len] == '=');
        if (!ours) try out.print(a, "{s}\n", .{line});
    }
    try out.appendSlice(a, "ifconfig_DEFAULT=\"DHCP\"\nsshd_enable=\"YES\"\n");
    return out.items;
}
// Lock the existing etc directory inode, not a file pw/pwd_mkdb replaces.
// Validation and refusal neither create a lock file nor change target files.
pub fn apply(ctx: sys.Ctx, root: []const u8, v: Values) !void {
    try validate(v);
    if (sys.c.geteuid() != 0) return error.NotRoot;
    if (ctx.fixture and !std.mem.startsWith(u8, root, try ctx.fmt("{s}/", .{ctx.root}))) return error.FixtureRoot;
    const etc = try at(ctx, root, "/private/etc");
    const lock = sys.c.open(etc, sys.c.O_RDONLY | sys.c.O_DIRECTORY | sys.c.O_CLOEXEC);
    if (lock < 0) return error.OwnerRoot;
    defer _ = sys.c.close(lock);
    if (sys.c.flock(lock, sys.c.LOCK_EX) != 0) return error.OwnerLock;
    if (try present(ctx, root)) return error.AlreadyOwned;
    const passwd = try sys.read(ctx.a, try at(ctx, root, "/private/etc/master.passwd"));
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, v.user) and line.len > v.user.len and line[v.user.len] == ':') return error.UserExists;
    const rc = try at(ctx, root, "/private/etc/rc.conf");
    const rc_text = try rcConf(ctx.a, sys.read(ctx.a, rc) catch "", v.hostname);
    const key = try publicKey(v.key);
    _ = try sys.capture(ctx, &.{ "/usr/sbin/pw", "-V", etc, "useradd", "-n", v.user, "-d", try ctx.fmt("/Users/{s}", .{v.user}), "-s", "/bin/sh", "-c", v.user, "-w", "no" });
    const shown = sys.trim(try sys.capture(ctx, &.{ "/usr/sbin/pw", "-V", etc, "usershow", "-n", v.user }));
    var fields = std.mem.splitScalar(u8, shown, ':');
    _ = fields.next();
    _ = fields.next();
    const uid = fields.next() orelse return error.UserShow;
    const gid = fields.next() orelse return error.UserShow;
    // The user's way in comes first: a failure before the lock leaves root
    // as it was, on the console. rmxos-owner(8) lists what each step leaves.
    const u = try std.fmt.parseInt(u32, uid, 10);
    const g = try std.fmt.parseInt(u32, gid, 10);
    const home = try at(ctx, root, try ctx.fmt("/Users/{s}", .{v.user}));
    const ssh = try ctx.z(try ctx.fmt("{s}/.ssh", .{home}));
    const keys = try ctx.z(try ctx.fmt("{s}/.ssh/authorized_keys", .{home}));
    for ([_]struct { p: [:0]const u8, mode: sys.c.mode_t }{ .{ .p = home, .mode = 0o755 }, .{ .p = ssh, .mode = 0o700 } }) |d| {
        if (sys.c.mkdir(d.p, d.mode) != 0 and !sys.exists(d.p)) return error.Home;
        if (sys.c.chown(d.p, u, g) != 0 or sys.c.chmod(d.p, d.mode) != 0) return error.Home;
    }
    try sys.replace(ctx.a, keys, try ctx.fmt("{s}\n", .{key}));
    if (sys.c.chown(keys, u, g) != 0 or sys.c.chmod(keys, 0o600) != 0) return error.Home;
    const settings = try at(ctx, root, "/private/etc/sysctl.conf");
    try sys.replace(ctx.a, settings, try ctx.fmt("{s}{s}", .{ sys.read(ctx.a, settings) catch "", try macDoRule(ctx.a, uid) }));
    try sys.replace(ctx.a, rc, rc_text);
    // Root last, then the databases; the marker records completion.
    _ = try sys.capture(ctx, &.{ "/usr/sbin/pw", "-V", etc, "lock", "root" });
    _ = try sys.capture(ctx, &.{ "/usr/sbin/pwd_mkdb", "-d", etc, "-p", try at(ctx, root, "/private/etc/master.passwd") });
    try sys.replace(ctx.a, try at(ctx, root, "/private/var/db/rmxos/owner"), try ctx.fmt("{s}\n", .{v.user}));
}
