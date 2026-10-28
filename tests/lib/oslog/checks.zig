const std = @import("std");
pub const c = @cImport({
    @cInclude("oslog_codec.h");
    @cInclude("codec_fixture.h");
    @cInclude("dlfcn.h");
    @cInclude("errno.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});
const fixtures = @import("fixtures.zig");
const Row = struct { eventMessage: []const u8, formatString: []const u8, messageType: []const u8, op: u32 };
pub var emit_hook: ?*const fn ([*:0]const u8, []const u8, c_uint, u32) void = null;
const a = std.heap.page_allocator;
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn contains(x: []const u8, y: []const u8) bool {
    return std.mem.indexOf(u8, x, y) != null;
}
fn expect(ok: bool) !void {
    try std.testing.expect(ok);
}
fn print(comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(a, format, args);
    defer a.free(text);
    var at: usize = 0;
    while (at < text.len) {
        const n = c.write(1, text[at..].ptr, text.len - at);
        if (n <= 0) return error.WriteFailed;
        at += @intCast(n);
    }
}
const Source = struct {
    regions: [64][]const u8 = undefined,
    count: usize = 0,
    fn register(self: *Source, data: []const u8) [*:0]const u8 {
        self.regions[self.count] = data;
        self.count += 1;
        return @ptrCast(data.ptr);
    }
    fn read(ptr: ?*anyopaque, address: usize, offset: usize, out: [*c]u8) callconv(.c) c_int {
        const self: *Source = @ptrCast(@alignCast(ptr.?));
        for (self.regions[0..self.count]) |region| {
            const begin = @intFromPtr(region.ptr);
            if (address < begin or address - begin >= region.len) continue;
            const delta = address - begin;
            if (offset >= region.len - delta) continue;
            out[0] = region[delta + offset];
            return 0;
        }
        return c.EFAULT;
    }
    fn copy(self: *Source, alloc: std.mem.Allocator, bytes: []const u8) ![*:0]const u8 {
        const text = try alloc.dupeZ(u8, bytes);
        return self.register(text[0 .. text.len + 1]);
    }
    fn literal(self: *Source, pointer: [*c]const u8) [*:0]const u8 {
        const text = std.mem.span(pointer);
        return self.register(text.ptr[0 .. text.len + 1]);
    }
};
fn bundlePath(alloc: std.mem.Allocator) ![:0]const u8 {
    var buffer: [4096]u8 = undefined;
    const n = try std.process.executablePath(std.Io.Threaded.global_single_threaded.io(), &buffer);
    return std.fmt.allocPrintSentinel(alloc, "{s}/literal_bundle.so", .{std.fs.path.dirname(buffer[0..n]).?}, 0);
}
pub fn oracle() !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const parsed = try std.json.parseFromSlice([]const Row, alloc, @embedFile("oracle.json"), .{});
    try expect(parsed.value.len == 74);
    for (parsed.value, 0..) |row, index| {
        var source = Source{};
        var input: c.struct_codec_input = std.mem.zeroes(c.struct_codec_input);
        input.i32 = 42;
        input.i64 = 42;
        input.real = 3.25;
        input.precision = 2000;
        input.pointer = 0x16f742608; // Replay the scalar pointer value recorded by the oracle.
        const long = try alloc.alloc(u8, 2001);
        @memset(long, 'A');
        long[2000] = 0;
        const long_pointer = source.register(long);
        input.strings[0] = long_pointer;
        input.strings[1] = long_pointer;
        var handle: ?*anyopaque = null;
        defer if (handle != null) {
            _ = c.dlclose(handle);
        };
        var duplicate: [*c]u8 = null;
        defer if (duplicate != null) c.free(duplicate);
        const format = row.formatString;
        if (row.op == 963) {
            if (contains(format, "privacy")) {
                if (contains(format, "literal")) input.strings[0] = source.literal(c.fixture_literal(0)) else input.strings[0] = try source.copy(alloc, "runtime-base");
                input.i32 = if (contains(format, " d=")) -12345 else if (contains(format, " u=")) 424242 else if (contains(format, " x=")) 0x1a2b3c else 'Q';
            } else if (contains(format, "fields")) {
                const name = if (contains(row.eventMessage, "log=created")) "created" else "OS_LOG_DEFAULT";
                if (contains(format, "with_type")) {
                    const kind = if (eq(row.messageType, "Fault")) "fault" else if (eq(row.messageType, "Error")) "error" else if (eq(row.messageType, "Info")) "info" else "default";
                    input.strings[0] = try source.copy(alloc, kind);
                    input.strings[1] = try source.copy(alloc, name);
                } else input.strings[0] = try source.copy(alloc, name);
            } else if (contains(format, "decoder value")) input.i32 = 12345;
        } else {
            if (contains(format, " A01 ")) input.strings[0] = source.literal(c.fixture_linked_literal());
            if (contains(format, " A02 ")) input.strings[0] = source.literal(c.fixture_literal(1));
            // macOS strerror returned read-only libc storage. FreeBSD strerror
            // uses writable storage; replay the same libc error-table bytes.
            if (contains(format, " A03 ")) {
                try expect(c.__oslog_codec_literal(c.strerror(c.ENOENT)) == 0);
                input.strings[0] = source.literal(c.fixture_error_literal());
            }
            if (contains(format, " A04")) {
                const flags: c_int = c.RTLD_NOW | c.RTLD_LOCAL | if (contains(format, "A04b")) @as(c_int, c.RTLD_NODELETE) else 0;
                handle = c.dlopen(try bundlePath(alloc), flags);
                try expect(handle != null);
                const symbol = c.dlsym(handle, "bundle_literal");
                try expect(symbol != null);
                const get: *const fn () callconv(.c) [*c]const u8 = @ptrCast(@alignCast(symbol.?));
                input.strings[0] = source.literal(get());
            }
            if (contains(format, " A05a ")) input.strings[0] = source.literal(c.fixture_literal(2));
            if (contains(format, " A05b ")) input.strings[0] = source.literal(c.fixture_literal(3));
            if (contains(format, " A05c ")) input.strings[0] = source.literal(c.fixture_func_literal());
            if (contains(format, " A05d ")) input.strings[0] = source.literal(c.fixture_literal(4));
            if (contains(format, " A05e ")) {
                duplicate = c.strdup("copied-literal");
                try expect(duplicate != null);
                input.strings[0] = source.literal(duplicate);
            }
            if (contains(format, " A06")) input.strings[0] = null;
            if (contains(format, " A07a ")) input.i32 = 12345;
            if (contains(format, " A07b ")) input.strings[0] = source.literal(c.fixture_literal(5));
            if (contains(format, " A07c ") or contains(format, " A07d ")) {
                input.strings[0] = source.literal(c.fixture_wide_literal());
            }
            if (contains(format, " B01")) {
                const n: usize = if (contains(format, "B01a")) 1014 else if (contains(format, "B01b")) 1015 else 1016;
                long[n] = 0;
            }
            if (contains(format, " B04 ")) input.strings[0] = source.literal(c.fixture_literal(6));
            if (contains(format, " B09a ")) input.strings[0] = try source.copy(alloc, "ok");
            if (contains(format, " B09b ") or contains(format, " B09c ")) input.strings[0] = source.literal(c.fixture_literal(7));
            if (contains(format, " B10 ")) {
                long[1014] = 0xc3;
                long[1015] = 0xa9;
                @memcpy(long[1016..1021], "-TAIL");
            }
            if (contains(format, " B11 ")) for (0..33) |n| {
                const value = try std.fmt.allocPrint(alloc, "{d:0>2}", .{n + 1});
                input.strings[n] = try source.copy(alloc, value);
            };
        }
        var sample: c.struct_codec_sample = undefined;
        fixtures.functions[index](&input, &sample);
        try expect(eq(std.mem.span(sample.format), format));
        var flat: [c.__OSLOG_CODEC_STORAGE]u8 = undefined;
        var flat_size: usize = 0;
        const kind: c_uint = if (eq(row.messageType, "Fault")) 17 else if (eq(row.messageType, "Error")) 16 else if (eq(row.messageType, "Info")) 1 else if (eq(row.messageType, "Debug")) 2 else 0;
        if (emit_hook) |hook| hook(sample.format, sample.bytes[0..sample.size], kind, row.op);
        const flatten = c.__oslog_codec_flatten(&sample.bytes, sample.size, kind, Source.read, &source, &flat, flat.len, &flat_size);
        if (flatten != 0) {
            try print("oracle[{d}] flatten={d} format={s}\n", .{ index, flatten, format });
            return error.FlattenFailed;
        }
        var message: [8192]u8 = undefined;
        var length: usize = 0;
        const render = c.__oslog_codec_render(sample.format, format.len, &flat, flat_size, &message, message.len, &length);
        if (render != 0 or !eq(message[0..length], row.eventMessage)) {
            try print("oracle[{d}] render={d}\nformat={s}\nexpected={s}\nobserved={s}\n", .{ index, render, format, row.eventMessage, message[0..length] });
            return error.OracleMismatch;
        }
        try print("oracle[{d}] op={d} bytes={d} PASS {s}\n", .{ index, row.op, length, format });
    }
}
pub fn malformed() !void {
    var flat: [2048]u8 = undefined;
    var length: usize = 123;
    const scalar = [_]u8{ 0, 1, 0, 4, 42, 0, 0, 0 };
    var source = Source{};
    try expect(c.__oslog_codec_flatten(&scalar, scalar.len, 0, Source.read, &source, &flat, flat.len, &length) == 0);
    var valid: [32]u8 = undefined;
    var valid_length: usize = 0;
    try expect(c.__oslog_codec_render("%d", 2, &flat, length, &valid, valid.len, &valid_length) == 0);
    try expect(eq(valid[0..valid_length], "42"));
    try expect(c.__oslog_codec_flatten(&scalar, scalar.len, 0, Source.read, &source, &flat, 1, &length) == c.ENOSPC);
    for (0..scalar.len) |n| try expect(c.__oslog_codec_flatten(&scalar, n, 0, Source.read, &source, &flat, flat.len, &length) != 0);
    var output: [128]u8 = undefined;
    const bad_public = [_]u8{ 2, 1, 0x22, 8, 1, 0, 0, 0, 0, 0, 0, 0 };
    try expect(c.__oslog_codec_flatten(&bad_public, bad_public.len, 0, Source.read, &source, &flat, flat.len, &length) == c.EFAULT);
    const bad_ranges = [_][10]u8{
        .{ 2, 1, 0x22, 4, 0xff, 0x7f, 2, 0, 'A', 0 },
        .{ 2, 1, 0x22, 4, 0, 0, 0xff, 0x7f, 'A', 0 },
        .{ 2, 1, 0x22, 4, 0, 0, 2, 0, 'A', 'B' },
        .{ 3, 1, 0x21, 4, 1, 0, 0, 0, 0, 0 },
    };
    const good_range = [_]u8{ 2, 1, 0x22, 4, 0, 0, 2, 0, 'A', 0 };
    for (0..good_range.len) |cut| try expect(c.__oslog_codec_render("%s", 2, &good_range, cut, &output, output.len, &length) != 0);
    try expect(c.__oslog_codec_render("%s", 2, &good_range, good_range.len, &output, output.len, &length) == 0);
    for (bad_ranges) |bad| try expect(c.__oslog_codec_render("%s", 2, &bad, bad.len, &output, output.len, &length) != 0);
    for ([_][]const u8{ "%n", "%{private}n", "%", "%{public", "%999999999999999d", "%1$d" }) |format| {
        try expect(c.__oslog_codec_render(format.ptr, format.len, &scalar, scalar.len, &output, output.len, &length) != 0);
    }
    var random = std.Random.DefaultPrng.init(201);
    var bytes: [96]u8 = undefined;
    for (0..20000) |_| {
        random.random().bytes(&bytes);
        const n = random.random().uintLessThan(usize, bytes.len + 1);
        _ = c.__oslog_codec_flatten(&bytes, n, 0, Source.read, &source, &flat, flat.len, &length);
        _ = c.__oslog_codec_render("%s", 2, &bytes, n, &output, output.len, &length);
    }
    try print("malformed clang_cuts={d} flat_cuts=10 bad_ranges=4 bad_pointer=1 forbidden_formats=6 fuzz_pairs=20000 PASS\n", .{scalar.len});
}
pub fn wire() !void {
    var source = Source{};
    const text = "secret";
    var input: c.struct_codec_input = std.mem.zeroes(c.struct_codec_input);
    input.strings[0] = source.register(text[0 .. text.len + 1]);
    var sample: c.struct_codec_sample = undefined;
    c.fixture_edges(&input, &sample);
    var flat: [2048]u8 = undefined;
    var length: usize = 0;
    try expect(c.__oslog_codec_flatten(&sample.bytes, sample.size, 0, Source.read, &source, &flat, flat.len, &length) == 0);
    try expect(!contains(flat[0..length], "secret"));
    var output: [256]u8 = undefined;
    var n: usize = 0;
    try expect(c.__oslog_codec_render(sample.format, std.mem.len(sample.format), &flat, length, &output, output.len, &n) == 0);
    try expect(eq(output[0..n], "[+0000042][0x2a][-1][3.25][sec][<private>][%][0x0]"));
    const string = [_]u8{ 2, 1, 0x22, 8 };
    var buffer: [12]u8 = undefined;
    @memcpy(buffer[0..4], &string);
    std.mem.writeInt(u64, buffer[4..12], @intFromPtr(input.strings[0]), .little);
    try expect(c.__oslog_codec_flatten(&buffer, buffer.len, 0, Source.read, &source, &flat, flat.len, &length) == 0);
    try expect(eq(flat[0..length], &.{ 2, 1, 0x22, 4, 0, 0, 7, 0, 's', 'e', 'c', 'r', 'e', 't', 0 }));
    var bounded = [_]u8{ 2, 2, 0x12, 4, 3, 0, 0, 0, 0x22, 8, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, bounded[10..18], @intFromPtr(input.strings[0]), .little);
    try expect(c.__oslog_codec_flatten(&bounded, bounded.len, 0, Source.read, &source, &flat, flat.len, &length) == 0);
    try expect(eq(flat[0..length], &.{ 2, 2, 0x12, 4, 3, 0, 0, 0, 0x22, 4, 0, 0, 3, 0, 's', 'e', 'c' }));
    const bounded_format = "%{public}.3s";
    try expect(c.__oslog_codec_render(bounded_format, bounded_format.len, &flat, length, &output, output.len, &n) == 0);
    try expect(eq(output[0..n], "sec"));
    bounded[4] = 0;
    try expect(c.__oslog_codec_flatten(&bounded, bounded.len, 0, Source.read, &source, &flat, flat.len, &length) == 0);
    const empty_format = "%{public}.0s";
    try expect(c.__oslog_codec_render(empty_format, empty_format.len, &flat, length, &output, output.len, &n) == 0);
    try expect(n == 0);
    // Exactly 1024 metadata bytes: a precision-zero string needs no data byte.
    var full: [1028]u8 = @splat(0);
    full[0] = 2;
    full[1] = 169;
    var at: usize = 2;
    for (0..167) |i| {
        const size: usize = if (i < 165) 4 else 8;
        full[at + 1] = @intCast(size);
        at += size + 2;
    }
    // Skip bounded's standalone header when embedding its two commands.
    std.mem.copyForwards(u8, full[at..], bounded[2..]);
    try expect(c.__oslog_codec_flatten(&full, full.len, 0, Source.read, &source, &flat, flat.len, &length) == 0);
    try expect(length == 1024 and flat[1] == 169 and std.mem.eql(u8, flat[1018..1024], &.{ 0x22, 4, 0, 0, 0, 0 }));
    try print("wire ranges/privacy/counts/scalars/percent PASS\n", .{});
}
test "74 macOS oracle eventMessages" {
    try oracle();
}
test "malformed and truncated buffers" {
    try malformed();
}
test "wire encoding and safe formatted scalar edges" {
    try wire();
}
