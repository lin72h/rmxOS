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
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
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
    if (boot) {
        const history = readBoot(key, value, prefix, bootWindow());
        a.free(history.files);
        return history.bytes;
    }
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
    files: []const u8,
    oldest: ?Timestamp,

    pub fn deinit(self: BootRead) void {
        a.free(self.bytes);
        a.free(self.files);
    }
    pub fn requireRecords(self: BootRead, records: []const []const u8) error{StartupRecordsMissing}!void {
        for (records) |record| {
            if (std.mem.indexOf(u8, self.bytes, record) == null) return error.StartupRecordsMissing;
        }
    }
    pub fn failure(self: BootRead) [:0]const u8 {
        if (self.oldest) |oldest| return std.fmt.allocPrintSentinel(a, "startup records missing; files read: [{s}]; store's oldest record: {d}.{d:0>9}", .{ self.files, oldest.sec, @as(u32, @intCast(oldest.nsec)) }, 0) catch unreachable;
        return std.fmt.allocPrintSentinel(a, "startup records missing; files read: [{s}]; store's oldest record: none (empty store)", .{self.files}, 0) catch unreachable;
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
extern fn asl_file_close(?*anyopaque) u32;
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
extern fn asl_file_fetch(?*anyopaque, u64, *c.asl_object_t) u32;
fn timestamp(message: c.asl_object_t) Timestamp {
    const sec = c.asl_get(message, "Time") orelse @panic("record time");
    const nsec = if (c.asl_get(message, "TimeNanoSec")) |n| std.fmt.parseInt(i64, std.mem.span(n), 10) catch unreachable else 0;
    if (nsec < 0 or nsec >= 1000000000) @panic("record nanoseconds");
    return .{ .sec = std.fmt.parseInt(i64, std.mem.span(sec), 10) catch unreachable, .nsec = nsec };
}
fn oldestRecord() ?Timestamp {
    const store = c.asl_open_path(storePath(), 0) orelse @panic("open oldest-record reader");
    defer c.asl_release(store);
    var last: usize = 0;
    const result = c.asl_match(store, null, &last, 0, 1, 0, 1);
    defer c.asl_release(result);
    return if (c.asl_next(result)) |m| timestamp(m) else null;
}
const BootRecord = struct { id: u64, raw: []const u8 };
fn byID(_: void, x: BootRecord, y: BootRecord) bool {
    return x.id < y.id;
}
fn inWindow(time: Timestamp, window: BootWindow) bool {
    return time.sec >= window.started and (time.sec < window.ready or
        (time.sec == window.ready and time.nsec <= window.ready_nsec));
}
// ASL v2's fixed record header is documented in lib/libasl/asl_file.h.
// Scan every linked MSG header, including records appended after later times.
// Decode only window records through libasl; storm records need no ASL objects.
fn scanFile(path: [:0]const u8, file: ?*anyopaque, key: [:0]const u8, value: []const u8, prefix: bool, window: BootWindow, records: *std.ArrayList(BootRecord)) void {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) @panic("open boot header reader");
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_size < 80) @panic("ASL header size");
    const size: usize = @intCast(st.st_size);
    const mapping = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (mapping == c.MAP_FAILED) @panic("map boot ASL headers");
    defer _ = c.munmap(mapping, size);
    const data: []const u8 = @as([*]const u8, @ptrCast(mapping))[0..size];
    scanHeaders(data, file, key, value, prefix, window, records) catch @panic("malformed boot ASL headers");
}
fn scanHeaders(data: []const u8, file: ?*anyopaque, key: [:0]const u8, value: []const u8, prefix: bool, window: BootWindow, records: *std.ArrayList(BootRecord)) error{Malformed}!void {
    if (data.len < 80 or !std.mem.eql(u8, data[0..6], "ASL DB") or
        std.mem.readInt(u32, data[12..16], .big) != 2) return error.Malformed;
    var offset = std.mem.readInt(u64, data[16..24], .big);
    while (offset != 0) {
        if (offset < 80 or offset > data.len or data.len - @as(usize, @intCast(offset)) < 122) return error.Malformed;
        const pos: usize = @intCast(offset);
        const head = data[pos..][0..122];
        const len = std.mem.readInt(u32, head[2..6], .big);
        if (std.mem.readInt(u16, head[0..2], .big) != 0 or len < 116 or len > data.len - pos - 6) return error.Malformed;
        const next = std.mem.readInt(u64, head[6..14], .big);
        if (next != 0 and next <= offset) return error.Malformed;
        const seconds = std.mem.readInt(u64, head[22..30], .big);
        const nano = std.mem.readInt(u32, head[30..34], .big);
        if (seconds > std.math.maxInt(i64) or nano >= 1000000000) return error.Malformed;
        const time: Timestamp = .{ .sec = @intCast(seconds), .nsec = nano };
        if (inWindow(time, window)) {
            const id = std.mem.readInt(u64, head[14..22], .big);
            var message: c.asl_object_t = null;
            if (asl_file_fetch(file, id, &message) != 0 or message == null) @panic("decode boot record");
            defer c.asl_release(message);
            if (c.asl_get(message, key)) |field| {
                const bytes = std.mem.span(field);
                if (if (prefix) std.mem.startsWith(u8, bytes, value) else std.mem.eql(u8, bytes, value)) {
                    const raw = c.asl_format(message, "raw", "sec", 0) orelse @panic("format boot ASL");
                    defer c.free(raw);
                    records.append(a, .{ .id = id, .raw = a.dupe(u8, std.mem.span(raw)) catch unreachable }) catch unreachable;
                }
            }
        }
        offset = next;
    }
}
pub fn readBoot(key: []const u8, value: []const u8, prefix: bool, window: BootWindow) BootRead {
    if (window.ready < window.started or window.ready_nsec < 0 or window.ready_nsec >= 1000000000) @panic("invalid boot readiness window");
    const dates = dayPrefixes(window.started);
    const dir = c.opendir(storePath()) orelse @panic("open boot ASL directory");
    defer _ = c.closedir(dir);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    var records: std.ArrayList(BootRecord) = .empty;
    defer {
        for (records.items) |record| a.free(record.raw);
        records.deinit(a);
    }
    const key_z = z(key);
    defer a.free(key_z);
    while (true) {
        c.__error().* = 0;
        const entry = c.readdir(dir) orelse {
            if (c.__error().* != 0) @panic("read boot ASL directory");
            break;
        };
        const name = entry.*.d_name[0..entry.*.d_namlen];
        if (!std.mem.startsWith(u8, name, dates[0][0..10]) and
            !std.mem.startsWith(u8, name, dates[1][0..10]) and !std.mem.startsWith(u8, name, "BB.")) continue;
        const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.mem.span(storePath()), name }, 0) catch unreachable;
        defer a.free(path);
        var file: ?*anyopaque = null;
        // Ignore non-ASL directory entries, as Apple's file reader does.
        if (asl_file_open_read(path, &file) != 0) continue;
        defer _ = asl_file_close(file);
        names.append(a, a.dupe(u8, name) catch unreachable) catch unreachable;
        scanFile(path, file, key_z, value, prefix, window, &records);
    }
    std.mem.sort(BootRecord, records.items, {}, byID);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (records.items) |record| {
        out.appendSlice(a, record.raw) catch unreachable;
        out.append(a, '\n') catch unreachable;
    }
    return .{ .bytes = out.toOwnedSlice(a) catch unreachable, .files = std.mem.join(a, ", ", names.items) catch unreachable, .oldest = oldestRecord() };
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
    defer boot_records.deinit();
    try boot_records.requireRecords(&.{"[Message banner]"});
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
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, history.bytes, "[Message banner]"));
}
test "an unrelated later U501 class cannot excuse missing startup records" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const window: BootWindow = .{ .started = 2000000000, .ready = 2000000001 };
    for ([_][]const u8{ "", ".G80", ".U0.G80" }, 0..) |class, i| {
        try testClassRecord(class, window.started - 1, "before boot", i + 1);
    }
    try testClassRecord(".U501", window.ready + 1, "first user record", 4);
    const history = readBoot("Message", "banner", false, window);
    defer history.deinit();
    try std.testing.expectError(error.StartupRecordsMissing, history.requireRecords(&.{"banner"}));
    const why = history.failure();
    defer a.free(why);
    try std.testing.expect(std.mem.indexOf(u8, why, ".U501.asl") != null);
    try std.testing.expect(std.mem.indexOf(u8, why, "store's oldest record: 1999999999.000000000") != null);
}
test "a store beginning after readiness fails with files and oldest record" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    try testSave(2000000100, "later", null);
    const history = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000001 });
    defer history.deinit();
    try std.testing.expectError(error.StartupRecordsMissing, history.requireRecords(&.{"banner"}));
    const why = history.failure();
    defer a.free(why);
    try std.testing.expect(std.mem.indexOf(u8, why, "files read: [2033.05.18") != null);
    try std.testing.expect(std.mem.indexOf(u8, why, "store's oldest record: 2000000100.000000000") != null);
}
test "empty fresh-boot history fails with an empty-store diagnostic" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const history = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000001 });
    defer history.deinit();
    try std.testing.expectError(error.StartupRecordsMissing, history.requireRecords(&.{"banner"}));
    const why = history.failure();
    defer a.free(why);
    try std.testing.expectEqualStrings("startup records missing; files read: []; store's oldest record: none (empty store)", why);
}
test "oldest diagnostic includes BB records outside the selected boot dates" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    try testSave(1999913600, "old BB", 2200000000);
    try testSave(2000000100, "later", null);
    const history = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000001 });
    defer history.deinit();
    try std.testing.expectEqual(@as(i64, 1999913600), history.oldest.?.sec);
    try std.testing.expectError(error.StartupRecordsMissing, history.requireRecords(&.{"banner"}));
}
test "window records after forty later-stamped records are found in ID order" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    try testSave(2000000000, "banner first", null);
    for (0..40) |_| try testSave(2000000100, "later", null);
    try testSave(2000000001, "banner second", null);
    try testSave(2000000000, "banner first", null);
    const history = readBoot("Message", "banner", true, .{ .started = 2000000000, .ready = 2000000001 });
    defer history.deinit();
    try history.requireRecords(&.{ "banner first", "banner second" });
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, history.bytes, "[Message banner"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, history.bytes, "[Message banner first]"));
    try std.testing.expect(std.mem.indexOf(u8, history.bytes, "banner first").? < std.mem.indexOf(u8, history.bytes, "banner second").?);
}
test "header scan rejects corrupt links timestamps and truncated records" {
    var data: [202]u8 = @splat(0);
    @memcpy(data[0..6], "ASL DB");
    std.mem.writeInt(u32, data[12..16], 2, .big);
    std.mem.writeInt(u64, data[16..24], 80, .big);
    std.mem.writeInt(u32, data[82..86], 116, .big);
    var records: std.ArrayList(BootRecord) = .empty;
    defer records.deinit(a);
    const window: BootWindow = .{ .started = 100, .ready = 101 };
    // A valid excluded record needs no decoder or ASL object.
    try scanHeaders(&data, null, "Message", "banner", false, window, &records);
    std.mem.writeInt(u64, data[86..94], 80, .big);
    try std.testing.expectError(error.Malformed, scanHeaders(&data, null, "Message", "banner", false, window, &records));
    std.mem.writeInt(u64, data[86..94], 1000, .big);
    try std.testing.expectError(error.Malformed, scanHeaders(&data, null, "Message", "banner", false, window, &records));
    std.mem.writeInt(u64, data[86..94], 0, .big);
    std.mem.writeInt(u32, data[110..114], 1000000000, .big);
    try std.testing.expectError(error.Malformed, scanHeaders(&data, null, "Message", "banner", false, window, &records));
    std.mem.writeInt(u32, data[110..114], 0, .big);
    try std.testing.expectError(error.Malformed, scanHeaders(data[0..201], null, "Message", "banner", false, window, &records));
}
test "readiness nanoseconds bound records within the same second" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const path = try std.fmt.allocPrintSentinel(a, "{s}/2033.05.18.asl", .{fixture.path}, 0);
    defer a.free(path);
    var file: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), asl_file_open_write(path, 0o600, c.getuid(), c.getgid(), &file));
    const message = c.asl_new(c.ASL_TYPE_MSG);
    defer c.asl_release(message);
    try std.testing.expect(c.asl_set(message, "Time", "2000000000") == 0);
    try std.testing.expect(c.asl_set(message, "Message", "banner") == 0);
    for ([_][*:0]const u8{ "101", "100", "99" }, 1..) |nano, number| {
        try std.testing.expect(c.asl_set(message, "TimeNanoSec", nano) == 0);
        var id: u64 = number;
        try std.testing.expectEqual(@as(u32, 0), asl_file_save(file, message, &id));
    }
    try std.testing.expectEqual(@as(u32, 0), asl_file_close(file));
    const history = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000000, .ready_nsec = 100 });
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, history.bytes, "[Message banner]"));
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
    const history = readBoot("Message", "ordered", true, .{ .started = 2000000000, .ready = 2000086401 });
    defer history.deinit();
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
    defer history.deinit();
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

