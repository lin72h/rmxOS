// The update lifecycle on the sealed layout: an update is a zfs send -i delta
// received into pool/base/main as it is, cloned to pool/ROOT/<snapshot>,
// activated for one boot and confirmed by the boot check. No promotion ever.
// An install is the same receive, clone and select on a named target: a pool
// imported under an alternate root, as the image builder leaves its pool.
const std = @import("std");
// The installer (rmxos-install) imports this module and shares its context.
pub const sys = @import("sys.zig");
pub const catalog = @import("catalog.zig");
const Esp = @import("esp.zig").Esp;
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
    lineage: []const u8,
    // "" for a named target: no environment of its pool is running.
    running: []const u8,
    target: Target = .running,
    fn name(_: Env, dataset: []const u8) []const u8 {
        return dataset[(std.mem.lastIndexOfScalar(u8, dataset, '/') orelse return dataset) + 1 ..];
    }
};

// Where receive, clone and select act: the running system (discover), or a
// pool imported under an alternate root (install, reinstall from recovery),
// which is selected as bootfs directly; there is nothing to fall back to.
pub const Target = union(enum) {
    running,
    pool: struct { name: []const u8, altroot: []const u8 },
};

pub fn open(ctx: Ctx, target: Target) !Env {
    return switch (target) {
        .running => discover(ctx),
        .pool => |p| named(ctx, p.name, p.altroot),
    };
}

// A named target is never the mounted root: its pool must be imported under
// the alternate root given, and that root is not /.
fn named(ctx: Ctx, pool: []const u8, altroot: []const u8) !Env {
    if (pool.len == 0 or pool.len > 64 or !std.ascii.isAlphabetic(pool[0])) return error.InvalidPool;
    for (pool) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return error.InvalidPool;
    if (ctx.fixture and !std.mem.startsWith(u8, pool, "rmxsu")) return error.FixturePool;
    const want = std.mem.trimEnd(u8, altroot, "/");
    if (altroot.len == 0 or altroot[0] != '/' or std.mem.indexOf(u8, altroot, "..") != null) return error.InvalidAltroot;
    if (want.len == 0) return error.AltrootIsRoot;
    const actual = sys.trim(try sys.capture(ctx, &.{ "/sbin/zpool", "get", "-H", "-o", "value", "altroot", pool }));
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, actual, "/"), want)) {
        sys.failure = try ctx.fmt("pool {s} is imported under {s}, not {s}", .{ pool, actual, want });
        return error.NotUnderAltroot;
    }
    return .{ .pool = pool, .root = try ctx.fmt("{s}/ROOT", .{pool}), .base = "", .lineage = "", .running = "", .target = .{ .pool = .{ .name = pool, .altroot = want } } };
}

pub fn discover(ctx: Ctx) !Env {
    const running = try sys.running(ctx);
    const slash = std.mem.indexOfScalar(u8, running, '/') orelse return error.NotSealedRoot;
    const pool = running[0..slash];
    // A host fixture never acts on the host's own pool.
    if (ctx.fixture and !std.mem.startsWith(u8, pool, "rmxsu")) return error.FixturePool;
    const root = try ctx.fmt("{s}/ROOT", .{pool});
    if (!std.mem.startsWith(u8, running, try ctx.fmt("{s}/", .{root}))) return error.NotSealedRoot;
    const origin = try get(ctx, "origin", running);
    const at = std.mem.lastIndexOfScalar(u8, origin, '@') orelse return error.NotSealedRoot;
    const prefix = try ctx.fmt("{s}/base/", .{pool});
    if (!std.mem.startsWith(u8, origin[0..at], prefix)) return error.NotSealedRoot;
    const suffix = origin[prefix.len..at];
    const lineage = suffix[0 .. std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len];
    if (lineage.len == 0) return error.NotSealedRoot;
    return .{ .pool = pool, .root = root, .base = origin[0..at], .lineage = lineage, .running = running };
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
    snapshot: []const u8 = "",
    confirm: []const u8 = "auto",
    state: []const u8 = "",
    // Why the boot check refused to confirm (state boot-check-failed).
    reason: []const u8 = "",
};
pub fn readRecord(ctx: Ctx) ?Record {
    const text = sys.read(ctx.a, ctx.path(fallback_path) catch return null) catch return null;
    var r = Record{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        inline for (.{ "environment", "time", "label", "staged", "snapshot", "confirm", "state", "reason" }) |f| {
            if (std.mem.eql(u8, k, f)) @field(r, f) = v;
        }
    }
    return r;
}
fn writeRecord(ctx: Ctx, r: Record) !void {
    try sys.replace(ctx.a, try ctx.path(fallback_path), try ctx.fmt(
        "environment={s}\ntime={s}\nlabel={s}\nstaged={s}\nsnapshot={s}\nconfirm={s}\nstate={s}\nreason={s}\n",
        .{ r.environment, r.time, r.label, r.staged, r.snapshot, r.confirm, r.state, r.reason },
    ));
}
fn history(ctx: Ctx, action: []const u8, label: []const u8, environment: []const u8) !void {
    return historyReason(ctx, action, label, environment, "");
}
// A new installation's first lifecycle line, written by the installer with
// ctx.root at the target's alternate root, once its Data is mounted there.
pub fn recordInstalled(ctx: Ctx, label: []const u8, environment: []const u8) !void {
    try sys.mkdirs(ctx.a, std.fs.path.dirname(try ctx.path(history_path)).?);
    return history(ctx, "installed", label, environment);
}
// A fifth column, when present, says why.
fn historyReason(ctx: Ctx, action: []const u8, label: []const u8, environment: []const u8, reason: []const u8) !void {
    try sys.append(ctx.a, try ctx.path(history_path), try ctx.fmt("{s}\t{s}\t{s}\t{s}{s}{s}\n", .{ try sys.now(ctx.a), action, label, environment, if (reason.len > 0) "\t" else "", reason }));
}

