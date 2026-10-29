const std = @import("std");
const u = @import("update.zig");
const e = u.engine;
const c = u.c;
const A = std.mem.Allocator;
const io = std.Io.Threaded.global_single_threaded.io();
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn trim(x: []const u8) []const u8 {
    return std.mem.trim(u8, x, " \t\r\n");
}
fn fmt(a: A, comptime f: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, f, args, 0);
}
fn value(root: e.Root, path: []const u8) !?[]const u8 {
    const bytes = try root.read(path);
    return if (bytes) |v| trim(v) else null;
}
pub const BE = struct { name: []const u8, flags: []const u8 };
pub fn listing(a: A, text: []const u8) ![]BE {
    var result: std.ArrayList(BE) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const flags = fields.next() orelse return error.MalformedBEList;
        if (!safeBE(name)) return error.InvalidBEName;
        try result.append(a, .{ .name = name, .flags = flags });
    }
    return result.toOwnedSlice(a);
}
fn safeBE(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-' or eq(name, ".") or eq(name, "..")) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_.-", ch) == null) return false;
    return true;
}
fn flag(be: BE, ch: u8) bool {
    return std.mem.indexOfScalar(u8, be.flags, ch) != null;
}
fn selected(bes: []const BE) !?[]const u8 {
    var name: ?[]const u8 = null;
    for (bes) |be| if (flag(be, 'T')) {
        if (name != null) return error.MultipleTemporaryBEs;
        name = be.name;
    };
    return name;
}
fn exists(bes: []const BE, name: []const u8) bool {
    for (bes) |be| if (eq(name, be.name)) return true;
    return false;
}
pub fn uptime() !u64 {
    var t: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_UPTIME, &t) != 0 or t.tv_sec < 0) return error.ClockFailed;
    return @intCast(t.tv_sec);
}
pub fn delay(root: e.Root) !u64 {
    const text = try value(root, "/var/db/softwareupdate/confirm-delay");
    if (text) |v| {
        const st = (try root.stat("/var/db/softwareupdate/confirm-delay")).?;
        if (root.ownership and (st.st_uid != 0 or st.st_mode & 0o022 != 0)) return error.UnsafeDelaySetting;
        const n = std.fmt.parseInt(u64, v, 10) catch return error.InvalidDelay;
        if (n > 600) return error.InvalidDelay;
        return n;
    }
    return 600;
}
pub fn status(ctx: u.Context, s: u.Snapshot) !void {
    const bes = try listing(ctx.allocator, s.listing orelse "");
    const temporary = try selected(bes);
    const pending = try ctx.optional("/var/db/rmxos/pending-target");
    const target = temporary orelse if (pending) |p| trim(p) else "none";
    try ctx.print(ctx.out, "staged={s}\n", .{target});
    const record = try ctx.optional("/var/db/softwareupdate/staged.tsv");
    var commit: []const u8 = "unknown";
    if (record) |bytes| {
        var fields = std.mem.tokenizeAny(u8, bytes, "\t\n");
        const name = fields.next() orelse "";
        const hash = fields.next() orelse "";
        if (eq(name, target) and u.hex(hash, 40)) commit = hash;
    }
    if (pending != null and s.dataset != null and eq(trim(pending.?), std.fs.path.basename(s.dataset.?))) {
        if (try ctx.optional("/var/db/rmxos/commit")) |v| commit = trim(v);
        const root = try e.inspectRunning(ctx.allocator, ctx.root);
        defer root.close();
        const wait = try delay(root);
        const now = try uptime();
        const manual = try value(root, "/var/db/softwareupdate/no-auto-confirm");
        try ctx.print(ctx.out, "pending_window_seconds={d}\nauto_confirm={s}\n", .{ wait - @min(wait, now), if (manual != null and eq(manual.?, "yes")) "disabled" else "enabled" });
    }
    if (!eq(target, "none")) try ctx.print(ctx.out, "staged_commit={s}\n", .{commit});
    if (try ctx.optional("/var/db/softwareupdate/boot-check-failed")) |why| try ctx.print(ctx.out, "good_boot=failed reason={s}\naction=run softwareupdate rollback\n", .{trim(why)});
}
fn logAction(ctx: u.Context, root: e.Root, backend: e.Backend, action: []const u8, target: []const u8) !void {
    return logReason(ctx, root, backend, action, target, null);
}
fn logReason(ctx: u.Context, root: e.Root, backend: e.Backend, action: []const u8, target: []const u8, reason: ?[]const u8) !void {
    const previous = (try value(root, "/var/db/rmxos/previous-be")) orelse "-";
    const commit = (try value(root, "/var/db/rmxos/commit")) orelse "-";
    const old = (try root.read("/var/db/softwareupdate/history.tsv")) orelse "";
    var now: c.time_t = 0;
    _ = c.time(&now);
    var utc: c.struct_tm = undefined;
    if (c.gmtime_r(&now, &utc) == null) return error.ClockFailed;
    var stamp: [64]u8 = undefined;
    const n = c.strftime(&stamp, stamp.len, "%Y-%m-%dT%H:%M:%SZ", &utc);
    if (n == 0) return error.ClockFailed;
    const suffix = if (reason) |why| try fmt(ctx.allocator, "\treason={s}", .{why}) else "";
    try root.write("/var/db/softwareupdate/history.tsv", try std.fmt.allocPrint(ctx.allocator, "{s}{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t0{s}\n", .{ old, stamp[0..n], action, commit, commit, previous, target, suffix }), 0o644);
    _ = try backend.command(ctx.allocator, &.{ "/usr/bin/logger", "-t", "softwareupdate", try fmt(ctx.allocator, "{s} target={s} commit={s}{s}", .{ action, target, commit, suffix }) });
}
fn failed(ctx: u.Context, root: e.Root, backend: e.Backend, action: []const u8, target: []const u8, err: anyerror) !u8 {
    const detail = if (backend.failure) |slot| slot.* orelse "" else "";
    const why = try std.fmt.allocPrint(ctx.allocator, "{s}{s}{s}", .{ @errorName(err), if (detail.len != 0) ": " else "", detail });
    // Keep one history row and one diagnostic even for multiline stderr.
    for (why) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
        ch.* = ' ';
    };
    try root.write("/var/db/softwareupdate/boot-check-failed", try fmt(ctx.allocator, "{s}\n", .{why}), 0o444);
    logReason(ctx, root, backend, action, target, why) catch |record_error| {
        return ctx.diagnostic(try fmt(ctx.allocator, "{s}: {s}; recording failed: {s}; run softwareupdate rollback", .{ action, why, @errorName(record_error) }));
    };
    return ctx.diagnostic(try fmt(ctx.allocator, "{s}: {s}; run softwareupdate rollback", .{ action, why }));
}
pub fn operationLock(root: e.Root) !c_int {
    const parent = (try root.parent("/var/db/softwareupdate/operation.lock", true)).?;
    defer _ = c.close(parent);
    const fd = c.openat(parent, "operation.lock", c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.LockFailed;
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        _ = c.close(fd);
        return error.UpdateOperationBusy;
    }
    return fd;
}
fn requirePending(root: e.Root, current: []const u8) !void {
    const pending = (try value(root, "/var/db/rmxos/pending-target")) orelse return error.NoPendingUpdate;
    if (!eq(pending, current)) return error.RunningBEDiffersFromPending;
}
fn identity(root: e.Root) !void {
    const bytes = (try root.read("/var/db/rmxos/manifest.tsv")) orelse return error.MissingManifest;
    const m = try e.manifest(root.a, bytes, false);
    for ([_][]const u8{ "/boot/RMXOS-RELEASE/kernel", "/boot/RMXOS-RELEASE/mach.ko", "/sbin/launchd" }) |path| {
        var found = false;
        for (m.rows) |row| if (eq(row.path, path) and !row.deleted) {
            if (!try root.matches(path, row.hash, row.mode, true)) return error.IdentityMismatch;
            found = true;
        };
        if (!found) return error.IdentityNotInManifest;
    }
}
pub fn goodBoot(ctx: u.Context, root: e.Root, backend: e.Backend) !void {
    try identity(root);
    const pid1 = trim(try backend.command(ctx.allocator, &.{ "/bin/ps", "-p", "1", "-o", "comm=" }));
    if (!eq(pid1, "launchd") and !eq(pid1, "/sbin/launchd")) return error.PID1NotLaunchd;
    _ = try backend.command(ctx.allocator, &.{ "/sbin/kldstat", "-n", "mach.ko" });
    const pids = trim(try backend.command(ctx.allocator, &.{ "/bin/pgrep", "-x", "logd" }));
    if (pids.len == 0) return error.LogdNotRunning;
    for (pids) |ch| if (!std.ascii.isDigit(ch) and ch != '\n' and ch != ' ') return error.InvalidLogdPID;
    var random: [16]u8 = undefined;
    c.arc4random_buf(&random, random.len);
    const marker = try fmt(ctx.allocator, "softwareupdate-good-boot-{s}", .{std.fmt.bytesToHex(random, .lower)});
    _ = try backend.command(ctx.allocator, &.{ "/usr/bin/logger", "-t", "softwareupdate", marker });
    // A unique exact Message/Sender match must be readable from the real store.
    // Fresh boots have a small store; -k is an exact query, no time-budget verdict.
    for (0..20) |_| {
        const output = try backend.command(ctx.allocator, &.{ "/usr/bin/log", "-F", "raw", "-k", "Sender", "softwareupdate", "-k", "Message", marker });
        if (std.mem.indexOf(u8, output, marker) != null) return;
        _ = c.usleep(500000);
    }
    return error.LogProbeNotStored;
}
fn owned(a: A, root: e.Root) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(a);
    const text = (try root.read("/var/db/softwareupdate/environments.tsv")) orelse return map;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const name = f.next() orelse return error.InvalidRegistry;
        const token = f.next() orelse return error.InvalidRegistry;
        if (!u.validName(name) or !u.hex(token, 32) or f.next() != null or map.contains(name)) return error.InvalidRegistry;
        try map.put(name, token);
    }
    return map;
}
pub fn register(ctx: u.Context, running: e.Root, clone: e.Root, target: []const u8, commit: []const u8, efi_changed: bool) !void {
    var random: [16]u8 = undefined;
    c.arc4random_buf(&random, random.len);
    const token = std.fmt.bytesToHex(random, .lower);
    var owners = try owned(ctx.allocator, running);
    try owners.put(target, &token);
    var bytes: std.ArrayList(u8) = .empty;
    var it = owners.iterator();
    while (it.next()) |entry| try bytes.appendSlice(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "{s}\t{s}\n", .{ entry.key_ptr.*, entry.value_ptr.* }));
    const registry = bytes.items;
    try clone.write("/var/db/softwareupdate/created-by", try std.fmt.allocPrint(ctx.allocator, "{s}\t{s}\n", .{ target, token }), 0o444);
    try clone.write("/var/db/softwareupdate/environments.tsv", registry, 0o444);
    try clone.write("/var/db/softwareupdate/efi-loader-changed", if (efi_changed) "yes\n" else "no\n", 0o444);
    try running.write("/var/db/softwareupdate/environments.tsv", registry, 0o444);
    try running.write("/var/db/softwareupdate/staged.tsv", try std.fmt.allocPrint(ctx.allocator, "{s}\t{s}\n", .{ target, commit }), 0o444);
}
const Mounted = struct {
    path: [:0]const u8,
    target: [:0]const u8,
    backend: e.Backend,
    a: A,
    root: e.Root,
    fn open(a: A, backend: e.Backend, target: []const u8, write: bool) !Mounted {
        const path = try a.dupeZ(u8, "/tmp/softwareupdate-inspect-XXXXXX");
        if (c.mkdtemp(path) == null) return error.TemporaryDirectory;
        errdefer _ = c.rmdir(path);
        const name = try a.dupeZ(u8, target);
        _ = write;
        _ = try backend.command(a, &.{ "/sbin/bectl", "mount", name, path });
        errdefer {
            _ = backend.command(a, &.{ "/sbin/bectl", "unmount", name }) catch {};
        }
        return .{ .path = path, .target = name, .backend = backend, .a = a, .root = try e.Root.open(a, path, false) };
    }
    fn close(self: Mounted) !void {
        self.root.close();
        _ = try self.backend.command(self.a, &.{ "/sbin/bectl", "unmount", self.target });
        _ = c.rmdir(self.path);
    }
};
fn matchesOwner(root: e.Root, name: []const u8, token: []const u8) !bool {
    const marker = (try value(root, "/var/db/softwareupdate/created-by")) orelse return false;
    return eq(marker, try std.fmt.allocPrint(root.a, "{s}\t{s}", .{ name, token }));
}
pub fn prune(ctx: u.Context, root: e.Root, backend: e.Backend, current_dataset: []const u8, previous: []const u8) !void {
    const current = std.fs.path.basename(current_dataset);
    var registry = try owned(ctx.allocator, root);
    const text = try backend.command(ctx.allocator, &.{ "/sbin/bectl", "list", "-H", "-c", "creation" });
    const bes = try listing(ctx.allocator, text);
    if (try selected(bes) != null) return error.TemporaryBootPending;
    var keep: usize = if (exists(bes, previous) and !eq(previous, current)) 1 else 0;
    var index = bes.len;
    while (index > 0) {
        index -= 1;
        const be = bes[index];
        if (eq(be.name, current) or eq(be.name, previous) or flag(be, 'N') or flag(be, 'R') or flag(be, 'T')) continue;
        const token = registry.get(be.name) orelse continue;
        if (keep < 3) {
            keep += 1;
            continue;
        }
        const mounted = try Mounted.open(ctx.allocator, backend, be.name, false);
        const ours = matchesOwner(mounted.root, be.name, token) catch |err| {
            mounted.close() catch {};
            return err;
        };
        try mounted.close();
        if (!ours) continue;
        try u.seals.release(ctx.allocator, backend, try fmt(ctx.allocator, "{s}/{s}", .{ std.fs.path.dirname(current_dataset).?, be.name }));
        _ = try backend.command(ctx.allocator, &.{ "/sbin/bectl", "destroy", try ctx.allocator.dupeZ(u8, be.name) });
        _ = registry.remove(be.name);
        try logAction(ctx, root, backend, "pruned", be.name);
    }
    var data: std.ArrayList(u8) = .empty;
    var it = registry.iterator();
    while (it.next()) |item| try data.appendSlice(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "{s}\t{s}\n", .{ item.key_ptr.*, item.value_ptr.* }));
    try root.write("/var/db/softwareupdate/environments.tsv", data.items, 0o444);
}
pub fn refreshEFI(ctx: u.Context, root: e.Root, backend: e.Backend) !void {
    const changed = (try value(root, "/var/db/softwareupdate/efi-loader-changed")) orelse "no";
    if (!eq(changed, "yes")) return;
    const loader = (try root.read("/boot/loader.efi")) orelse return error.LoaderAbsent;
    // Match the authenticated-by-checksum installed manifest before touching ESP.
    const m = try e.manifest(ctx.allocator, (try root.read("/var/db/rmxos/manifest.tsv")) orelse return error.MissingManifest, false);
    var declared = false;
    for (m.rows) |row| if (eq(row.path, "/boot/loader.efi") and !row.deleted) {
        if (!try root.matches(row.path, row.hash, row.mode, true)) return error.LoaderIdentityMismatch;
        declared = true;
    };
    if (!declared) return error.LoaderNotInManifest;
    const mounts = try backend.command(ctx.allocator, &.{ "/sbin/mount", "-p" });
    var lines = std.mem.tokenizeScalar(u8, mounts, '\n');
    var esp: ?[]const u8 = null;
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t");
        _ = f.next() orelse continue;
        const at = f.next() orelse continue;
        const kind = f.next() orelse continue;
        if (eq(kind, "msdosfs")) {
            if (esp != null) return error.MultipleESPs;
            esp = at;
        }
    }
    var temporary: ?[:0]const u8 = null;
    defer if (temporary) |path| {
        _ = backend.command(ctx.allocator, &.{ "/sbin/umount", path }) catch {};
        _ = c.rmdir(path);
    };
    if (esp == null) {
        const parts = try backend.command(ctx.allocator, &.{ "/sbin/gpart", "show", "-p" });
        var plines = std.mem.tokenizeScalar(u8, parts, '\n');
        var device: ?[]const u8 = null;
        while (plines.next()) |line| {
            var f = std.mem.tokenizeAny(u8, line, " \t");
            _ = f.next() orelse continue;
            _ = f.next() orelse continue;
            const part = f.next() orelse continue;
            if (eq(f.next() orelse "", "efi")) {
                if (device != null) return error.MultipleESPs;
                for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidESPDevice;
                device = part;
            }
        }
        if (device == null) return error.ESPNotFound;
        const path = try ctx.allocator.dupeZ(u8, "/tmp/softwareupdate-esp-XXXXXX");
        if (c.mkdtemp(path) == null) return error.TemporaryDirectory;
        temporary = path;
        _ = try backend.command(ctx.allocator, &.{ "/sbin/mount", "-t", "msdosfs", try fmt(ctx.allocator, "/dev/{s}", .{device.?}), path });
        esp = path;
    }
    const esp_root = try e.Root.open(ctx.allocator, try ctx.allocator.dupeZ(u8, esp.?), false);
    defer esp_root.close();
    const dest = if (try esp_root.stat("/efi/freebsd/loader.efi") != null) "/efi/freebsd/loader.efi" else if (try esp_root.stat("/EFI/BOOT/BOOTX64.EFI") != null) "/EFI/BOOT/BOOTX64.EFI" else return error.ESPLoaderNotFound;
    try esp_root.write(dest, loader, 0o644);
    const result = (try esp_root.read(dest)) orelse return error.EFIVerificationFailed;
    if (!eq(result, loader)) return error.EFIVerificationFailed;
    try root.write("/var/db/softwareupdate/efi-loader-changed", "no\n", 0o444);
    try logAction(ctx, root, backend, "efi-refreshed", dest);
}
fn confirmPending(ctx: u.Context, root: e.Root, s: u.Snapshot, bes: []const BE, backend: e.Backend) !void {
    const current = std.fs.path.basename(s.dataset.?);
    const previous = (try value(root, "/var/db/rmxos/previous-be")) orelse return error.PreviousBEAbsent;
    if (!safeBE(previous) or !exists(bes, previous) or eq(current, previous)) return error.PreviousBEAbsent;
    const parent = std.fs.path.dirname(s.dataset.?).?;
    const pool = try ctx.allocator.dupeZ(u8, s.dataset.?[0..std.mem.indexOfScalar(u8, s.dataset.?, '/').?]);
    const old_bootfs = trim(try backend.command(ctx.allocator, &.{ "/sbin/zpool", "get", "-H", "-o", "value", "bootfs", pool }));
    if (!eq(old_bootfs, try fmt(ctx.allocator, "{s}/{s}", .{ parent, previous }))) return error.UnexpectedBootDefault;
    // Before any promote, bind every still-local legacy seal, including the
    // predecessor and a candidate sealed by the old installer after apply.
    for (bes) |be| try u.seals.migrate(ctx.allocator, backend, try fmt(ctx.allocator, "{s}/{s}", .{ parent, be.name }));
    try refreshEFI(ctx, root, backend);
    _ = backend.command(ctx.allocator, &.{ "/sbin/bectl", "activate", try ctx.allocator.dupeZ(u8, current) }) catch |err| {
        const original = if (backend.failure) |slot| slot.* orelse @errorName(err) else @errorName(err);
        // be_activate changes bootfs before promotion and can then fail.
        // Restore the property directly; activating the predecessor would
        // itself promote and could fail again for the same snapshot reason.
        const restore = backend.command(ctx.allocator, &.{ "/sbin/zpool", "set", try fmt(ctx.allocator, "bootfs={s}", .{old_bootfs}), pool });
        if (restore) |_| {
            const observed = backend.command(ctx.allocator, &.{ "/sbin/zpool", "get", "-H", "-o", "value", "bootfs", pool });
            if (observed) |bootfs| {
                if (!eq(trim(bootfs), old_bootfs)) {
                    if (backend.failure) |slot| slot.* = try fmt(ctx.allocator, "{s}; bootfs restoration mismatch", .{original});
                    return error.BootDefaultRestoreFailed;
                }
            } else |restore_error| {
                if (backend.failure) |slot| slot.* = try fmt(ctx.allocator, "{s}; bootfs restoration verification: {s}", .{ original, @errorName(restore_error) });
                return error.BootDefaultRestoreFailed;
            }
        } else |restore_error| {
            const extra = if (backend.failure) |slot| slot.* orelse @errorName(restore_error) else @errorName(restore_error);
            if (backend.failure) |slot| slot.* = try fmt(ctx.allocator, "{s}; bootfs restoration failed: {s}", .{ original, extra });
            return error.BootDefaultRestoreFailed;
        }
        if (backend.failure) |slot| slot.* = original;
        return err;
    };
    try root.write("/var/db/rmxos/confirmed-target", try fmt(ctx.allocator, "{s}\n", .{current}), 0o444);
    try root.remove("/var/db/rmxos/pending-target");
    try root.remove("/var/db/softwareupdate/boot-check-failed");
    try root.remove("/var/db/softwareupdate/staged.tsv");
    try logAction(ctx, root, backend, "confirmed", current);
    try ctx.print(ctx.out, "confirmed={s}\n", .{current});
    try prune(ctx, root, backend, s.dataset.?, previous);
}
pub fn command(ctx: u.Context, action: u.Action, s: u.Snapshot, backend: e.Backend, restart: bool) !u8 {
    // Only cancellation may clear an outstanding one-time selection.
    var checked = s;
    if (action == .cancel and s.listing != null) {
        const copy = try ctx.allocator.dupe(u8, s.listing.?);
        var lines = std.mem.splitScalar(u8, copy, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            _ = fields.next();
            if (fields.next()) |flags| for (@constCast(flags)) |*ch| {
                if (ch.* == 'T') ch.* = '-';
            };
        }
        checked.listing = copy;
    }
    if (u.refusal(checked, null)) |reason| return ctx.diagnostic(reason);
    const root = try e.inspectRunning(ctx.allocator, ctx.root);
    defer root.close();
    const current = std.fs.path.basename(s.dataset.?);
    const bes = try listing(ctx.allocator, s.listing.?);
    const pending = try value(root, "/var/db/rmxos/pending-target");
    const temporary = try selected(bes);
    if (temporary != null and pending != null and eq(pending.?, current)) return error.TemporaryBootPending;
    if (action == .confirm) {
        try requirePending(root, current);
        const fd = try operationLock(root);
        defer _ = c.close(fd);
        try requirePending(root, current);
        var detail: ?[]const u8 = null;
        var tracked = backend;
        if (tracked.failure == null) tracked.failure = &detail;
        confirmPending(ctx, root, s, bes, tracked) catch |err| return failed(ctx, root, tracked, "confirm-failed", current, err);
        return 0;
    }
    if (action == .rollback or (action == .cancel and pending != null and eq(pending.?, current))) {
        const previous = (try value(root, "/var/db/rmxos/previous-be")) orelse return error.PreviousBEAbsent;
        if (!safeBE(previous) or !exists(bes, previous) or eq(previous, current)) return error.PreviousBEAbsent;
        const fd = try operationLock(root);
        defer _ = c.close(fd);
        _ = try backend.command(ctx.allocator, &.{ "/sbin/bectl", "activate", try ctx.allocator.dupeZ(u8, previous) });
        try root.remove("/var/db/rmxos/pending-target");
        try root.remove("/var/db/softwareupdate/staged.tsv");
        try logAction(ctx, root, backend, if (action == .cancel) "cancelled" else "rollback", previous);
        try ctx.print(ctx.out, "selected={s}; reboot with: shutdown -r now\n", .{previous});
        if (restart) _ = try backend.command(ctx.allocator, &.{ "/sbin/shutdown", "-r", "now" });
        return 0;
    }
    if (action == .cancel) {
        // u.refusal rejects T for ordinary changing commands; cancel deliberately
        // permits exactly the staged selection it is commissioned to remove.
        const target = temporary orelse return error.NoStagedUpdate;
        var registry = try owned(ctx.allocator, root);
        const token = registry.get(target) orelse return error.UnownedStagedBE;
        const fd = try operationLock(root);
        defer _ = c.close(fd);
        const mounted = try Mounted.open(ctx.allocator, backend, target, true);
        var open = true;
        defer if (open) {
            mounted.close() catch {};
        };
        if (!try matchesOwner(mounted.root, target, token)) return error.UnownedStagedBE;
        if (!eq((try value(mounted.root, "/var/db/rmxos/pending-target")) orelse "", target)) return error.NoPendingUpdate;
        try mounted.root.remove("/var/db/rmxos/pending-target");
        try mounted.root.remove("/var/db/softwareupdate/staged.tsv");
        try mounted.close();
        open = false;
        _ = try backend.command(ctx.allocator, &.{ "/sbin/bectl", "activate", "-T" });
        try u.seals.release(ctx.allocator, backend, try fmt(ctx.allocator, "{s}/{s}", .{ std.fs.path.dirname(s.dataset.?).?, target }));
        _ = try backend.command(ctx.allocator, &.{ "/sbin/bectl", "destroy", try ctx.allocator.dupeZ(u8, target) });
        _ = registry.remove(target);
        var registry_bytes: std.ArrayList(u8) = .empty;
        var registry_iterator = registry.iterator();
        while (registry_iterator.next()) |item| try registry_bytes.appendSlice(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "{s}\t{s}\n", .{ item.key_ptr.*, item.value_ptr.* }));
        try root.write("/var/db/softwareupdate/environments.tsv", registry_bytes.items, 0o444);
        try root.remove("/var/db/softwareupdate/staged.tsv");
        try logAction(ctx, root, backend, "cancelled", target);
        return 0;
    }
    return error.InvalidLifecycleCommand;
}
pub fn bootCheck(ctx: u.Context, backend: e.Backend) !u8 {
    if (c.geteuid() != 0) return ctx.diagnostic("root required");
    const root = try e.inspectRunning(ctx.allocator, ctx.root);
    defer root.close();
    const s = u.snapshot(ctx.allocator);
    const pending = (try value(root, "/var/db/rmxos/pending-target")) orelse return 0;
    if (s.dataset == null or !eq(std.fs.path.basename(s.dataset.?), pending)) return 0;
    if (eq((try value(root, "/var/db/softwareupdate/no-auto-confirm")) orelse "no", "yes")) return 0;
    const window = try delay(root);
    while (try uptime() < window) {
        _ = c.usleep(500000);
    }
    return checkReady(ctx, u.snapshot(ctx.allocator), backend);
}
pub fn checkReady(ctx: u.Context, s: u.Snapshot, backend: e.Backend) !u8 {
    if (u.refusal(s, null)) |reason| return ctx.diagnostic(reason);
    const root = try e.inspectRunning(ctx.allocator, ctx.root);
    defer root.close();
    const pending = (try value(root, "/var/db/rmxos/pending-target")) orelse return 0;
    if (!eq(std.fs.path.basename(s.dataset.?), pending)) return 0;
    if (eq((try value(root, "/var/db/softwareupdate/no-auto-confirm")) orelse "no", "yes")) return 0;
    if (try uptime() < try delay(root)) return 0;
    // Re-read after waiting: manual confirm/cancel may have ended the window.
    if (!eq((try value(root, "/var/db/rmxos/pending-target")) orelse "", pending)) return 0;
    var detail: ?[]const u8 = null;
    var tracked = backend;
    if (tracked.failure == null) tracked.failure = &detail;
    goodBoot(ctx, root, tracked) catch |err| return failed(ctx, root, tracked, "good-boot-failed", pending, err);
    return command(ctx, .confirm, s, tracked, false);
}
