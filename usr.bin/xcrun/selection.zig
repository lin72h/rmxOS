const std = @import("std");
pub const paths = @import("developer_paths");

pub fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (result < 0) {
            if (std.c.errno(result) == .INTR) continue;
            return error.OutputFailed;
        }
        if (result == 0) return error.OutputFailed;
        offset += @intCast(result);
    }
}

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    program: []const u8,

    pub fn diagnostic(self: Resolver, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.allocator, "{s}: " ++ format ++ "\n", .{self.program} ++ args) catch {
            writeAll(2, self.program) catch {};
            writeAll(2, ": out of memory\n") catch {};
            return;
        };
        writeAll(2, text) catch {};
    }

    pub fn directoryError(self: Resolver, selected: []const u8, reason: []const u8) void {
        self.diagnostic("developer directory '{s}': {s}; developer tools must be installed or selected", .{ selected, reason });
    }

    pub fn validateDirectory(self: Resolver, selected: [:0]const u8) bool {
        if (!std.fs.path.isAbsolute(selected)) {
            self.directoryError(selected, "selection must be absolute");
            return false;
        }
        var info: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, selected, &info, 0) != 0 or !std.c.S.ISDIR(info.mode)) {
            self.directoryError(selected, "selection is not an accessible directory");
            return false;
        }
        return true;
    }

    pub fn resolve(self: Resolver) ![:0]const u8 {
        const selected = try self.selectedDirectory();
        if (!self.validateDirectory(selected)) return error.InvalidSelection;
        return selected;
    }

    fn selectedDirectory(self: Resolver) ![:0]const u8 {
        if (std.c.getenv("DEVELOPER_DIR")) |value| {
            const directory = std.mem.span(value);
            if (directory.len != 0) return self.allocator.dupeZ(u8, directory);
        }
        // Only absence permits the default. A dangling link still selects its target.
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = std.c.readlink(paths.selection_link, &buffer, buffer.len);
        if (length < 0) {
            if (std.c.errno(length) == .NOENT) return paths.default_directory;
            self.diagnostic("cannot read selection link '{s}' ({s}); developer tools must be installed or selected", .{ paths.selection_link, @tagName(std.c.errno(length)) });
            return error.InvalidSelection;
        }
        const count: usize = @intCast(length);
        if (count == buffer.len) {
            self.diagnostic("selection link '{s}' is too long; developer tools must be installed or selected", .{paths.selection_link});
            return error.InvalidSelection;
        }
        return self.allocator.dupeZ(u8, buffer[0..count]);
    }
};
