// Test-side ASL reads: current-case tail for live observations, current boot
// for boot history. Never rerun an unbounded historical scan in a poll.
const std = @import("std");
// ATF callbacks have no process.Init; their file operations are synchronous.
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("asl.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("sys/time.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/stat.h");
    @cInclude("time.h");
    @cInclude("dirent.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});
const a = std.heap.page_allocator;
var floor: usize = 0;
fn storePath() [*:0]const u8 {
    return if (c.getenv("RMX_ASL_TEST_STORE")) |p| p else "/var/log/asl";
}
fn z(s: []const u8) [:0]const u8 {
    return a.dupeZ(u8, s) catch unreachable;
}
pub fn begin() void {
    const store = c.asl_open_path(storePath(), 0) orelse @panic("open ASL scope");
    defer c.asl_release(store);
    var last: usize = 0;
    const result = c.asl_match(store, null, &last, std.math.maxInt(usize), 1, 100000, -1);
    defer c.asl_release(result);
    floor = last;
}
pub fn query(key: []const u8, value: []const u8, prefix: bool, boot: bool) []const u8 {
    if (boot) return readBoot(key, value, prefix, bootWindow()).bytes;
    const store = c.asl_open_path(storePath(), 0) orelse @panic("open scoped ASL reader");
    defer c.asl_release(store);
    const q = c.asl_new(c.ASL_TYPE_QUERY) orelse unreachable;
    defer c.asl_release(q);
    const list = c.asl_new(c.ASL_TYPE_LIST) orelse unreachable;
    defer c.asl_release(list);
    if (c.asl_set_query(q, z(key), z(value), @intCast(c.ASL_QUERY_OP_EQUAL | @as(c_int, if (prefix) c.ASL_QUERY_OP_PREFIX else 0))) != 0) @panic("ASL query key");
    c.asl_append(list, q);
    // A matching boundary record terminates an absent-tail search without
    // walking the older store. It is discarded, never treated as a match.
    if (!boot and floor != 0) {
        const boundary = c.asl_new(c.ASL_TYPE_QUERY) orelse unreachable;
        defer c.asl_release(boundary);
        var buf: [32]u8 = undefined;
        const id = std.fmt.bufPrintZ(&buf, "{d}", .{floor}) catch unreachable;
        if (c.asl_set_query(boundary, "ASLMessageID", id, c.ASL_QUERY_OP_NUMERIC | c.ASL_QUERY_OP_LESS_EQUAL) != 0) unreachable;
        c.asl_append(list, boundary);
    }
    var strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (strings.items) |s| a.free(s);
        strings.deinit(a);
    }
    var start: usize = std.math.maxInt(usize);
    while (true) {
        var last: usize = 0;
        const result = c.asl_match(store, list, &last, start, 1024, 100000, -1);
        defer c.asl_release(result);
        var stop = false;
        while (c.asl_next(result)) |message| {
            // List iteration returns borrowed messages, unlike store iteration.
            const id = c.asl_get(message, "ASLMessageID") orelse @panic("record ID");
            const number = std.fmt.parseInt(usize, std.mem.span(id), 10) catch unreachable;
            if (!boot and number <= floor) {
                stop = true;
                break;
            }
            const raw = c.asl_format(message, "raw", "sec", 0) orelse @panic("format ASL");
            defer c.free(raw);
            strings.append(a, a.dupe(u8, std.mem.span(raw)) catch unreachable) catch unreachable;
        }
        if (stop or last == 0 or last >= start or last == 1) break;
        start = last - 1;
    }
    var out: std.ArrayList(u8) = .empty;
    var i = strings.items.len;
    while (i > 0) {
        i -= 1;
        out.appendSlice(a, strings.items[i]) catch unreachable;
        out.append(a, '\n') catch unreachable;
    }
    return out.toOwnedSlice(a) catch unreachable;
}

pub const BootWindow = struct { started: i64, ready: i64, ready_nsec: i64 = 999999999 };
const Timestamp = struct { sec: i64, nsec: i64 };
pub const BootRead = struct {
    bytes: []const u8,
    retained: bool,
    oldest: ?Timestamp,
    window: BootWindow,

    // A missing startup window alone cannot distinguish retention from loss.
    // Return a reason only when the whole store demonstrably starts later.
    pub fn startupCheck(self: BootRead, reason: *[256]u8) error{ StartupRecordsMissing, EmptyStore }!?[:0]const u8 {
        if (self.retained) return null;
        const oldest = self.oldest orelse return error.EmptyStore;
        if (oldest.sec < self.window.ready or
            (oldest.sec == self.window.ready and oldest.nsec <= self.window.ready_nsec))
            return error.StartupRecordsMissing;
        return std.fmt.bufPrintZ(reason, "the store's oldest record ({d}.{d:0>9}) is newer than the boot's first readiness ({d}.{d:0>9})", .{
            oldest.sec, @as(u32, @intCast(oldest.nsec)), self.window.ready, @as(u32, @intCast(self.window.ready_nsec)),
        }) catch unreachable;
    }
};
const ReadyProof = extern struct { boot_sec: i64, boot_usec: i64, marker_sec: i64, marker_nsec: i64, ready_sec: i64, ready_nsec: i64 };
pub fn bootWindow() BootWindow {
    var started: c.struct_timeval = undefined;
    var size: usize = @sizeOf(c.struct_timeval);
    if (c.sysctlbyname("kern.boottime", &started, &size, null, 0) != 0 or size != @sizeOf(c.struct_timeval)) @panic("boot time");
    // launchd_logging captures this before restart cases or compatibility
    // onestart can replace the service-ready file. Never use a later restart.
    if (c.fopen("/var/run/op942-first-asld-ready", "rb")) |fp| {
        defer _ = c.fclose(fp);
        var proof: ReadyProof = undefined;
        if (c.fread(&proof, @sizeOf(ReadyProof), 1, fp) != 1 or proof.boot_sec != started.tv_sec or proof.boot_usec != started.tv_usec) @panic("first asld readiness proof");
        return .{ .started = started.tv_sec, .ready = proof.ready_sec, .ready_nsec = proof.ready_nsec };
    }
    // A standalone kernel case may precede the launchd cases. Accept the
    // current marker only when the boot log proves there was one readiness.
    const fp = c.fopen("/var/run/asld.boot-service.log", "r") orelse @panic("asld boot log");
    defer _ = c.fclose(fp);
    var line: [1024]u8 = undefined;
    var observations: usize = 0;
    while (c.fgets(&line, line.len, fp) != null) {
        if (std.mem.startsWith(u8, std.mem.sliceTo(&line, 0), "asld: compatibility service ready pid=")) observations += 1;
    }
    var ready: c.struct_stat = undefined;
    if (c.ferror(fp) != 0 or observations != 1 or c.stat("/var/run/asld.service-ready", &ready) != 0) @panic("first asld readiness unavailable");
    var marker: c.struct_stat = undefined;
    if (c.stat("/var/run/asld.filesystems-ready", &marker) != 0) @panic("asld filesystem readiness");
    const proof: ReadyProof = .{ .boot_sec = started.tv_sec, .boot_usec = started.tv_usec, .marker_sec = marker.st_mtim.tv_sec, .marker_nsec = marker.st_mtim.tv_nsec, .ready_sec = ready.st_mtim.tv_sec, .ready_nsec = ready.st_mtim.tv_nsec };
    const saved = c.fopen("/var/run/op942-first-asld-ready", "wbx") orelse @panic("capture first asld readiness");
    const written = c.fwrite(&proof, @sizeOf(ReadyProof), 1, saved);
    const closed = c.fclose(saved);
    if (written != 1 or closed != 0) @panic("save first asld readiness");
    return .{ .started = started.tv_sec, .ready = ready.st_mtim.tv_sec, .ready_nsec = ready.st_mtim.tv_nsec };
}

extern fn asl_file_open_read([*:0]const u8, *?*anyopaque) u32;
extern fn asl_file_list_add(?*anyopaque, ?*anyopaque) ?*anyopaque;
extern fn asl_file_list_close(?*anyopaque) void;
extern fn asl_file_close(?*anyopaque) u32;
extern fn asl_file_list_match(?*anyopaque, c.asl_object_t, *u64, u64, u32, u32, i32) c.asl_object_t;
fn dayPrefixes(started: i64) [2][11]u8 {
    var stamp: c.time_t = @intCast(started);
    var local: c.struct_tm = undefined;
    if (c.localtime_r(&stamp, &local) == null) @panic("local boot date");
    var dates: [2][11]u8 = undefined;
    if (c.strftime(&dates[0], dates[0].len, "%Y.%m.%d", &local) != 10) @panic("boot date prefix");
    // Include the following civil day for boots that straddle midnight.
    // mktime, rather than +86400, handles short/long days across DST.
    local.tm_mday += 1;
    local.tm_hour = 12;
    local.tm_min = 0;
    local.tm_sec = 0;
    local.tm_isdst = -1;
    stamp = c.mktime(&local);
    if (stamp == -1 or c.localtime_r(&stamp, &local) == null or c.strftime(&dates[1], dates[1].len, "%Y.%m.%d", &local) != 10) @panic("next boot date prefix");
    return dates;
}
fn bootFiles(started: i64) ?*anyopaque {
    const dates = dayPrefixes(started);
    const dir = c.opendir(storePath()) orelse @panic("open boot ASL directory");
    defer _ = c.closedir(dir);
    var files: ?*anyopaque = null;
    while (true) {
        c.__error().* = 0;
        const entry = c.readdir(dir) orelse {
            if (c.__error().* != 0) @panic("read boot ASL directory");
            break;
        };
        const name = entry.*.d_name[0..entry.*.d_namlen];
        if (!std.mem.startsWith(u8, name, dates[0][0..10]) and !std.mem.startsWith(u8, name, dates[1][0..10]) and !std.mem.startsWith(u8, name, "BB.")) continue;
        const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.mem.span(storePath()), name }, 0) catch unreachable;
        defer a.free(path);
        var file: ?*anyopaque = null;
        // Like Apple's store reader, ignore non-ASL files and files removed
        // by retention between directory enumeration and open.
        if (asl_file_open_read(path, &file) != 0) continue;
        const next = asl_file_list_add(files, file);
        if (next == files) {
            _ = asl_file_close(file); // Legacy files are not added.
        } else if (next == null) {
            _ = asl_file_close(file);
            asl_file_list_close(files);
            @panic("boot ASL file list");
        } else files = next;
    }
    return files;
}
fn since(window: BootWindow) c.asl_object_t {
    const q = c.asl_new(c.ASL_TYPE_QUERY) orelse unreachable;
    var buf: [32]u8 = undefined;
    const stamp = std.fmt.bufPrintZ(&buf, "{d}", .{window.started}) catch unreachable;
    if (c.asl_set_query(q, "Time", stamp, c.ASL_QUERY_OP_NUMERIC | c.ASL_QUERY_OP_GREATER_EQUAL) != 0) unreachable;
    return q;
}
fn startupRetained(files: ?*anyopaque, window: BootWindow) bool {
    const q = since(window);
    defer c.asl_release(q);
    const list = c.asl_new(c.ASL_TYPE_LIST) orelse unreachable;
    defer c.asl_release(list);
    c.asl_append(list, q);
    var start: u64 = 0;
    while (true) {
        var last: u64 = 0;
        const result = asl_file_list_match(files, list, &last, start, 1024, 100000, 1);
        defer c.asl_release(result);
        while (c.asl_next(result)) |message| {
            const time = c.asl_get(message, "Time") orelse @panic("boot record time");
            const sec = std.fmt.parseInt(i64, std.mem.span(time), 10) catch unreachable;
            const nsec = if (c.asl_get(message, "TimeNanoSec")) |n| std.fmt.parseInt(i64, std.mem.span(n), 10) catch unreachable else 0;
            if (sec < window.ready or (sec == window.ready and nsec <= window.ready_nsec)) return true;
        }
        if (last == 0 or last < start or last == std.math.maxInt(u64)) return false;
        start = last + 1;
    }
}
fn oldestRecord() ?Timestamp {
    const store = c.asl_open_path(storePath(), 0) orelse @panic("open ASL store for oldest record");
    defer c.asl_release(store);
    var last: usize = 0;
    // All store files, no Time predicate: one forward match from the start.
    const result = c.asl_match(store, null, &last, 0, 1, 0, 1);
    defer c.asl_release(result);
    const message = c.asl_next(result) orelse return null;
    const time = c.asl_get(message, "Time") orelse @panic("oldest record time");
    const nsec = if (c.asl_get(message, "TimeNanoSec")) |n| std.fmt.parseInt(i64, std.mem.span(n), 10) catch @panic("invalid oldest record nanoseconds") else 0;
    if (nsec < 0 or nsec >= 1000000000) @panic("invalid oldest record nanoseconds");
    return .{
        .sec = std.fmt.parseInt(i64, std.mem.span(time), 10) catch @panic("invalid oldest record time"),
        .nsec = nsec,
    };
}
pub fn readBoot(key: []const u8, value: []const u8, prefix: bool, window: BootWindow) BootRead {
    if (window.ready < window.started or window.ready_nsec < 0 or window.ready_nsec >= 1000000000) @panic("invalid boot readiness window");
    const files = bootFiles(window.started);
    defer asl_file_list_close(files);
    const retained = startupRetained(files, window);
    const q = since(window);
    defer c.asl_release(q);
    const key_z = z(key);
    defer a.free(key_z);
    const value_z = z(value);
    defer a.free(value_z);
    if (c.asl_set_query(q, key_z, value_z, @intCast(c.ASL_QUERY_OP_EQUAL | @as(c_int, if (prefix) c.ASL_QUERY_OP_PREFIX else 0))) != 0) @panic("boot query key");
    const list = c.asl_new(c.ASL_TYPE_LIST) orelse unreachable;
    defer c.asl_release(list);
    c.asl_append(list, q);
    var last: u64 = 0;
    const result = asl_file_list_match(files, list, &last, std.math.maxInt(u64), 0, 0, -1);
    defer c.asl_release(result);
    var strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (strings.items) |s| a.free(s);
        strings.deinit(a);
    }
    while (c.asl_next(result)) |message| {
        const raw = c.asl_format(message, "raw", "sec", 0) orelse @panic("format boot ASL");
        defer c.free(raw);
        strings.append(a, a.dupe(u8, std.mem.span(raw)) catch unreachable) catch unreachable;
    }
    var out: std.ArrayList(u8) = .empty;
    var i = strings.items.len;
    while (i > 0) {
        i -= 1;
        out.appendSlice(a, strings.items[i]) catch unreachable;
        out.append(a, '\n') catch unreachable;
    }
    return .{ .bytes = out.toOwnedSlice(a) catch unreachable, .retained = retained, .oldest = if (retained) null else oldestRecord(), .window = window };
}

