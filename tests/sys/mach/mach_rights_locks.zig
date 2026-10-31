// SPDX-License-Identifier: BSD-2-Clause
// Fix plan B (op-309): rights and locks. One case per fix; each ends with the
// space's entry counts back at their start values.
const std = @import("std");
const fm = @import("file_message.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/notify.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/sysctl.h");
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const names = [_][*:0]const u8{ "reply_relock", "pset_seqno", "copy_send_dead", "task_self_interpose", "backup_keeps_send" };
var cases: [names.len]c.atf_tc_t = undefined;
const dead: u32 = 0xffffffff;
fn fact(name: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("rights_locks check=%s expected=%lld observed=%lld\n", name, @as(c_longlong, expected), @as(c_longlong, observed));
    if (expected != observed) c.atf_tc_fail("rights/locks observation differs");
}
fn task() u32 {
    return c.mach_task_self();
}
fn receiveRight() u32 {
    var port: u32 = 0;
    fact("allocate", 0, c.mach_port_allocate(task(), c.MACH_PORT_RIGHT_RECEIVE, &port));
    return port;
}
fn sendRight(port: u32) void {
    fact("make_send", 0, c.mach_port_insert_right(task(), port, port, c.MACH_MSG_TYPE_MAKE_SEND));
}
fn release(port: u32) void {
    fact("receive_release", 0, c.mach_port_mod_refs(task(), port, c.MACH_PORT_RIGHT_RECEIVE, -1));
}
fn kind(port: u32) i64 {
    var t: c.mach_port_type_t = 0;
    const kr = c.mach_port_type(task(), port, &t);
    return if (kr != 0) -@as(i64, kr) else @intCast(t);
}
const Stats = struct { buf: [192]u8 = @splat(0), len: usize = 0 };
fn stats() Stats {
    var s = Stats{};
    s.len = s.buf.len;
    if (c.sysctlbyname("mach.current_task_space_stats", &s.buf, &s.len, null, 0) != 0) c.atf_tc_fail("space stats unavailable");
    return s;
}
fn sameStats(before: Stats, after: Stats) void {
    _ = c.printf("rights_locks stats before=\"%s\" after=\"%s\"\n", &before.buf, &after.buf);
    if (c.strcmp(&before.buf, &after.buf) != 0) c.atf_tc_fail("space entry counts changed");
}

// 1. A send-once reply port destroyed while the receiver copies out the
// header. The receiver gets the right or a dead name, never an assertion.
var relock_dest: u32 = 0;
var relock_done: u32 = 0;
var relock_dead: u32 = 0;
var relock_live: u32 = 0;
var relock_bad: u32 = 0;
var relock_total: u32 = 0;
fn relockReceiver(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var i: u32 = 0;
    while (i < @atomicLoad(u32, &relock_total, .acquire)) : (i += 1) {
        var out: [256]u8 align(8) = @splat(0);
        const kr = c.mach_msg(@ptrCast(&out), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, out.len, relock_dest, 5000, 0);
        const h: *fm.Header = @ptrCast(&out);
        if (kr != 0 or h.local != relock_dest or h.id != 30901) {
            _ = @atomicRmw(u32, &relock_bad, .Add, 1, .acq_rel);
        } else if (h.remote == dead) {
            _ = @atomicRmw(u32, &relock_dead, .Add, 1, .acq_rel);
        } else if (h.remote != 0) {
            // A send-once right (or the dead name it became); give it back.
            if (c.mach_port_deallocate(task(), h.remote) != 0) _ = @atomicRmw(u32, &relock_bad, .Add, 1, .acq_rel);
            _ = @atomicRmw(u32, &relock_live, .Add, 1, .acq_rel);
        } else _ = @atomicRmw(u32, &relock_bad, .Add, 1, .acq_rel);
        @atomicStore(u32, &relock_done, i + 1, .release);
    }
    return null;
}
fn replyRelock() void {
    relock_dest = receiveRight();
    sendRight(relock_dest);
    const before = stats();
    const rounds: u32 = 20000;
    relock_done = 0;
    relock_dead = 0;
    relock_live = 0;
    relock_bad = 0;
    @atomicStore(u32, &relock_total, rounds, .release);
    var t: c.pthread_t = undefined;
    if (c.pthread_create(&t, null, &relockReceiver, null) != 0) c.atf_tc_fail("receiver setup failed");
    var i: u32 = 0;
    while (i < rounds) : (i += 1) {
        const reply = receiveRight();
        var msg = fm.Header{ .bits = c.MACH_MSG_TYPE_COPY_SEND | (c.MACH_MSG_TYPE_MAKE_SEND_ONCE << 8), .size = 24, .remote = relock_dest, .local = reply, .voucher = 0, .id = 30901 };
        fact("relock_send", 0, c.mach_msg(@ptrCast(&msg), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 24, 0, 0, 5000, 0));
        // Vary the gap so destruction lands before, inside and after copyout.
        var spin: u32 = i % 64;
        while (spin > 0) : (spin -= 1) std.atomic.spinLoopHint();
        release(reply);
        while (@atomicLoad(u32, &relock_done, .acquire) <= i) std.atomic.spinLoopHint();
    }
    if (c.pthread_join(t, null) != 0) c.atf_tc_fail("receiver join failed");
    _ = c.printf("rights_locks reply_relock rounds=%u dead=%u live=%u\n", rounds, relock_dead, relock_live);
    fact("relock_bad", 0, relock_bad);
    fact("relock_all_received", rounds, relock_dead + relock_live);
    if (relock_dead == 0) c.atf_tc_fail("receiver never saw a dead reply name");
    sameStats(before, stats());
    fact("relock_dest_send_release", 0, c.mach_port_mod_refs(task(), relock_dest, c.MACH_PORT_RIGHT_SEND, -1));
    release(relock_dest);
}