// Refusals before anything is received, one line each.
pub fn install(ctx: Ctx, env: Env, u: catalog.Update, source: []const u8, manual: bool) !u8 {
    return installChoice(ctx, env, u, source, manual, false, env.lineage);
}

pub fn installChoice(ctx: Ctx, running_env: Env, u: catalog.Update, source: []const u8, manual: bool, full: bool, lineage: []const u8) !u8 {
    var env = running_env;
    if (readRecord(ctx)) |r| if (std.mem.eql(u8, r.state, "staged"))
        return ctx.refuse("{s}: {s} is already staged for the next boot; nothing received", .{ u.label, r.label });
    // Only from the boot environment: an unconfirmed one recorded as the
    // fallback would be where rollback returns.
    const boot = try bootfs(ctx, env);
    if (!std.mem.eql(u8, boot, env.running))
        return ctx.refuse("{s}: running {s} is not the boot environment {s}; softwareupdate confirm, or rollback and restart, first; nothing received", .{ u.label, env.running, boot });
    const written = try get(ctx, "written", env.base);
    if (!std.mem.eql(u8, written, "0"))
        return ctx.refuse("{s}: sealed base {s} changed (written={s}); nothing received", .{ u.label, env.base, written });
    if (try retryExisting(ctx, env, u, manual, lineage)) |rc| return rc;
    if (try resumeReceived(ctx, env, u, manual, lineage)) |rc| return rc;
    const h: Snapshot = if (full) .{ .name = "", .guid = "0" } else try head(ctx, env);
    if (!std.mem.eql(u8, h.guid, u.origin_guid))
        return ctx.refuse("{s}: update starts from GUID {s}, installed base {s} is GUID {s}; nothing received", .{ u.label, u.origin_guid, h.name, h.guid });
    const v = (try verifiedStream(ctx, u, source, h.guid)) orelse return 1;
    if (full) {
        const canonical = try ctx.fmt("{s}/base/{s}", .{ env.pool, lineage });
        const all = try zfs(ctx, &.{ "list", "-H", "-o", "name", "-r", env.pool });
        const present = hasWord(all, canonical);
        env.base = if (present) try ctx.fmt("{s}/{s}", .{ canonical, u.snapshot }) else canonical;
        if (hasWord(all, env.base)) return ctx.refuse("{s}: full-stream destination {s} already exists; nothing received", .{ u.label, env.base });
    }
    const snapshot = try ctx.fmt("{s}@{s}", .{ env.base, u.snapshot });
    const received = try ctx.fmt("{s}{s}", .{ env.base, v.at });
    const clone = try ctx.fmt("{s}/{s}", .{ env.root, u.snapshot });
    const record_path = try ctx.path(fallback_path);
    const old_record = if (sys.exists(record_path)) try sys.read(ctx.a, record_path) else null;
    const hist_path = try ctx.path(history_path);
    const hist_size = sys.size(hist_path);
    const r = try receiveStream(ctx, env.base, v.path, full);
    if (r.status != 0) return ctx.refuse("{s}: zfs receive failed: {s}", .{ u.label, sys.firstLine(r.stderr) });
    var made_clone = false;
    var activated = false;
    var wrote_record = false;
    stage(ctx, env, u, snapshot, clone, manual, true, &made_clone, &activated, &wrote_record) catch |err| {
        const cause = sys.failure;
        undoInstall(ctx, env, received, clone, h.name, made_clone, activated, wrote_record, old_record, hist_size) catch |cleanup_err|
            return ctx.refuse("{s}: {s} {s}; recovery incomplete: {s}", .{ u.label, @errorName(err), cause, @errorName(cleanup_err) });
        return ctx.refuse("{s}: {s} {s}; install undone", .{ u.label, @errorName(err), cause });
    };
    ctx.out("Installed {s} into {s}; it boots once on the next restart.\n", .{ u.label, clone });
    return 0;
}

