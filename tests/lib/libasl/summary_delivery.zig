// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
extern fn rmx_summary_status() c_uint;
test "summary fails when the ASL client cannot send to asld" {
    try std.testing.expectEqual(@as(c_int, 0), c.setenv("ASL_DISABLE", "1", 1));
    try std.testing.expect(rmx_summary_status() != 0);
}
