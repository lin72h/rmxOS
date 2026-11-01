// The update lifecycle on the sealed layout: an update is a zfs send -i delta
// received into pool/base/main as it is, cloned to pool/ROOT/<snapshot>,
// activated for one boot and confirmed by the boot check. No promotion ever.
const std = @import("std");
const sys = @import("sys.zig");
const catalog = @import("catalog.zig");
const Ctx = sys.Ctx;

pub const fallback_path = "/private/var/db/rmxos/fallback";
pub const history_path = "/private/var/db/rmxos/history";
pub const ownership_path = "/System/Library/LaunchDaemons/org.rmxos.softwareupdate.ownership";
const ownership_legacy = "/etc/launchd.d/org.rmxos.softwareupdate.ownership";
const data_sets = [_][]const u8{ "private", "Users", "Library", "local" };

pub const Env = struct {
    pool: []const u8,
    root: []const u8,
    base: []const u8,
    running: []const u8,
    fn name(_: Env, dataset: []const u8) []const u8 {
        return dataset[(std.mem.lastIndexOfScalar(u8, dataset, '/') orelse return dataset) + 1 ..];
    }
};

pub fn discover(ctx: Ctx) !Env {
    const running = try sys.running(ctx);
    const slash = std.mem.indexOfScalar(u8, running, '/') orelse return error.NotSealedRoot;
    const pool = running[0..slash];
    // A host fixture never acts on the host's own pool.
    if (ctx.fixture and !std.mem.startsWith(u8, pool, "rmxsu")) return error.FixturePool;
    const root = try ctx.fmt("{s}/ROOT", .{pool});
    if (!std.mem.startsWith(u8, running, root) or running.len <= root.len + 1) return error.NotSealedRoot;
    return .{ .pool = pool, .root = root, .base = try ctx.fmt("{s}/base/main", .{pool}), .running = running };
}

fn zfs(ctx: Ctx, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.a, "/sbin/zfs");
    try argv.appendSlice(ctx.a, args);
    return sys.capture(ctx, argv.items);
}
fn get(ctx: Ctx, prop: []const u8, dataset: []const u8) ![]const u8 {
    return sys.trim(try zfs(ctx, &.{ "get", "-Hp", "-o", "value", prop, dataset }));
}
fn bootfs(ctx: Ctx, env: Env) ![]const u8 {
    return sys.trim(try sys.capture(ctx, &.{ "/sbin/zpool", "get", "-H", "-o", "value", "bootfs", env.pool }));
}

pub const Snapshot = struct { name: []const u8, guid: []const u8 };
// The chain head: pool/base/main's newest snapshot.
pub fn head(ctx: Ctx, env: Env) !Snapshot {
    const text = try zfs(ctx, &.{ "list", "-H", "-p", "-t", "snapshot", "-o", "name,guid", "-s", "createtxg", "-d", "1", env.base });
    var last: ?Snapshot = null;
    var lines = std.mem.splitScalar(u8, sys.trim(text), '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const n = cols.next() orelse continue;
        const g = cols.next() orelse continue;
        last = .{ .name = n, .guid = g };
    }
    return last orelse error.NoBaseSnapshot;
}

pub const Header = struct { from: u64, to: u64, name: []const u8 };
// DRR_BEGIN of a zfs send stream: drr_type 0, magic at 8, toguid at 40,
// fromguid at 48, toname at 56 (sys/fs/zfs.h dmu_replay_record).
pub fn header(ctx: Ctx, p: [:0]const u8) !Header {
    const fd = sys.c.open(p, sys.c.O_RDONLY);
    if (fd < 0) return error.Open;
    defer _ = sys.c.close(fd);
    var b: [312]u8 = undefined;
    if (sys.c.read(fd, &b, b.len) != b.len) return error.TruncatedStream;
    if (std.mem.readInt(u32, b[0..4], .little) != 0 or std.mem.readInt(u64, b[8..16], .little) != 0x2F5BACBAC) return error.NotAStream;
    return .{
        .from = std.mem.readInt(u64, b[48..56], .little),
        .to = std.mem.readInt(u64, b[40..48], .little),
        .name = try ctx.a.dupe(u8, std.mem.sliceTo(b[56..312], 0)),
    };
}

