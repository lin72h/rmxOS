// SPDX-License-Identifier: BSD-2-Clause
// macOS's CPU and workqueue sysctl names on rmxOS: each answers as a
// read-only int32 (CTLTYPE_INT, format "I") with a plausible value.
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("stdio.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;

const names = [_][*:0]const u8{
    "hw.activecpu",                    "hw.logicalcpu",      "hw.logicalcpu_max",
    "hw.physicalcpu",                  "hw.physicalcpu_max", "kern.wq_max_threads",
    "kern.wq_max_constrained_threads",
};

// The value, after checking its size, kind and format.
fn read(name: [*:0]const u8) i32 {
    var mib: [c.CTL_MAXNAME + 2]c_int = undefined;
    var miblen: usize = c.CTL_MAXNAME;
    if (c.sysctlnametomib(name, mib[2..].ptr, &miblen) != 0) c.atf_tc_fail("%s does not answer", name);
    // {0, 4, mib...} returns the node's kind (u_int) then its format string.
    mib[0] = 0;
    mib[1] = 4;
    var fmt: [64]u8 = undefined;
    var fmtlen: usize = fmt.len;
    if (c.sysctl(&mib, @intCast(miblen + 2), &fmt, &fmtlen, null, 0) != 0) c.atf_tc_fail("%s: no format", name);
    const kind = std.mem.readInt(u32, fmt[0..4], .little);
    const format = std.mem.sliceTo(fmt[4..fmtlen], 0);
    var value: i32 = 0;
    var size: usize = 8;
    var wide: [8]u8 = undefined;
    if (c.sysctlbyname(name, &wide, &size, null, 0) != 0) c.atf_tc_fail("%s: read failed", name);
    @memcpy(std.mem.asBytes(&value), wide[0..4]);
    _ = c.printf("macos_sysctl %s=%d size=%zu kind=0x%x format=%.*s\n", name, value, size, kind, @as(c_int, @intCast(format.len)), format.ptr);
    if (size != 4) c.atf_tc_fail("%s: size %zu, expected 4 (int32)", name, size);
    if ((kind & c.CTLTYPE) != c.CTLTYPE_INT or !std.mem.eql(u8, format, "I")) c.atf_tc_fail("%s: not CTLTYPE_INT \"I\"", name);
    if ((kind & c.CTLFLAG_WR) != 0) c.atf_tc_fail("%s: writable", name);
    return value;
}

fn macosSysctls(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var v: [names.len]i32 = undefined;
    for (names, 0..) |n, i| v[i] = read(n);
    var ncpu: c_int = 0;
    var size: usize = @sizeOf(c_int);
    if (c.sysctlbyname("hw.ncpu", &ncpu, &size, null, 0) != 0) c.atf_tc_fail("hw.ncpu");
    var threads: c_int = 1;
    size = @sizeOf(c_int);
    _ = c.sysctlbyname("kern.smp.threads_per_core", &threads, &size, null, 0);
    _ = c.printf("macos_sysctl hw.ncpu=%d kern.smp.threads_per_core=%d\n", ncpu, threads);
    _ = c.fflush(null);
    if (v[0] != ncpu) c.atf_tc_fail("hw.activecpu %d != hw.ncpu %d", v[0], ncpu);
    if (v[1] != ncpu) c.atf_tc_fail("hw.logicalcpu %d != hw.ncpu %d", v[1], ncpu);
    if (v[2] < v[1]) c.atf_tc_fail("hw.logicalcpu_max %d < hw.logicalcpu %d", v[2], v[1]);
    if (v[3] < 1 or v[3] > v[1]) c.atf_tc_fail("hw.physicalcpu %d not in 1..logicalcpu", v[3]);
    if (v[4] < v[3] or v[4] * @max(1, threads) < v[1]) c.atf_tc_fail("hw.physicalcpu_max %d implausible", v[4]);
    if (v[6] <= 0 or v[5] < v[6]) c.atf_tc_fail("kern.wq_max_threads %d / wq_max_constrained_threads %d implausible", v[5], v[6]);
}

var case: c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "10");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&case, "macosSysctls", &head, &macosSysctls, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &case);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