const Verified = struct { path: [:0]const u8, at: []const u8 };
// The catalog's stream before anything is received: its size and sha256, a
// zfs send stream from `origin` to the update's target GUID and snapshot.
// Null after a one-line refusal.
fn verifiedStream(ctx: Ctx, u: catalog.Update, source: []const u8, origin_guid: []const u8) !?Verified {
    const path = catalog.stream(ctx, source, u) catch return refused(ctx.refuse("{s}: stream {s} unavailable; nothing received", .{ u.label, u.stream }));
    const got = sys.size(path) orelse 0;
    if (got != u.size)
        return refused(ctx.refuse("{s}: stream is truncated ({d} of {d} bytes); nothing received", .{ u.label, got, u.size }));
    const digest = try sys.sha256File(path);
    if (!std.mem.eql(u8, &digest, u.sha256))
        return refused(ctx.refuse("{s}: stream sha256 {s} does not match the catalog; nothing received", .{ u.label, digest }));
    const hd = header(ctx, path) catch return refused(ctx.refuse("{s}: not a zfs send stream; nothing received", .{u.label}));
    const origin = try ctx.fmt("{d}", .{hd.from});
    const target = try ctx.fmt("{d}", .{hd.to});
    if (!std.mem.eql(u8, origin, origin_guid) or !std.mem.eql(u8, target, u.target_guid))
        return refused(ctx.refuse("{s}: stream origin GUID {s} (target {s}) does not match base GUID {s}; nothing received", .{ u.label, origin, target, origin_guid }));
    const at = std.mem.lastIndexOfScalar(u8, hd.name, '@') orelse return error.NotAStream;
    if (!std.mem.eql(u8, hd.name[at + 1 ..], u.snapshot)) return refused(ctx.refuse("{s}: stream snapshot does not match the catalog; nothing received", .{u.label}));
    return .{ .path = path, .at = hd.name[at..] };
}
fn refused(_: u8) ?Verified {
    return null;
}

// The three steps an update and an install share. A full stream arrives
// sealed and unmounted, as the image builder receives it.
fn receiveStream(ctx: Ctx, dest: []const u8, path: [:0]const u8, full: bool) !sys.Result {
    const args: []const []const u8 = if (full) &.{ "/sbin/zfs", "receive", "-u", "-o", "mountpoint=none", "-o", "canmount=off", "-o", "readonly=on", dest } else &.{ "/sbin/zfs", "receive", "-u", dest };
    return sys.run(ctx.a, args, path);
}
fn cloneEnvironment(ctx: Ctx, snapshot: []const u8, clone: []const u8) !void {
    _ = try zfs(ctx, &.{ "clone", "-o", "mountpoint=/", "-o", "canmount=noauto", "-o", "readonly=on", snapshot, clone });
}
// The running system boots a new environment once, so the boot check can
// fall back; a named target's pool boots it from now on.
fn select(ctx: Ctx, env: Env, clone: []const u8) !void {
    switch (env.target) {
        .running => _ = try sys.capture(ctx, &.{ "/sbin/bectl", "-r", env.root, "activate", "-t", env.name(clone) }),
        .pool => _ = try sys.capture(ctx, &.{ "/sbin/zpool", "set", try ctx.fmt("bootfs={s}", .{clone}), env.pool }),
    }
}

pub const head_tag = "rmxos-head";
const Made = struct { base_parent: bool = false, root: bool = false, received: bool = false, clone: bool = false, hold: bool = false };

// Install the catalog's full stream on a named target: <pool>/base/<lineage>
// received, its newest snapshot cloned to <pool>/ROOT/<snapshot> and held as
// rmxos-head, then bootfs. No fallback record or history: those are the
// running system's, and the target's Data does not exist yet.
pub fn installTarget(ctx: Ctx, target_env: Env, u: catalog.Update, source: []const u8, lineage: []const u8) !u8 {
    if (target_env.target != .pool) return error.NotNamedTarget;
    var env = target_env;
    if (!std.mem.eql(u8, u.origin_guid, "0"))
        return ctx.refuse("{s}: {s} takes a full stream; nothing received", .{ u.label, env.pool });
    env.lineage = lineage;
    env.base = try ctx.fmt("{s}/base/{s}", .{ env.pool, lineage });
    const clone = try ctx.fmt("{s}/{s}", .{ env.root, u.snapshot });
    const all = try zfs(ctx, &.{ "list", "-H", "-t", "all", "-o", "name", "-r", env.pool });
    for ([_][]const u8{ env.base, clone }) |existing| if (hasWord(all, existing))
        return ctx.refuse("{s}: {s} already exists; nothing received", .{ u.label, existing });
    const v = (try verifiedStream(ctx, u, source, "0")) orelse return 1;
    const snapshot = try ctx.fmt("{s}@{s}", .{ env.base, u.snapshot });
    var made = Made{};
    installSteps(ctx, env, u, v.path, snapshot, clone, all, &made) catch |err| {
        const cause = sys.failure;
        undoTarget(ctx, env, snapshot, clone, made) catch |cleanup_err|
            return ctx.refuse("{s}: {s} {s}; recovery incomplete: {s}", .{ u.label, @errorName(err), cause, @errorName(cleanup_err) });
        return ctx.refuse("{s}: {s} {s}; install undone", .{ u.label, @errorName(err), cause });
    };
    ctx.out("Installed {s} into {s}; {s} boots it.\n", .{ u.label, clone, env.pool });
    return 0;
}