// 2. mach_port_set_seqno on a member of a port set releases the set's lock.
fn psetSeqno() void {
    const before = stats();
    const port = receiveRight();
    var set: u32 = 0;
    fact("pset_allocate", 0, c.mach_port_allocate(task(), c.MACH_PORT_RIGHT_PORT_SET, &set));
    fact("pset_member", 0, c.mach_port_move_member(task(), port, set));
    fact("seqno_first", 0, c.mach_port_set_seqno(task(), port, 5));
    fact("seqno_second", 0, c.mach_port_set_seqno(task(), port, 9));
    var status: c.mach_port_status_t = undefined;
    var count: c.mach_msg_type_number_t = c.MACH_PORT_RECEIVE_STATUS_COUNT;
    fact("seqno_status", 0, c.mach_port_get_attributes(task(), port, c.MACH_PORT_RECEIVE_STATUS, @ptrCast(&status), &count));
    fact("seqno_value", 9, status.mps_seqno);
    fact("pset_destroy", 0, c.mach_port_mod_refs(task(), set, c.MACH_PORT_RIGHT_PORT_SET, -1));
    fact("seqno_after_set", 0, c.mach_port_set_seqno(task(), port, 11));
    release(port);
    sameStats(before, stats());
}

// 3. COPY_SEND copyin of a send right whose port dies in another thread.
var cs_right: u32 = 0;
var cs_sink: u32 = 0;
var cs_sends: u32 = 0;
var cs_bad: u32 = 0;
const cs_per_thread: u32 = 400;
fn copyDescriptor(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var i: u32 = 0;
    while (i < cs_per_thread) : (i += 1) {
        var msg = fm.Message{ .header = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = 40, .remote = cs_sink, .local = 0, .voucher = 0, .id = 30903 }, .count = 1, .descriptor = .{ .name = cs_right, .pad = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND, .kind = c.MACH_MSG_PORT_DESCRIPTOR }, .trailer = [_]u8{0} ** 128 };
        const kr = c.mach_msg(@ptrCast(&msg), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 40, 0, 0, 0, 0);
        if (kr == c.MACH_SEND_TIMED_OUT) c.mach_msg_destroy(@ptrCast(&msg)) else if (kr != 0 and kr != c.MACH_SEND_INVALID_RIGHT) {
            _ = c.printf("rights_locks copy_send_dead descriptor kr=%#x\n", kr);
            _ = @atomicRmw(u32, &cs_bad, .Add, 1, .acq_rel);
        }
        _ = @atomicRmw(u32, &cs_sends, .Add, 1, .acq_rel);
    }
    return null;
}
fn copyDest(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var i: u32 = 0;
    while (i < cs_per_thread) : (i += 1) {
        var msg = fm.Header{ .bits = c.MACH_MSG_TYPE_COPY_SEND, .size = 24, .remote = cs_right, .local = 0, .voucher = 0, .id = 30904 };
        const kr = c.mach_msg(@ptrCast(&msg), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 24, 0, 0, 0, 0);
        if (kr == c.MACH_SEND_TIMED_OUT) c.mach_msg_destroy(@ptrCast(&msg)) else if (kr != 0 and kr != c.MACH_SEND_INVALID_DEST) {
            _ = c.printf("rights_locks copy_send_dead destination kr=%#x\n", kr);
            _ = @atomicRmw(u32, &cs_bad, .Add, 1, .acq_rel);
        }
        _ = @atomicRmw(u32, &cs_sends, .Add, 1, .acq_rel);
    }
    return null;
}
fn copySendDead() void {
    const before = stats();
    var round: u32 = 0;
    while (round < 300) : (round += 1) {
        cs_right = receiveRight();
        sendRight(cs_right);
        // Park the receive right in a message on carrier, so cs_right is a
        // pure send right that dies when carrier is destroyed.
        const carrier = receiveRight();
        sendRight(carrier);
        var park = fm.Message{ .header = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = 40, .remote = carrier, .local = 0, .voucher = 0, .id = 30902 }, .count = 1, .descriptor = .{ .name = cs_right, .pad = 0, .pad2 = 0, .disposition = c.MACH_MSG_TYPE_MOVE_RECEIVE, .kind = c.MACH_MSG_PORT_DESCRIPTOR }, .trailer = [_]u8{0} ** 128 };
        fact("park_receive", 0, c.mach_msg(@ptrCast(&park), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 40, 0, 0, 0, 0));
        fact("parked_send_only", c.MACH_PORT_TYPE_SEND, kind(cs_right));
        cs_sink = receiveRight();
        sendRight(cs_sink);
        cs_sends = 0;
        var threads: [3]c.pthread_t = undefined;
        if (c.pthread_create(&threads[0], null, &copyDescriptor, null) != 0) c.atf_tc_fail("worker setup failed");
        if (c.pthread_create(&threads[1], null, &copyDescriptor, null) != 0) c.atf_tc_fail("worker setup failed");
        if (c.pthread_create(&threads[2], null, &copyDest, null) != 0) c.atf_tc_fail("worker setup failed");
        while (@atomicLoad(u32, &cs_sends, .acquire) < 2 * (round % 32)) std.atomic.spinLoopHint();
        fact("carrier_send_release", 0, c.mach_port_mod_refs(task(), carrier, c.MACH_PORT_RIGHT_SEND, -1));
        release(carrier);
        for (threads) |t| if (c.pthread_join(t, null) != 0) c.atf_tc_fail("worker join failed");
        fact("dead_entry_type", c.MACH_PORT_TYPE_DEAD_NAME, kind(cs_right));
        var refs: c.mach_port_urefs_t = 0;
        fact("dead_entry_refs_call", 0, c.mach_port_get_refs(task(), cs_right, c.MACH_PORT_RIGHT_DEAD_NAME, &refs));
        fact("dead_entry_refs", 1, refs);
        fact("dead_entry_release", 0, c.mach_port_mod_refs(task(), cs_right, c.MACH_PORT_RIGHT_DEAD_NAME, -1));
        fact("sink_send_release", 0, c.mach_port_mod_refs(task(), cs_sink, c.MACH_PORT_RIGHT_SEND, -1));
        release(cs_sink);
    }
    fact("copy_send_bad", 0, cs_bad);
    sameStats(before, stats());
}

