// SPDX-License-Identifier: BSD-2-Clause
// mach.ko reports the INVARIANTS and WITNESS options it was compiled with;
// each must equal the running kernel's, so the module's assertions and lock
// checks are in effect exactly when the kernel's are.
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn __error() *c_int;
var tc: c.atf_tc_t = undefined;
// A kern.features entry exists only when the kernel has the option.
fn feature(name: [*:0]const u8) c_int {
    var value: c_int = 0;
    var size: usize = @sizeOf(c_int);
    if (c.sysctlbyname(name, &value, &size, null, 0) != 0) {
        const err = __error().*;
        if (err != c.ENOENT) c.atf_tc_fail("%s read failed errno=%d", name, err);
        return 0;
    }
    if (size != @sizeOf(c_int)) c.atf_tc_fail("%s returned size=%zu", name, size);
    return value;
}
fn report(name: [*:0]const u8) c_int {
    var value: c_int = -1;
    var size: usize = @sizeOf(c_int);
    if (c.sysctlbyname(name, &value, &size, null, 0) != 0) c.atf_tc_fail("%s read failed errno=%d", name, __error().*);
    if (size != @sizeOf(c_int)) c.atf_tc_fail("%s returned size=%zu", name, size);
    const other: c_int = 1 - value;
    const rc = c.sysctlbyname(name, null, null, &other, @sizeOf(c_int));
    const err = __error().*;
    _ = c.printf("%s write expected_rc=-1 observed_rc=%d expected_errno=%d observed_errno=%d\n", name, rc, c.EPERM, err);
    if (rc != -1 or err != c.EPERM) c.atf_tc_fail("%s accepted a write", name);
    return value;
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const kernel_invariants = feature("kern.features.invariants");
    const kernel_witness = feature("kern.features.witness");
    const module_invariants = report("kern.mach.build_invariants");
    const module_witness = report("kern.mach.build_witness");
    _ = c.printf("build_options expected_invariants=%d observed_invariants=%d expected_witness=%d observed_witness=%d\n", kernel_invariants, module_invariants, kernel_witness, module_witness);
    if (module_invariants != kernel_invariants) c.atf_tc_fail("mach.ko INVARIANTS=%d kernel=%d", module_invariants, kernel_invariants);
    if (module_witness != kernel_witness) c.atf_tc_fail("mach.ko WITNESS=%d kernel=%d", module_witness, kernel_witness);
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "mach.ko is compiled with the kernel's INVARIANTS and WITNESS");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    var e = c.atf_tc_init(&tc, "kernel_options", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(e)) return e;
    e = c.atf_tp_add_tc(tp, &tc);
    return e;
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