pub const Record = struct {
    environment: []const u8 = "",
    time: []const u8 = "",
    label: []const u8 = "",
    staged: []const u8 = "",
    confirm: []const u8 = "auto",
    state: []const u8 = "",
};
pub fn readRecord(ctx: Ctx) ?Record {
    const text = sys.read(ctx.a, ctx.path(fallback_path) catch return null) catch return null;
    var r = Record{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        inline for (.{ "environment", "time", "label", "staged", "confirm", "state" }) |f| {
            if (std.mem.eql(u8, k, f)) @field(r, f) = v;
        }
    }
    return r;
}
fn writeRecord(ctx: Ctx, r: Record) !void {
    try sys.replace(ctx.a, try ctx.path(fallback_path), try ctx.fmt(
        "environment={s}\ntime={s}\nlabel={s}\nstaged={s}\nconfirm={s}\nstate={s}\n",
        .{ r.environment, r.time, r.label, r.staged, r.confirm, r.state },
    ));
}
fn history(ctx: Ctx, action: []const u8, label: []const u8, environment: []const u8) !void {
    try sys.append(ctx.a, try ctx.path(history_path), try ctx.fmt("{s}\t{s}\t{s}\t{s}\n", .{ try sys.now(ctx.a), action, label, environment }));
}

// Refusals before anything is received, one line each.
pub fn install(ctx: Ctx, env: Env, u: catalog.Update, source: []const u8, manual: bool) !u8 {
    const written = try get(ctx, "written", env.base);
    if (!std.mem.eql(u8, written, "0"))
        return ctx.refuse("{s}: sealed base {s} changed (written={s}); nothing received", .{ u.label, env.base, written });
    const h = try head(ctx, env);
    if (!std.mem.eql(u8, h.guid, u.origin_guid))
        return ctx.refuse("{s}: update starts from GUID {s}, installed base {s} is GUID {s}; nothing received", .{ u.label, u.origin_guid, h.name, h.guid });
    if (readRecord(ctx)) |r| if (std.mem.eql(u8, r.state, "staged"))
        return ctx.refuse("{s}: {s} is already staged for the next boot; nothing received", .{ u.label, r.label });
    const path = catalog.stream(ctx, source, u) catch return ctx.refuse("{s}: stream {s} unavailable; nothing received", .{ u.label, u.stream });
    const got = sys.size(path) orelse 0;
    if (got != u.size)
        return ctx.refuse("{s}: stream is truncated ({d} of {d} bytes); nothing received", .{ u.label, got, u.size });
    const digest = try sys.sha256File(path);
    if (!std.mem.eql(u8, &digest, u.sha256))
        return ctx.refuse("{s}: stream sha256 {s} does not match the catalog; nothing received", .{ u.label, digest });
    const hd = header(ctx, path) catch return ctx.refuse("{s}: not a zfs send stream; nothing received", .{u.label});
    const origin = try ctx.fmt("{d}", .{hd.from});
    const target = try ctx.fmt("{d}", .{hd.to});
    if (!std.mem.eql(u8, origin, h.guid) or !std.mem.eql(u8, target, u.target_guid))
        return ctx.refuse("{s}: stream origin GUID {s} (target {s}) does not match base GUID {s}; nothing received", .{ u.label, origin, target, h.guid });

    const snapshot = try ctx.fmt("{s}@{s}", .{ env.base, u.snapshot });
    const r = try sys.run(ctx.a, &.{ "/sbin/zfs", "receive", "-u", env.base }, path);
    if (r.status != 0) return ctx.refuse("{s}: zfs receive failed: {s}", .{ u.label, sys.firstLine(r.stderr) });
    const guid = try get(ctx, "guid", snapshot);
    if (!std.mem.eql(u8, guid, u.target_guid)) return ctx.refuse("{s}: received {s} has GUID {s}, catalog {s}", .{ u.label, snapshot, guid, u.target_guid });

    const clone = try ctx.fmt("{s}/{s}", .{ env.root, u.snapshot });
    _ = try zfs(ctx, &.{ "clone", "-o", "mountpoint=/", "-o", "canmount=noauto", "-o", "readonly=on", snapshot, clone });
    _ = try sys.capture(ctx, &.{ "/sbin/bectl", "-r", env.root, "activate", "-t", u.snapshot });
    try writeRecord(ctx, .{ .environment = env.running, .time = try sys.now(ctx.a), .label = u.label, .staged = clone, .confirm = if (manual) "manual" else "auto", .state = "staged" });
    try history(ctx, "staged", u.label, clone);
    ctx.out("Installed {s} into {s}; it boots once on the next restart.\n", .{ u.label, clone });
    return 0;
}

