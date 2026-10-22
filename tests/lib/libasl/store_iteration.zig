// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("asl.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
});
extern fn asl_store_open_write([*:0]const u8, *?*anyopaque) u32;
extern fn asl_store_save(?*anyopaque, c.asl_object_t) u32;
extern fn asl_store_close(?*anyopaque) u32;
const messages = [_][:0]const u8{ "op856.zero", "op856.one", "op856.two", "op856.three" };
pub fn run(backward: bool) !void {
    var path = "op856-iteration-XXXXXX".* ++ [_]u8{0};
    if (c.mkdtemp(@ptrCast(&path)) == null) return error.FixtureDirectory;
    const fixture = std.mem.sliceTo(&path, 0);
    defer std.fs.cwd().deleteTree(fixture) catch {};
    var writer: ?*anyopaque = null;
    if (asl_store_open_write(@ptrCast(&path), &writer) != 0 or writer == null) return error.OpenWriter;
    var time: [32]u8 = undefined;
    const timestamp = try std.fmt.bufPrintZ(&time, "{d}", .{c.time(null)});
    for (messages) |text| {
        const message = c.asl_new(c.ASL_TYPE_MSG) orelse return error.NewMessage;
        defer c.asl_release(message);
        if (c.asl_set(message, "Message", text) != 0 or c.asl_set(message, "Time", timestamp) != 0) return error.SetMessage;
        if (asl_store_save(writer, message) != 0) return error.SaveMessage;
    }
    if (asl_store_close(writer) != 0) return error.CloseWriter;
    // Read-only is the zero option in this public header.
    const store = c.asl_open_path(@ptrCast(&path), 0) orelse return error.OpenReader;
    c.asl_reset_iteration(store, if (backward) std.math.maxInt(usize) else 0);
    var retained: [messages.len]c.asl_object_t = undefined;
    for (&retained, 0..) |*message, i| {
        message.* = (if (backward) c.asl_prev(store) else c.asl_next(store)) orelse return error.MissingMessage;
        // Use the message after the iterator's temporary result list is gone.
        const observed = c.asl_get(message.*, "Message") orelse return error.MissingText;
        const expected = messages[if (backward) messages.len - 1 - i else i];
        if (!std.mem.eql(u8, std.mem.span(observed), expected) or c.asl_count(message.*) == 0) return error.MessageContent;
    }
    if ((if (backward) c.asl_prev(store) else c.asl_next(store)) != null) return error.ExtraMessage;
    c.asl_release(store);
    for (retained, 0..) |message, i| {
        defer c.asl_release(message);
        const expected = messages[if (backward) messages.len - 1 - i else i];
        const observed = c.asl_get(message, "Message") orelse return error.MissingTextAfterClose;
        if (!std.mem.eql(u8, std.mem.span(observed), expected)) return error.ContentAfterClose;
        if (c.asl_set(message, "after-close", "owned") != 0) return error.MutateOwnedMessage;
    }
    _ = c.printf("asl_store_iteration direction=%s records=4 used_after_store_close=4\n", @as([*:0]const u8, if (backward) "prev" else "next"));
}
test "store next returns owned usable messages" {
    try run(false);
}
test "store prev returns owned usable messages" {
    try run(true);
}
