// SPDX-License-Identifier: BSD-2-Clause
// sendOnceDescriptorNotify (op-757): a send-once right made from this
// process's receive right travels in a body port descriptor
// (MACH_MSG_TYPE_MAKE_SEND_ONCE, sys/compat/mach/ipc/ipc_kmsg.c) to another
// process, which drops it unused: in one form it exits holding the right,
// in the other it deallocates it and stays alive. Each time the kernel must
// send exactly one MACH_NOTIFY_SEND_ONCE (msgh_id 71) to the port the right
// names. libxpc's reply rights rest on this; the case uses no libxpc.
//
// The child is reached as mach_child_setters.zig reaches it: the bootstrap
// special port is set to a channel port before fork, the child reads it with
// task_get_special_port and sends the parent a send right to a port of its
// own, on which it then receives the send-once right.
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/notify.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;

const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
const Descriptor = extern struct { name: u32, pad: u32, pad2: u16, disposition: u8, kind: u8 };
// One port descriptor; the receive buffer leaves room for any trailer.
const Message = extern struct { header: Header, count: u32, descriptor: Descriptor, trailer: [128]u8 };
const COMPLEX: u32 = 0x80000000;
const LIMIT_MS: u64 = 2000;

var failed = false;
fn fact(form: [*:0]const u8, label: [*:0]const u8, expected: i64, observed: i64) void {
    _ = c.printf("mach_send_once form=%s fact=%s expected=%lld observed=%lld\n", form, label, @as(c_longlong, expected), @as(c_longlong, observed));
    _ = c.fflush(null);
    if (expected != observed) failed = true;
}
fn setup(ok: bool, what: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("setup: %s", what);
}
fn nowMs() u64 {
    var t: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    return @as(u64, @intCast(t.tv_sec)) * 1000 + @as(u64, @intCast(t.tv_nsec)) / 1_000_000;
}
fn receivePort() u32 {
    var p: u32 = 0;
    setup(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) == 0, "receive right");
    return p;
}
fn receive(port: u32, msg: *Message, ms: u32) c_int {
    msg.* = std.mem.zeroes(Message);
    return c.mach_msg(@ptrCast(msg), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Message), port, ms, 0);
}
// A complex message to dest with one port descriptor: name by disposition.
fn sendPort(dest: u32, name: u32, disposition: u8, id: i32) c_int {
    var m = std.mem.zeroes(Message);
    m.header = .{ .bits = COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = @offsetOf(Message, "trailer"), .remote = dest, .local = 0, .voucher = 0, .id = id };
    m.count = 1;
    m.descriptor = .{ .name = name, .pad = 0, .pad2 = 0, .disposition = disposition, .kind = c.MACH_MSG_PORT_DESCRIPTOR };
    return c.mach_msg(@ptrCast(&m), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, m.header.size, 0, 0, 1000, 0);
}

// The child: give the parent a send right to its own port, receive the
// send-once right there, then exit holding it ('x'), or deallocate it, say
// so on the pipe and wait for the parent's word before exiting ('d').
fn child(mode: u8, report: c_int, command: c_int) noreturn {
    _ = c.alarm(10);
    var bootstrap: u32 = 0;
    if (c.task_get_special_port(c.mach_task_self(), c.TASK_BOOTSTRAP_PORT, &bootstrap) != 0) c._exit(90);
    var own: u32 = 0;
    if (c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &own) != 0) c._exit(91);
    if (sendPort(bootstrap, own, c.MACH_MSG_TYPE_MAKE_SEND, 757) != 0) c._exit(92);
    var m: Message = undefined;
    if (receive(own, &m, 5000) != 0) c._exit(93);
    if ((m.header.bits & COMPLEX) == 0 or m.count != 1 or m.descriptor.kind != c.MACH_MSG_PORT_DESCRIPTOR or
        m.descriptor.disposition != c.MACH_MSG_TYPE_PORT_SEND_ONCE or m.descriptor.name == 0) c._exit(94);
    const sonce = m.descriptor.name;
    if (mode == 'x') c._exit(0);
    if (c.mach_port_deallocate(c.mach_task_self(), sonce) != 0) c._exit(95);
    var b: u8 = 'd';
    if (c.write(report, &b, 1) != 1) c._exit(96);
    var cmd: u8 = 0;
    if (c.read(command, &cmd, 1) != 1) c._exit(97);
    c._exit(0);
}