// Reusable real-shape fixture for host timing; callers may provide its directory.
fn stormFixture(path: [:0]const u8) !void {
    const done = try std.fmt.allocPrintSentinel(a, "{s}/fixture.complete", .{path}, 0);
    defer a.free(done);
    if (c.access(done, 0) == 0) return;
    var id: u64 = 1;
    const started: i64 = 2000000000;
    const dates = dayPrefixes(started);
    const m = c.asl_new(c.ASL_TYPE_MSG);
    defer c.asl_release(m);
    for ([_][]const u8{ "", ".G80", ".U0.G80", ".U501" }, 0..) |class, class_index| {
        // Each class has a pre-boot file, an initial boot file, and a size split.
        for (0..3) |part| {
            const suffix = if (part == 2) ".2000000100" else if (part == 0) ".1999999900" else "";
            const name = try std.fmt.allocPrintSentinel(a, "{s}/{s}{s}{s}.asl", .{ path, dates[0][0..10], class, suffix }, 0);
            defer a.free(name);
            var file: ?*anyopaque = null;
            try std.testing.expectEqual(@as(u32, 0), asl_file_open_write(name, 0o600, c.getuid(), c.getgid(), &file));
            id = if (part == 0) class_index + 1 else if (part == 1) class_index + 5 else 9 + class_index * 300000;
            const count: usize = if (part == 2) 300000 else 1;
            for (0..count) |_| {
                const time = if (part == 0) "1999999900" else if (part == 1) "2000000000" else "2000000100";
                try std.testing.expect(c.asl_set(m, "Time", time) == 0);
                try std.testing.expect(c.asl_set(m, "Message", if (part == 1) "banner" else "storm-padding-0123456789-0123456789-0123456789") == 0);
                try std.testing.expectEqual(@as(u32, 0), asl_file_save(file, m, &id));
                id += 1;
            }
            try std.testing.expectEqual(@as(u32, 0), asl_file_close(file));
        }
    }
    const fp = c.fopen(done, "w") orelse return error.Fixture;
    try std.testing.expect(c.fclose(fp) == 0);
}
test "real-shape same-day 1.2M-record store reads only startup records" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const path = if (c.getenv("RMX_SCOPE_STORM_STORE")) |p| try a.dupeZ(u8, std.mem.span(p)) else try a.dupeZ(u8, fixture.path);
    defer a.free(path);
    try std.testing.expect(c.setenv("RMX_ASL_TEST_STORE", path, 1) == 0);
    try stormFixture(path);
    var before: c.struct_timespec = undefined;
    var after: c.struct_timespec = undefined;
    try std.testing.expect(c.clock_gettime(c.CLOCK_MONOTONIC, &before) == 0);
    const history = readBoot("Message", "banner", false, .{ .started = 2000000000, .ready = 2000000001 });
    try std.testing.expect(c.clock_gettime(c.CLOCK_MONOTONIC, &after) == 0);
    defer history.deinit();
    const ns = (after.tv_sec - before.tv_sec) * std.time.ns_per_s + after.tv_nsec - before.tv_nsec;
    std.debug.print("storm_read records=1200000 classes=plain,G80,U0.G80,U501 elapsed_ms={d}\n", .{@divTrunc(ns, std.time.ns_per_ms)});
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, history.bytes, "[Message banner]"));
    if (c.getenv("RMX_SCOPE_BASELINE") == null) try std.testing.expect(ns < 2 * std.time.ns_per_s);
}

