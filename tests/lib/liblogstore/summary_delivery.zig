// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    // Zig 0.16 cannot translate the unused BSD bintime_shift inline.
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("stdlib.h");
});
extern fn rmx_summary_status() c_uint;
test "summary fails when the ASL client cannot send to logd" {
    try std.testing.expectEqual(@as(c_int, 0), c.setenv("ASL_DISABLE", "1", 1));
    try std.testing.expect(rmx_summary_status() != 0);
}
