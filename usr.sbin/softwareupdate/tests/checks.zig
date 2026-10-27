const std = @import("std");
const u = @import("update");
const c = u.c;
const a = std.heap.page_allocator;
const io = std.Io.Threaded.global_single_threaded.io();
const current = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const next = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const good = u.Snapshot{ .uid = 0, .dataset = "zroot/ROOT/rmxos-aaaaaaaaaaaa", .listing = "rmxos-aaaaaaaaaaaa\tNR\t/\t1G\t2026-10-27\n" };
fn expect(b: bool) !void {
    try std.testing.expect(b);
}
fn contains(s: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, s, part) != null;
}
const Fixture = struct {
    root: [:0]const u8,
    fn init() !Fixture {
        const template = try a.dupeZ(u8, "/tmp/softwareupdate-XXXXXX");
        if (c.mkdtemp(template) == null) return error.TemporaryDirectory;
        return .{ .root = template };
    }
    fn deinit(self: Fixture) void {
        std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
        a.free(self.root);
    }
    fn path(self: Fixture, name: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ self.root, name }, 0);
    }
    fn put(self: Fixture, name: []const u8, bytes: []const u8) !void {
        const filename = try self.path(name);
        defer a.free(filename);
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(filename).?);
        const fp = c.fopen(filename, "w") orelse return error.OpenFailed;
        defer _ = c.fclose(fp);
        try expect(c.fwrite(bytes.ptr, 1, bytes.len, fp) == bytes.len);
    }
    fn output(self: Fixture, args: []const []const u8, snap: u.Snapshot) !struct { rc: u8, text: []const u8 } {
        const filename = try self.path("/output");
        defer a.free(filename);
        const fd = c.open(filename, c.O_RDWR | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        const rc = try u.run(.{ .allocator = a, .root = self.root, .out = fd, .err = fd }, args, snap);
        try expect(c.lseek(fd, 0, c.SEEK_SET) == 0);
        return .{ .rc = rc, .text = try u.readFd(a, fd, 1024 * 1024) };
    }
};
pub fn arguments() !void {
    for ([_][]const u8{ "--list", "--history", "--help", "status", "confirm", "cancel", "rollback", "--download", "--install" }) |word| _ = try u.parse(&.{word});
    const install = try u.parse(&.{ "--install", "--restart", "--no-auto-confirm", "--recommended", "--all", "--os-only", "rmxos-bbbbbbbbbbbb" });
    try expect(install.action == .install and install.restart and install.no_auto_confirm);
    _ = try u.parse(&.{ "--install", "/tmp/update.tar" });
    _ = try u.parse(&.{ "--download", "all" });
    _ = try u.parse(&.{ "rollback", "--restart" });
    _ = try u.parse(&.{ "--list", "--catalog", "/tmp/tree" });
    for ([_][]const []const u8{ &.{}, &.{"--unknown"}, &.{ "status", "--list" }, &.{ "--list", "--restart" }, &.{ "--download", "--no-auto-confirm" }, &.{ "--install", "../escape" }, &.{ "--list", "--catalog" }, &.{ "status", "extra" }, &.{ "--install", "all", "extra" }, &.{ "--install", "--restart", "--restart" } }) |bad| try std.testing.expectError(error.InvalidArguments, u.parse(bad));
}
pub fn refusals() !void {
    const f = try Fixture.init();
    defer f.deinit();
    const samples = [_]struct { s: u.Snapshot, target: ?[]const u8, reason: []const u8 }{
        .{ .s = .{ .uid = 501, .dataset = good.dataset, .listing = good.listing }, .target = null, .reason = "root required" },
        .{ .s = .{ .uid = 0, .dataset = null, .listing = null }, .target = null, .reason = "running root is not ZFS" },
        .{ .s = .{ .uid = 0, .dataset = "zroot/other/current", .listing = good.listing }, .target = null, .reason = "running root is not a boot environment" },
        .{ .s = .{ .uid = 0, .dataset = good.dataset, .listing = null }, .target = null, .reason = "cannot read boot environment list" },
        .{ .s = .{ .uid = 0, .dataset = good.dataset, .listing = "other\tNR\t/\n" }, .target = null, .reason = "running root is not recognized by bectl" },
        .{ .s = .{ .uid = 0, .dataset = good.dataset, .listing = "rmxos-aaaaaaaaaaaa\tNR\t/\nother\tT\t-\n" }, .target = null, .reason = "one-time boot already pending" },
        .{ .s = good, .target = "rmxos-aaaaaaaaaaaa", .reason = "target is running" },
        .{ .s = .{ .uid = 0, .dataset = good.dataset, .listing = "rmxos-aaaaaaaaaaaa\tNR\t/\nrmxos-bbbbbbbbbbbb\t-\t-\n" }, .target = "rmxos-bbbbbbbbbbbb", .reason = "target already exists" },
        .{ .s = .{ .uid = 0, .dataset = good.dataset, .listing = "garbled" }, .target = null, .reason = "malformed boot environment list" },
    };
    for (samples) |v| {
        try expect(std.mem.eql(u8, u.refusal(v.s, v.target).?, v.reason));
        const out = try f.output(&.{ "--install", v.target orelse "rmxos-bbbbbbbbbbbb" }, v.s);
        defer a.free(out.text);
        try expect(out.rc != 0 and contains(out.text, "softwareupdate: ") and contains(out.text, v.reason));
    }
    for ([_][]const u8{ "--download", "--install", "confirm", "cancel", "rollback" }) |command| {
        const out = try f.output(&.{command}, samples[0].s);
        defer a.free(out.text);
        try expect(out.rc != 0 and std.mem.eql(u8, out.text, "softwareupdate: root required\n"));
    }
    try expect(u.refusal(good, "rmxos-bbbbbbbbbbbb") == null);
    try expect(u.dataset("/dev/ada0 / ufs rw 1 1\n") == null);
    try expect(std.mem.eql(u8, u.dataset("zroot/ROOT/rmxos-aaaaaaaaaaaa / zfs rw 0 0\n").?, good.dataset.?));
    // The tests create only their fixture. Preconditions never mutate it.
    const missing = try f.path("/var/db/softwareupdate");
    defer a.free(missing);
    try expect(c.access(missing, c.F_OK) != 0);
}
fn publish(f: Fixture, from: []const u8) ![:0]const u8 {
    try f.put("/var/db/rmxos/commit", current ++ "\n");
    try f.put("/var/db/rmxos/manifest.tsv", "fixture manifest\n");
    const manifest = try u.hashPath(a, try f.path("/var/db/rmxos/manifest.tsv"));
    defer a.free(manifest);
    const sha = std.fmt.bytesToHex(archiveHash(), .lower);
    const text = try std.fmt.allocPrint(a, "{{\"format\":\"rmxos-catalog-v1\",\"updates\":[{{\"name\":\"rmxos-bbbbbbbbbbbb\",\"commit\":\"{s}\",\"sha256\":\"{s}\",\"from\":{{\"commit\":\"{s}\",\"manifest_sha256\":\"{s}\"}},\"date\":\"2026-10-27T00:00:00Z\",\"size\":15,\"restart_required\":true}}]}}", .{ next, sha, from, manifest });
    defer a.free(text);
    try f.put("/published/catalog.json", text);
    try f.put("/published/rmxos-bbbbbbbbbbbb/update.tar", "fixture archive");
    try f.put("/published/rmxos-bbbbbbbbbbbb/update.tar.sha256", &sha);
    return f.path("/published");
}
pub fn listing() !void {
    const f = try Fixture.init();
    defer f.deinit();
    const dir = try publish(f, current);
    defer a.free(dir);
    const out = try f.output(&.{ "--list", "--catalog", dir }, good);
    defer a.free(out.text);
    try expect(out.rc == 0 and contains(out.text, "applies=yes") and contains(out.text, "rmxos-bbbbbbbbbbbb"));
    try f.put("/var/db/rmxos/commit", next ++ "\n");
    const mismatch = try f.output(&.{ "--list", "--catalog", dir }, good);
    defer a.free(mismatch.text);
    try expect(mismatch.rc == 0 and contains(mismatch.text, "applies=no"));
    try f.put("/var/db/rmxos/commit", current ++ "\n");
    try f.put("/var/db/rmxos/manifest.tsv", "different manifest\n");
    const changed = try f.output(&.{ "--list", "--catalog", dir }, good);
    defer a.free(changed.text);
    try expect(contains(changed.text, "applies=no"));
}
pub fn malformed() !void {
    const f = try Fixture.init();
    defer f.deinit();
    const dir = try publish(f, current);
    defer a.free(dir);
    try f.put("/published/catalog.json", "{garbled");
    const result = f.output(&.{ "--list", "--catalog", dir }, good);
    if (result) |_| return error.AcceptedMalformedCatalog else |_| {}
    const incomplete = "{\"format\":\"rmxos-catalog-v1\",\"updates\":[{}]}";
    if (u.catalog(a, incomplete)) |p| {
        p.deinit();
        return error.AcceptedMalformedCatalog;
    } else |_| {}
    const valid = try publish(f, current);
    defer a.free(valid);
    try f.put("/published/rmxos-bbbbbbbbbbbb/update.tar.sha256", "bad");
    try std.testing.expectError(error.ChecksumSidecarMismatch, f.output(&.{ "--list", "--catalog", dir }, good));
}
pub fn statusFields() !void {
    const f = try Fixture.init();
    defer f.deinit();
    try f.put("/etc/sub/owner.rmxos-new", "new");
    try f.put("/sbin/launchd", "pid1 fixture");
    try f.put("/boot/RMXOS-RELEASE/kernel", "kernel fixture");
    try f.put("/boot/RMXOS-RELEASE/mach.ko", "mach fixture");
    try f.put("/var/db/rmxos/commit", current ++ "\n");
    try f.put("/var/db/rmxos/pending-target", "rmxos-bbbbbbbbbbbb\n");
    try f.put("/var/db/rmxos/confirmed-target", "rmxos-aaaaaaaaaaaa\n");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..12) |i| try text.appendSlice(a, try std.fmt.allocPrint(a, "time\taction-{d}\tfrom\tto\told\tnew\t0\n", .{i}));
    try f.put("/var/db/softwareupdate/history.tsv", text.items);
    const out = try f.output(&.{"status"}, good);
    defer a.free(out.text);
    for ([_][]const u8{ "root_dataset=zroot/ROOT/", "running_be=rmxos-aaaaaaaaaaaa", "sha256 /boot/RMXOS-RELEASE/kernel=", "sha256 /boot/RMXOS-RELEASE/mach.ko=", "sha256 /sbin/launchd=", "commit=" ++ current, "staged=rmxos-bbbbbbbbbbbb", "confirmed=rmxos-aaaaaaaaaaaa", "sidecar=/etc/sub/owner.rmxos-new", "sidecars=1", "boot_environments:", "history_last_10:", "action-2\t", "action-11\t" }) |part| try expect(contains(out.text, part));
    try expect(!contains(out.text, "action-0\t") and !contains(out.text, "action-1\t"));
    const hist = try f.output(&.{"--history"}, good);
    defer a.free(hist.text);
    try expect(std.mem.eql(u8, hist.text, text.items));
    for ([_][]const u8{ "/sbin/launchd", "/boot/RMXOS-RELEASE/kernel", "/boot/RMXOS-RELEASE/mach.ko" }) |path| {
        const actual = try u.hashPath(a, try f.path(path));
        defer a.free(actual);
        const field = try std.fmt.allocPrint(a, "sha256 {s}={s}", .{ path, actual });
        defer a.free(field);
        try expect(contains(out.text, field));
    }
    // Before reboot the pending marker lives in the clone, not this root.
    const pending_path = try f.path("/var/db/rmxos/pending-target");
    try expect(c.unlink(pending_path) == 0);
    try f.put("/var/db/softwareupdate/staged.tsv", "rmxos-bbbbbbbbbbbb\t" ++ "b" ** 40 ++ "\n");
    var staged = good;
    staged.listing = "rmxos-aaaaaaaaaaaa\tNR\t/\nrmxos-bbbbbbbbbbbb\tT\t-\n";
    const before_boot = try f.output(&.{"status"}, staged);
    try expect(contains(before_boot.text, "staged=rmxos-bbbbbbbbbbbb\nstaged_commit=" ++ "b" ** 40));
    try f.put("/var/db/rmxos/pending-target", "rmxos-aaaaaaaaaaaa\n");
    try f.put("/var/db/softwareupdate/no-auto-confirm", "yes\n");
    try f.put("/var/db/softwareupdate/boot-check-failed", "LogProbeNotStored\n");
    const window = try f.output(&.{"status"}, good);
    try expect(contains(window.text, "pending_window_seconds=") and contains(window.text, "auto_confirm=disabled"));
    try expect(contains(window.text, "good_boot=failed reason=LogProbeNotStored") and contains(window.text, "action=run softwareupdate rollback"));
}
pub fn unimplemented() !void {
    const f = try Fixture.init();
    defer f.deinit();
    for ([_][]const []const u8{ &.{"--download"}, &.{ "--download", "all" }, &.{ "--install", "rmxos-bbbbbbbbbbbb" }, &.{"--install"} }) |args| {
        const out = try f.output(args, good);
        defer a.free(out.text);
        try expect(out.rc != 0 and std.mem.eql(u8, out.text, "softwareupdate: not yet implemented\n"));
    }
}
pub fn installed() !void {
    const env = c.getenv("SOFTWAREUPDATE_TEST_BINARY");
    const binary: [:0]const u8 = if (env != null) std.mem.span(env) else "/usr/sbin/softwareupdate";
    const help = try u.capture(a, &.{ binary, "--help" });
    defer a.free(help);
    try expect(contains(help, "--install") and contains(help, "rollback"));
    const out = try u.capture(a, &.{ binary, "status" });
    defer a.free(out);
    for ([_][]const u8{ "running_be=", "sha256 /boot/RMXOS-RELEASE/kernel=", "sha256 /boot/RMXOS-RELEASE/mach.ko=", "sha256 /sbin/launchd=", "commit=", "staged=", "confirmed=", "sidecars=", "boot_environments:", "history_last_10:" }) |part| try expect(contains(out, part));
    if (c.geteuid() != 0) return;
    var pipes: [2]c_int = undefined;
    try expect(c.pipe(&pipes) == 0);
    const pid = c.fork();
    try expect(pid >= 0);
    if (pid == 0) {
        _ = c.close(pipes[0]);
        _ = c.dup2(pipes[1], 2);
        _ = c.close(pipes[1]);
        if (c.setgid(65534) != 0 or c.setuid(65534) != 0) c._exit(90);
        _ = c.execl(binary, binary, "--install", "rmxos-bbbbbbbbbbbb", @as(?[*:0]const u8, null));
        c._exit(91);
    }
    _ = c.close(pipes[1]);
    defer _ = c.close(pipes[0]);
    const stderr = try u.readFd(a, pipes[0], 8192);
    defer a.free(stderr);
    var status: c_int = 0;
    try expect(c.waitpid(pid, &status, 0) == pid and status == 256);
    try expect(std.mem.eql(u8, stderr, "softwareupdate: root required\n"));
}
test "argument surface" {
    try arguments();
}
test "all BE refusals without mutation" {
    try refusals();
}
test "local catalog applicability requires commit and manifest" {
    try listing();
}
test "malformed catalog and checksum sidecar" {
    try malformed();
}
test "status identities sidecars and history" {
    try statusFields();
}
test "changing commands remain disabled" {
    try unimplemented();
}
test "installed command surface and real nonroot refusal" {
    try installed();
}
fn archiveHash() [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture archive", &digest, .{});
    return digest;
}