fn installSteps(ctx: Ctx, env: Env, u: catalog.Update, path: [:0]const u8, snapshot: []const u8, clone: []const u8, all: []const u8, made: *Made) !void {
    // The image builder's parents: base unmountable, ROOT without a mountpoint.
    const parent = try ctx.fmt("{s}/base", .{env.pool});
    if (!hasWord(all, parent)) {
        _ = try zfs(ctx, &.{ "create", "-o", "canmount=off", parent });
        made.base_parent = true;
    }
    if (!hasWord(all, env.root)) {
        _ = try zfs(ctx, &.{ "create", "-o", "mountpoint=none", "-o", "canmount=off", env.root });
        made.root = true;
    }
    const r = try receiveStream(ctx, env.base, path, true);
    if (r.status != 0) {
        sys.failure = sys.firstLine(r.stderr);
        return error.ReceiveFailed;
    }
    made.received = true;
    if (!std.mem.eql(u8, (try head(ctx, env)).name, snapshot)) return error.ReceivedSnapshotMismatch;
    if (!std.mem.eql(u8, try get(ctx, "guid", snapshot), u.target_guid)) return error.ReceivedGuidMismatch;
    try cloneEnvironment(ctx, snapshot, clone);
    made.clone = true;
    _ = try zfs(ctx, &.{ "hold", head_tag, snapshot });
    made.hold = true;
    try select(ctx, env, clone);
}

// bootfs is set last, so a failure never leaves it pointing at what is undone.
fn undoTarget(ctx: Ctx, env: Env, snapshot: []const u8, clone: []const u8, made: Made) !void {
    var failed = false;
    if (made.hold) _ = zfs(ctx, &.{ "release", head_tag, snapshot }) catch {
        failed = true;
    };
    if (made.clone) _ = zfs(ctx, &.{ "destroy", clone }) catch {
        failed = true;
    };
    if (made.received) {
        _ = zfs(ctx, &.{ "destroy", snapshot }) catch {
            failed = true;
        };
        _ = zfs(ctx, &.{ "destroy", env.base }) catch {
            failed = true;
        };
    }
    if (made.root) _ = zfs(ctx, &.{ "destroy", env.root }) catch {
        failed = true;
    };
    if (made.base_parent) _ = zfs(ctx, &.{ "destroy", try ctx.fmt("{s}/base", .{env.pool}) }) catch {
        failed = true;
    };
    if (failed) return error.InstallCleanup;
}

pub fn runningGuid(ctx: Ctx, env: Env) ![]const u8 {
    return get(ctx, "guid", try get(ctx, "origin", env.running));
}

pub fn retryAvailable(ctx: Ctx, env: Env, u: catalog.Update, lineage: []const u8) !bool {
    const clone = try ctx.fmt("{s}/{s}", .{ env.root, u.snapshot });
    if (std.mem.eql(u8, clone, env.running)) return false;
    if (readRecord(ctx)) |r| if (std.mem.eql(u8, r.state, "staged")) return false;
    const all = try zfs(ctx, &.{ "list", "-H", "-o", "name", "-r", env.root });
    return hasWord(all, clone) or try leftover(ctx, env, u, lineage) != .none;
}

const Leftover = union(enum) { none, ambiguous, one: []const u8 };
// An install cut off after its receive and before its clone: the one
// snapshot @<snapshot> in the lineage with the update's target GUID, used by
// neither the running nor the fallback environment. (Without a clone of that
// name; a clone is retryExisting's.)
fn leftover(ctx: Ctx, env: Env, u: catalog.Update, lineage: []const u8) !Leftover {
    const text = try zfs(ctx, &.{ "list", "-H", "-p", "-t", "snapshot", "-o", "name,guid", "-r", try ctx.fmt("{s}/base", .{env.pool}) });
    const running_origin = try get(ctx, "origin", env.running);
    const fallback = if (readRecord(ctx)) |r| r.environment else "";
    const fallback_origin = if (fallback.len > 0) get(ctx, "origin", fallback) catch "" else "";
    const suffix = try ctx.fmt("@{s}", .{u.snapshot});
    var found: ?[]const u8 = null;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, sys.trim(text), '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const name = cols.next() orelse continue;
        const guid = cols.next() orelse continue;
        if (!std.mem.endsWith(u8, name, suffix) or !std.mem.eql(u8, guid, u.target_guid) or !try inLineage(ctx, env, name, lineage)) continue;
        if (std.mem.eql(u8, name, running_origin) or std.mem.eql(u8, name, fallback_origin)) return .none;
        count += 1;
        found = name;
    }
    return if (count > 1) .ambiguous else if (found) |f| .{ .one = f } else .none;
}

