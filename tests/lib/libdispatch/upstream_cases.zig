// id-151: upstream swift-6.4.0-RELEASE tests/CMakeLists.txt, extended suite enabled.
// Excluded: dispatch_thread_name (macOS workers are unnamed), cffd and
// dispatch_cf_main (no CoreFoundation), dispatch_deadname (idle worker lifetime).
pub const names = [_][:0]const u8{
    "dispatch_apply",       "dispatch_api",             "dispatch_debug",         "dispatch_queue_finalizer",
    "dispatch_overcommit",  "dispatch_context_for_key", "dispatch_after",         "dispatch_timer",
    "dispatch_timer_short", "dispatch_timer_timeout",   "dispatch_sema",          "dispatch_timer_bit31",
    "dispatch_timer_bit63", "dispatch_timer_set_time",  "dispatch_data",          "dispatch_io_muxed",
    "dispatch_io_net",      "dispatch_io_pipe",         "dispatch_io_pipe_close", "dispatch_select",
    "dispatch_priority",    "dispatch_concur",          "dispatch_group",         "dispatch_read",
    "dispatch_read2",       "dispatch_starfish",        "dispatch_suspend_timer", "dispatch_pingpong",
    "dispatch_drift",       "dispatch_readsync",        "dispatch_cascade",       "dispatch_io",
    "dispatch_priority2",   "dispatch_proc",            "dispatch_vm",            "dispatch_vnode",
    "dispatch_c99",         "dispatch_plusplus",        "dispatch_workqueue",
};
pub fn retries(name: []const u8) bool {
    const std = @import("std");
    for (names[20..33]) |item| if (std.mem.eql(u8, name, item)) return true;
    return false;
}