fn confirmRunning(ctx: Ctx, env: Env, r: Record) !u8 {
    _ = try sys.capture(ctx, &.{ "/sbin/zpool", "set", try ctx.fmt("bootfs={s}", .{env.running}), env.pool });
    // The loader consumed the one-boot setting; clear any remainder.
    _ = sys.run(ctx.a, &.{ "/sbin/bectl", "-r", env.root, "activate", "-T" }, null) catch {};
    var n = r;
    n.state = "confirmed";
    try writeRecord(ctx, n);
    try history(ctx, "installed", r.label, env.running);
    ctx.out("Confirmed {s}: {s} is the boot environment.\n", .{ r.label, env.running });
    return retain(ctx, env);
}

// Every boot: the first boot of a staged environment confirms it (unless
// --no-auto-confirm was given); then the ownership list is asserted.
pub fn bootCheck(ctx: Ctx, env: Env) !u8 {
    var rc: u8 = 0;
    if (readRecord(ctx)) |r| {
        if (std.mem.eql(u8, r.state, "staged")) {
            if (std.mem.eql(u8, r.staged, env.running)) {
                if (std.mem.eql(u8, r.confirm, "manual")) {
                    var n = r;
                    n.state = "booted";
                    try writeRecord(ctx, n);
                    ctx.out("{s} is running; waiting for softwareupdate confirm.\n", .{r.label});
                } else rc = try confirmRunning(ctx, env, r);
            } else {
                var n = r;
                n.state = "not-confirmed";
                try writeRecord(ctx, n);
                try history(ctx, "not-confirmed", r.label, r.staged);
                ctx.out("{s} did not reach its boot check; {s} is running.\n", .{ r.label, env.running });
            }
        }
    }
    if (try ownership(ctx) != 0) rc = 1;
    return rc;
}

pub fn confirm(ctx: Ctx, env: Env) !u8 {
    const r = readRecord(ctx) orelse return ctx.refuse("no install is waiting for confirmation", .{});
    if (!std.mem.eql(u8, r.confirm, "manual")) return ctx.refuse("confirm is only for an install made with --no-auto-confirm", .{});
    if (!std.mem.eql(u8, r.state, "booted") or !std.mem.eql(u8, r.staged, env.running))
        return ctx.refuse("{s} is not the running environment; restart into it before confirm", .{r.label});
    return confirmRunning(ctx, env, r);
}

pub fn cancel(ctx: Ctx, env: Env) !u8 {
    const r = readRecord(ctx) orelse return ctx.refuse("no install is waiting for confirmation", .{});
    if (!std.mem.eql(u8, r.confirm, "manual")) return ctx.refuse("cancel is only for an install made with --no-auto-confirm", .{});
    if (std.mem.eql(u8, r.staged, env.running)) return ctx.refuse("{s} is running; use rollback", .{r.label});
    if (!std.mem.eql(u8, r.state, "staged")) return ctx.refuse("no install is waiting for confirmation", .{});
    _ = try sys.capture(ctx, &.{ "/sbin/bectl", "-r", env.root, "activate", "-T" });
    // Undo the receive too, so the same update installs again from this base.
    _ = try zfs(ctx, &.{ "destroy", r.staged });
    _ = try zfs(ctx, &.{ "destroy", try ctx.fmt("{s}@{s}", .{ env.base, env.name(r.staged) }) });
    // The received data stays in the base's head until it is rolled back.
    _ = try zfs(ctx, &.{ "rollback", (try head(ctx, env)).name });
    var n = r;
    n.state = "canceled";
    try writeRecord(ctx, n);
    try history(ctx, "canceled", r.label, r.staged);
    ctx.out("Canceled {s}; {s} stays the boot environment.\n", .{ r.label, env.running });
    return 0;
}

