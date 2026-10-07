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
            out.owned = portActive(watched_control.?);
        },
        4 => out.owned = portActive(watched_control orelse return 22),
        5 => rmx_lifetime_clear(),

        10 => return observeEmptyProc(out),
        11 => return observeParkedReply(out),
        12 => {
            // Negative-control cleanup only: do not let batch-2 exit loop
            // on names that are no longer in the current descriptor table.
            const space = watched_space orelse return 22;
            while (rmx_fixture_first_file(space)) |file| {
                rmx_fixture_file_revoke(file);
                rmx_fixture_file_drop(file);
            }
        },

        8 => {
            watched_space = rmx_fixture_space();
            ipc_space_reference(watched_space.?);
        },
        9 => {
            out.result = @intFromBool(rmx_fixture_space() != watched_space);
            out.owned = @intFromBool(rmx_fixture_bootstrap() == watched_bootstrap and watched_bootstrap != null and portActive(watched_bootstrap.?) == 1);
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

extern fn rmx_fixture_proc_empty(*anyopaque) void;
extern fn rmx_fixture_proc_ctor(*anyopaque) void;
extern fn rmx_fixture_proc_dtor(*anyopaque) void;
extern fn rmx_fixture_proc_attached(*anyopaque) c_int;
fn observeEmptyProc(out: *Observation) c_int {
    const allocator = rmx_fixture_malloc_type();
    const snapshot = malloc(rmx_fixture_proc_size(), allocator, 0x102) orelse return 12;
    defer free(snapshot, allocator);
    rmx_fixture_proc_empty(snapshot);
    rmx_fixture_proc_ctor(snapshot);
    out.result = rmx_fixture_proc_attached(snapshot);
    rmx_fixture_proc_dtor(snapshot);
    out.owned = rmx_fixture_proc_attached(snapshot);
    return 0;
}

extern fn rmx_fixture_mach_thread_size() usize;
extern fn rmx_fixture_parked(*anyopaque) ?*anyopaque;
extern fn rmx_fixture_set_parked(*anyopaque, ?*anyopaque) void;
extern fn rmx_fixture_kmsg_header(*anyopaque) *anyopaque;
extern fn rmx_fixture_kmsg_header_size() usize;
extern fn ipc_thread_init(*anyopaque) void;
extern fn ipc_thread_terminate(*anyopaque) void;
extern fn ipc_kmsg_alloc(u32) ?*anyopaque;
extern fn ipc_kmsg_destroy(*anyopaque) void;
const KernelHeader = extern struct { bits: u32, size: u32, remote: ?*anyopaque, local: ?*anyopaque, voucher: u32, id: i32 };
fn observeParkedReply(out: *Observation) c_int {
    if (rmx_fixture_kmsg_header_size() != @sizeOf(KernelHeader)) return 22;
    const allocator = rmx_fixture_malloc_type();
    const thread = malloc(rmx_fixture_mach_thread_size(), allocator, 0x102) orelse return 12;
    defer free(thread, allocator);
    ipc_thread_init(thread);
    const port = rmx_fixture_control_port(0);
    rmx_fixture_port_hold(port);
    defer rmx_fixture_port_drop(port);
    const before = rmx_fixture_send_count(port);
    const message = ipc_kmsg_alloc(@sizeOf(KernelHeader) + 128) orelse return 12;
    const header: *KernelHeader = @ptrCast(@alignCast(rmx_fixture_kmsg_header(message)));
    header.* = .{ .bits = 17, .size = @sizeOf(KernelHeader), .remote = ipc_port_make_send(port), .local = null, .voucher = 0, .id = 437 };
    rmx_fixture_set_parked(thread, message);
    // Both native retirement and committed exec use this common cleanup.
    ipc_thread_terminate(thread);
    ipc_thread_terminate(thread);
    out.result = @intFromBool(rmx_fixture_parked(thread) == null);
    out.owned = @intCast(rmx_fixture_send_count(port) - before);
    // Clean up the negative control's retained message without concealing it.
    if (rmx_fixture_parked(thread)) |retained| {
        rmx_fixture_set_parked(thread, null);
        ipc_kmsg_destroy(retained);
    }
    return 0;
}

fn portActive(port: *anyopaque) c_int {
    // ip_active is an activity bit mask, not a Boolean 1.
    return @intFromBool(rmx_fixture_port_active(port) != 0);
}
extern fn rmx_fixture_first_file(*anyopaque) ?*anyopaque;
extern fn rmx_fixture_file_revoke(*anyopaque) void;
export fn rmx_lifetime_refs(name: u32, out: *Observation) c_int {
    var count: u32 = 0;
    out.result = rmx_fixture_get_urefs(name, &count);
    out.owned = @intCast(count);
    return 0;
}
extern fn rmx_fixture_pset_hold(u32) ?*anyopaque;
extern fn rmx_fixture_pset_drop(*anyopaque) void;
extern fn rmx_fixture_note_lock(*anyopaque) void;
extern fn rmx_fixture_note_unlock(*anyopaque) void;
extern fn rmx_fixture_note_waiter(*anyopaque) c_int;
extern fn rmx_fixture_pset_refs(*anyopaque) u32;
extern fn rmx_fixture_pause() void;
extern fn rmx_fixture_receive_hold(u32) ?*anyopaque;
extern fn rmx_fixture_object_lock(*anyopaque) void;
extern fn rmx_fixture_object_drop(*anyopaque) void;
extern fn rmx_fixture_retire_waiter(*anyopaque, *anyopaque) c_int;
extern fn rmx_fixture_object_refs(*anyopaque) u32;
var pin_port: ?*anyopaque = null;
var pin_pset: ?*anyopaque = null;
var pin_release: u32 = 0;
var pin_locked: u32 = 0;
var retire_observed: Observation = .{ .result = 0, .owned = 0 };
export fn rmx_pset_pin_observe(command: u64, out: *Observation) c_int {
    out.* = .{ .result = 0, .owned = 0 };
    switch (command >> 32) {
        1 => {
            if (pin_pset != null) return 16;
            pin_pset = rmx_fixture_pset_hold(@truncate(command)) orelse return 22;
            @atomicStore(u32, &pin_release, 0, .release);
            @atomicStore(u32, &pin_locked, 0, .release);
        },
        2 => {
            const p = pin_pset orelse return 22;
            rmx_fixture_note_lock(p);
            @atomicStore(u32, &pin_locked, 1, .release);
            const begin = rmx_fixture_uptime();
            while (@atomicLoad(u32, &pin_release, .acquire) == 0 and rmx_fixture_uptime() - begin < 10 * 4294967296) rmx_fixture_pause();
            rmx_fixture_note_unlock(p);
        },
        3 => {
            const p = pin_pset orelse return 22;
            out.result = rmx_fixture_note_waiter(p);
            out.owned = @intCast(rmx_fixture_pset_refs(p));
        },
        4 => @atomicStore(u32, &pin_release, 1, .release),
        5 => {
            rmx_fixture_pset_drop(pin_pset orelse return 22);
            pin_pset = null;
        },
        6 => out.result = @intCast(@atomicLoad(u32, &pin_locked, .acquire)),
        7 => {
            retire_observed = .{ .result = 0, .owned = 0 };
            pin_port = rmx_fixture_receive_hold(@truncate(command)) orelse return 22;
        },
        8 => {
            const p = pin_port orelse return 22;
            rmx_fixture_object_lock(p);
            @atomicStore(u32, &pin_locked, 1, .release);
            const begin = rmx_fixture_uptime();
            // The holder observes before unlock: adaptive mutex spinning need
            // not publish MTX_CONTESTED, and two busy CPUs can starve userland.
            while (rmx_fixture_uptime() - begin < 10 * 4294967296) {
                if (rmx_fixture_retire_waiter(pin_pset orelse return 22, p) != 0) {
                    retire_observed = .{ .result = 1, .owned = @intCast(rmx_fixture_object_refs(p)) };
                    break;
                }
                @import("std").atomic.spinLoopHint();
            }

            rmx_fixture_unlock(p);
        },
        9 => {
            out.* = retire_observed;
        },
        10 => {
            rmx_fixture_object_drop(pin_port orelse return 22);
            pin_port = null;
        },

        else => return 22,
    }
    return 0;
}
extern fn ipc_object_copyout(?*anyopaque, ?*anyopaque, u32, *u32) c_int;
extern fn ipc_port_release_send(?*anyopaque) void;
var copyout_port: ?*anyopaque = null;
var copyout_ready: u32 = 0;
export fn rmx_copyout_observe(command: u64, out: *Observation) c_int {
    out.* = .{ .result = 0, .owned = 0 };
    switch (command) {
        1 => {
            if (copyout_port != null) return 16;
            copyout_port = rmx_fixture_alloc_kernel() orelse return 12;
            @atomicStore(u32, &copyout_ready, 0, .release);
        },
        2 => {
            const port = copyout_port orelse return 22;
            const right = ipc_port_make_send(port);
            _ = @atomicRmw(u32, &copyout_ready, .Add, 1, .acq_rel);
            const deadline = rmx_fixture_uptime() + (10 << 32);
            while (@atomicLoad(u32, &copyout_ready, .acquire) < 2) {
                if (rmx_fixture_uptime() >= deadline) {
                    ipc_port_release_send(right);
                    return 60;
                }
                @import("std").atomic.spinLoopHint();
            }
            var name: u32 = 0;
            out.result = ipc_object_copyout(rmx_fixture_space(), right, 17, &name);
            if (out.result != 0) ipc_port_release_send(right);
            out.owned = @intCast(name);
        },
        3 => {
            rmx_fixture_dealloc_kernel(copyout_port orelse return 22);
            copyout_port = null;
        },
        else => return 22,
    }
    return 0;
}
extern fn rmx_revoke_prepare(u32, u32) c_int;
extern fn rmx_revoke_thread() void;
extern fn rmx_revoke_thread_done() void;
extern fn rmx_revoke_facts([*]u32) void;
extern fn rmx_revoke_phase(c_int) void;
extern fn rmx_revoke_deliver() c_int;
extern fn rmx_revoke_finish() void;
var revoke_name: u32 = 0;
export fn rmx_revoke_control(command: u64, out: [*]u32) c_int {
    switch (command >> 32) {
        1 => revoke_name = @truncate(command),
        2 => return rmx_revoke_prepare(revoke_name, @truncate(command)),
        3 => rmx_revoke_thread(),
        4 => rmx_revoke_facts(out),
        5 => rmx_revoke_phase(0),
        6 => return rmx_revoke_deliver(),
        7 => rmx_revoke_phase(1),
        8 => rmx_revoke_finish(),
        9 => rmx_revoke_thread_done(),
        else => return 22,
    }
    return 0;
}
extern fn rmx_mig_slot_num(u32) c_int;
extern fn rmx_mig_slot_set(u32, u32) void;
extern fn rmx_mig_trailer(*anyopaque) [*]u8;
extern fn rmx_mig_trailer_size() u32;
extern fn rmx_mig_success(*anyopaque) void;
var mig_slot: ?u32 = null;
var mig_poisoned: u32 = 0;
export fn rmx_poison_reply(_: *anyopaque, reply: *anyopaque) void {
    const bytes = rmx_mig_trailer(reply);
    @memset(bytes[0..rmx_mig_trailer_size()], 0xa5);
    rmx_mig_success(reply);
    @atomicStore(u32, &mig_poisoned, 1, .release);
}
export fn rmx_mig_control(command: u32, out: *u32) c_int {
    switch (command) {
        1 => {
            if (mig_slot != null) return 16;
            for (0..1024) |i| {
                const slot: u32 = @intCast(i);
                if (rmx_mig_slot_num(slot) == 3405) {
                    mig_slot = slot;
                    const id: u32 = 3405;
                    rmx_mig_slot_set(slot, id);
                    out.* = id;
                    @atomicStore(u32, &mig_poisoned, 0, .release);
                    return 0;
                }
            }
            return 12;
        },
        2 => {
            rmx_mig_slot_set(mig_slot orelse return 22, 0);
            mig_slot = null;
        },
        3 => out.* = @atomicLoad(u32, &mig_poisoned, .acquire),
        else => return 22,
    }
    return 0;
}

export fn rmx_child_send_count(name: u32, out: *Observation) c_int {
    var object: ?*anyopaque = null;
    out.result = ipc_object_translate(rmx_fixture_space(), name, 1, &object);
    if (out.result != 0) return 0;
    const port = object orelse return 22;
    rmx_fixture_port_hold(port);
    rmx_fixture_unlock(port);
    out.owned = @intCast(rmx_fixture_send_count(port));
    rmx_fixture_port_drop(port);
    return 0;
}

const ChildAction = extern struct { present: u32, behavior: i32, flavor: i32 };
extern fn rmx_fixture_child_action(u32, *ChildAction) void;
export fn rmx_child_crash(index: u32, out: *ChildAction) c_int {
    if (index == 0 or index >= 13) return 22;
    rmx_fixture_child_action(index, out);
    return 0;
}
