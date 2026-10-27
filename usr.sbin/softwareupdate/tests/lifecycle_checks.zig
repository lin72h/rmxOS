const std = @import("std");
const u = @import("update");
const l = u.lifecycle;
const e = u.engine;
const c = u.c;
const a = std.heap.page_allocator;
const io = std.Io.Threaded.global_single_threaded.io();
const current = "rmxos-bbbbbbbbbbbb";
const previous = "rmxos-aaaaaaaaaaaa";
const token = "0123456789abcdef0123456789abcdef";
const expect = std.testing.expect;
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn fmt(comptime f: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, f, args, 0);
}
const Fixture = struct {
    path: [:0]const u8,
    root: e.Root,
    ctx: u.Context,
    calls: std.ArrayList([]const u8) = .empty,
    text: []const u8 = previous ++ "\tR\t-\n" ++ current ++ "\tN\t/\n",
    fail: []const u8 = "",
    marker: []const u8 = "",
    mounted: ?struct { name: []const u8, path: [:0]const u8 } = null,
    fn init() !Fixture {
        const path = try a.dupeZ(u8, "/tmp/softwareupdate-lifecycle-XXXXXX");
        if (c.mkdtemp(path) == null) return error.TemporaryDirectory;
        errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        const root = try e.Root.open(a, path, false);
        errdefer root.close();
        const fd = c.open("/dev/null", c.O_WRONLY);
        if (fd < 0) return error.OpenFailed;
        var f = Fixture{ .path = path, .root = root, .ctx = .{ .allocator = a, .root = path, .out = fd, .err = fd } };
        try root.write("/var/db/rmxos/previous-be", previous ++ "\n", 0o444);
        try root.write("/var/db/rmxos/pending-target", current ++ "\n", 0o444);
        try root.write("/var/db/rmxos/commit", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n", 0o444);
        try f.identity();
        return f;
    }
    fn deinit(f: Fixture) void {
        f.root.close();
        _ = c.close(f.ctx.out);
        std.Io.Dir.cwd().deleteTree(io, f.path) catch {};
    }
    fn identity(f: Fixture) !void {
        var rows: std.ArrayList(u8) = .empty;
        try rows.appendSlice(a, "rmx-overlay-v1\nbase=" ++ "a" ** 64 ++ "\n");
        for ([_][]const u8{ "/boot/RMXOS-RELEASE/kernel", "/boot/RMXOS-RELEASE/mach.ko", "/sbin/launchd", "/boot/loader.efi" }) |path| {
            try f.root.write(path, "identity fixture", 0o555);
            const hash = try u.hashPath(a, try fmt("{s}{s}", .{ f.path, path }));
            try rows.appendSlice(a, try fmt("{s}\t0555\t{s}\n", .{ hash, path }));
        }
        try f.root.write("/var/db/rmxos/manifest.tsv", rows.items, 0o444);
    }
    fn snap(f: Fixture) u.Snapshot {
        return .{ .uid = 0, .dataset = "pool/ROOT/" ++ current, .listing = f.text };
    }
    fn backend(f: *Fixture) e.Backend {
        return .{ .data = f, .execute = execute };
    }
    fn has(f: Fixture, needle: []const u8) bool {
        for (f.calls.items) |s| if (eq(s, needle)) return true;
        return false;
    }
    fn execute(ptr: ?*anyopaque, _: std.mem.Allocator, args: []const [:0]const u8) ![]const u8 {
        const f: *Fixture = @ptrCast(@alignCast(ptr.?));
        var line: std.ArrayList(u8) = .empty;
        for (args, 0..) |arg, i| {
            if (i != 0) try line.append(a, ' ');
            try line.appendSlice(a, arg);
        }
        try f.calls.append(a, try line.toOwnedSlice(a));
        if (eq(args[0], f.fail)) return error.FakeCommandFailure;
        if (eq(args[0], "/bin/ps")) return if (eq(f.fail, "pid1")) "init\n" else "launchd\n";
        if (eq(args[0], "/bin/pgrep")) return if (eq(f.fail, "logd")) "" else "42\n";
        if (eq(args[0], "/usr/bin/logger")) {
            f.marker = args[args.len - 1];
            return "";
        }
        if (eq(args[0], "/usr/bin/log")) return f.marker;
        if (eq(args[0], "/sbin/zfs")) {
            if (eq(args[1], "list")) return try fmt("{s}@sealed\n", .{args[args.len - 1]});
            if (eq(args[1], "get")) return "1234567890\n";
            if (eq(args[1], "holds")) return try fmt("{s}\tsoftwareupdate\tdate\n", .{args[args.len - 1]});
            return "";
        }
        if (eq(args[0], "/sbin/mount")) return try fmt("/dev/fake {s}/esp msdosfs rw 0 0\n", .{f.path});
        if (!eq(args[0], "/sbin/bectl")) return "";
        if (eq(args[1], "list")) return f.text;
        if (eq(args[1], "mount")) {
            const name = args[args.len - 2];
            const at = args[args.len - 1];
            _ = c.rmdir(at);
            if (c.rename(try fmt("{s}/bes/{s}", .{ f.path, name }), at) != 0) return error.FakeMount;
            f.mounted = .{ .name = name, .path = at };
        } else if (eq(args[1], "unmount")) {
            const m = f.mounted orelse return error.FakeUnmount;
            if (!eq(args[2], m.name)) return error.FakeUnmount;
            if (c.rename(m.path, try fmt("{s}/bes/{s}", .{ f.path, m.name })) != 0) return error.FakeUnmount;
            f.mounted = null;
        } else if (eq(args[1], "destroy")) {
            try std.Io.Dir.cwd().deleteTree(io, try fmt("{s}/bes/{s}", .{ f.path, args[2] }));
        }
        return "";
    }
    fn other(f: Fixture, name: []const u8, owner: []const u8) !void {
        const path = try fmt("{s}/bes/{s}", .{ f.path, name });
        try std.Io.Dir.cwd().createDirPath(io, path);
        const root = try e.Root.open(a, path, false);
        defer root.close();
        try root.write("/var/db/softwareupdate/created-by", try fmt("{s}\t{s}\n", .{ name, owner }), 0o444);
        try root.write("/var/db/rmxos/pending-target", try fmt("{s}\n", .{name}), 0o444);
    }
};
pub fn confirm() !void {
    var f = try Fixture.init();
    defer f.deinit();
    try expect(try l.command(f.ctx, .confirm, f.snap(), f.backend(), false) == 0);
    try expect(f.has("/sbin/bectl activate " ++ current));
    try expect(try f.root.stat("/var/db/rmxos/pending-target") == null);
    try expect(eq((try f.root.read("/var/db/rmxos/confirmed-target")).?, current ++ "\n"));
    try std.testing.expectError(error.NoPendingUpdate, l.command(f.ctx, .confirm, f.snap(), f.backend(), false));
}
pub fn rollback() !void {
    for ([_]u.Action{ .rollback, .cancel }) |action| {
        var f = try Fixture.init();
        defer f.deinit();
        try expect(try l.command(f.ctx, action, f.snap(), f.backend(), action == .rollback) == 0);
        try expect(f.has("/sbin/bectl activate " ++ previous));
        try expect(f.has("/sbin/shutdown -r now") == (action == .rollback));
        try expect(try f.root.stat("/var/db/rmxos/pending-target") == null);
    }
}
pub fn cancelStaged() !void {
    var f = try Fixture.init();
    defer f.deinit();
    try f.root.remove("/var/db/rmxos/pending-target");
    try f.other(previous, token);
    try f.root.write("/var/db/softwareupdate/environments.tsv", previous ++ "\t" ++ token ++ "\n", 0o444);
    f.text = current ++ "\tNR\t/\n" ++ previous ++ "\tT\t-\n";
    try expect(try l.command(f.ctx, .cancel, f.snap(), f.backend(), false) == 0);
    try expect(f.has("/sbin/bectl activate -T"));
    try expect(f.has("/sbin/bectl destroy " ++ previous));
    const calls = try std.mem.join(a, "\n", f.calls.items);
    try expect(std.mem.indexOf(u8, calls, "/sbin/zfs release softwareupdate").? < std.mem.indexOf(u8, calls, "/sbin/bectl destroy").?);
    try expect(c.access(try fmt("{s}/bes/{s}", .{ f.path, previous }), c.F_OK) != 0);
}
pub fn refusals() !void {
    var f = try Fixture.init();
    defer f.deinit();
    var s = f.snap();
    s.uid = 501;
    for ([_]u.Action{ .confirm, .cancel, .rollback }) |action| try expect(try l.command(f.ctx, action, s, f.backend(), false) != 0);
    try expect(f.calls.items.len == 0);
    s = f.snap();
    s.dataset = null;
    try expect(try l.command(f.ctx, .confirm, s, f.backend(), false) != 0);
    s = f.snap();
    s.listing = current ++ "\tN\n" ++ previous ++ "\tT\n";
    try expect(try l.command(f.ctx, .confirm, s, f.backend(), false) != 0);
    try f.root.remove("/var/db/rmxos/pending-target");
    try std.testing.expectError(error.UnownedStagedBE, l.command(f.ctx, .cancel, s, f.backend(), false));
    try f.root.write("/var/db/rmxos/pending-target", previous, 0o444);
    try std.testing.expectError(error.RunningBEDiffersFromPending, l.command(f.ctx, .confirm, f.snap(), f.backend(), false));
    try f.root.remove("/var/db/rmxos/previous-be");
    try std.testing.expectError(error.PreviousBEAbsent, l.command(f.ctx, .rollback, f.snap(), f.backend(), false));
    try expect(f.calls.items.len == 0);
}
pub fn goodBoot() !void {
    var f = try Fixture.init();
    defer f.deinit();
    try l.goodBoot(f.ctx, f.root, f.backend());
    try expect(f.marker.len != 0);
    f.fail = "pid1";
    try std.testing.expectError(error.PID1NotLaunchd, l.goodBoot(f.ctx, f.root, f.backend()));
    f.fail = "/sbin/kldstat";
    try std.testing.expectError(error.FakeCommandFailure, l.goodBoot(f.ctx, f.root, f.backend()));
    f.fail = "logd";
    try std.testing.expectError(error.LogdNotRunning, l.goodBoot(f.ctx, f.root, f.backend()));
    f.fail = "/usr/bin/log";
    try std.testing.expectError(error.FakeCommandFailure, l.goodBoot(f.ctx, f.root, f.backend()));
    try f.root.write("/sbin/launchd", "changed", 0o555);
    try std.testing.expectError(error.IdentityMismatch, l.goodBoot(f.ctx, f.root, f.backend()));
    try expect(try f.root.stat("/var/db/rmxos/pending-target") != null);
}
pub fn settings() !void {
    var f = try Fixture.init();
    defer f.deinit();
    try expect(try l.delay(f.root) == 600);
    try f.root.write("/var/db/softwareupdate/confirm-delay", "3\n", 0o444);
    try expect(try l.delay(f.root) == 3);
    try f.root.write("/var/db/softwareupdate/confirm-delay", "601", 0o444);
    try std.testing.expectError(error.InvalidDelay, l.delay(f.root));
    try f.root.write("/var/db/softwareupdate/confirm-delay", "0", 0o444);
    const fd = try l.operationLock(f.root);
    defer _ = c.close(fd);
    try std.testing.expectError(error.UpdateOperationBusy, l.operationLock(f.root));
}
pub fn retention() !void {
    var f = try Fixture.init();
    defer f.deinit();
    const names = [_][]const u8{ "rmxos-111111111111", "rmxos-222222222222", "rmxos-333333333333", "rmxos-444444444444" };
    var registry: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "foreign\t-\n" ++ previous ++ "\t-\n");
    for (names) |name| {
        try f.other(name, token);
        try registry.appendSlice(a, try fmt("{s}\t{s}\n", .{ name, token }));
        try text.appendSlice(a, try fmt("{s}\t-\n", .{name}));
    }
    try text.appendSlice(a, current ++ "\tNR\n");
    f.text = text.items;
    try f.root.write("/var/db/softwareupdate/environments.tsv", registry.items, 0o444);
    try l.prune(f.ctx, f.root, f.backend(), "pool/ROOT/" ++ current, previous);
    try expect(f.has("/sbin/bectl destroy rmxos-111111111111"));
    try expect(f.has("/sbin/bectl destroy rmxos-222222222222"));
    try expect(!f.has("/sbin/bectl destroy foreign") and !f.has("/sbin/bectl destroy " ++ previous));
    try expect(!f.has("/sbin/bectl destroy rmxos-333333333333"));
    const calls = try std.mem.join(a, "\n", f.calls.items);
    try expect(std.mem.indexOf(u8, calls, "/sbin/zfs release softwareupdate").? < std.mem.indexOf(u8, calls, "/sbin/bectl destroy").?);
    f.text = current ++ "\tN\n" ++ previous ++ "\tT\n";
    try std.testing.expectError(error.TemporaryBootPending, l.prune(f.ctx, f.root, f.backend(), "pool/ROOT/" ++ current, previous));
}
pub fn efi() !void {
    var f = try Fixture.init();
    defer f.deinit();
    try f.root.write("/esp/EFI/BOOT/BOOTX64.EFI", "old", 0o644);
    try f.root.write("/var/db/softwareupdate/efi-loader-changed", "yes", 0o444);
    try l.refreshEFI(f.ctx, f.root, f.backend());
    try expect(eq((try f.root.read("/esp/EFI/BOOT/BOOTX64.EFI")).?, "identity fixture"));
    try expect(eq((try f.root.read("/var/db/softwareupdate/efi-loader-changed")).?, "no\n"));
    try f.root.write("/var/db/softwareupdate/efi-loader-changed", "yes", 0o444);
    try f.root.write("/boot/loader.efi", "corrupt", 0o555);
    try std.testing.expectError(error.LoaderIdentityMismatch, l.refreshEFI(f.ctx, f.root, f.backend()));
}
pub fn autoConfirm() !void {
    var f = try Fixture.init();
    defer f.deinit();
    try f.root.write("/var/db/softwareupdate/confirm-delay", "0", 0o444);
    try f.root.write("/var/db/softwareupdate/no-auto-confirm", "yes", 0o444);
    try expect(try l.checkReady(f.ctx, f.snap(), f.backend()) == 0);
    try expect(f.calls.items.len == 0);
    try f.root.write("/var/db/softwareupdate/no-auto-confirm", "no", 0o444);
    f.fail = "pid1";
    try expect(try l.checkReady(f.ctx, f.snap(), f.backend()) != 0);
    try expect(!f.has("/sbin/bectl activate " ++ current));
    try expect(try f.root.stat("/var/db/softwareupdate/boot-check-failed") != null);
    try expect(std.mem.indexOf(u8, (try f.root.read("/var/db/softwareupdate/history.tsv")).?, "good-boot-failed") != null);
    f.fail = "";
    try expect(try l.checkReady(f.ctx, f.snap(), f.backend()) == 0);
    try expect(f.has("/sbin/bectl activate " ++ current));
    try expect(try f.root.stat("/var/db/softwareupdate/boot-check-failed") == null);
}
test "automatic confirmation is gated and failure remains pending" {
    try autoConfirm();
}
test "confirm is persistent and clears pending" {
    try confirm();
}
test "rollback and postboot cancel select previous" {
    try rollback();
}
test "preboot cancellation clears T and clone state" {
    try cancelStaged();
}
test "lifecycle refusals do not activate" {
    try refusals();
}
test "good boot requires identity and all services and stored marker" {
    try goodBoot();
}
test "default delay test setting and exclusive lock" {
    try settings();
}
test "retention protects previous foreign and selected environments" {
    try retention();
}
test "EFI loader refresh and identity refusal" {
    try efi();
}
