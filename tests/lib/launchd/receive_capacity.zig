// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("servers/bootstrap.h");
    @cInclude("stdio.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("syslog.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn vproc_mig_log(u32, c_int, c_int, [*:0]u8) c_int;
fn need(ok: bool, what: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", what);
}
fn logCapacity(_: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.alarm(8);
    var message: [2001:0]u8 = @splat('L');
    message[2000] = 0;
    const rc = vproc_mig_log(c.bootstrap_port, c.LOG_DEBUG, 0, &message);
    _ = c.printf("launchd_log message_bytes=2000 expected_rc=0 observed_rc=%d\n", rc);
    need(rc == 0, "PID 1 replies to 2000-byte MIG log request");
    _ = c.alarm(0);
}
fn bootstrapRoundtrip(_: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.alarm(8);
    var name: [128]u8 = @splat(0);
    _ = c.snprintf(&name, name.len, "org.rmxos.op746.%d", c.getpid());
    var port: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &port) == 0, "bootstrap receive right");
    need(c.mach_port_insert_right(c.mach_task_self(), port, port, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "bootstrap send right");
    const registered = c.bootstrap_register(c.bootstrap_port, &name, port);
    need(registered == 0, "unique bootstrap registration");
    var found: u32 = 0;
    const looked = c.bootstrap_look_up(c.bootstrap_port, &name, &found);
    _ = c.printf("bootstrap_roundtrip expected_register=0 observed_register=%d expected_lookup=0 observed_lookup=%d expected_name=%u observed_name=%u\n", registered, looked, port, found);
    need(looked == 0 and found == port, "PID 1 bootstrap register/lookup round trip");
    need(c.mach_port_deallocate(c.mach_task_self(), found) == 0, "lookup right release");
    need(c.mach_port_destroy(c.mach_task_self(), port) == 0, "bootstrap right cleanup");
    _ = c.alarm(0);
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "15");
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
}
var cases: [2]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (&cases, [_][*:0]const u8{ "log_2000", "bootstrap_roundtrip" }, [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &logCapacity, &bootstrapRoundtrip }) |*tc, name, body| {
        var err = c.atf_tc_init(tc, name, &head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