fn runForm(name: [*:0]const u8, mode: u8) void {
    const task = c.mach_task_self();
    const notify = receivePort();
    const channel = receivePort();
    setup(c.mach_port_insert_right(task, channel, channel, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "channel send right");
    var saved: u32 = 0;
    setup(c.task_get_special_port(task, c.TASK_BOOTSTRAP_PORT, &saved) == 0, "bootstrap save");
    setup(c.task_set_special_port(task, c.TASK_BOOTSTRAP_PORT, channel) == 0, "bootstrap set");
    var report: [2]c_int = undefined;
    var command: [2]c_int = undefined;
    setup(c.pipe(&report) == 0 and c.pipe(&command) == 0, "pipes");
    const pid = c.fork();
    setup(pid >= 0, "fork");
    if (pid == 0) {
        _ = c.close(report[0]);
        _ = c.close(command[1]);
        child(mode, report[1], command[0]);
    }
    _ = c.close(report[1]);
    _ = c.close(command[0]);
    setup(c.task_set_special_port(task, c.TASK_BOOTSTRAP_PORT, saved) == 0, "bootstrap restore");
    var m: Message = undefined;
    const got_child = receive(channel, &m, 3000);
    fact(name, "child_port_received", 0, got_child);
    if (got_child != 0) {
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
        c.atf_tc_fail("%s: no port from the child", name);
    }
    const other = m.descriptor.name;
    fact(name, "send_once_sent", 0, sendPort(other, notify, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, 758));
    const t0 = nowMs();
    var alive_at_notice: i64 = -1;
    if (mode == 'd') {
        // The child is alive until told: the notice must come from its
        // deallocation, not from its exit.
        var ready = c.struct_pollfd{ .fd = report[0], .events = c.POLLIN, .revents = 0 };
        var b: u8 = 0;
        const said = c.poll(&ready, 1, 3000) == 1 and c.read(report[0], &b, 1) == 1 and b == 'd';
        fact(name, "child_deallocated", 1, @intFromBool(said));
    }
    const first = receive(notify, &m, @intCast(LIMIT_MS));
    const elapsed = nowMs() - t0;
    if (mode == 'd') alive_at_notice = @intFromBool(c.waitpid(pid, null, c.WNOHANG) == 0);
    _ = c.printf("mach_send_once form=%s first_rc=0x%x msgh_id=%d bits=0x%x size=%u elapsed_ms=%llu limit_ms=%llu\n", name, @as(c_uint, @bitCast(first)), m.header.id, m.header.bits, m.header.size, elapsed, LIMIT_MS);
    fact(name, "notice_received", 0, first);
    fact(name, "notice_msgh_id", c.MACH_NOTIFY_SEND_ONCE, if (first == 0) m.header.id else -1);
    fact(name, "notice_within_limit", 1, @intFromBool(first == 0 and elapsed <= LIMIT_MS));
    if (mode == 'd') fact(name, "child_alive_at_notice", 1, alive_at_notice);
    var cmd: u8 = 'x';
    if (mode == 'd') _ = c.write(command[1], &cmd, 1);
    var status: c_int = -1;
    const reaped = c.waitpid(pid, &status, 0);
    fact(name, "child_reaped", pid, reaped);
    fact(name, "child_status", 0, status);
    // One right, one notice.
    fact(name, "second_message", c.MACH_RCV_TIMED_OUT, receive(notify, &m, 200));
    _ = c.close(report[0]);
    _ = c.close(command[1]);
    _ = c.mach_port_deallocate(task, other);
    _ = c.mach_port_mod_refs(task, notify, c.MACH_PORT_RIGHT_RECEIVE, -1);
    _ = c.mach_port_mod_refs(task, channel, c.MACH_PORT_RIGHT_RECEIVE, -1);
    _ = c.mach_port_deallocate(task, channel);
    if (saved != 0) _ = c.mach_port_deallocate(task, saved);
}

fn sendOnceDescriptorNotify(_: [*c]const c.atf_tc_t) callconv(.c) void {
    runForm("exit", 'x');
    runForm("deallocate", 'd');
    if (failed) c.atf_tc_fail("a send-once observation differs from its expected value");
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
var cases: [1]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    var e = c.atf_tc_init(&cases[0], "sendOnceDescriptorNotify", &head, &sendOnceDescriptorNotify, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(e)) return e;
    e = c.atf_tp_add_tc(tp, &cases[0]);
    if (c.atf_is_error(e)) return e;
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
