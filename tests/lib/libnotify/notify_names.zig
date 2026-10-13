// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("notify.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Notify names across out-of-line page boundaries");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "60");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    for ([_]usize{ 4095, 4096, 4097, 8192 }) |length| {
        var storage: [8193]u8 = @splat('x');
        const prefix = c.snprintf(&storage, storage.len, "op672.%d.%zu.", c.getpid(), length);
        if (prefix <= 0) c.atf_tc_fail("name prefix");
        storage[@intCast(prefix)] = 'x';
        storage[length] = 0;
        var token: c_int = -1;
        var changed: c_int = 0;
        const registered = c.notify_register_check(&storage, &token);
        if (registered != c.NOTIFY_STATUS_OK) c.atf_tc_fail("register length=%zu status=%u", length, registered);
        if (c.notify_check(token, &changed) != c.NOTIFY_STATUS_OK) c.atf_tc_fail("initial check length=%zu", length);
        if (c.notify_post(&storage) != c.NOTIFY_STATUS_OK) c.atf_tc_fail("post length=%zu", length);
        var checks: usize = 0;
        while (checks < 2000) : (checks += 1) {
            if (c.notify_check(token, &changed) != c.NOTIFY_STATUS_OK) c.atf_tc_fail("check length=%zu", length);
            if (changed != 0) break;
            _ = c.usleep(1000);
        }
        if (changed == 0) c.atf_tc_fail("post not observed length=%zu", length);
        if (c.notify_check(token, &changed) != c.NOTIFY_STATUS_OK or changed != 0) c.atf_tc_fail("check did not clear length=%zu", length);
        if (c.notify_cancel(token) != c.NOTIFY_STATUS_OK) c.atf_tc_fail("cancel length=%zu", length);
        _ = c.printf("notify_names length=%zu register=0 post=0 check=0 delivered=1 cancel=0\n", length);
    }
}
var tc: c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "long_names", head, body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, add);
}
