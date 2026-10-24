const std = @import("std");
const selection = @import("selection.zig");
const paths = selection.paths;
const Resolver = selection.Resolver;

const help =
    \\Usage: xcode-select --print-path | -p
    \\       xcode-select --switch DIR | -s DIR
    \\       xcode-select --reset | -r
    \\       xcode-select --help | -h
    \\Preview: selection only; installation/download UI is not implemented.
    \\
;

const State = enum { absent, symlink };

fn state(report: Resolver, parent: std.c.fd_t, name: [:0]const u8) !State {
    var info: std.c.Stat = undefined;
    const result = std.c.fstatat(parent, name, &info, std.c.AT.SYMLINK_NOFOLLOW);
    if (result != 0) {
        if (std.c.errno(result) == .NOENT) return .absent;
        report.diagnostic("cannot inspect selector '{s}' ({s})", .{ paths.selection_link, @tagName(std.c.errno(result)) });
        return error.MutationFailed;
    }
    if (!std.c.S.ISLNK(info.mode)) {
        report.diagnostic("selector '{s}' is not a symlink; preserving it", .{paths.selection_link});
        return error.MutationFailed;
    }
    return .symlink;
}

fn mutate(report: Resolver, target: ?[:0]const u8) !void {
    if (target) |directory| {
        if (!report.validateDirectory(directory)) return error.InvalidSelection;
    }
    const parent_path = try report.allocator.dupeZ(u8, std.fs.path.dirname(paths.selection_link) orelse ".");
    const name = try report.allocator.dupeZ(u8, std.fs.path.basename(paths.selection_link));
    const parent = std.c.openat(std.c.AT.FDCWD, parent_path, .{ .DIRECTORY = true, .CLOEXEC = true });
    if (parent < 0) {
        if (target == null and std.c.errno(parent) == .NOENT) return;
        report.diagnostic("cannot open selector parent '{s}' ({s}); parent must exist and permit selection changes", .{ parent_path, @tagName(std.c.errno(parent)) });
        return error.MutationFailed;
    }
    defer _ = std.c.close(parent);
    const existing = try state(report, parent, name);
    if (target == null) {
        if (existing == .absent) return;
        const result = std.c.unlinkat(parent, name, 0);
        if (result != 0 and std.c.errno(result) != .NOENT) {
            report.diagnostic("cannot reset selector '{s}' ({s}); parent must permit selection changes", .{ paths.selection_link, @tagName(std.c.errno(result)) });
            return error.MutationFailed;
        }
        return;
    }

    // Build the new symlink beside the selector, never unlinking the old choice.
    // The open parent fd anchors creation, validation, cleanup and atomic rename.
    for (0..16) |_| {
        var random: [16]u8 = undefined;
        std.c.arc4random_buf(&random, random.len);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const temporary = try std.fmt.allocPrintSentinel(report.allocator, ".{s}.tmp.{s}", .{ name, suffix }, 0);
        const created = std.c.symlinkat(target.?, parent, temporary);
        if (created != 0) {
            if (std.c.errno(created) == .EXIST) continue;
            report.diagnostic("cannot stage selection for '{s}' ({s}); parent must permit selection changes", .{ paths.selection_link, @tagName(std.c.errno(created)) });
            return error.MutationFailed;
        }
        var staged = true;
        defer if (staged) {
            _ = std.c.unlinkat(parent, temporary, 0);
        };
        // Preserve a non-symlink selector if it appeared while staging the link.
        _ = try state(report, parent, name);
        const renamed = std.c.renameat(parent, temporary, parent, name);
        if (renamed != 0) {
            report.diagnostic("cannot replace selector '{s}' ({s}); parent must permit selection changes", .{ paths.selection_link, @tagName(std.c.errno(renamed)) });
            return error.MutationFailed;
        }
        staged = false; // rename consumed the temporary name.
        return;
    }
    report.diagnostic("cannot allocate a temporary symlink beside '{s}'", .{paths.selection_link});
    return error.MutationFailed;
}

fn matches(value: []const u8, long: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, value, long) or std.mem.eql(u8, value, short);
}

fn run(report: Resolver, args: []const [:0]const u8) !u8 {
    if (args.len >= 2) {
        const option = args[1];
        if (matches(option, "--switch", "-s") and args.len == 3) {
            try mutate(report, args[2]);
            return 0;
        }
        if (args.len == 2) {
            if (matches(option, "--print-path", "-p")) {
                const selected = try report.resolve();
                try selection.writeAll(1, selected);
                try selection.writeAll(1, "\n");
                return 0;
            }
            if (matches(option, "--reset", "-r")) {
                try mutate(report, null);
                return 0;
            }
            if (matches(option, "--help", "-h")) {
                try selection.writeAll(1, help);
                return 0;
            }
        }
    }
    report.diagnostic("unsupported option or missing/extra operands; use --help for preview forms", .{});
    return 2;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const report = Resolver{ .allocator = arena.allocator(), .program = "xcode-select" };
    const args = init.args.toSlice(report.allocator) catch {
        report.diagnostic("cannot read arguments", .{});
        return 1;
    };
    return run(report, args) catch |err| {
        switch (err) {
            error.MutationFailed, error.InvalidSelection => {}, // Already diagnosed.
            else => report.diagnostic("{s}", .{@errorName(err)}),
        }
        return 1;
    };
}