// Stage from a leftover receive: no stream is read and nothing received. A
// staging failure undoes only what this attempt made; the snapshot stays.
fn resumeReceived(ctx: Ctx, env: Env, u: catalog.Update, manual: bool, lineage: []const u8) !?u8 {
    const snapshot = switch (try leftover(ctx, env, u, lineage)) {
        .none => return null,
        .ambiguous => return ctx.refuse("{s}: ambiguous received snapshots; nothing changed", .{u.label}),
        .one => |name| name,
    };
    const clone = try ctx.fmt("{s}/{s}", .{ env.root, u.snapshot });
    const rp = try ctx.path(fallback_path);
    const old = if (sys.exists(rp)) try sys.read(ctx.a, rp) else null;
    const hist_size = sys.size(try ctx.path(history_path));
    var made = false;
    var activated = false;
    var recorded = false;
    stage(ctx, env, u, snapshot, clone, manual, true, &made, &activated, &recorded) catch |err| {
        const cause = sys.failure;
        undoInstall(ctx, env, "", clone, "", made, activated, recorded, old, hist_size) catch |cleanup_err|
            return ctx.refuse("{s}: {s} {s}; recovery incomplete: {s}", .{ u.label, @errorName(err), cause, @errorName(cleanup_err) });
        return ctx.refuse("{s}: {s} {s}; resume undone, {s} kept", .{ u.label, @errorName(err), cause, snapshot });
    };
    ctx.out("Resumed {s} from {s} into {s}; it boots once on the next restart.\n", .{ u.label, snapshot, clone });
    return 0;
}

fn inLineage(ctx: Ctx, env: Env, snapshot: []const u8, lineage: []const u8) !bool {
    const prefix = try ctx.fmt("{s}/base/{s}", .{ env.pool, lineage });
    return std.mem.startsWith(u8, snapshot, prefix) and snapshot.len > prefix.len and
        (snapshot[prefix.len] == '/' or snapshot[prefix.len] == '@');
}

fn retryExisting(ctx: Ctx, env: Env, u: catalog.Update, manual: bool, lineage: []const u8) !?u8 {
    const clone = try ctx.fmt("{s}/{s}", .{ env.root, u.snapshot });
    const all = try zfs(ctx, &.{ "list", "-H", "-o", "name", "-r", env.root });
    if (!hasWord(all, clone)) return null;
    const fallback = if (readRecord(ctx)) |r| r.environment else "";
    if (std.mem.eql(u8, clone, env.running) or std.mem.eql(u8, clone, fallback) or std.mem.eql(u8, clone, try bootfs(ctx, env)))
        return ctx.refuse("{s}: environment is running or protected; nothing changed", .{u.label});
    const origin = try get(ctx, "origin", clone);
    if (try inLineage(ctx, env, origin, lineage)) {
        const guid = try get(ctx, "guid", origin);
        if (std.mem.eql(u8, guid, u.target_guid) and std.mem.eql(u8, try get(ctx, "written", clone), "0")) {
            const rp = try ctx.path(fallback_path);
            const old = if (sys.exists(rp)) try sys.read(ctx.a, rp) else null;
            const hist_size = sys.size(try ctx.path(history_path));
            var made = false;
            var activated = false;
            var recorded = false;
            stage(ctx, env, u, origin, clone, manual, false, &made, &activated, &recorded) catch |err| {
                const cause = sys.failure;
                undoInstall(ctx, env, "", clone, "", false, activated, recorded, old, hist_size) catch |cleanup_err|
                    return ctx.refuse("{s}: {s} {s}; recovery incomplete: {s}", .{ u.label, @errorName(err), cause, @errorName(cleanup_err) });
                return ctx.refuse("{s}: {s} {s}; retry undone", .{ u.label, @errorName(err), cause });
            };
            ctx.out("Restaged {s} into {s}; it boots once on the next restart.\n", .{ u.label, clone });
            return 0;
        }
    }
    // A failed candidate's clone may have been changed. Remove only that
    // candidate and its receive, never a running/fallback origin or -r/-R.
    const snapshots = try zfs(ctx, &.{ "list", "-H", "-t", "snapshot", "-o", "name", "-r", try ctx.fmt("{s}/base", .{env.pool}) });
    const running_origin = try get(ctx, "origin", env.running);
    const fallback_origin = if (fallback.len > 0) try get(ctx, "origin", fallback) else "";
    var received: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, sys.trim(snapshots), '\n');
    while (lines.next()) |snap| {
        if (!std.mem.endsWith(u8, snap, try ctx.fmt("@{s}", .{u.snapshot})) or !try inLineage(ctx, env, snap, lineage)) continue;
        if (std.mem.eql(u8, snap, running_origin) or std.mem.eql(u8, snap, fallback_origin))
            return ctx.refuse("{s}: received snapshot is protected; nothing changed", .{u.label});
        if (received != null) return ctx.refuse("{s}: ambiguous received snapshots; nothing changed", .{u.label});
        received = snap;
    }
    _ = try zfs(ctx, &.{ "destroy", clone });
    if (received) |snap| {
        _ = try zfs(ctx, &.{ "destroy", snap });
        const base = snap[0..std.mem.lastIndexOfScalar(u8, snap, '@').?];
        if (std.mem.eql(u8, base, env.base)) {
            _ = try zfs(ctx, &.{ "rollback", (try head(ctx, env)).name });
        } else _ = try zfs(ctx, &.{ "destroy", base });
    }
    return null;
}

