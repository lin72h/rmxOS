// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/event.h");
    @cInclude("sys/syscall.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("sys/param.h");
    @cInclude("sys/module.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/sysctl.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
const Message = extern struct { header: Header, payload: [64]u8 };
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "BSD proc info accepts an exiting process with a NULL descriptor table");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
const Observation = extern struct { result: c_int, owned: c_int };
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    var dummy: u32 = 0;
    var path: [4096]u8 = undefined;
    const length = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    if (length < 0 or length >= path.len) c.atf_tc_fail("module path too long");
    const module = c.kldload(&path);
    if (module < 0) c.atf_tc_fail("test fixture module load failed");
    defer _ = c.kldunload(module);
    var observed: Observation = undefined;
    var size: usize = @sizeOf(Observation);
    const rc = c.sysctlbyname("debug.rmx_proc_observe", &observed, &size, &dummy, @sizeOf(u32));
    if (rc != 0 or size != @sizeOf(Observation)) c.atf_tc_fail("fixture observation failed result=%d", rc);
    _ = c.printf("translate expected_result=0 observed_result=%d expected_nfiles=0 observed_nfiles=%d\n", observed.result, observed.owned);
    if (observed.result != 0 or observed.owned != 0) c.atf_tc_fail("NULL descriptor table did not yield zero files");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "null_fd", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
