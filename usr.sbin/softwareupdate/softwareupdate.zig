// softwareupdate(8): macOS's command surface over the sealed-base lifecycle.
const std = @import("std");
const sys = @import("sys.zig");
const catalog = @import("catalog.zig");
const engine = @import("engine.zig");
const Ctx = sys.Ctx;

pub const help =
    \\usage: softwareupdate <cmd> [<args> ...]
    \\
    \\** Manage Updates:
    \\        -l | --list                List all appropriate update labels (options: --no-scan, --product-types)
    \\        -d | --download            Download Only
    \\        -i | --install             Install
    \\                <label> ...        specific updates
    \\                -a | --all         All appropriate updates
    \\                -R | --restart     Automatically restart if required to complete installation.
    \\                -r | --recommended Only recommended updates
    \\                     --os-only     Only OS updates
    \\        --background               Trigger a background scan and download (no install)
    \\        --history                  Show the install history. By default, only displays updates installed by softwareupdate.
    \\        --dump-state               Print the update state (as status)
    \\
    \\** Options:
    \\        --no-scan                  Do not scan when listing or installing updates (use the last fetched catalog)
    \\        --verbose                  Enable verbose output
    \\        --force                    Force an operation to complete
    \\        --agree-to-license         Agree to the software license agreement without user interaction (accepted; no effect)
    \\        --help                     Print this help
    \\
    \\** Other Tools (rmxOS):
    \\        status                     The installed label, base snapshot and GUID, written on the base, fallback, history
    \\        rollback [--restart]       Boot the fallback environment next
    \\        --catalog DIR|URL          Read catalog.json from DIR or URL (developer option)
    \\        --no-auto-confirm          With --install: wait for confirm after the restart
    \\        confirm | cancel           Only for an install made with --no-auto-confirm
    \\
;

pub const Action = enum { none, help, list, download, install, history, background, dump_state, status, rollback, confirm, cancel, boot_check };
pub const Options = struct {
    action: Action = .none,
    labels: std.ArrayList([]const u8) = .empty,
    all: bool = false,
    recommended: bool = false,
    os_only: bool = false,
    restart: bool = false,
    no_scan: bool = false,
    verbose: bool = false,
    force: bool = false,
    no_auto_confirm: bool = false,
    catalog: ?[]const u8 = null,
};
// macOS flags rmxOS does not carry; each refused with one line.
pub const refused = [_][]const u8{ "--fetch-full-installer", "--list-full-installers", "--install-rosetta", "--stdinpass", "--user", "--safari-only" };

pub const ParseError = error{ Usage, Refused };
pub var refused_flag: []const u8 = "";

pub fn parse(a: std.mem.Allocator, args: []const []const u8) !Options {
    var o = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        for (refused) |r| if (std.mem.eql(u8, x, r)) {
            refused_flag = r;
            return error.Refused;
        };
        const action: ?Action = if (eq(x, "-l") or eq(x, "--list")) .list else if (eq(x, "-d") or eq(x, "--download")) .download else if (eq(x, "-i") or eq(x, "--install")) .install else if (eq(x, "--history")) .history else if (eq(x, "--background")) .background else if (eq(x, "--dump-state")) .dump_state else if (eq(x, "-h") or eq(x, "--help")) .help else if (eq(x, "status")) .status else if (eq(x, "rollback")) .rollback else if (eq(x, "confirm")) .confirm else if (eq(x, "cancel")) .cancel else if (eq(x, "--boot-check")) .boot_check else null;
        if (action) |act| {
            if (o.action != .none) return error.Usage;
            o.action = act;
        } else if (eq(x, "-a") or eq(x, "--all")) {
            o.all = true;
        } else if (eq(x, "-r") or eq(x, "--recommended")) {
            o.recommended = true;
        } else if (eq(x, "--os-only")) {
            o.os_only = true;
        } else if (eq(x, "-R") or eq(x, "--restart")) {
            o.restart = true;
        } else if (eq(x, "--no-scan")) {
            o.no_scan = true;
        } else if (eq(x, "--verbose")) {
            o.verbose = true;
        } else if (eq(x, "--force")) {
            o.force = true;
        } else if (eq(x, "--agree-to-license")) {} else if (eq(x, "--no-auto-confirm")) {
            o.no_auto_confirm = true;
        } else if (eq(x, "--product-types")) {
            // One product type (the OS); the filter selects every update.
            if (i + 1 == args.len) return error.Usage;
            i += 1;
        } else if (eq(x, "--catalog")) {
            if (i + 1 == args.len or o.catalog != null) return error.Usage;
            i += 1;
            o.catalog = args[i];
        } else if (x.len > 0 and x[0] != '-' and (o.action == .install or o.action == .download)) {
            try o.labels.append(a, x);
        } else return error.Usage;
    }
    if (o.restart and o.action != .install and o.action != .rollback) return error.Usage;
    if (o.no_auto_confirm and o.action != .install) return error.Usage;
    if (o.action == .install and o.labels.items.len == 0 and !o.all and !o.recommended and !o.os_only) return error.Usage;
    return o;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = Ctx.init(a);
    const argv = init.args.toSlice(a) catch return 1;
    const o = parse(a, argv[1..]) catch |err| switch (err) {
        error.Refused => return ctx.refuse("{s} is not supported on rmxOS", .{refused_flag}),
        else => {
            sys.writeAll(2, help) catch {};
            return 2;
        },
    };
    ctx.verbose = o.verbose;
    return run(ctx, o) catch |err| ctx.refuse("{s}{s}{s}", .{ @errorName(err), if (sys.failure.len > 0) ": " else "", sys.failure });
}