// 4. task_self_trap while another thread interposes the task's self port.
var ts_ports: [2]u32 = .{ 0, 0 };
var ts_stop: u32 = 0;
var ts_set_failed: u32 = 0;
fn interposer(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var i: u32 = 0;
    while (@atomicLoad(u32, &ts_stop, .acquire) == 0) : (i +%= 1) {
        const port = if (i % 3 == 2) task() else ts_ports[i % 3];
        if (c.task_set_special_port(task(), c.TASK_KERNEL_PORT, port) != 0) _ = @atomicRmw(u32, &ts_set_failed, .Add, 1, .acq_rel);
    }
    if (c.task_set_special_port(task(), c.TASK_KERNEL_PORT, task()) != 0) _ = @atomicRmw(u32, &ts_set_failed, .Add, 1, .acq_rel);
    return null;
}
fn taskSelfInterpose() void {
    ts_ports = .{ receiveRight(), receiveRight() };
    for (ts_ports) |p| sendRight(p);
    const before = stats();
    ts_stop = 0;
    ts_set_failed = 0;
    var t: c.pthread_t = undefined;
    if (c.pthread_create(&t, null, &interposer, null) != 0) c.atf_tc_fail("interposer setup failed");
    var seen = [_]u32{ 0, 0, 0 };
    var invalid: u32 = 0;
    var i: u32 = 0;
    while (i < 50000) : (i += 1) {
        const name: u32 = @bitCast(@as(i32, c.syscall(c.SYS_task_self_trap)));
        const k = kind(name);
        if (k < 0 or (k & c.MACH_PORT_TYPE_SEND) == 0 or c.mach_port_deallocate(task(), name) != 0) {
            if (invalid < 4) _ = c.printf("rights_locks task_self name=%#x type=%lld\n", name, @as(c_longlong, k));
            invalid += 1;
        } else if (name == ts_ports[0]) seen[0] += 1 else if (name == ts_ports[1]) seen[1] += 1 else if (name == task()) seen[2] += 1 else invalid += 1;
    }
    @atomicStore(u32, &ts_stop, 1, .release);
    if (c.pthread_join(t, null) != 0) c.atf_tc_fail("interposer join failed");
    _ = c.printf("rights_locks task_self a=%u b=%u self=%u\n", seen[0], seen[1], seen[2]);
    fact("task_self_invalid", 0, invalid);
    fact("task_self_set_failed", 0, ts_set_failed);
    const restored: u32 = @bitCast(@as(i32, c.syscall(c.SYS_task_self_trap)));
    fact("task_self_restored", task(), restored);
    fact("task_self_restored_release", 0, c.mach_port_deallocate(task(), restored));
    sameStats(before, stats());
    for (ts_ports) |p| {
        fact("interposed_send_release", 0, c.mach_port_mod_refs(task(), p, c.MACH_PORT_RIGHT_SEND, -1));
        release(p);
    }
}