extern fn asl_store_open_write([*:0]const u8, *?*anyopaque) u32;
extern fn asl_store_save(?*anyopaque, c.asl_object_t) u32;
extern fn asl_store_close(?*anyopaque) u32;
test "old boot records are excluded and current duplicates remain visible" {
    var path = "op942-scope-XXXXXX".* ++ [_]u8{0};
    try std.testing.expect(c.mkdtemp(@ptrCast(&path)) != null);
    defer std.Io.Dir.cwd().deleteTree(io, std.mem.sliceTo(&path, 0)) catch {};
    try std.testing.expectEqual(@as(c_int, 0), c.setenv("RMX_ASL_TEST_STORE", @ptrCast(&path), 1));
    defer _ = c.unsetenv("RMX_ASL_TEST_STORE");
    var writer: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), asl_store_open_write(@ptrCast(&path), &writer));
    const m = c.asl_new(c.ASL_TYPE_MSG);
    defer c.asl_release(m);
    try std.testing.expectEqual(@as(c_int, 0), c.asl_set(m, "Message", "banner"));
    try std.testing.expectEqual(@as(c_int, 0), c.asl_set(m, "Time", "1"));
    try std.testing.expectEqual(@as(u32, 0), asl_store_save(writer, m));
    try std.testing.expectEqual(@as(u32, 0), asl_store_close(writer));
    begin();
    const absent = query("Message", "banner", false, false);
    defer a.free(absent);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, absent, "[Message banner]"));
    try std.testing.expectEqual(@as(u32, 0), asl_store_open_write(@ptrCast(&path), &writer));
    try std.testing.expectEqual(@as(c_int, 0), c.asl_set(m, "Time", "2000000000"));
    for (0..2) |_| try std.testing.expectEqual(@as(u32, 0), asl_store_save(writer, m));
    try std.testing.expectEqual(@as(u32, 0), asl_store_close(writer));
    const boot_records = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000000 });
    defer a.free(boot_records.bytes);
    try std.testing.expect(boot_records.retained);
    var reason: [256]u8 = undefined;
    try std.testing.expect(try boot_records.startupCheck(&reason) == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, boot_records.bytes, "[Message banner]"));
    const tail = query("Message", "banner", false, false);
    defer a.free(tail);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, tail, "[Message banner]"));
}