fn applicable(env_head: engine.Snapshot, updates: []catalog.Update) ?catalog.Update {
    // Updates form a chain from the installed base's head; -a takes it to the newest.
    for (updates) |u| if (std.mem.eql(u8, u.origin_guid, env_head.guid)) return u;
    return null;
}

fn run(ctx: Ctx, o: Options) !u8 {
    switch (o.action) {
        .none, .help => {
            ctx.out("{s}", .{help});
            return 0;
        },
        .history => return engine.printHistory(ctx),
        else => {},
    }
    const env = try engine.discover(ctx);
    switch (o.action) {
        .status, .dump_state => return engine.status(ctx, env),
        .rollback => {
            const rc = try engine.rollback(ctx, env);
            if (rc == 0 and o.restart) try sys.restart(ctx);
            return rc;
        },
        .confirm => return engine.confirm(ctx, env),
        .cancel => return engine.cancel(ctx, env),
        .boot_check => return engine.bootCheck(ctx, env),
        else => {},
    }
    const loaded = catalog.load(ctx, o.catalog, o.no_scan) catch |err| switch (err) {
        error.NoCatalog => return ctx.refuse("no catalog: set catalog_url in /etc/softwareupdate.conf or use --catalog", .{}),
        error.NoCachedCatalog => return ctx.refuse("--no-scan: no catalog has been fetched yet", .{}),
        error.CatalogUnavailable => return ctx.refuse("catalog unavailable: {s}", .{sys.failure}),
        error.MalformedCatalog => return ctx.refuse("catalog.json is not a {s} catalog", .{catalog.format}),
        else => return err,
    };
    const h = try engine.head(ctx, env);
    const next = applicable(h, loaded.catalog.updates);
    switch (o.action) {
        .list => {
            ctx.out("Software Update Tool\n\n", .{});
            if (!o.no_scan) ctx.out("Finding available software\n", .{});
            const u = next orelse {
                ctx.out("No new software available.\n", .{});
                return 0;
            };
            ctx.out("Software Update found the following new or updated software:\n", .{});
            var cur: ?catalog.Update = u;
            while (cur) |x| {
                ctx.out("* Label: {s}\n\tTitle: rmxOS {s}, Version: {s}, Size: {d}K, Recommended: YES, Action: restart,\n", .{ x.label, x.build, x.build, (x.size + 1023) / 1024 });
                cur = applicable(.{ .name = x.snapshot, .guid = x.target_guid }, loaded.catalog.updates);
            }
            return 0;
        },
        .download, .background => {
            var cur = next;
            while (cur) |x| : (cur = applicable(.{ .name = x.snapshot, .guid = x.target_guid }, loaded.catalog.updates)) {
                if (o.labels.items.len > 0 and !contains(o.labels.items, x.label)) continue;
                const p = try catalog.download(ctx, loaded.source, x);
                const d = try sys.sha256File(p);
                if (!std.mem.eql(u8, &d, x.sha256)) return ctx.refuse("{s}: downloaded stream sha256 {s} does not match the catalog", .{ x.label, d });
                ctx.out("Downloaded {s}\n", .{x.label});
            }
            return 0;
        },
        .install => {
            // Named labels in order, or (-a, -r, --os-only) the chain to its newest.
            var chain: std.ArrayList(catalog.Update) = .empty;
            if (o.labels.items.len > 0) {
                for (o.labels.items) |l| {
                    const u = find(loaded.catalog.updates, l) orelse return ctx.refuse("{s}: no such update in the catalog", .{l});
                    try chain.append(ctx.a, u);
                }
            } else {
                var cur = next;
                while (cur) |x| : (cur = applicable(.{ .name = x.snapshot, .guid = x.target_guid }, loaded.catalog.updates)) try chain.append(ctx.a, x);
                if (chain.items.len == 0) {
                    ctx.out("No updates are available.\n", .{});
                    return 0;
                }
                // One staged environment per restart: the newest of the chain is
                // reached by installing in order; stage the first.
                chain.items.len = 1;
            }
            for (chain.items) |u| {
                const rc = try engine.install(ctx, env, u, loaded.source, o.no_auto_confirm);
                if (rc != 0) return rc;
            }
            if (o.restart) {
                ctx.out("Restarting...\n", .{});
                try sys.restart(ctx);
            } else ctx.out("Please restart immediately.\n", .{});
            return 0;
        },
        else => unreachable,
    }
}
fn find(updates: []catalog.Update, label: []const u8) ?catalog.Update {
    for (updates) |u| if (std.mem.eql(u8, u.label, label)) return u;
    return null;
}
fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

test {
    _ = @import("tests/unit.zig");
}
