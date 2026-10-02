// SPDX-License-Identifier: BSD-2-Clause
const f = @import("file_message.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/param.h");
    @cInclude("sys/module.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});
const Identity = extern struct { sender: [2]u32, audit: [8]u32 };
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach send trailer uses the sender's current credentials");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    var path: [4096]u8 = undefined;
    const length = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (length < 0 or length >= path.len) c.atf_tc_fail("fixture path too long");
    const module = c.kldload(&path);
    if (module < 0) c.atf_tc_fail("fixture load failed");
    defer _ = c.kldunload(module);
    const gid = c.getegid();
    if (c.setegid(4321) != 0 or c.seteuid(1234) != 0) c.atf_tc_fail("credential setup failed");
    var message = f.Header{ .bits = 0, .size = 24, .remote = 0, .local = 0, .voucher = 0, .id = 42601 };
    var address: u64 = @intFromPtr(&message);
    var observed: Identity = undefined;
    var size: usize = @sizeOf(Identity);
    const rc = c.sysctlbyname("debug.rmx_identity_observe", &observed, &size, &address, @sizeOf(u64));
    if (c.seteuid(0) != 0 or c.setegid(gid) != 0) c.atf_tc_fail("credential restore failed");
    if (rc != 0 or size != @sizeOf(Identity)) c.atf_tc_fail("send-trailer observation failed");
    _ = c.printf("send_identity expected_euid=1234 observed_sender_uid=%u observed_audit_euid=%u expected_egid=4321 observed_sender_gid=%u observed_audit_egid=%u expected_pid=%d observed_pid=%u\n", observed.sender[0], observed.audit[1], observed.sender[1], observed.audit[2], c.getpid(), observed.audit[5]);
    if (observed.sender[0] != 1234 or observed.sender[1] != 4321 or observed.audit[1] != 1234 or observed.audit[2] != 4321 or observed.audit[3] != c.getuid() or observed.audit[4] != c.getgid() or observed.audit[5] != c.getpid()) c.atf_tc_fail("Mach trailer used a stale identity");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) _ = c.kldunload(module);
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "live_credentials", &head, &body, &cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