const TestStore = struct {
    path: [:0]u8,
    old_tz: ?[:0]u8,
    fn init() !TestStore {
        var template = "op099-scope-XXXXXX".* ++ [_]u8{0};
        try std.testing.expect(c.mkdtemp(@ptrCast(&template)) != null);
        const path = try a.dupeZ(u8, std.mem.sliceTo(&template, 0));
        const old_tz = if (c.getenv("TZ")) |tz| try a.dupeZ(u8, std.mem.span(tz)) else null;
        try std.testing.expect(c.setenv("TZ", "UTC", 1) == 0);
        c.tzset();
        try std.testing.expect(c.setenv("RMX_ASL_TEST_STORE", path, 1) == 0);
        return .{ .path = path, .old_tz = old_tz };
    }
    fn deinit(self: TestStore) void {
        _ = c.unsetenv("RMX_ASL_TEST_STORE");
        if (self.old_tz) |tz| {
            _ = c.setenv("TZ", tz, 1);
            a.free(tz);
        } else _ = c.unsetenv("TZ");
        c.tzset();
        std.Io.Dir.cwd().deleteTree(io, self.path) catch unreachable;
        a.free(self.path);
    }
};
fn testSave(at: i64, message: [*:0]const u8, expiry: ?i64) !void {
    var writer: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), asl_store_open_write(storePath(), &writer));
    defer _ = asl_store_close(writer);
    const m = c.asl_new(c.ASL_TYPE_MSG);
    defer c.asl_release(m);
    var stamp: [32]u8 = undefined;
    const time = try std.fmt.bufPrintZ(&stamp, "{d}", .{at});
    try std.testing.expect(c.asl_set(m, "Time", time) == 0);
    try std.testing.expect(c.asl_set(m, "Message", message) == 0);
    var expires: [32]u8 = undefined;
    if (expiry) |until| {
        const value = try std.fmt.bufPrintZ(&expires, "{d}", .{until});
        try std.testing.expect(c.asl_set(m, "ASLExpireTime", value) == 0);
    }
    try std.testing.expectEqual(@as(u32, 0), asl_store_save(writer, m));
}
extern fn asl_file_open_write([*:0]const u8, c.mode_t, c.uid_t, c.gid_t, *?*anyopaque) u32;
extern fn asl_file_save(?*anyopaque, c.asl_object_t, *u64) u32;
test "boot date selection excludes old files and same-day earlier boots" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const started: i64 = 2000000000;
    try testSave(started - 86400, "banner", null);
    try testSave(started - 1, "banner", null);
    try testSave(started, "banner", null);
    // Even a boot-qualified timestamp in an older named file is excluded.
    const old = try std.fmt.allocPrintSentinel(a, "{s}/1999.12.31.asl", .{fixture.path}, 0);
    defer a.free(old);
    var file: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), asl_file_open_write(old, 0o600, c.getuid(), c.getgid(), &file));
    const m = c.asl_new(c.ASL_TYPE_MSG);
    defer c.asl_release(m);
    try std.testing.expect(c.asl_set(m, "Time", "2000000000") == 0);
    try std.testing.expect(c.asl_set(m, "Message", "banner") == 0);
    var id: u64 = 10000;
    try std.testing.expectEqual(@as(u32, 0), asl_file_save(file, m, &id));
    try std.testing.expectEqual(@as(u32, 0), asl_file_close(file));
    const history = readBoot("Message", "banner", false, .{ .started = started, .ready = started });
    defer a.free(history.bytes);
    try std.testing.expect(history.retained);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, history.bytes, "[Message banner]"));
}
test "missing boot-day files cannot justify skipping when older records remain" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    try testSave(1999913600, "banner", null);
    const history = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000001 });
    defer a.free(history.bytes);
    try std.testing.expectEqual(@as(usize, 0), history.bytes.len);
    try std.testing.expect(!history.retained);
    var reason: [256]u8 = undefined;
    try std.testing.expectError(error.StartupRecordsMissing, history.startupCheck(&reason));
}
test "a store beginning after readiness permits skipping with the observed times" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    try testSave(2000000100, "later", null);
    const history = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000001 });
    defer a.free(history.bytes);
    try std.testing.expect(history.bytes.len == 0 and !history.retained);
    var reason: [256]u8 = undefined;
    const removed = (try history.startupCheck(&reason)) orelse return error.MissingReason;
    try std.testing.expectEqualStrings("the store's oldest record (2000000100.000000000) is newer than the boot's first readiness (2000000001.999999999)", removed);
    // An absent banner remains a failure when any startup record survives.
    try testSave(2000000000, "other startup record", null);
    const retained = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000001 });
    defer a.free(retained.bytes);
    try std.testing.expect(retained.bytes.len == 0 and retained.retained);
    try std.testing.expect(try retained.startupCheck(&reason) == null);
}
test "pre-boot history plus post-readiness records fails rather than hiding startup loss" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const window: BootWindow = .{ .started = 2000000000, .ready = 2000000001 };
    // The pre-boot file is outside bootFiles' date selection. The fallback
    // must inspect the whole store to see that it still reaches back.
    try testSave(window.started - 86400, "older day", null);
    try testSave(window.ready + 1, "after readiness", null);
    const missing = readBoot("Message", "banner", false, window);
    defer a.free(missing.bytes);
    try std.testing.expect(missing.bytes.len == 0 and !missing.retained);
    try std.testing.expectEqual(window.started - 86400, missing.oldest.?.sec);
    var reason: [256]u8 = undefined;
    try std.testing.expectError(error.StartupRecordsMissing, missing.startupCheck(&reason));
    // Reaching back with a startup-window record keeps the normal assertions.
    try testSave(window.started, "banner", null);
    const present = readBoot("Message", "banner", false, window);
    defer a.free(present.bytes);
    try std.testing.expect(try present.startupCheck(&reason) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, present.bytes, "[Message banner]"));
}
test "an empty store cannot prove removal and never skips" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const history = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000001 });
    defer a.free(history.bytes);
    var reason: [256]u8 = undefined;
    try std.testing.expectError(error.EmptyStore, history.startupCheck(&reason));
}
test "split files next day and BB records preserve global message ID order" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    try testSave(2000000000, "ordered first", null);
    const dates = dayPrefixes(2000000000);
    const split = try std.fmt.allocPrintSentinel(a, "{s}/{s}.123.asl", .{ fixture.path, dates[0][0..10] }, 0);
    defer a.free(split);
    // The store may suffix uid/gid fields, so find the actual date file.
    const dir = c.opendir(fixture.path) orelse return error.Directory;
    var renamed = false;
    while (c.readdir(dir)) |entry| {
        const name = entry.*.d_name[0..entry.*.d_namlen];
        if (!std.mem.startsWith(u8, name, dates[0][0..10])) continue;
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ fixture.path, name }, 0);
        defer a.free(path);
        try std.testing.expect(c.rename(path, split) == 0);
        renamed = true;
        break;
    }
    _ = c.closedir(dir);
    try std.testing.expect(renamed);
    try testSave(2000086400, "ordered second", null);
    try testSave(2000000001, "ordered third", 2100000000);
    const history = readBoot("Message", "ordered", true, .{ .started = 2000000000, .ready = 2000000002 });
    defer a.free(history.bytes);
    try std.testing.expect(history.retained);
    const first = std.mem.indexOf(u8, history.bytes, "ordered first") orelse return error.First;
    const second = std.mem.indexOf(u8, history.bytes, "ordered second") orelse return error.Second;
    const third = std.mem.indexOf(u8, history.bytes, "ordered third") orelse return error.Third;
    try std.testing.expect(first < second and second < third);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, history.bytes, "[Message ordered"));
}
test "all long-expiry buckets retain startup records without a day file" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    try testSave(2000000000, "BB first", 2100000000);
    try testSave(2000000001, "BB second", 2200000000);
    const dir = c.opendir(fixture.path) orelse return error.Directory;
    var buckets: usize = 0;
    const dates = dayPrefixes(2000000000);
    while (c.readdir(dir)) |entry| {
        const name = entry.*.d_name[0..entry.*.d_namlen];
        if (std.mem.startsWith(u8, name, "BB.")) buckets += 1;
        try std.testing.expect(!std.mem.startsWith(u8, name, dates[0][0..10]));
    }
    _ = c.closedir(dir);
    try std.testing.expectEqual(@as(usize, 2), buckets);
    const history = readBoot("Message", "BB", true, .{ .started = 2000000000, .ready = 2000000001 });
    defer a.free(history.bytes);
    try std.testing.expect(history.retained);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, history.bytes, "[Message BB"));
}
test "calendar selection handles DST and year boundaries" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    try std.testing.expect(c.setenv("TZ", "America/New_York", 1) == 0);
    c.tzset();
    var local = std.mem.zeroes(c.struct_tm);
    local.tm_year = 2026 - 1900;
    local.tm_mon = 10;
    local.tm_mday = 1;
    local.tm_hour = 0;
    local.tm_min = 30;
    local.tm_isdst = -1;
    const dates = dayPrefixes(c.mktime(&local));
    try std.testing.expectEqualStrings("2026.11.01", dates[0][0..10]);
    try std.testing.expectEqualStrings("2026.11.02", dates[1][0..10]);
    local.tm_mon = 11;
    local.tm_mday = 31;
    local.tm_isdst = -1;
    const year = dayPrefixes(c.mktime(&local));
    try std.testing.expectEqualStrings("2026.12.31", year[0][0..10]);
    try std.testing.expectEqualStrings("2027.01.01", year[1][0..10]);
}