// 5. Releasing a receive right that a port-destroyed request sends to a
// backup port keeps the caller's send right.
fn backupKeepsSend() void {
    const before = stats();
    const port = receiveRight();
    sendRight(port);
    const backup = receiveRight();
    var previous: u32 = 0;
    fact("pd_request", 0, c.mach_port_request_notification(task(), port, c.MACH_NOTIFY_PORT_DESTROYED, 0, backup, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous));
    fact("pd_previous", 0, previous);
    fact("receive_to_backup", 0, c.mach_port_mod_refs(task(), port, c.MACH_PORT_RIGHT_RECEIVE, -1));
    fact("send_kept_type", c.MACH_PORT_TYPE_SEND, kind(port));
    var refs: c.mach_port_urefs_t = 0;
    fact("send_kept_refs_call", 0, c.mach_port_get_refs(task(), port, c.MACH_PORT_RIGHT_SEND, &refs));
    fact("send_kept_refs", 1, refs);
    var msg: fm.Message = undefined;
    fact("backup_receive", 0, c.mach_msg(@ptrCast(&msg), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(fm.Message), backup, 2000, 0));
    fact("backup_selector", c.MACH_NOTIFY_PORT_DESTROYED, msg.header.id);
    fact("backup_descriptor_count", 1, msg.count);
    fact("backup_right_name", port, msg.descriptor.name);
    fact("backup_right_disposition", c.MACH_MSG_TYPE_PORT_RECEIVE, msg.descriptor.disposition);
    fact("rights_reunited", c.MACH_PORT_TYPE_SEND_RECEIVE, kind(port));
    fact("final_send_release", 0, c.mach_port_mod_refs(task(), port, c.MACH_PORT_RIGHT_SEND, -1));
    release(port);
    release(backup);
    sameStats(before, stats());
}

fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "120");
}
fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    _ = c.alarm(110);
    const name = std.mem.span(c.atf_tc_get_ident(t));
    if (std.mem.eql(u8, name, "reply_relock")) replyRelock() else if (std.mem.eql(u8, name, "pset_seqno")) psetSeqno() else if (std.mem.eql(u8, name, "copy_send_dead")) copySendDead() else if (std.mem.eql(u8, name, "task_self_interpose")) taskSelfInterpose() else backupKeepsSend();
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    for (names, 0..) |name, i| {
        var e = c.atf_tc_init(&cases[i], name, &head, &body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
