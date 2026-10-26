const std = @import("std");
pub fn ready(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "logd: compatibility service ready") != null and
        std.mem.indexOf(u8, text, "logd socket not ready") == null;
}
test "ready boot and late-start refusal" {
    try std.testing.expect(ready("logd: compatibility service ready pid=12 socket=/var/run/log\n"));
    try std.testing.expect(!ready(""));
    try std.testing.expect(!ready("WARNING: logd socket not ready after 30 seconds\n"));
    try std.testing.expect(!ready("WARNING: logd socket not ready after 30 seconds\nlogd: compatibility service ready pid=12\n"));
}
