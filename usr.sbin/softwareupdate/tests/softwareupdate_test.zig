const std = @import("std");
const seals = @import("seal_checks.zig");
const seal_guest = @import("seal_guest.zig");
const checks = @import("checks.zig");
const install = @import("install_checks.zig");
const lifecycle = @import("lifecycle_checks.zig");
const catalog = @import("catalog_checks.zig");
const mounts = @import("mount_checks.zig");
const lineage = @import("lineage_checks.zig");
const c = @cImport({
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn arguments(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.arguments() catch c.atf_tc_fail("argument parsing");
}
fn refusals(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.refusals() catch c.atf_tc_fail("BE refusals");
}
fn listing(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.listing() catch c.atf_tc_fail("catalog applicability");
}
fn malformed(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.malformed() catch c.atf_tc_fail("malformed catalog");
}
fn status(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.statusFields() catch c.atf_tc_fail("status fields");
}
fn disabled(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.unimplemented() catch c.atf_tc_fail("changing commands disabled");
}
fn installed(_: [*c]const c.atf_tc_t) callconv(.c) void {
    checks.installed() catch c.atf_tc_fail("installed command");
}
fn first(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.fileRules(true) catch |err| c.atf_tc_fail("first update: %s", @errorName(err).ptr);
}
fn second(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.fileRules(false) catch |err| c.atf_tc_fail("second update: %s", @errorName(err).ptr);
}
fn negative(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.negative() catch |err| c.atf_tc_fail("negative: %s", @errorName(err).ptr);
}
fn unsafePaths(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.unsafe() catch |err| c.atf_tc_fail("unsafe path: %s", @errorName(err).ptr);
}
fn fakeBE(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.orchestration(false) catch |err| c.atf_tc_fail("fake BE: %s", @errorName(err).ptr);
}
fn failedHints(_: [*c]const c.atf_tc_t) callconv(.c) void {
    install.orchestration(true) catch |err| c.atf_tc_fail("hints refusal: %s", @errorName(err).ptr);
}
fn guest(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    if (!c.atf_tc_has_config_var(tc, "install_fixture")) c.atf_tc_skip("requires a disposable guest commissioned for an install");
    install.guestInstall() catch |err| c.atf_tc_fail("guest install: %s", @errorName(err).ptr);
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "20");
    _ = c.atf_tc_set_md_var(tc, "require.user", "root");
    for ([_][]const u8{ "secondUpdateConfirms", "sealFoundAfterPromote" }) |name| {
        if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), name)) _ = c.atf_tc_set_md_var(tc, "timeout", "120");
    }
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), "seal_zfs")) {
        _ = c.atf_tc_set_md_var(tc, "timeout", "180");
        _ = c.atf_tc_set_md_var(tc, "require.config", "seal_fixture");
    }
    if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), "install_guest")) {
        _ = c.atf_tc_set_md_var(tc, "timeout", "120");
        _ = c.atf_tc_set_md_var(tc, "require.config", "install_fixture");
    }
}
fn lifecycleCase(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    const functions = .{ lifecycle.confirm, lifecycle.rollback, lifecycle.cancelStaged, lifecycle.refusals, lifecycle.goodBoot, lifecycle.settings, lifecycle.retention, lifecycle.efi, lifecycle.autoConfirm };
    inline for (functions, 0..) |function, i| {
        if (std.mem.eql(u8, name, std.mem.span(lifecycle_names[i]))) function() catch |err| c.atf_tc_fail("lifecycle: %s", @errorName(err).ptr);
    }
}
const lifecycle_names = [_][*:0]const u8{ "confirm", "rollback", "cancel_staged", "lifecycle_refusals", "good_boot", "confirmation_window", "retention", "efi_loader", "auto_confirm" };
fn directoryCase(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const functions = .{ install.declaredDirectories, install.systemEtc, install.directoryValidation, install.directoryMetadata };
    inline for (functions, directory_names) |function, name| {
        if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), std.mem.span(name))) function() catch |err| c.atf_tc_fail("directory/system paths: %s", @errorName(err).ptr);
    }
}
const directory_names = [_][*:0]const u8{ "declared_directories", "system_etc", "directory_validation", "directory_metadata" };
fn catalogCase(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const functions = .{ catalog.missing, catalog.fileURL, catalog.download, catalog.nonroot, catalog.published, catalog.cut, catalog.disagreements, catalog.config };
    inline for (functions, catalog_names) |function, name| {
        if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), std.mem.span(name))) function() catch |err| {
            if (err == error.SkipZigTest) c.atf_tc_skip("requires commissioned local publication/loopback fixtures");
            c.atf_tc_fail("catalog/download: %s", @errorName(err).ptr);
        };
    }
}
const catalog_names = [_][*:0]const u8{ "catalog_missing", "catalog_file_url", "download", "download_nonroot", "published_install", "cut_transfer", "download_mismatch", "catalog_config" };
fn sealCase(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const name = std.mem.span(c.atf_tc_get_ident(tc));
    if (std.mem.eql(u8, name, "seal_zfs")) {
        if (!c.atf_tc_has_config_var(tc, "seal_fixture")) c.atf_tc_skip("requires commissioned disposable guest ZFS fixtures");
        seal_guest.run() catch |err| c.atf_tc_fail("seal ZFS: %s", @errorName(err).ptr);
        return;
    }
    const functions = .{ seals.arguments, sealInstall, sealFailure, seals.comparison, seals.metadata };
    inline for (functions, 0..) |function, i| {
        if (std.mem.eql(u8, name, std.mem.span(seal_names[i]))) function() catch |err| c.atf_tc_fail("seal: %s", @errorName(err).ptr);
    }
}
fn sealInstall() !void {
    try seals.installation(false);
}
fn sealFailure() !void {
    try seals.installation(true);
}
const seal_names = [_][*:0]const u8{ "seal_arguments", "seal_install", "seal_failure", "seal_drift", "seal_metadata", "seal_zfs" };
fn mountCase(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const functions = .{ mounts.freebsdLayout, mounts.mountOnDeclared, mounts.acrossMount };
    inline for (functions, mount_names) |function, name| {
        if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), std.mem.span(name))) function() catch |err| c.atf_tc_fail("mounted directories: %s", @errorName(err).ptr);
    }
}
const mount_names = [_][*:0]const u8{ "preflightFreeBSDLayout", "preflightMountOnDeclared", "verifyAcrossMount" };
const lineage_names = [_][*:0]const u8{ "secondUpdateConfirms", "sealFoundAfterPromote", "failedActivateKeepsBoot", "failedConfirmRecorded" };
fn lineageCase(tc: [*c]const c.atf_tc_t) callconv(.c) void {
    const functions = .{ secondUpdateConfirms, sealFoundAfterPromote, lifecycle.failedActivateKeepsBoot, lifecycle.failedConfirmRecorded };
    inline for (functions, lineage_names) |function, name| {
        if (std.mem.eql(u8, std.mem.span(c.atf_tc_get_ident(tc)), std.mem.span(name))) function() catch |err| {
            if (err == error.SkipZigTest) c.atf_tc_skip("requires disposable guest ZFS pool: OP242_REAL_ZFS=1");
            c.atf_tc_fail("lineage: %s", @errorName(err).ptr);
        };
    }
}
fn secondUpdateConfirms() !void {
    try lineage.run(false);
}
fn sealFoundAfterPromote() !void {
    try lineage.run(true);
}
var cases: [48]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "arguments", "refusals", "list_local", "malformed_catalog", "status_fields", "not_implemented", "installed", "first_update", "second_update", "install_refusals", "unsafe_paths", "fake_bectl", "hints_failure", "install_guest" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ arguments, refusals, listing, malformed, status, disabled, installed, first, second, negative, unsafePaths, fakeBE, failedHints, guest };
    for (cases[0..14], names, bodies) |*tc, name, body| {
        var e = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(e)) return e;
    }
    for (cases[14..23], lifecycle_names) |*tc, name| {
        var err = c.atf_tc_init(tc, name, head, lifecycleCase, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    for (cases[23..27], directory_names) |*tc, name| {
        var err = c.atf_tc_init(tc, name, head, directoryCase, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    for (cases[27..35], catalog_names) |*tc, name| {
        var err = c.atf_tc_init(tc, name, head, catalogCase, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    for (cases[35..41], seal_names) |*tc, name| {
        var err = c.atf_tc_init(tc, name, head, sealCase, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    for (cases[41..44], mount_names) |*tc, name| {
        var err = c.atf_tc_init(tc, name, head, mountCase, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    for (cases[44..], lineage_names) |*tc, name| {
        var err = c.atf_tc_init(tc, name, head, lineageCase, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    _ = @import("update").c.setenv("OP242_TEST_HELPER", argv[0], 1);
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--op242-clean")) {
        lineage.clean() catch return 1;
        return 0;
    }
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--op242-bectl-fail")) {
        @import("update").write(2, "cannot promote newest: conflicting snapshot sealed\n") catch return 254;
        return 255;
    }
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--op198-zfs")) {
        seal_guest.run() catch |err| {
            @import("update").write(2, @errorName(err)) catch {};
            return 1;
        };
        return 0;
    }
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--op190-stage-restart")) {
        install.guestStageRestart() catch |err| {
            @import("update").write(2, @errorName(err)) catch {};
            return 1;
        };
        return 1;
    }
    if (argc == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--op190-verify-confirmed")) {
        install.guestVerifyConfirmed() catch |err| {
            @import("update").write(2, @errorName(err)) catch {};
            return 1;
        };
        return 0;
    }
    return atf_tp_main(argc, argv, add);
}