pub fn rollback(ctx: Ctx, env: Env) !u8 {
    const r = readRecord(ctx) orelse return ctx.refuse("no fallback environment recorded", .{});
    if (r.environment.len == 0) return ctx.refuse("no fallback environment recorded", .{});
    if (!std.mem.eql(u8, sys.trim(zfs(ctx, &.{ "list", "-H", "-o", "name", r.environment }) catch ""), r.environment))
        return ctx.refuse("fallback environment {s} no longer exists", .{r.environment});
    _ = try sys.capture(ctx, &.{ "/sbin/zpool", "set", try ctx.fmt("bootfs={s}", .{r.environment}), env.pool });
    _ = sys.run(ctx.a, &.{ "/sbin/bectl", "-r", env.root, "activate", "-T" }, null) catch {};
    var n = r;
    n.state = "rolled-back";
    try writeRecord(ctx, n);
    try history(ctx, "rollback", r.label, r.environment);
    ctx.out("Rolled back: {s} boots next.\n", .{r.environment});
    return 0;
}

// Keep the newest N environments (softwareupdate.conf retain, default 3),
// never the running, fallback or bootfs one, and the snapshots they use.
pub fn retain(ctx: Ctx, env: Env) !u8 {
    const n = std.fmt.parseInt(usize, catalog.setting(ctx, "retain") orelse "3", 10) catch 3;
    const text = try zfs(ctx, &.{ "list", "-H", "-p", "-o", "name,origin", "-S", "creation", "-d", "1", env.root });
    const keep_also = [_][]const u8{ env.running, if (readRecord(ctx)) |r| r.environment else "", bootfs(ctx, env) catch "" };
    var lines = std.mem.splitScalar(u8, sys.trim(text), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const name = cols.next() orelse continue;
        const origin = cols.next() orelse "-";
        if (std.mem.eql(u8, name, env.root)) continue;
        var protected = false;
        for (keep_also) |k| if (std.mem.eql(u8, k, name)) {
            protected = true;
        };
        if (count < n or protected) {
            count += 1;
            continue;
        }
        _ = try zfs(ctx, &.{ "destroy", name });
        try history(ctx, "removed", env.name(name), name);
        ctx.out("Removed {s}.\n", .{name});
        // A snapshot another environment still uses refuses its destroy; the
        // chain head is the newest environment's origin, which is kept.
        _ = sys.run(ctx.a, &.{ "/sbin/zfs", "destroy", origin }, null) catch {};
    }
    return 0;
}

fn tail(ctx: Ctx, rows: usize) ![]const []const u8 {
    const text = sys.read(ctx.a, try ctx.path(history_path)) catch return &.{};
    var all: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, sys.trim(text), '\n');
    while (lines.next()) |l| if (l.len > 0) try all.append(ctx.a, l);
    return all.items[all.items.len -| rows..];
}

pub fn status(ctx: Ctx, env: Env) !u8 {
    const h = try head(ctx, env);
    const origin = get(ctx, "origin", env.running) catch "-";
    const written = try get(ctx, "written", env.base);
    var label: []const u8 = origin[(std.mem.indexOfScalar(u8, origin, '@') orelse 0) + 1 ..];
    for (try tail(ctx, 1000)) |row| {
        var cols = std.mem.splitScalar(u8, row, '\t');
        _ = cols.next();
        const action = cols.next() orelse continue;
        const l = cols.next() orelse continue;
        const e = cols.next() orelse continue;
        if (std.mem.eql(u8, action, "installed") and std.mem.eql(u8, e, env.running)) label = l;
    }
    ctx.out("Installed: {s}\n", .{label});
    ctx.out("Environment: {s} (origin {s})\n", .{ env.running, origin });
    ctx.out("Base snapshot: {s} GUID {s}\n", .{ h.name, h.guid });
    if (std.mem.eql(u8, written, "0")) ctx.out("Base written: 0 (sealed)\n", .{}) else ctx.out("Base written: {s}: sealed-base change\n", .{written});
    ctx.out("Boot environment: {s}\n", .{bootfs(ctx, env) catch "-"});
    if (readRecord(ctx)) |r| {
        ctx.out("Fallback: {s} (from {s}, {s}, {s})\n", .{ r.environment, r.label, r.time, r.state });
    } else ctx.out("Fallback: none\n", .{});
    for (data_sets) |d| {
        const ds = try ctx.fmt("{s}/data/{s}", .{ env.pool, d });
        const mounted = get(ctx, "mounted", ds) catch "missing";
        ctx.out("Data {s}: {s}\n", .{ d, if (std.mem.eql(u8, mounted, "yes")) "mounted" else if (std.mem.eql(u8, mounted, "missing")) "missing" else "not mounted" });
    }
    ctx.out("History:\n", .{});
    for (try tail(ctx, 5)) |row| ctx.out("  {s}\n", .{row});
    return if (std.mem.eql(u8, written, "0")) 0 else 1;
}

