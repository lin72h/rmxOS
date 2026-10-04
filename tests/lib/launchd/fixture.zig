// SPDX-License-Identifier: BSD-2-Clause
// Test scheduling and observations in the real guest PID 1.
const std = @import("std");
const p = @import("protocol.zig");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/event.h");
    @cInclude("sys/stat.h");
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/notify.h");
    @cInclude("launch.h");
});
const Job = ?*anyopaque;
extern fn job_import(c.launch_data_t) Job;
extern fn job_remove(Job) void;
extern fn job_dispatch(Job, bool) Job;
extern fn job_find(Job, [*:0]const u8) Job;
extern var root_jobmgr: Job;
extern fn op484_first_service(Job) Job;
extern fn op484_service_port(Job) u32;
extern fn op484_job_pid(Job) c_int;
extern fn op484_job_runs(Job) u32;
extern fn op484_send_service(Job, [*:0]const u8, *u32) Job;
extern fn op484_demand_scan() void;
extern fn op484_request_size() u32;
extern fn runtime_add_mport(u32, ?*anyopaque) c_int;
extern fn launchd_mport_close_recv(u32) c_int;
extern fn do_mach_notify_dead_name(u32, u32) c_int;
extern fn kevent_mod(usize, i16, u16, u32, isize, ?*anyopaque) c_int;

const Drain = struct {
    port: u32 = 0,
    calls: u64 = 0,
    successes: u64 = 0,
    identifiers: [3]u32 = @splat(0),
    timeout: u64 = 0,
    limit: u64 = 0,
    allocations: u64 = 0,
    freed: u64 = 0,
    storage: [2]?*anyopaque = @splat(null),
    complete: u64 = 0,
    signal: u64 = 0,
    crashed: bool = false,
    first_error: c_int = 0,
};
var drains: [3]Drain = @splat(.{});
var active: ?usize = null;
var stale_job: Job = null;
var stale_port: u32 = 0;
var snapshot: u64 = 0;
var removed: u64 = 0;
var null_calls: u64 = 0;
var close_port: u32 = 0;
var detached: bool = false;
var close_order: u64 = 0;
var fixture_error: u32 = 0;
var listener: c_int = -1;
const Callback = *const fn (?*anyopaque, *c.struct_kevent) callconv(.c) void;
const Context = extern struct { callback: Callback };
var context = Context{ .callback = &serve };