fn stage(ctx: Ctx, env: Env, u: catalog.Update, snapshot: []const u8, clone: []const u8, manual: bool, create: bool, made_clone: *bool, activated: *bool, wrote_record: *bool) !void {
    const guid = try get(ctx, "guid", snapshot);
    if (!std.mem.eql(u8, guid, u.target_guid)) return error.ReceivedGuidMismatch;
    if (create) {
        try cloneEnvironment(ctx, snapshot, clone);
        made_clone.* = true;
    }
    wrote_record.* = true;
    try writeRecord(ctx, .{ .environment = env.running, .time = try sys.now(ctx.a), .label = u.label, .staged = clone, .snapshot = snapshot, .confirm = if (manual) "manual" else "auto", .state = "staged" });
    try history(ctx, "staged", u.label, clone);
    activated.* = true;
    try select(ctx, env, clone);
}

fn undoInstall(ctx: Ctx, env: Env, received: []const u8, clone: []const u8, previous: []const u8, made_clone: bool, activated: bool, wrote_record: bool, old_record: ?[]const u8, hist_size: ?u64) !void {
    // Attempt every step even if another cleanup step fails.
    var failed = false;
    if (activated) _ = sys.capture(ctx, &.{ "/sbin/bectl", "-r", env.root, "activate", "-T" }) catch {
        failed = true;
    };
    if (made_clone) _ = zfs(ctx, &.{ "destroy", clone }) catch {
        failed = true;
    };
    if (received.len > 0) {
        _ = zfs(ctx, &.{ "destroy", received }) catch {
            failed = true;
        };
        if (previous.len > 0) {
            _ = zfs(ctx, &.{ "rollback", previous }) catch {
                failed = true;
            };
        } else {
            _ = zfs(ctx, &.{ "destroy", env.base }) catch {
                failed = true;
            };
        }
    }
    if (wrote_record) {
        const p = try ctx.path(fallback_path);
        if (old_record) |bytes| {
            const actual = sys.read(ctx.a, p) catch "";
            if (!std.mem.eql(u8, actual, bytes)) sys.replace(ctx.a, p, bytes) catch {
                failed = true;
            };
        } else if (sys.exists(p) and sys.c.unlink(p) != 0) {
            failed = true;
        }
    }
    const hp = try ctx.path(history_path);
    if (sys.size(hp) != hist_size) {
        if (hist_size) |size| {
            const fd = sys.c.open(hp, sys.c.O_WRONLY | sys.c.O_NOFOLLOW);
            if (fd < 0) {
                failed = true;
            } else {
                defer _ = sys.c.close(fd);
                if (sys.c.ftruncate(fd, @intCast(size)) != 0 or sys.c.fsync(fd) != 0) failed = true;
            }
        } else if (sys.c.unlink(hp) != 0) {
            failed = true;
        }
    }
    if (failed) return error.InstallCleanup;
}

// The ESP's loader is refreshed before bootfs moves; a failed refresh
// (error.EspRefresh, the reason in sys.failure) leaves both as they were.
fn confirmRunning(ctx: Ctx, env: Env, r: Record) !u8 {
    var esp = try Esp.open(ctx);
    defer esp.close(ctx);
    const refreshed = try esp.refresh(ctx);
    _ = sys.capture(ctx, &.{ "/sbin/zpool", "set", try ctx.fmt("bootfs={s}", .{env.running}), env.pool }) catch |err| {
        if (refreshed) esp.restore(ctx);
        return err;
    };
    // The loader consumed the one-boot setting; clear any remainder.
    _ = sys.run(ctx.a, &.{ "/sbin/bectl", "-r", env.root, "activate", "-T" }, null) catch {};
    var n = r;
    n.state = "confirmed";
    try writeRecord(ctx, n);
    if (refreshed) try historyReason(ctx, "esp-refreshed", r.label, env.running, esp.detail);
    try history(ctx, "installed", r.label, env.running);
    ctx.out("Confirmed {s}: {s} is the boot environment.\n", .{ r.label, env.running });
    return retain(ctx, env);
}

pub const max_confirm_delay = 600;

// confirm_delay from softwareupdate.conf (default and at most 600 seconds),
// read only from setting files owned by root and writable by nobody else;
// a refusal's reason is in sys.failure.
pub fn confirmDelay(ctx: Ctx) !u64 {
    var value: ?[]const u8 = null;
    for (catalog.settings_files) |f| {
        const p = try ctx.path(f);
        if (!sys.exists(p)) continue;
        const text = sys.readOwned(ctx.a, p) catch |err| {
            sys.failure = try ctx.fmt("setting file {s} is not a regular file owned by root and writable only by root", .{f});
            return err;
        };
        if (catalog.lookup(text, "confirm_delay")) |v| value = v;
    }
    const v = value orelse return max_confirm_delay;
    for (v) |ch| if (!std.ascii.isDigit(ch)) return delayRefused(ctx, v);
    const n = std.fmt.parseInt(u64, v, 10) catch return delayRefused(ctx, v);
    return if (n > max_confirm_delay) delayRefused(ctx, v) else n;
}
fn delayRefused(ctx: Ctx, v: []const u8) error{InvalidConfirmDelay} {
    sys.failure = ctx.fmt("confirm_delay {s} is not 0 to {d} seconds", .{ v, max_confirm_delay }) catch "confirm_delay is out of range";
    return error.InvalidConfirmDelay;
}