// macOS's --history columns (Display Name, Date); ours under --verbose.
pub fn printHistory(ctx: Ctx) !u8 {
    if (ctx.verbose) ctx.out("{s: <40} {s: <22} {s: <14} {s}\n", .{ "Display Name", "Date", "Action", "Environment" }) else ctx.out("{s: <40} {s}\n", .{ "Display Name", "Date" });
    for (try tail(ctx, 100000)) |row| {
        var cols = std.mem.splitScalar(u8, row, '\t');
        const time = cols.next() orelse continue;
        const action = cols.next() orelse continue;
        const label = cols.next() orelse continue;
        const e = cols.next() orelse "";
        if (ctx.verbose) {
            ctx.out("{s: <40} {s: <22} {s: <14} {s}\n", .{ try ctx.fmt("rmxOS {s}", .{label}), time, action, e });
        } else if (std.mem.eql(u8, action, "installed")) ctx.out("{s: <40} {s}\n", .{ try ctx.fmt("rmxOS {s}", .{label}), time });
    }
    return 0;
}

// li-915 § Ownership: no service both in service -e and launchctl list,
// every listed launchd job present.
pub fn ownership(ctx: Ctx) !u8 {
    const table = sys.read(ctx.a, try ctx.path(ownership_path)) catch sys.read(ctx.a, try ctx.path(ownership_legacy)) catch {
        if (ctx.fixture) return 0;
        _ = ctx.refuse("ownership list {s} missing", .{ownership_path});
        return 1;
    };
    const services = if (ctx.fixture) sys.read(ctx.a, try ctx.path("/service-e")) catch "" else sys.capture(ctx, &.{ "/usr/sbin/service", "-e" }) catch "";
    const jobs = if (ctx.fixture) sys.read(ctx.a, try ctx.path("/launchctl-list")) catch "" else sys.capture(ctx, &.{ "/bin/launchctl", "list" }) catch "";
    var bad: u8 = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |raw| {
        const line = sys.trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        const owner = cols.next() orelse continue;
        const name = cols.next() orelse continue;
        if (std.mem.eql(u8, owner, "launchd")) {
            if (!hasWord(jobs, name)) {
                ctx.out("ownership: launchd job {s} is not loaded\n", .{name});
                bad = 1;
            }
            while (cols.next()) |rc_name| if (hasService(services, rc_name)) {
                ctx.out("ownership: {s} is both the launchd job {s} and an enabled rc service\n", .{ rc_name, name });
                bad = 1;
            };
        } else if (std.mem.eql(u8, owner, "rc")) {
            var words = std.mem.tokenizeAny(u8, jobs, " \t\r\n");
            while (words.next()) |w| if (std.mem.endsWith(u8, w, name) and w.len > name.len and w[w.len - name.len - 1] == '.') {
                ctx.out("ownership: rc service {s} is also the launchd job {s}\n", .{ name, w });
                bad = 1;
            };
        }
    }
    if (bad == 0) ctx.out("ownership: one owner per service\n", .{});
    return bad;
}
fn hasWord(text: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}
fn hasService(text: []const u8, name: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |l| if (std.mem.eql(u8, std.fs.path.basename(sys.trim(l)), name)) return true;
    return false;
}
