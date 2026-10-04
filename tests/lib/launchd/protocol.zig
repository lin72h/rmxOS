// SPDX-License-Identifier: BSD-2-Clause
// A fixed-size local control protocol, shared by the guest client and PID 1.
pub const socket_path = "/op484-launchd.sock";
pub const Request = extern struct {
    magic: u32 = 0x48400001,
    operation: u32,
};
pub const Operation = enum(u32) {
    demand_removed = 1,
    drain_start = 2,
    drain_observe = 3,
    terminal_start = 4,
    terminal_observe = 5,
    late_dead_name = 6,
};
pub const Reply = extern struct {
    magic: u32 = 0x48400002,
    operation: u32 = 0,
    pid: u32 = 0,
    setup_error: u32 = 0,
    facts: [32]u64 = @splat(0),
};
