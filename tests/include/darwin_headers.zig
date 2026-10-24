//! Host-only standalone installed-header check. No source-tree include paths or defines.
const std = @import("std");
const a = std.heap.page_allocator;

fn run(io: std.Io, argv: []const []const u8, log: []const u8) !bool {
    const result = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(4 * 1024 * 1024), .stderr_limit = .limited(4 * 1024 * 1024) });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    const file = try std.Io.Dir.cwd().createFile(io, log, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 1 and args.len != 3 and args.len != 4) {
        std.debug.print("usage: darwin_headers SYSROOT RESULTS [ZIG_CHECKER]\n", .{});
        std.process.exit(2);
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, if (args.len == 1) "/" else args[1], a);
    const out = if (args.len == 1) "." else args[2];
    try std.Io.Dir.cwd().createDirPath(io, out);
    var headers: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "dispatch/dispatch.h", "dispatch/introspection.h", "os/base.h", "os/object.h", "os/assumes.h", "os/trace.h", "xpc/xpc.h", "xpc/debug.h", "xpc/launchd.h", "asl.h", "notify.h", "launch.h", "Block.h", "Availability.h", "AvailabilityInternal.h", "AvailabilityMacros.h" }) |h| try headers.append(a, h);
    // All installed Mach headers, including device/i386 and the mach.h umbrella.
    var dir = try std.Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(a, "{s}/usr/include/mach", .{root}), .{ .iterate = true });
    defer dir.close(io);
    var it = try dir.walk(a);
    defer it.deinit();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".h")) try headers.append(a, try std.fmt.allocPrint(a, "mach/{s}", .{entry.path}));
    }
    std.mem.sort([]const u8, headers.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var failures: usize = 0;
    for (headers.items) |header| {
        const name = try a.dupe(u8, header);
        std.mem.replaceScalar(u8, name, '/', '_');
        const input = try std.fmt.allocPrint(a, "{s}/{s}.c", .{ out, name });
        const file = try std.Io.Dir.cwd().createFile(io, input, .{});
        try file.writeStreamingAll(io, try std.fmt.allocPrint(a, "#include <{s}>\n", .{header}));
        file.close(io);
        for ([_][]const u8{ "c", "c++" }) |lang| {
            const log = try std.fmt.allocPrint(a, "{s}/{s}.{s}.log", .{ out, name, lang });
            const deps = try std.fmt.allocPrint(a, "{s}/{s}.{s}.d", .{ out, name, lang });
            var ok = try run(io, &.{ if (std.mem.eql(u8, lang, "c")) "/usr/bin/cc" else "/usr/bin/c++", "--sysroot", root, "-fblocks", "-fsyntax-only", "-MD", "-MF", deps, "-x", lang, input }, log);
            if (ok) {
                const dependencies = try std.Io.Dir.cwd().readFileAlloc(io, deps, a, .limited(4 * 1024 * 1024));
                // Clang's C default search can otherwise escape --sysroot here.
                if (std.mem.indexOf(u8, dependencies, "/usr/local/include") != null) {
                    std.debug.print("host include escaped sysroot: {s}\n", .{deps});
                    ok = false;
                }
            }
            std.debug.print("{s}\t{s}\t{s}\n", .{ header, lang, if (ok) "PASS" else "FAIL" });
            if (!ok) failures += 1;
        }
    }
    if (args.len == 4) {
        for ([_][]const u8{ "dispatch/dispatch.h", "os/object.h", "xpc/xpc.h" }) |header| {
            const name = try a.dupe(u8, header);
            std.mem.replaceScalar(u8, name, '/', '_');
            const log = try std.fmt.allocPrint(a, "{s}/{s}.translate.log", .{ out, name });
            const path = try std.fmt.allocPrint(a, "{s}/usr/include/{s}", .{ root, header });
            const ok = try run(io, &.{ args[3], "translate-c", "-target", "x86_64-freebsd", "--sysroot", root, "-isystem", try std.fmt.allocPrint(a, "{s}/usr/include", .{root}), path }, log);
            std.debug.print("{s}\ttranslate-c\t{s}\n", .{ header, if (ok) "PASS" else "FAIL" });
            if (!ok) failures += 1;
        }
    }
    std.debug.print("headers={d} failures={d}\n", .{ headers.items.len, failures });
    if (failures != 0) std.process.exit(1);
}
