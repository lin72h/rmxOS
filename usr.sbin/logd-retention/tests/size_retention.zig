const std = @import("std");
const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("errno.h");
    @cInclude("dirent.h");
    @cInclude("atf-c.h");
    @cInclude("asl.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn asl_file_open_write([*:0]const u8, c.mode_t, c.uid_t, c.gid_t, *?*anyopaque) u32;
extern fn asl_file_close(?*anyopaque) u32;
extern fn asl_store_open_write([*:0]const u8, *?*anyopaque) u32;
extern fn asl_store_close(?*anyopaque) u32;
const shape = [_]struct { day: usize, suffix: []const u8, size: u64 }{
    .{ .day = 0, .suffix = ".U0.G80.asl", .size = 5112967 },
    .{ .day = 0, .suffix = ".U501.asl", .size = 2446 },
    .{ .day = 0, .suffix = ".asl", .size = 104060 },
    .{ .day = 1, .suffix = ".G80.1792926000.asl", .size = 25600115 },
    .{ .day = 1, .suffix = ".G80.1792931058.asl", .size = 25600017 },
    .{ .day = 1, .suffix = ".G80.1792931217.asl", .size = 25600142 },
    .{ .day = 1, .suffix = ".G80.1792931376.asl", .size = 25600047 },
    .{ .day = 1, .suffix = ".G80.1792931535.asl", .size = 25600084 },
    .{ .day = 1, .suffix = ".G80.1792931694.asl", .size = 25600041 },
    .{ .day = 1, .suffix = ".G80.1792931853.asl", .size = 25600019 },
    .{ .day = 1, .suffix = ".G80.asl", .size = 16594700 },
    .{ .day = 1, .suffix = ".asl", .size = 6428 },
    .{ .day = 2, .suffix = ".G80.asl", .size = 3400 },
};
const Dates = struct {
    names: [3][11]u8,
    fn at(stamp: c.time_t) !Dates {
        var local: c.struct_tm = undefined;
        if (c.localtime_r(&stamp, &local) == null) return error.LocalDate;
        var dates: Dates = undefined;
        for (0..3) |i| {
            var day = local;
            day.tm_hour = 12;
            day.tm_min = 0;
            day.tm_sec = 0;
            day.tm_isdst = -1;
            if (i == 0) day.tm_mday -= 1;
            if (i == 2) day.tm_year += 1;
            var normalized = c.mktime(&day);
            if (normalized == -1 or c.localtime_r(&normalized, &day) == null) return error.CalendarDate;
            if (c.strftime(&dates.names[i], 11, "%Y.%m.%d", &day) != 10) return error.FormatDate;
        }
        return dates;
    }
};
const Fixture = struct {
    path: [64:0]u8,
    names: [13][128:0]u8,
    bare_inode: u64 = 0,
    bare_fd: c_int = -1,
    fn init(dates: Dates) !Fixture {
        var fixture: Fixture = .{ .path = @splat(0), .names = @splat(@splat(0)) };
        const template = "/tmp/logd_retention-size-XXXXXX";
        @memcpy(fixture.path[0..template.len], template);
        if (c.mkdtemp(&fixture.path) == null) return error.TemporaryDirectory;
        errdefer fixture.deinit();
        var store: ?*anyopaque = null;
        if (asl_store_open_write(&fixture.path, &store) != 0) return error.StoreData;
        if (asl_store_close(store) != 0) return error.StoreClose;
        var total: u64 = 0;
        // Creation and modification times deliberately oppose name order.
        var index: usize = shape.len;
        while (index != 0) {
            index -= 1;
            const entry = shape[index];
            const name = try std.fmt.bufPrintZ(&fixture.names[index], "{s}{s}{s}", .{
                if (entry.day == 2) "BB." else "", dates.names[entry.day][0..10], entry.suffix,
            });
            var path: [256]u8 = undefined;
            const full = try std.fmt.bufPrintZ(&path, "{s}/{s}", .{ std.mem.span(@as([*:0]const u8, &fixture.path)), name });
            var file: ?*anyopaque = null;
            if (asl_file_open_write(full, 0o600, c.getuid(), c.getgid(), &file) != 0) return error.ASLHeader;
            if (asl_file_close(file) != 0) return error.ASLClose;
            const fd = c.open(full, c.O_RDWR);
            if (fd < 0) return error.FileOpen;
            defer _ = c.close(fd);
            if (c.ftruncate(fd, @intCast(entry.size)) != 0) return error.SparseSize;
            if (index == 11) {
                var st: c.struct_stat = undefined;
                if (c.fstat(fd, &st) != 0) return error.BareIdentity;
                fixture.bare_inode = st.st_ino;
                // Keeping the old inode open prevents immediate inode reuse
                // from concealing deletion followed by summary recreation.
                fixture.bare_fd = c.open(full, c.O_RDONLY | c.O_CLOEXEC);
                if (fixture.bare_fd < 0) return error.BareOpen;
            }
            const times = [_]c.struct_timespec{ .{ .tv_sec = @intCast(shape.len - index), .tv_nsec = 0 }, .{ .tv_sec = @intCast(shape.len - index), .tv_nsec = 0 } };
            if (c.futimens(fd, &times) != 0) return error.ModificationTime;
            total += entry.size;
        }
        if (total != 201024466) return error.FixtureTotal;
        return fixture;
    }
    fn deinit(self: *const Fixture) void {
        if (self.bare_fd >= 0) _ = c.close(self.bare_fd);
        var path: [256]u8 = undefined;
        // Also remove a summary day file created across an unshimmed midnight.
        if (c.opendir(&self.path)) |dir| {
            while (c.readdir(dir)) |entry| {
                const name = entry.*.d_name[0..entry.*.d_namlen];
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                const full = std.fmt.bufPrintZ(&path, "{s}/{s}", .{ std.mem.span(@as([*:0]const u8, &self.path)), name }) catch unreachable;
                _ = c.unlink(full);
            }
            _ = c.closedir(dir);
        }
        _ = c.rmdir(&self.path);
    }
};
fn manager(path: [*:0]const u8, limit: [*:0]const u8) !void {
    const program: [*:0]const u8 = if (c.getenv("RMX_LOGD_RETENTION")) |p| @ptrCast(p) else "/usr/libexec/logd-retention";
    var pipe: [2]c_int = undefined;
    if (c.pipe(&pipe) != 0) return error.Pipe;
    const pid = c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = c.close(pipe[0]);
        _ = c.dup2(pipe[1], 1);
        _ = c.dup2(pipe[1], 2);
        _ = c.close(pipe[1]);
        _ = c.alarm(15);
        const argv = [_]?[*:0]const u8{ program, "-s", path, "-once", "-size", limit, "-ttl", "0", "-logdb", "-d", null };
        _ = c.execv(program, @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.close(pipe[1]);
    var out: [4096]u8 = undefined;
    while (true) {
        const n = c.read(pipe[0], &out, out.len);
        if (n < 0) return error.Read;
        if (n == 0) break;
        _ = c.printf("%.*s", @as(c_int, @intCast(n)), &out);
    }
    _ = c.close(pipe[0]);
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid or status != 0) return error.ManagerStatus;
}
fn summaryCount(path: [*:0]const u8, files: u64, bytes: u64) !void {
    const store = c.asl_open_path(path, 0) orelse return error.OpenSummary;
    defer c.asl_release(store);
    const q = c.asl_new(c.ASL_TYPE_QUERY);
    defer c.asl_release(q);
    const queries = c.asl_new(c.ASL_TYPE_LIST);
    defer c.asl_release(queries);
    if (c.asl_set_query(q, "org.rmxos.logd.retention.record", "summary", c.ASL_QUERY_OP_EQUAL) != 0) return error.Query;
    c.asl_append(queries, q);
    var last: usize = 0;
    const result = c.asl_match(store, queries, &last, std.math.maxInt(usize), 2, 0, -1);
    defer c.asl_release(result);
    const message = c.asl_next(result) orelse return error.MissingSummary;
    for ([_][*:0]const u8{ "space_files", "space_bytes", "expired_files", "expired_bytes", "failures" }, [_]u64{ files, bytes, 0, 0, 0 }) |key, expected| {
        const value = c.asl_get(message, key) orelse return error.SummaryField;
        const observed = try std.fmt.parseInt(u64, std.mem.span(value), 10);
        _ = c.printf("retention_summary %s expected=%ju observed=%ju\n", key, expected, observed);
        if (observed != expected) return error.SummaryCount;
    }
    if (c.asl_next(result) != null) return error.DuplicateSummary;
}
fn check(exact: bool) !void {
    // An unshimmed runtime may cross midnight. Discard only that run's
    // calendar-dependent fixture and try the new local day, never its verdict.
    for (0..3) |_| {
        const dates = try Dates.at(c.time(null));
        const fixture = try Fixture.init(dates);
        defer fixture.deinit();
        _ = c.printf("retention_dates yesterday=%s today=%s BB_year_ahead=%s limit=%s\n", &dates.names[0], &dates.names[1], &dates.names[2], @as([*:0]const u8, if (exact) "9000" else "150000000"));
        try manager(&fixture.path, if (exact) "9000" else "150000000");
        const after = try Dates.at(c.time(null));
        if (!std.mem.eql(u8, dates.names[1][0..10], after.names[1][0..10])) continue;
        var removed_bytes: u64 = 0;
        var removed_files: u64 = 0;
        for (shape, 0..) |entry, i| {
            var path: [256]u8 = undefined;
            const full = try std.fmt.bufPrintZ(&path, "{s}/{s}", .{ std.mem.span(@as([*:0]const u8, &fixture.path)), std.mem.span(@as([*:0]const u8, &fixture.names[i])) });
            var st: c.struct_stat = undefined;
            const rc = c.stat(full, &st);
            const stat_errno = c.__error().*;
            const keep = if (exact) i == 11 else i >= 5;
            _ = c.printf("retention_file %s expected=%s observed=%s\n", &fixture.names[i], @as([*:0]const u8, if (keep) "present" else "absent"), @as([*:0]const u8, if (rc == 0) "present" else "absent"));
            if (keep) {
                if (rc != 0) return error.UnexpectedRemoval;
                if (i == 11) {
                    if (st.st_size < entry.size or st.st_ino != fixture.bare_inode) return error.BareIdentity;
                } else if (st.st_size != entry.size) return error.SurvivorSize;
            } else {
                if (rc == 0 or stat_errno != c.ENOENT) return error.UnexpectedSurvivor;
                removed_files += 1;
                removed_bytes += entry.size;
            }
        }
        if (removed_files != (if (exact) @as(u64, 12) else 5) or removed_bytes != (if (exact) @as(u64, 201018038) else 56419605)) return error.RemovalTotal;
        if (201024466 - removed_bytes != (if (exact) @as(u64, 6428) else 144604861)) return error.RemainingTotal;
        try summaryCount(&fixture.path, removed_files, removed_bytes);
        var path: [256]u8 = undefined;
        const metadata = try std.fmt.bufPrintZ(&path, "{s}/StoreData", .{std.mem.span(@as([*:0]const u8, &fixture.path))});
        if (c.access(metadata, c.F_OK) != 0) return error.RemovedStoreData;
        return;
    }
    return error.CalendarChangedRepeatedly;
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "60");
}
fn body(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    check(std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), "exact_name_guard")) catch |err| c.atf_tc_fail("size retention: %s", @errorName(err).ptr);
}
var cases: [2]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (&cases, [_][*:0]const u8{ "adx01_sweep", "exact_name_guard" }) |*tc, name| {
        var err = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--clock-points")) {
        var stamp = c.time(null);
        var day: c.struct_tm = undefined;
        if (c.localtime_r(&stamp, &day) == null) return 1;
        day.tm_mday += 1;
        day.tm_hour = 0;
        day.tm_min = 0;
        day.tm_sec = 0;
        day.tm_isdst = -1;
        stamp = c.mktime(&day);
        if (stamp == -1) return 1;
        _ = c.printf("%jd\n%jd\n", stamp - 1, stamp);
        return 0;
    }
    return atf_tp_main(argc, argv, add);
}
