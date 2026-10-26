// A reconciliation pass must distinguish absent records from slow reads.
// ASL count=0 and duration=0 mean exhaust the store, with no result/time cap.
const std = @import("std");
const c = @cImport({
    @cInclude("asl.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});
fn Nullable(comptime T: type) type {
    return if (@typeInfo(T) == .optional) T else ?T;
}
pub fn all(store: anytype, queries: Nullable(@TypeOf(store))) Nullable(@TypeOf(store)) {
    var last: usize = 0;
    return @ptrCast(c.asl_match(@ptrCast(store), @ptrCast(queries), &last, std.math.maxInt(usize), 0, 0, -1));
}

extern fn asl_store_open_write([*:0]const u8, *?*anyopaque) u32;
extern fn asl_store_save(?*anyopaque, c.asl_object_t) u32;
extern fn asl_store_close(?*anyopaque) u32;
const Fixture = struct {
    path: [40:0]u8,
    fn init() !Fixture {
        var self = Fixture{ .path = @splat(0) };
        const template = "op156-reconcile-XXXXXX";
        @memcpy(self.path[0..template.len], template);
        try std.testing.expect(c.mkdtemp(&self.path) != null);
        return self;
    }
    fn deinit(self: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), std.mem.sliceTo(&self.path, 0)) catch unreachable;
    }
    fn save(self: *Fixture, record_count: usize, tag: [*:0]const u8) !void {
        var writer: ?*anyopaque = null;
        try std.testing.expectEqual(@as(u32, 0), asl_store_open_write(&self.path, &writer));
        defer _ = asl_store_close(writer);
        const message = c.asl_new(c.ASL_TYPE_MSG);
        defer c.asl_release(message);
        try std.testing.expect(c.asl_set(message, "Sender", tag) == 0);
        try std.testing.expect(c.asl_set(message, "Time", "2000000000") == 0);
        for (0..record_count) |_| try std.testing.expectEqual(@as(u32, 0), asl_store_save(writer, message));
    }
    fn count(self: *Fixture, tag: ?[*:0]const u8) !usize {
        const store = c.asl_open_path(&self.path, 0);
        try std.testing.expect(store != null);
        defer c.asl_release(store);
        const queries = c.asl_new(c.ASL_TYPE_LIST);
        defer c.asl_release(queries);
        if (tag) |name| {
            const q = c.asl_new(c.ASL_TYPE_QUERY);
            defer c.asl_release(q);
            try std.testing.expect(c.asl_set_query(q, "Sender", name, c.ASL_QUERY_OP_EQUAL) == 0);
            c.asl_append(queries, q);
        }
        const result = all(store, if (tag != null) queries else null);
        defer c.asl_release(result);
        var found: usize = 0;
        while (c.asl_next(result) != null) found += 1;
        return found;
    }
};
test "complete tagged pass exceeds former flood and shedding result caps" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.save(11005, "wanted");
    try fixture.save(3, "other");
    try std.testing.expectEqual(@as(usize, 11005), try fixture.count("wanted"));
    try std.testing.expectEqual(@as(usize, 11008), try fixture.count(null));
}
test "another complete pass sees records that arrived after the earlier pass" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.save(1, "wanted");
    try std.testing.expectEqual(@as(usize, 1), try fixture.count("wanted"));
    try fixture.save(1, "wanted");
    try std.testing.expectEqual(@as(usize, 2), try fixture.count("wanted"));
}
test "an exhausted store can have no matching records" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.save(1, "other");
    try std.testing.expectEqual(@as(usize, 0), try fixture.count("wanted"));
}
