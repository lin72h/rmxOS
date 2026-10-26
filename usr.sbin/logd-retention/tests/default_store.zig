const std = @import("std");
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});
extern fn rmx_default_run(?[*:0]const u8, c_int, [*]const ?[*:0]const u8) c_int;
extern fn rmx_default_path() [*:0]const u8;
extern fn rmx_default_ttl() u32;
extern fn rmx_default_rules() u32;
extern fn rmx_default_calls() u32;
extern fn rmx_default_size() usize;

fn check(config: ?[:0]const u8, options: []const ?[*:0]const u8, path: []const u8, ttl: u32, size: usize, rules: u32) !void {
    var directory = "op904-config-XXXXXX".* ++ [_]u8{0};
    try std.testing.expect(c.mkdtemp(@ptrCast(&directory)) != null);
    defer std.Io.Dir.cwd().deleteTree(io, std.mem.sliceTo(&directory, 0)) catch {};
    var buffer: [256]u8 = undefined;
    const filename = try std.fmt.bufPrintZ(&buffer, "{s}/logd.conf", .{std.mem.sliceTo(&directory, 0)});
    if (config) |text| {
        const file = c.fopen(filename.ptr, "w") orelse return error.ConfigOpen;
        try std.testing.expect(c.fputs(text.ptr, file) >= 0);
        try std.testing.expectEqual(@as(c_int, 0), c.fclose(file));
    }
    var args: [20]?[*:0]const u8 = @splat(null);
    args[0] = "logd-retention";
    args[1] = "-logdb";
    args[2] = "-dd";
    @memcpy(args[3..][0..options.len], options);
    const rc = rmx_default_run(if (config != null) filename.ptr else null, @intCast(3 + options.len), &args);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expectEqual(@as(u32, 1), rmx_default_calls());
    try std.testing.expectEqualStrings(path, std.mem.span(rmx_default_path()));
    try std.testing.expectEqual(ttl, rmx_default_ttl());
    try std.testing.expectEqual(size, rmx_default_size());
    try std.testing.expectEqual(rules, rmx_default_rules());
    std.debug.print("dryrun path={s} ttl={d} size={d} store_rules={d} rc={d}\n", .{ std.mem.span(rmx_default_path()), rmx_default_ttl(), rmx_default_size(), rmx_default_rules(), rc });
}

test "no store rule and no -s uses the default store" {
    try check("# No store output rule.\n", &.{}, "/var/db/logd", 7, 150000000, 0);
}
test "parameters apply to the fallback before command options" {
    try check("= store_ttl 13\n= max_store_size 7654321\n", &.{}, "/var/db/logd", 13, 7654321, 0);
}
test "command options apply to the fallback" {
    try check("# No store output rule.\n", &.{ "-store_ttl", "17", "-size", "123456" }, "/var/db/logd", 17, 123456, 0);
}
test "missing configuration uses the default store" {
    try check(null, &.{}, "/var/db/logd", 7, 150000000, 0);
}
test "a configured system store keeps its settings" {
    try check("> /var/db/logd ttl=19 all_max=222222\n", &.{}, "/var/db/logd", 19, 222222, 1);
}
test "explicit -s keeps precedence over the configured store" {
    try check("> /var/db/logd ttl=19 all_max=222222\n", &.{ "-s", "/op904/private-store" }, "/op904/private-store", 7, 150000000, 1);
}