// Before the boot check takes the lock (status and rollback stay available):
// a staged environment's first boot waits until uptime reaches confirm_delay.
// A shutdown meanwhile leaves it staged, so the next boot is the fallback's.
pub fn awaitConfirm(ctx: Ctx) !?u8 {
    const r = readRecord(ctx) orelse return null;
    if (!std.mem.eql(u8, r.state, "staged") or !std.mem.eql(u8, r.confirm, "auto") or !std.mem.eql(u8, r.staged, try sys.running(ctx))) return null;
    // An unusable setting is refused under the lock.
    const delay = confirmDelay(ctx) catch return null;
    var announced = false;
    while (true) {
        const up = try sys.uptime(ctx);
        if (up >= delay) return null;
        if (!announced) ctx.out("{s}: boot check in {d} s (confirm_delay {d} s)\n", .{ r.label, delay - up, delay });
        announced = true;
        if (try sys.shutdownWithin(delay - up)) return ctx.refuse("{s}: shutdown during confirm_delay; not confirmed", .{r.label});
    }
}

// The good-boot check before a confirm: the Data datasets mounted, one owner
// per service and the base unchanged. Null when all pass, else every failure.
fn health(ctx: Ctx, env: Env) !?[]const u8 {
    var failed: std.ArrayList(u8) = .empty;
    for (data_sets) |d| {
        const mounted = get(ctx, "mounted", try ctx.fmt("{s}/data/{s}", .{ env.pool, d })) catch "missing";
        if (!std.mem.eql(u8, mounted, "yes"))
            try failed.appendSlice(ctx.a, try ctx.fmt("; Data {s} {s}", .{ d, if (std.mem.eql(u8, mounted, "missing")) "missing" else "not mounted" }));
    }
    if (try ownership(ctx) != 0) try failed.appendSlice(ctx.a, "; ownership check failed");
    const written = get(ctx, "written", env.base) catch "unknown";
    if (!std.mem.eql(u8, written, "0")) try failed.appendSlice(ctx.a, try ctx.fmt("; base {s} written={s}", .{ env.base, written }));
    return if (failed.items.len == 0) null else failed.items[2..];
}

// No confirm: bootfs is untouched, so the next restart returns to the fallback.
fn checkFailed(ctx: Ctx, env: Env, r: Record, why: []const u8) !u8 {
    const reason = try ctx.a.dupe(u8, why);
    for (reason) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
        ch.* = ' ';
    };
    var n = r;
    n.state = "boot-check-failed";
    n.reason = reason;
    try writeRecord(ctx, n);
    try historyReason(ctx, "boot-check-failed", r.label, env.running, reason);
    return ctx.refuse("{s}: boot check failed: {s}; not confirmed, {s} boots next", .{ r.label, reason, bootfs(ctx, env) catch "the fallback" });
}

// Every boot: the first boot of a staged environment confirms it after
// confirm_delay and a good-boot check (unless --no-auto-confirm was given);
// other boots assert the ownership list.
pub fn bootCheck(ctx: Ctx, env: Env) !u8 {
    const r = readRecord(ctx) orelse return ownership(ctx);
    if (!std.mem.eql(u8, r.state, "staged")) return ownership(ctx);
    if (!std.mem.eql(u8, r.staged, env.running)) {
        var n = r;
        n.state = "not-confirmed";
        try writeRecord(ctx, n);
        try history(ctx, "not-confirmed", r.label, r.staged);
        ctx.out("{s} did not reach its boot check; {s} is running.\n", .{ r.label, env.running });
        return ownership(ctx);
    }
    if (std.mem.eql(u8, r.confirm, "manual")) {
        var n = r;
        n.state = "booted";
        try writeRecord(ctx, n);
        ctx.out("{s} is running; waiting for softwareupdate confirm.\n", .{r.label});
        return ownership(ctx);
    }
    const delay = confirmDelay(ctx) catch return checkFailed(ctx, env, r, sys.failure);
    if (try sys.uptime(ctx) < delay) return ctx.refuse("{s}: boot check before confirm_delay; not confirmed", .{r.label});
    if (try health(ctx, env)) |why| return checkFailed(ctx, env, r, why);
    return confirmRunning(ctx, env, r) catch |err| switch (err) {
        error.EspRefresh => checkFailed(ctx, env, r, try ctx.fmt("ESP loader refresh: {s}", .{sys.failure})),
        else => err,
    };
}

pub fn confirm(ctx: Ctx, env: Env) !u8 {
    const r = readRecord(ctx) orelse return ctx.refuse("no install is waiting for confirmation", .{});
    if (!std.mem.eql(u8, r.confirm, "manual")) return ctx.refuse("confirm is only for an install made with --no-auto-confirm", .{});
    if (!std.mem.eql(u8, r.state, "booted") or !std.mem.eql(u8, r.staged, env.running))
        return ctx.refuse("{s} is not the running environment; restart into it before confirm", .{r.label});
    return confirmRunning(ctx, env, r) catch |err| switch (err) {
        error.EspRefresh => ctx.refuse("{s}: ESP loader refresh: {s}; not confirmed", .{ r.label, sys.failure }),
        else => err,
    };
}