fn testClassRecord(suffix: []const u8, at: i64, message: [*:0]const u8, number: u64) !void {
    const dates = dayPrefixes(2000000000);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}{s}.asl", .{ std.mem.span(storePath()), dates[0][0..10], suffix }, 0);
    defer a.free(path);
    var file: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), asl_file_open_write(path, 0o600, c.getuid(), c.getgid(), &file));
    defer _ = asl_file_close(file);
    const m = c.asl_new(c.ASL_TYPE_MSG);
    defer c.asl_release(m);
    var buf: [32]u8 = undefined;
    const stamp = try std.fmt.bufPrintZ(&buf, "{d}", .{at});
    try std.testing.expect(c.asl_set(m, "Time", stamp) == 0);
    try std.testing.expect(c.asl_set(m, "Message", message) == 0);
    var id = number;
    try std.testing.expectEqual(@as(u32, 0), asl_file_save(file, m, &id));
}
test "a truncated class cannot excuse missing fresh-boot records" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const window: BootWindow = .{ .started = 2000000000, .ready = 2000000001 };
    try testClassRecord("", window.started - 100, "before boot", 1);
    try testClassRecord(".U501", window.started, "other startup", 2);
    try testClassRecord(".U0.G80", window.started, "other startup", 3);
    try testClassRecord(".G80.2000001200", window.started + 1200, "surviving split", 4);
    try testSave(window.started, "BB startup", 2200000000);
    const history = readBoot("Message", "launchd banner", false, window);
    defer history.deinit();
    try std.testing.expect(history.bytes.len == 0);
    try std.testing.expectError(error.StartupRecordsMissing, history.requireRecords(&.{"launchd banner"}));
}
test "missing expected startup records fail when every access class reaches back" {
    const fixture = try TestStore.init();
    defer fixture.deinit();
    const window: BootWindow = .{ .started = 2000000000, .ready = 2000000001 };
    for ([_][]const u8{ "", ".G80", ".U0.G80", ".U501" }, 0..) |class, i| {
        try testClassRecord(class, window.started - 1, "before boot", i + 1);
    }
    try testClassRecord(".G80.2000000000", window.started, "other startup", 5);
    const history = readBoot("Message", "launchd banner", false, window);
    defer history.deinit();
    try std.testing.expect(history.bytes.len == 0);
    try std.testing.expectError(error.StartupRecordsMissing, history.requireRecords(&.{"launchd banner"}));
}
