const std = @import("std");
const selection = @import("selection.zig");
const writeAll = selection.writeAll;
const Allocator = std.mem.Allocator;

// execv uses the existing environment and never searches PATH.
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const help =
    \\Usage: xcrun TOOL [args...]
    \\       xcrun --run TOOL [args...]
    \\       xcrun --find TOOL
    \\       xcrun --show-sdk-path
    \\       xcrun --help
    \\Preview: tools come only from the selected developer directory's usr/bin.
    \\Other Apple xcrun options are not implemented.
    \\
;

fn diagnostic(allocator: Allocator, comptime format: []const u8, args: anytype) void {
    (selection.Resolver{ .allocator = allocator, .program = "xcrun" }).diagnostic(format, args);
}

fn selectionError(allocator: Allocator, selected: []const u8, reason: []const u8) void {
    (selection.Resolver{ .allocator = allocator, .program = "xcrun" }).directoryError(selected, reason);
}

fn developerDirectory(allocator: Allocator) ![:0]const u8 {
    return (selection.Resolver{ .allocator = allocator, .program = "xcrun" }).resolve();
}

fn isAlias(name: []const u8) bool {
    inline for (.{ "swift", "swiftc", "swift-build", "swift-test", "swift-run", "swift-package", "sourcekit-lsp" }) |alias| {
        if (std.mem.eql(u8, name, alias)) return true;
    }
    return false;
}

fn run(allocator: Allocator, args: []const [:0]const u8) !u8 {
    const invoked = if (args.len > 0) std.fs.path.basename(args[0]) else "xcrun";
    var tool: []const u8 = undefined;
    var remaining: []const [:0]const u8 = undefined;
    var find = false;
    if (isAlias(invoked)) {
        tool = invoked;
        remaining = args[1..];
    } else {
        if (args.len < 2) {
            diagnostic(allocator, "missing tool; use --help for supported preview forms", .{});
            return 2;
        }
        const first = args[1];
        if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "--show-sdk-path")) {
            if (args.len != 2) {
                diagnostic(allocator, "option '{s}' does not accept arguments", .{first});
                return 2;
            }
            try writeAll(1, if (std.mem.eql(u8, first, "--help")) help else "/\n");
            return 0;
        }
        if (std.mem.eql(u8, first, "--find") or std.mem.eql(u8, first, "--run")) {
            find = std.mem.eql(u8, first, "--find");
            if (args.len < 3 or (find and args.len != 3)) {
                diagnostic(allocator, "option '{s}' requires a tool{s}", .{ first, if (find) " and no extra arguments" else "" });
                return 2;
            }
            tool = args[2];
            remaining = args[3..];
        } else {
            if (std.mem.startsWith(u8, first, "-")) {
                diagnostic(allocator, "unsupported preview option '{s}'; use --help", .{first});
                return 2;
            }
            tool = first;
            remaining = args[2..];
        }
    }
    if (tool.len == 0 or tool[0] == '-' or std.mem.indexOfScalar(u8, tool, '/') != null or
        std.mem.eql(u8, tool, ".") or std.mem.eql(u8, tool, ".."))
    {
        diagnostic(allocator, "tool '{s}' must be a basename, not a path or option", .{tool});
        return 2;
    }
    const selected = developerDirectory(allocator) catch |err| switch (err) {
        error.InvalidSelection => return 1,
        else => return err,
    };
    const executable = try std.fmt.allocPrintSentinel(allocator, "{s}/usr/bin/{s}", .{ std.mem.trimEnd(u8, selected, "/"), tool }, 0);
    var tool_stat: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, executable, &tool_stat, 0) != 0 or !std.c.S.ISREG(tool_stat.mode) or std.c.access(executable, 1) != 0) {
        const reason = try std.fmt.allocPrint(allocator, "tool '{s}' is missing or not executable at '{s}'", .{ tool, executable });
        selectionError(allocator, selected, reason);
        return 1;
    }
    if (find) {
        try writeAll(1, executable);
        try writeAll(1, "\n");
        return 0;
    }
    const argv = try allocator.allocSentinel(?[*:0]const u8, remaining.len + 1, null);
    argv[0] = executable.ptr;
    for (remaining, 1..) |argument, index| argv[index] = argument.ptr;
    const result = execv(executable, argv.ptr);
    const reason = try std.fmt.allocPrint(allocator, "cannot execute '{s}' ({s})", .{ executable, @tagName(std.c.errno(result)) });
    selectionError(allocator, selected, reason);
    return 1;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = init.args.toSlice(allocator) catch {
        diagnostic(allocator, "cannot read arguments", .{});
        return 1;
    };
    return run(allocator, args) catch |err| {
        diagnostic(allocator, "{s}", .{@errorName(err)});
        return 1;
    };
}
