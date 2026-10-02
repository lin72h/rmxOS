// SPDX-License-Identifier: BSD-2-Clause
// Freestanding kernel probe: report facts; the ATF program validates them.
extern fn rmx_fixture_space() ?*anyopaque;
extern fn rmx_fixture_entry(u32) ?*anyopaque;
extern fn rmx_fixture_entry_locked(u32) ?*anyopaque;
extern fn rmx_fixture_object(*anyopaque) ?*anyopaque;
extern fn rmx_fixture_owned(*anyopaque) c_int;
extern fn rmx_fixture_unlock(*anyopaque) void;
extern fn ipc_object_translate(?*anyopaque, u32, u32, *?*anyopaque) c_int;
const Observation = extern struct { result: c_int, owned: c_int };
extern fn rmx_fixture_task() *anyopaque;
extern fn rmx_fixture_control_port(c_int) *anyopaque;
extern fn rmx_fixture_port_active(*anyopaque) c_int;
extern fn rmx_fixture_send_count(*anyopaque) u32;
extern fn rmx_fixture_alloc_kernel() ?*anyopaque;
extern fn rmx_fixture_dealloc_kernel(*anyopaque) void;
extern fn ipc_port_make_send(*anyopaque) ?*anyopaque;
extern fn rmx_fixture_port_hold(*anyopaque) void;
extern fn rmx_fixture_port_drop(*anyopaque) void;
extern fn task_set_special_port(*anyopaque, c_int, ?*anyopaque) c_int;
var watched_control: ?*anyopaque = null;
var watched_bootstrap: ?*anyopaque = null;
var watched_space: ?*anyopaque = null;
extern fn rmx_fixture_bootstrap() ?*anyopaque;
extern fn ipc_space_reference(*anyopaque) void;
extern fn ipc_space_release(*anyopaque) void;
export fn rmx_lifetime_clear() void {
    if (watched_space) |space| ipc_space_release(space);
    watched_space = null;
    if (watched_control) |port| rmx_fixture_port_drop(port);
    watched_control = null;
    if (watched_bootstrap) |port| rmx_fixture_dealloc_kernel(port);
    watched_bootstrap = null;
}
// ATF serializes commands: observe a real control port or bootstrap send count.
export fn rmx_lifetime_observe(command: u32, out: *Observation) c_int {
    out.* = .{ .result = 0, .owned = 0 };
    switch (command) {
        1 => {
            watched_bootstrap = rmx_fixture_alloc_kernel() orelse return 12;
            out.result = task_set_special_port(rmx_fixture_task(), 4, ipc_port_make_send(watched_bootstrap.?));
        },
        2 => out.owned = @intCast(rmx_fixture_send_count(watched_bootstrap orelse return 22)),
        3, 6 => {
            if (watched_control != null) return 16;
            watched_control = rmx_fixture_control_port(if (command == 6) 1 else 0);
            rmx_fixture_port_hold(watched_control.?);
            out.owned = rmx_fixture_port_active(watched_control.?);
        },
        4 => out.owned = rmx_fixture_port_active(watched_control orelse return 22),
        5 => rmx_lifetime_clear(),
        8 => {
            watched_space = rmx_fixture_space();
            ipc_space_reference(watched_space.?);
        },
        9 => {
            out.result = @intFromBool(rmx_fixture_space() != watched_space);
            out.owned = @intFromBool(rmx_fixture_bootstrap() == watched_bootstrap and watched_bootstrap != null and rmx_fixture_port_active(watched_bootstrap.?) == 1);
        },
        else => return 22,
    }
    return 0;
}
const Identity = extern struct { sender: [2]u32, audit: [8]u32 };
const Trailer = extern struct { kind: u32, size: u32, seqno: u32, sender: [2]u32, audit: [8]u32 };
extern fn ipc_kmsg_get(*anyopaque, u32, *?*anyopaque, ?*anyopaque) c_int;
extern fn ipc_kmsg_free(*anyopaque) void;
extern fn rmx_fixture_message_trailer(*anyopaque) *anyopaque;
export fn rmx_identity_observe(address: u64, out: *Identity) c_int {
    var message: ?*anyopaque = null;
    const result = ipc_kmsg_get(@ptrFromInt(address), 24, &message, rmx_fixture_space());
    if (result != 0) return 22;
    const kmsg = message orelse return 12;
    defer ipc_kmsg_free(kmsg);
    const trailer: *const Trailer = @ptrCast(@alignCast(rmx_fixture_message_trailer(kmsg)));
    out.sender = trailer.sender;
    out.audit = trailer.audit;
    return 0;
}
const EntryControl = extern struct { name: u32, flags: u64 };
extern fn rmx_fixture_space_lock(*anyopaque) void;
extern fn rmx_fixture_space_unlock(*anyopaque) void;
extern fn rmx_fixture_uptime() i64;
extern fn copyin(*const anyopaque, *anyopaque, usize) c_int;
extern fn copyout(*const anyopaque, *anyopaque, usize) c_int;
export fn rmx_entry_lock_observe(control: *const EntryControl, out: *Observation) c_int {
    const space = rmx_fixture_space() orelse return 22;
    rmx_fixture_space_lock(space);
    defer rmx_fixture_space_unlock(space);
    const entry = rmx_fixture_entry_locked(control.name);
    out.owned = if (entry != null) 1 else 0;
    const go: u32 = 1;
    var error_code = copyout(&go, @ptrFromInt(control.flags), @sizeOf(u32));
    if (error_code != 0) return error_code;
    const worker_deadline = rmx_fixture_uptime() + (@as(i64, 2) << 32);
    var attempted: u32 = 0;
    while (attempted == 0 and rmx_fixture_uptime() < worker_deadline) {
        error_code = copyin(@ptrFromInt(control.flags + @sizeOf(u32)), &attempted, @sizeOf(u32));
        if (error_code != 0) return error_code;
    }
    if (attempted != 1) return 11;
    const deadline = rmx_fixture_uptime() + (@as(i64, 2) << 32);
    var closed: u32 = 0;
    while (rmx_fixture_uptime() < deadline) {
        error_code = copyin(@ptrFromInt(control.flags + 2 * @sizeOf(u32)), &closed, @sizeOf(u32));
        if (error_code != 0) return error_code;
        if (closed != 0) break;
    }
    out.result = @intCast(closed);
    return 0;
}
extern fn rmx_fixture_file_hold(u32, *?*anyopaque) c_int;
extern fn rmx_fixture_file_drop(*anyopaque) void;
extern fn rmx_fixture_get_urefs(u32, *u32) c_int;
export fn rmx_urefs_observe(name: u32, out: *Observation) c_int {
    var file: ?*anyopaque = null;
    const result = rmx_fixture_file_hold(name, &file);
    if (result != 0) return result;
    const held = file orelse return 9;
    defer rmx_fixture_file_drop(held);
    var urefs: u32 = 0;
    out.result = rmx_fixture_get_urefs(name, &urefs);
    out.owned = @intCast(urefs);
    return 0;
}
extern fn rmx_fixture_malloc_type() *anyopaque;
extern fn malloc(usize, *anyopaque, c_int) ?*anyopaque;
extern fn free(*anyopaque, *anyopaque) void;
extern fn rmx_fixture_proc_size() usize;
extern fn rmx_fixture_bsdinfo_size() usize;
extern fn rmx_fixture_proc_copy(*anyopaque) void;
extern fn rmx_fixture_proc_set_fd(*anyopaque, ?*anyopaque) void;
extern fn rmx_fixture_proc_set_group(*anyopaque, ?*anyopaque) void;
extern fn rmx_fixture_nfiles(*anyopaque) c_int;
extern fn proc_pidbsdinfo(*anyopaque, *anyopaque, c_int) c_int;
extern fn rmx_fixture_thread() *anyopaque;
extern fn rmx_fixture_timeout(*anyopaque) u32;
extern fn rmx_fixture_set_timeout(*anyopaque, u32) void;
extern fn thread_will_wait_with_timeout(*anyopaque, u32) void;
export fn rmx_timeout_observe(milliseconds: u32, out: *Observation) c_int {
    const thread = rmx_fixture_thread();
    const saved = rmx_fixture_timeout(thread);
    defer rmx_fixture_set_timeout(thread, saved);
    thread_will_wait_with_timeout(thread, milliseconds);
    out.result = 0;
    out.owned = @intCast(rmx_fixture_timeout(thread));
    return 0;
}
export fn rmx_proc_observe(_: u32, out: *Observation) c_int {
    const allocator = rmx_fixture_malloc_type();
    const snapshot = malloc(rmx_fixture_proc_size(), allocator, 2) orelse return 12;
    defer free(snapshot, allocator);
    const info = malloc(rmx_fixture_bsdinfo_size(), allocator, 2) orelse return 12;
    defer free(info, allocator);
    rmx_fixture_proc_copy(snapshot);
    rmx_fixture_proc_set_fd(snapshot, null);
    rmx_fixture_proc_set_group(snapshot, null);
    out.result = proc_pidbsdinfo(snapshot, info, 0);
    out.owned = rmx_fixture_nfiles(info);
    return 0;
}
export fn rmx_translate_observe(name: u32, out: *Observation) c_int {
    const entry = rmx_fixture_entry(name) orelse return 2;
    var object = rmx_fixture_object(entry) orelse return 2;
    // Deliberately exercise the equality condition without undefined test data.
    var output: ?*anyopaque = object;
    out.result = ipc_object_translate(rmx_fixture_space(), name, 1, &output);
    out.owned = 0;
    if (out.result == 0) {
        object = output orelse return 2;
        out.owned = rmx_fixture_owned(object);
        if (out.owned != 0) rmx_fixture_unlock(object);
    }
    return 0;
}