fn errorIf(bad: bool, code: u32) void {
    if (bad and fixture_error == 0) fixture_error = code;
}
fn makeJob(label: [*:0]const u8, service: ?[*:0]const u8, crash: bool) Job {
    const dict = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY);
    errorIf(dict == null, 10);
    if (dict == null) return null;
    defer c.launch_data_free(dict);
    _ = c.launch_data_dict_insert(dict, c.launch_data_new_string(label), c.LAUNCH_JOBKEY_LABEL);
    _ = c.launch_data_dict_insert(dict, c.launch_data_new_string("/usr/tests/lib/launchd/launchd_consumer_test"), c.LAUNCH_JOBKEY_PROGRAM);
    const args = c.launch_data_alloc(c.LAUNCH_DATA_ARRAY);
    _ = c.launch_data_array_set_index(args, c.launch_data_new_string("/usr/tests/lib/launchd/launchd_consumer_test"), 0);
    _ = c.launch_data_array_set_index(args, c.launch_data_new_string("--crash-job"), 1);
    _ = c.launch_data_dict_insert(dict, args, c.LAUNCH_JOBKEY_PROGRAMARGUMENTS);
    if (crash) _ = c.launch_data_dict_insert(dict, c.launch_data_new_bool(true), c.LAUNCH_JOBKEY_LAUNCHONLYONCE);
    if (service) |name| {
        const services = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY);
        const options = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY);
        if (crash) _ = c.launch_data_dict_insert(options, c.launch_data_new_string("All"), c.LAUNCH_JOBKEY_MACH_DRAINMESSAGESONCRASH);
        _ = c.launch_data_dict_insert(services, options, name);
        _ = c.launch_data_dict_insert(dict, services, c.LAUNCH_JOBKEY_MACHSERVICES);
    }
    const job = job_import(dict);
    errorIf(job == null, 11);
    return job;
}
fn port() u32 {
    var name: u32 = 0;
    errorIf(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &name) != 0, 12);
    return name;
}
fn sendRight(name: u32) void {
    errorIf(c.mach_port_insert_right(c.mach_task_self(), name, name, c.MACH_MSG_TYPE_MAKE_SEND) != 0, 13);
}
fn refs(name: u32, kind: u32) u64 {
    var count: u32 = 0;
    errorIf(c.mach_port_get_refs(c.mach_task_self(), name, kind, &count) != 0, 14);
    return count;
}
fn queue(name: u32, id: u32, size: usize) void {
    var bytes: [65536]u8 align(8) = @splat(0);
    errorIf(size < @sizeOf(c.mach_msg_header_t) or size > bytes.len, 15);
    if (fixture_error != 0) return;
    const head: *c.mach_msg_header_t = @ptrCast(&bytes);
    head.msgh_bits = c.MACH_MSG_TYPE_MAKE_SEND;
    head.msgh_remote_port = name;
    head.msgh_id = @intCast(id);
    head.msgh_size = @intCast(size);
    errorIf(c.mach_msg(head, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, head.msgh_size, 0, 0, 0, 0) != 0, 16);
}
fn launchDrain(index: usize, label: [*:0]const u8, service: [*:0]const u8, kind: u32) void {
    const job = makeJob(label, service, true);
    if (job == null) return;
    const ms = op484_first_service(job);
    errorIf(ms == null, 17);
    if (ms == null) return;
    const name = op484_service_port(ms);
    drains[index] = .{ .port = name };
    if (kind == 0) {
        for (0..3) |i| queue(name, @intCast(48410 + i), 64);
    } else if (kind == 1) {
        // Directly remove this fixture's receive right; leave the real job's
        // service record for the crash drain to encounter an invalid name.
        errorIf(c.mach_port_mod_refs(c.mach_task_self(), name, c.MACH_PORT_RIGHT_RECEIVE, -1) != 0, 18);
    } else {
        queue(name, 48420, @as(usize, op484_request_size()) + 4096);
    }
    if (fixture_error == 0) errorIf(job_dispatch(job, true) == null, 19);
}
fn unique(d: Drain) u64 {
    var count: u64 = 0;
    for (d.identifiers, 0..) |id, i| {
        if (id == 0) continue;
        var duplicate = false;
        for (d.identifiers[0..i]) |earlier| duplicate = duplicate or earlier == id;
        if (!duplicate) count += 1;
    }
    return count;
}
fn demand(reply: *p.Reply) void {
    snapshot = 0;
    removed = 0;
    null_calls = 0;
    const unrelated = makeJob("org.rmx.op484.unrelated", "org.rmx.op484.unrelated.service", false);
    stale_job = makeJob("org.rmx.op484.removed", "org.rmx.op484.removed.service", false);
    if (fixture_error != 0) return;
    stale_port = op484_service_port(op484_first_service(stale_job));
    queue(stale_port, 48401, 64);
    if (fixture_error == 0) op484_demand_scan();
    reply.facts[0] = snapshot;
    reply.facts[1] = removed;
    reply.facts[2] = null_calls;
    reply.facts[3] = @as(u64, @intCast(op484_job_pid(unrelated))) + op484_job_runs(unrelated);
    // Exercise the shared close routine with a registered owned receive
    // right. This covers destruction order even when job_remove itself
    // has already called job_ignore before closing its service rights.
    close_port = port();
    detached = false;
    close_order = 0;
    errorIf(runtime_add_mport(close_port, null) != 0, 20);
    errorIf(launchd_mport_close_recv(close_port) != 0, 21);
    reply.facts[4] = close_order;
    close_port = 0;
    if (stale_job != null) {
        job_remove(stale_job);
        stale_job = null;
    }
    job_remove(unrelated);
}
fn lateDead(reply: *p.Reply) void {
    const unrelated = port();
    sendRight(unrelated);
    errorIf(c.mach_port_mod_refs(c.mach_task_self(), unrelated, c.MACH_PORT_RIGHT_SEND, 2) != 0, 22);
    reply.facts[4] = refs(unrelated, c.MACH_PORT_RIGHT_SEND);
    const job = makeJob("org.rmx.op484.dead", null, false);
    if (fixture_error != 0) return;
    var watched = port();
    sendRight(watched);
    // One send uref belongs to the job, one to this fixture.
    errorIf(c.mach_port_mod_refs(c.mach_task_self(), watched, c.MACH_PORT_RIGHT_SEND, 1) != 0, 23);
    errorIf(op484_send_service(job, "org.rmx.op484.dead.service", &watched) == null, 24);
    const notify = port();
    var previous: u32 = 0;
    errorIf(c.mach_port_request_notification(c.mach_task_self(), watched, c.MACH_NOTIFY_DEAD_NAME, 0, notify, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous) != 0 or previous != 0, 25);
    job_remove(job);
    reply.facts[0] = @intFromBool(job_find(root_jobmgr, "org.rmx.op484.dead") == null);
    errorIf(refs(watched, c.MACH_PORT_RIGHT_SEND) != 1, 26);
    errorIf(c.mach_port_mod_refs(c.mach_task_self(), watched, c.MACH_PORT_RIGHT_RECEIVE, -1) != 0, 27);
    var bytes: [512]u8 align(8) = @splat(0);
    const header: *c.mach_msg_header_t = @ptrCast(&bytes);
    errorIf(c.mach_msg(header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, notify, 0, 0) != 0, 28);
    const message: *c.mach_dead_name_notification_t = @ptrCast(&bytes);
    reply.facts[1] = @intFromBool(header.msgh_id == c.MACH_NOTIFY_DEAD_NAME and message.not_port == watched);
    reply.facts[2] = refs(watched, c.MACH_PORT_RIGHT_DEAD_NAME);
    if (fixture_error == 0) errorIf(do_mach_notify_dead_name(notify, message.not_port) != 0, 29);
    reply.facts[3] = refs(watched, c.MACH_PORT_RIGHT_DEAD_NAME);
    reply.facts[5] = refs(unrelated, c.MACH_PORT_RIGHT_SEND);
    _ = c.mach_port_deallocate(c.mach_task_self(), watched);
    _ = c.mach_port_destroy(c.mach_task_self(), notify);
    _ = c.mach_port_destroy(c.mach_task_self(), unrelated);
}
fn serve(_: ?*anyopaque, _: *c.struct_kevent) callconv(.c) void {
    const fd = c.accept(listener, null, null);
    if (fd < 0) return;
    defer _ = c.close(fd);
    var q: p.Request = undefined;
    if (c.recv(fd, &q, @sizeOf(p.Request), 0) != @sizeOf(p.Request) or q.magic != 0x48400001) return;
    fixture_error = 0;
    var reply = p.Reply{ .operation = q.operation, .pid = @intCast(c.getpid()) };
    const op = std.meta.intToEnum(p.Operation, q.operation) catch return;
    switch (op) {
        .demand_removed => demand(&reply),
        .late_dead_name => lateDead(&reply),
        .drain_start => launchDrain(0, "org.rmx.op484.drain", "org.rmx.op484.drain.service", 0),
        .terminal_start => {
            launchDrain(1, "org.rmx.op484.gone", "org.rmx.op484.gone.service", 1);
            launchDrain(2, "org.rmx.op484.large", "org.rmx.op484.large.service", 2);
        },
        .drain_observe => {
            const d = drains[0];
            reply.facts[0..12].* = .{ d.complete, d.successes, unique(d), d.timeout, d.limit, d.allocations, d.freed, d.signal, @intCast(d.first_error), d.identifiers[0], d.identifiers[1], d.identifiers[2] };
        },
        .terminal_observe => {
            const a = drains[1];
            const b = drains[2];
            reply.facts[0..10].* = .{ a.complete * b.complete, a.calls, b.calls, a.limit + b.limit, a.allocations + b.allocations, a.freed + b.freed, a.signal, b.signal, @intCast(a.first_error), @intCast(b.first_error) };
        },
    }
    reply.setup_error = fixture_error;
    _ = c.send(fd, &reply, @sizeOf(p.Reply), 0);
}
fn initialize(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    listener = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET, 0);
    if (listener < 0) return null;
    var address = std.mem.zeroes(c.sockaddr_un);
    address.sun_len = @sizeOf(c.sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(std.mem.asBytes(&address.sun_path)[0..p.socket_path.len], p.socket_path);
    for (0..600) |_| {
        _ = c.unlink(p.socket_path);
        if (c.bind(listener, @ptrCast(&address), @sizeOf(c.sockaddr_un)) == 0) break;
        _ = c.usleep(100_000);
    } else return null;
    _ = c.chmod(p.socket_path, 0o600);
    if (c.listen(listener, 4) != 0) return null;
    _ = kevent_mod(@intCast(listener), c.EVFILT_READ, c.EV_ADD, 0, 0, &context);
    return null;
}
pub export fn op484_init() void {
    if (c.getpid() != 1) return;
    var thread: c.pthread_t = undefined;
    if (c.pthread_create(&thread, null, &initialize, null) == 0) _ = c.pthread_detach(thread);
}
pub export fn op484_attributes(name: u32, result: c_int, count: u32) void {
    if (name != stale_port or result != 0 or count == 0 or stale_job == null) return;
    snapshot += 1;
    const job = stale_job;
    stale_job = null;
    stale_port = 0;
    job_remove(job);
    removed += 1;
}
pub export fn op484_invoke(job: ?*anyopaque, event: *c.struct_kevent) void {
    if (job == null) {
        null_calls += 1;
        return;
    }
    const callback: *const Callback = @ptrCast(@alignCast(job.?));
    callback.*(job, event);
}
pub export fn op484_drain_begin(name: u32, status: c_int, crashed: c_int) void {
    for (&drains, 0..) |*d, i| if (d.port == name and name != 0) {
        active = i;
        d.signal = @intCast(status & 0x7f);
        d.crashed = crashed != 0;
        return;
    };
}
pub export fn op484_drain_end(name: u32) void {
    if (active) |i| if (drains[i].port == name) {
        drains[i].complete = @intFromBool(drains[i].crashed);
        active = null;
    };
}
pub export fn op484_before_receive(options: u32, name: u32, _: u32) u32 {
    if ((options & c.MACH_RCV_MSG) == 0) return 0;
    if (active) |i| {
        const d = &drains[i];
        if (d.port != name) return 0;
        d.calls += 1;
        if (d.calls > 16) {
            d.limit += 1;
            return c.MACH_RCV_TIMED_OUT;
        }
    }
    return 0;
}
pub export fn op484_after_receive(header: *c.mach_msg_header_t, options: u32, name: u32, result: c_int) void {
    if ((options & c.MACH_RCV_MSG) == 0) return;
    if (active) |i| {
        const d = &drains[i];
        if (d.port != name) return;
        if (result == 0) {
            if (d.successes < d.identifiers.len) d.identifiers[@intCast(d.successes)] = @intCast(header.msgh_id);
            d.successes += 1;
        } else {
            if (d.first_error == 0) d.first_error = result;
            if (result == c.MACH_RCV_TIMED_OUT) d.timeout += 1;
        }
    }
}
pub export fn op484_allocation(ptr: ?*anyopaque, _: usize, _: usize) void {
    if (active) |i| {
        const d = &drains[i];
        if (d.allocations < d.storage.len) d.storage[@intCast(d.allocations)] = ptr;
        d.allocations += 1;
    }
}
pub export fn op484_free(ptr: ?*anyopaque) void {
    if (ptr == null) return;
    if (active) |i| for (&drains[i].storage) |*address| {
        if (address.* == ptr) {
            drains[i].freed += 1;
            address.* = null;
        }
    };
}
pub export fn op484_move(name: u32, set: u32, result: c_int) void {
    if (name == close_port and set == 0 and result == 0) detached = true;
}
pub export fn op484_close(name: u32, right: u32, delta: c_int) void {
    if (name == close_port and right == c.MACH_PORT_RIGHT_RECEIVE and delta == -1) close_order = @intFromBool(detached);
}