pub fn cancel(ctx: Ctx, env: Env) !u8 {
    const r = readRecord(ctx) orelse return ctx.refuse("no install is waiting for confirmation", .{});
    if (!std.mem.eql(u8, r.confirm, "manual")) return ctx.refuse("cancel is only for an install made with --no-auto-confirm", .{});
    if (std.mem.eql(u8, r.staged, env.running)) return ctx.refuse("{s} is running; use rollback", .{r.label});
    if (!std.mem.eql(u8, r.state, "staged")) return ctx.refuse("no install is waiting for confirmation", .{});
    const written = try get(ctx, "written", env.base);
    if (!std.mem.eql(u8, written, "0"))
        return ctx.refuse("{s}: sealed base {s} changed (written={s}); nothing canceled", .{ r.label, env.base, written });
    // Undo the receive too, so the same update installs again from this base.
    const received = if (r.snapshot.len > 0) r.snapshot else try ctx.fmt("{s}@{s}", .{ env.base, env.name(r.staged) });
    if (!std.mem.startsWith(u8, received, try ctx.fmt("{s}/base/", .{env.pool}))) return error.NotSealedRoot;
    const received_at = std.mem.lastIndexOfScalar(u8, received, '@') orelse return error.NotSealedRoot;
    const received_base = received[0..received_at];
    if (!std.mem.eql(u8, received_base, env.base)) {
        const all = try zfs(ctx, &.{ "list", "-H", "-o", "name", "-r", env.pool });
        if (hasWord(all, received_base) and !std.mem.eql(u8, try get(ctx, "written", received_base), "0"))
            return ctx.refuse("{s}: received sealed base changed; nothing canceled", .{r.label});
    }
    if (std.mem.eql(u8, received, try get(ctx, "origin", env.running))) return error.ProtectedSnapshot;
    _ = try sys.capture(ctx, &.{ "/sbin/bectl", "-r", env.root, "activate", "-T" });
    try destroyIfPresent(ctx, env, r.staged);
    try destroyIfPresent(ctx, env, received);
    if (!std.mem.eql(u8, received_base, env.base)) try destroyIfPresent(ctx, env, received_base);
    // The received data stays in the base's head until it is rolled back.
    _ = try zfs(ctx, &.{ "rollback", (try head(ctx, env)).name });
    var n = r;
    n.state = "canceled";
    try writeRecord(ctx, n);
    try history(ctx, "canceled", r.label, r.staged);
    ctx.out("Canceled {s}; {s} stays the boot environment.\n", .{ r.label, env.running });
    return 0;
}

fn destroyIfPresent(ctx: Ctx, env: Env, name: []const u8) !void {
    // Enumerate the pool successfully before deciding an object is absent;
    // permission and pool errors must not masquerade as a missing clone.
    const all = try zfs(ctx, &.{ "list", "-H", "-t", "all", "-o", "name", "-r", env.pool });
    var lines = std.mem.splitScalar(u8, sys.trim(all), '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, line, name)) {
        _ = try zfs(ctx, &.{ "destroy", name });
        return;
    };
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
    const boot = bootfs(ctx, env) catch return ctx.refuse("bootfs lookup failed; retention removed nothing", .{});
    const keep_also = [_][]const u8{ env.running, if (readRecord(ctx)) |r| r.environment else "", boot };
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
        if (std.mem.eql(u8, r.state, "staged") and std.mem.eql(u8, r.staged, env.running) and std.mem.eql(u8, r.confirm, "auto")) {
            if (confirmDelay(ctx)) |delay| {
                const up = sys.uptime(ctx) catch 0;
                ctx.out("Boot check: confirms {s} in {d} s (confirm_delay {d} s, uptime {d} s)\n", .{ r.label, delay -| up, delay, up });
            } else |_| ctx.out("Boot check: refuses {s}: {s}\n", .{ r.label, sys.failure });
        }
        if (std.mem.eql(u8, r.state, "boot-check-failed")) ctx.out("Boot check: failed for {s}: {s}\n", .{ r.label, r.reason });
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
        const reason = cols.rest();
        if (ctx.verbose) {
            ctx.out("{s: <40} {s: <22} {s: <14} {s}{s}{s}\n", .{ try ctx.fmt("rmxOS {s}", .{label}), time, action, e, if (reason.len > 0) "  " else "", reason });
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
            // "<address>.anonymous.<program>" is launchd's record of a process
            // that touched the bootstrap port (rc's own sshd, devd, sh), not a
            // job: a launchd job counts only by its own label.
            while (words.next()) |w| if (!anonymous(w) and std.mem.endsWith(u8, w, name) and w.len > name.len and w[w.len - name.len - 1] == '.') {
                ctx.out("ownership: rc service {s} is also the launchd job {s}\n", .{ name, w });
                bad = 1;
            };
        }
    }
    if (bad == 0) ctx.out("ownership: one owner per service\n", .{});
    return bad;
}
fn anonymous(label: []const u8) bool {
    return std.mem.indexOf(u8, label, ".anonymous.") != null;
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
