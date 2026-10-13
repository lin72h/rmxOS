// SPDX-License-Identifier: BSD-2-Clause
// The oracle is independent of the kernel and of numeric descriptor allocation.
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/notify.h");
    @cInclude("op644_extract.h");
    @cInclude("stdio.h");
    @cInclude("sys/mman.h");
    @cInclude("errno.h");
});
const invalid_name = 15;
const invalid_right = 17;
const invalid_value = 18;
const not_in_set = 12;
const send_invalid_dest = 0x10000003;
const recv_invalid_name = 0x10004002;
const recv_timed_out = 0x10004003;
const send_timed_out = 0x10000004;
const Right = enum(u32) { send, receive, once, set, dead };
const Call = enum { allocate, insert, mod_refs, deallocate, destroy, move_member, extract, send, receive, names };
const Action = struct { call: Call, slot: usize = 0, other: usize = 0, right: Right = .receive, delta: i32 = 0, once: bool = false };
const Entry = struct {
    name: u32 = 0,
    refs: [5]u32 = @splat(0),
    owner: ?usize = null,
    member: ?usize = null,
    queue: [30]i32 = @splat(0),
    queued: usize = 0,
    fn live(e: Entry) bool {
        for (e.refs) |n| if (n != 0) return true;
        return false;
    }
    fn ty(e: Entry) u32 {
        var result: u32 = 0;
        for (e.refs, 0..) |n, r| if (n != 0) {
            result |= @as(u32, 1) << @intCast(r + 16);
        };
        return result;
    }
};
const Model = struct {
    entries: [128]Entry = @splat(.{}),
    count: usize = 0,
    fn add(m: *Model, right: Right, owner: ?usize) usize {
        const slot = m.count;
        m.count += 1;
        m.entries[slot].refs[@intFromEnum(right)] = 1;
        m.entries[slot].owner = owner;
        return slot;
    }
    fn retireReceive(m: *Model, slot: usize) void {
        const e = &m.entries[slot];
        e.refs[1] = 0;
        e.refs[4] += e.refs[0];
        e.refs[0] = 0;
        e.member = null;
        e.queued = 0;
        for (m.entries[0..m.count]) |*other| if (other.owner == slot and other.refs[2] != 0) {
            other.refs[2] = 0;
            other.refs[4] = 1;
        };
    }
    fn retireSet(m: *Model, slot: usize) void {
        m.entries[slot].refs[3] = 0;
        for (m.entries[0..m.count]) |*e| if (e.member == slot) {
            e.member = null;
        };
    }
    fn retireOnce(m: *Model, slot: usize) void {
        const e = &m.entries[slot];
        if (e.refs[2] == 0) return;
        const dest = &m.entries[e.owner.?];
        // Dropping an unused once right sends MACH_NOTIFY_SEND_ONCE even
        // without a notification request, and can exceed the queue limit.
        dest.queue[dest.queued] = 71;
        dest.queued += 1;
        e.refs[2] = 0;
    }
    fn apply(m: *Model, a: Action, id: i32) i32 {
        if (a.call == .allocate) {
            _ = m.add(a.right, null);
            return 0;
        }
        const e = &m.entries[a.slot];
        if (a.call == .send) {
            if (e.refs[0] == 0 and e.refs[2] == 0) return send_invalid_dest;
            const dest = if (e.refs[2] != 0) &m.entries[e.owner.?] else e;
            if (e.refs[2] == 0 and dest.queued >= 5) {
                // Failed-send pseudo-copyout returns the copied destination
                // right to this task, adding a uref (XNU ipc_kmsg.c:4330).
                e.refs[0] += 1;
                return send_timed_out;
            }
            dest.queue[dest.queued] = id;
            dest.queued += 1;
            if (e.refs[2] != 0) e.refs[2] = 0;
            return 0;
        }
        if (a.call == .receive) {
            std.debug.assert(e.refs[3] == 0); // port-set selection is outside this oracle
            if (e.refs[1] == 0) return recv_invalid_name;
            if (e.queued == 0) return recv_timed_out;
            e.queued -= 1;
            std.mem.copyForwards(i32, e.queue[0..e.queued], e.queue[1 .. e.queued + 1]);
            return 0;
        }
        if (!e.live()) return invalid_name;
        switch (a.call) {
            .insert, .extract => {
                // MAKE_SEND / MAKE_SEND_ONCE require a receive right.
                if (e.refs[1] == 0) return invalid_right;
                if (a.call == .extract and a.once) {
                    _ = m.add(.once, a.slot);
                } else e.refs[0] += 1;
            },
            .mod_refs => {
                const r = @intFromEnum(a.right);
                if (e.refs[r] == 0) return invalid_right;
                if (a.right == .receive or a.right == .set or a.right == .once) {
                    if (a.delta != 0 and a.delta != -1) return invalid_value;
                } else if (@as(i64, e.refs[r]) + a.delta < 0) return invalid_value;
                if (a.delta == -1 and a.right == .receive) m.retireReceive(a.slot) else if (a.delta == -1 and a.right == .set) m.retireSet(a.slot) else if (a.delta == -1 and a.right == .once) m.retireOnce(a.slot) else e.refs[r] = @intCast(@as(i64, e.refs[r]) + a.delta);
            },
            .deallocate => {
                for ([_]usize{ 0, 2, 4 }) |r| if (e.refs[r] != 0) {
                    if (r == 2) m.retireOnce(a.slot) else e.refs[r] -= 1;
                    return 0;
                };
                return invalid_right;
            },
            .destroy => {
                m.retireOnce(a.slot);
                if (e.refs[1] != 0) m.retireReceive(a.slot);
                if (e.refs[3] != 0) m.retireSet(a.slot);
                e.refs = @splat(0);
            },
            .move_member => {
                if (e.refs[1] == 0) return invalid_right;
                if (a.other == 60) {
                    if (e.member == null) return not_in_set;
                    e.member = null;
                } else {
                    const set = m.entries[a.other];
                    if (!set.live()) return invalid_name;
                    if (set.refs[3] == 0) return invalid_right;
                    e.member = a.other;
                }
            },
            else => unreachable,
        }
        return 0;
    }
};
const Generator = struct {
    state: u64,
    fn next(g: *Generator) u32 {
        // Fully specified LCG; no dependency on std.Random implementation.
        g.state = g.state *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(g.state >> 32);
    }
    fn action(g: *Generator, m: Model) Action {
        const op = g.next() % 9;
        const target = g.next();
        const other = g.next();
        const right = g.next();
        const delta = g.next();
        if (m.count == 0 or op == 0) return .{ .call = .allocate, .right = ([_]Right{ .receive, .set, .dead })[right % 3] };
        var a: Action = .{ .call = @enumFromInt(op), .slot = target % m.count, .other = if (other % 3 == 0) 60 else other % m.count, .right = @enumFromInt(right % 5), .delta = @as(i32, @intCast(delta % 5)) - 2, .once = right % 2 != 0 };
        // Direct receive of members is outside this model's call domain.
        // Generate a membership removal instead, including NOT_IN_SET controls.
        if (a.call == .receive and m.entries[a.slot].refs[3] != 0) {
            a.call = .mod_refs;
            a.right = .set;
            a.delta = 0;
        } else if (a.call == .receive and m.entries[a.slot].member != null) {
            a.call = .move_member;
            a.other = 60;
        }
        return a;
    }
};

test "fixed generator vector and seed determinism" {
    var vector: Generator = .{ .state = 1 };
    try std.testing.expectEqual(@as(u32, 1817669548), vector.next());
    for (0..2000) |seed| {
        var x: Generator = .{ .state = seed };
        var y = x;
        var a: Model = .{};
        var b: Model = .{};
        for (0..30) |step| {
            const ax = x.action(a);
            const ay = y.action(b);
            try std.testing.expectEqualDeep(ax, ay);
            try std.testing.expectEqual(a.apply(ax, @intCast(step)), b.apply(ay, @intCast(step)));
            try std.testing.expectEqualDeep(a, b);
        }
    }
}
test "generator excludes legal but unmodeled port-set receives" {
    var m: Model = .{};
    _ = m.add(.set, null);
    for (0..2000) |seed| {
        var g: Generator = .{ .state = seed };
        try std.testing.expect(g.action(m).call != .receive);
    }
}
test "receive send urefs death and send-once death" {
    var m: Model = .{};
    _ = m.add(.receive, null);
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .insert }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .extract, .once = true }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .mod_refs, .right = .send, .delta = 2 }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .mod_refs, .right = .receive, .delta = -1 }, 0));
    try std.testing.expectEqualDeep([_]u32{ 0, 0, 0, 0, 3 }, m.entries[0].refs);
    try std.testing.expectEqualDeep([_]u32{ 0, 0, 0, 0, 1 }, m.entries[1].refs);
    try std.testing.expectEqual(@as(i32, invalid_value), m.apply(.{ .call = .mod_refs, .right = .dead, .delta = -4 }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .deallocate }, 0));
    try std.testing.expectEqual(@as(u32, 2), m.entries[0].refs[4]);
}
test "set membership singleton restrictions and queue FIFO" {
    var m: Model = .{};
    _ = m.add(.receive, null);
    _ = m.add(.set, null);
    try std.testing.expectEqual(@as(i32, not_in_set), m.apply(.{ .call = .move_member, .other = 60 }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .move_member, .other = 1 }, 0));
    try std.testing.expectEqual(@as(i32, invalid_value), m.apply(.{ .call = .mod_refs, .right = .receive, .delta = 1 }, 0));
    try std.testing.expectEqual(@as(i32, invalid_right), m.apply(.{ .call = .deallocate }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .destroy, .slot = 1 }, 0));
    try std.testing.expectEqual(@as(?usize, null), m.entries[0].member);
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .insert }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .send }, 11));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .send }, 12));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .receive }, 0));
    try std.testing.expectEqual(@as(i32, 12), m.entries[0].queue[0]);
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .receive }, 0));
    try std.testing.expectEqual(@as(i32, recv_timed_out), m.apply(.{ .call = .receive }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .destroy }, 0));
    try std.testing.expectEqual(@as(i32, invalid_name), m.apply(.{ .call = .deallocate }, 0));
}
test "unused send-once notifies and bypasses the queue limit" {
    var m: Model = .{};
    _ = m.add(.receive, null);
    _ = m.add(.once, 0);
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .insert }, 0));
    for (0..5) |id| try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .send }, @intCast(id)));
    try std.testing.expectEqual(@as(i32, send_timed_out), m.apply(.{ .call = .send }, 99));
    try std.testing.expectEqual(@as(u32, 2), m.entries[0].refs[0]);
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .send, .slot = 1 }, 100));
    _ = m.add(.once, 0);
    try std.testing.expectEqual(@as(i32, invalid_value), m.apply(.{ .call = .mod_refs, .slot = 2, .right = .once, .delta = 1 }, 0));
    try std.testing.expectEqual(@as(i32, 0), m.apply(.{ .call = .deallocate, .slot = 2 }, 0));
    try std.testing.expectEqual(@as(usize, 7), m.entries[0].queued);
    try std.testing.expectEqual(@as(i32, 71), m.entries[0].queue[6]);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var cases: [8]c.atf_tc_t = undefined;
var cleanup_failures: u32 = 0;
const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
const Observer = struct {
    seed: u32,
    step: usize = 0,
    action: Action = .{ .call = .allocate },
    bad: bool = false,
    owned: [128]u32 = @splat(0),
    owned_count: usize = 0,
    first_field: ?[*:0]const u8 = null,
    first_expected: i64 = 0,
    first_observed: i64 = 0,
    suppress_field: ?[*:0]const u8 = null,
    suppress_expected: i64 = 0,
    suppress_observed: i64 = 0,
    fn remember(o: *Observer, name: u32) void {
        if (name == 0 or name == 0xffffffff) return;
        for (o.owned[0..o.owned_count]) |known| if (known == name) return;
        o.owned[o.owned_count] = name;
        o.owned_count += 1;
    }
    fn equal(o: *Observer, field: [*:0]const u8, name: u32, right: usize, expected: i64, observed: i64) void {
        if (expected == observed or o.bad) return;
        o.bad = true;
        o.first_field = field;
        o.first_expected = expected;
        o.first_observed = observed;
        if (o.suppress_field) |prior| {
            if (std.mem.eql(u8, std.mem.span(prior), std.mem.span(field)) and o.suppress_expected == expected and o.suppress_observed == observed) return;
        }
        const call = @tagName(o.action.call);
        _ = c.printf("port_model mismatch seed=%u step=%zu call=%.*s field=%s name=%u right=%zu expected=%lld observed=%lld\n", o.seed, o.step, @as(c_int, @intCast(call.len)), call.ptr, field, name, right, @as(c_longlong, expected), @as(c_longlong, observed));
        _ = c.fflush(null);
    }
};
fn bindName(m: *Model, slot: usize, name: u32) void {
    // A newly allocated numeric name can reuse a retired name.
    for (m.entries[0..slot]) |*e| if (e.name == name and !e.live()) {
        e.name = 0;
    };
    m.entries[slot].name = name;
}
fn argumentName(e: Entry) u32 {
    return if (e.name == 0) 0x7ffffffe else e.name;
}
test "forgotten numeric names never become NULL call arguments" {
    try std.testing.expectEqual(@as(u32, 0x7ffffffe), argumentName(.{}));
    try std.testing.expectEqual(@as(u32, 42), argumentName(.{ .name = 42 }));
}
fn observe(o: *Observer, m: Model, before: ?Model) void {
    for (m.entries[0..m.count], 0..) |entry, slot| {
        var e = entry;
        e.name = argumentName(e);
        if (before) |old| {
            const involved = slot == o.action.slot or (o.action.call == .move_member and slot == o.action.other) or slot >= old.count;
            if (!involved and std.mem.eql(u32, &e.refs, &old.entries[slot].refs)) continue;
        }
        var ty: u32 = 0;
        const expected_rc: i32 = if (e.live()) 0 else invalid_name;
        o.equal("type_rc", e.name, 0, expected_rc, c.mach_port_type(c.mach_task_self(), e.name, &ty));
        if (e.live()) o.equal("type", e.name, 0, e.ty(), ty);
        for (e.refs, 0..) |refs, r| {
            var n: u32 = 0;
            o.equal("refs_rc", e.name, r, expected_rc, c.mach_port_get_refs(c.mach_task_self(), e.name, @intCast(r), &n));
            if (e.live()) o.equal("refs", e.name, r, refs, n);
        }
    }
}
fn inventory(o: *Observer) void {
    o.action = .{ .call = .names };
    var names: [*c]u32 = null;
    var types: [*c]u32 = null;
    var n: u32 = 0;
    var t: u32 = 0;
    const rc = c.mach_port_names(c.mach_task_self(), &names, &n, &types, &t);
    // Known rmxOS 1.0 gap: NextBSD file-descriptor port names remain in use.
    // mach_port.c:233 returns KERN_NOT_SUPPORTED; the XNU name table is deferred.
    // Change this case when mach_port_names namespace enumeration is implemented.
    o.equal("names_rc", 0, 0, c.KERN_NOT_SUPPORTED, rc);
    if (rc == 0) {
        _ = c.mach_vm_deallocate(c.mach_task_self(), @intFromPtr(names), @as(u64, n) * 4);
        _ = c.mach_vm_deallocate(c.mach_task_self(), @intFromPtr(types), @as(u64, t) * 4);
    }
}
fn execute(m: *Model, a: Action, id: i32, o: *Observer) void {
    const before = m.*;
    const expected = m.apply(a, id);
    const self = c.mach_task_self();
    // Zero marks a forgotten tombstone after numeric reuse. Query a valid
    // but unallocated name instead of MACH_PORT_NULL's special semantics.
    const name = argumentName(before.entries[a.slot]);
    if (a.call != .allocate) o.remember(name);
    if (a.call == .move_member and a.other != 60) o.remember(argumentName(before.entries[a.other]));
    var new_name: u32 = 0;
    var acquired: c.mach_msg_type_name_t = 0;
    var result_id: i32 = 0;
    const rc = switch (a.call) {
        .names => unreachable, // Inventory runs outside generated state transitions.
        .allocate => c.mach_port_allocate(self, @intFromEnum(a.right), &new_name),
        .insert => c.mach_port_insert_right(self, name, name, c.MACH_MSG_TYPE_MAKE_SEND),
        .mod_refs => c.mach_port_mod_refs(self, name, @intFromEnum(a.right), a.delta),
        .deallocate => c.mach_port_deallocate(self, name),
        .destroy => c.mach_port_destroy(self, name),
        .move_member => c.mach_port_move_member(self, name, if (a.other == 60) 0 else argumentName(before.entries[a.other])),
        .extract => c.op644_extract_right(self, name, if (a.once) c.MACH_MSG_TYPE_MAKE_SEND_ONCE else c.MACH_MSG_TYPE_MAKE_SEND, &new_name, &acquired),
        .send => blk: {
            var h: Header = .{ .bits = if (before.entries[a.slot].refs[2] != 0) c.MACH_MSG_TYPE_MOVE_SEND_ONCE else c.MACH_MSG_TYPE_COPY_SEND, .size = 24, .remote = name, .local = 0, .voucher = 0, .id = id };
            break :blk c.mach_msg(@ptrCast(&h), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 24, 0, 0, 0, 0);
        },
        .receive => blk: {
            var bytes: [256]u8 align(8) = @splat(0);
            const r = c.mach_msg(@ptrCast(&bytes), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, name, 0, 0);
            const h: *Header = @ptrCast(&bytes);
            if (r == 0) {
                o.equal("message_size", name, 0, 24, h.size);
                result_id = h.id;
            }
            break :blk r;
        },
    };
    o.equal("return", name, 0, expected, rc);
    if (rc == 0 and (a.call == .allocate or a.call == .extract)) {
        // Cleanup is based on observed ownership even when the oracle rejects
        // an unexpected successful call or an unexpected output name.
        o.remember(new_name);
        o.equal("output_name_valid", new_name, 0, 1, @intFromBool(new_name != 0 and new_name != 0xffffffff));
        if (a.call == .allocate or a.once) for (before.entries[0..before.count]) |e| {
            o.equal("output_name_fresh", new_name, 0, 0, @intFromBool(e.live() and e.name == new_name));
        };
    }
    if (rc == 0 and a.call == .allocate) bindName(m, before.count, new_name);
    if (rc == 0 and a.call == .extract) {
        o.equal("acquired_type", name, 0, if (a.once) c.MACH_MSG_TYPE_PORT_SEND_ONCE else c.MACH_MSG_TYPE_PORT_SEND, acquired);
        if (a.once) bindName(m, before.count, new_name) else o.equal("extracted_name", name, 0, name, new_name);
    }
    if (rc == 0 and a.call == .receive) o.equal("message_id", name, 0, before.entries[a.slot].queue[0], result_id);
    // Never continue a sequence with a divergent oracle; clean its known names.
    observe(o, m.*, before);
}
fn cleanup(o: *Observer, m: *Model) void {
    for (o.owned[0..o.owned_count]) |name| {
        var ty: u32 = 0;
        const rc = c.mach_port_type(c.mach_task_self(), name, &ty);
        if (rc == 0) o.equal("cleanup_destroy", name, 0, 0, c.mach_port_destroy(c.mach_task_self(), name));
    }
    m.* = .{ .count = o.owned_count };
    for (o.owned[0..o.owned_count], 0..) |name, i| m.entries[i].name = name;
    observe(o, m.*, null);
}
fn runSeed(seed: u32, shortest: bool) bool {
    var g: Generator = .{ .state = seed };
    var m: Model = .{};
    var o: Observer = .{ .seed = seed };
    for (0..if (shortest) @as(usize, 2) else 30) |step| {
        const a = if (shortest) (if (step == 0) Action{ .call = .allocate } else Action{ .call = .extract }) else g.action(m);
        o.step = step;
        o.action = a;
        execute(&m, a, @intCast(step + 64400), &o);
        if (o.bad) break;
    }
    o.step = if (shortest) 2 else 30;
    var clean: Observer = .{ .seed = seed, .step = 30, .action = .{ .call = .destroy } };
    clean.owned = o.owned;
    clean.owned_count = o.owned_count;
    clean.suppress_field = o.first_field;
    clean.suppress_expected = o.first_expected;
    clean.suppress_observed = o.first_observed;
    cleanup(&clean, &m);
    cleanup_failures += @intFromBool(clean.bad);
    return o.bad or clean.bad;
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Deterministic model of Mach rights, urefs, membership and simple messages");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "120");
}
fn sequences(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var mismatches: u32 = 0;
    for (0..2000) |seed| mismatches += @intFromBool(runSeed(@intCast(seed), false));
    _ = c.printf("port_model summary seeds=2000 max_steps=30 mismatches=%u cleanup_failures=%u\n", mismatches, cleanup_failures);
    if (mismatches != 0) c.atf_tc_fail("port rights differ from model; see seed and step");
}
fn extractMakeSend(_: [*c]const c.atf_tc_t) callconv(.c) void {
    if (runSeed(0, true)) c.atf_tc_fail("allocate receive; extract MAKE_SEND differs from Mach contract");
}
fn namesInventory(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var m: Model = .{};
    var o: Observer = .{ .seed = 0 };
    execute(&m, .{ .call = .allocate }, 64400, &o);
    o.step = 1;
    inventory(&o);
    var clean: Observer = .{ .seed = 0, .step = 2, .action = .{ .call = .destroy }, .owned = o.owned, .owned_count = o.owned_count, .suppress_field = o.first_field, .suppress_expected = o.first_expected, .suppress_observed = o.first_observed };
    cleanup(&clean, &m);
    if (o.bad or clean.bad) c.atf_tc_fail("known 1.0 names gap or type/refs cleanup contract differs");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "sequences", "extract_make_send", "names_inventory", "descriptor_sequences", "thread_self_saturation", "urefs_delta_limits", "urefs_notifications", "urefs_moves" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &sequences, &extractMakeSend, &namesInventory, &descriptorSequences, &threadSelfSaturation, &urefsDeltaLimits, &urefsNotifications, &urefsMoves };
    for (names, bodies, 0..) |name, body, i| {
        const err = c.atf_tc_init(&cases[i], name, &head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}

fn threadSelfSaturation(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var thread: u32 = 0;
    for (0..70000) |i| {
        const p = c.mach_thread_self();
        if (p == 0 or p == 0xffffffff or (i != 0 and p != thread)) c.atf_tc_fail("thread self changed at call %zu", i + 1);
        thread = p;
    }
    var refs: u32 = 0;
    if (c.mach_port_get_refs(c.mach_task_self(), thread, c.MACH_PORT_RIGHT_SEND, &refs) != 0 or refs != c.MACH_PORT_UREFS_MAX) c.atf_tc_fail("70000 calls: expected max=%u observed=%u", @as(u32, c.MACH_PORT_UREFS_MAX), refs);
    var destination: u32 = 0;
    if (c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &destination) != 0) c.atf_tc_fail("channel allocation");
    var bytes: [256]u8 align(8) = @splat(0);
    const h: *Header = @ptrCast(&bytes);
    h.* = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_MAKE_SEND, .size = 40, .remote = destination, .local = 0, .voucher = 0, .id = 67200 };
    const count: *u32 = @ptrCast(@alignCast(bytes[24..].ptr));
    count.* = 1;
    const d: *align(1) PortWire = @ptrCast(bytes[28..].ptr);
    d.* = .{ .name = thread, .disposition = c.MACH_MSG_TYPE_COPY_SEND };
    const sent = c.mach_msg(@ptrCast(h), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 40, 0, 0, 0, 0);
    if (sent != 0) c.atf_tc_fail("saturated right send kr=%d", sent);
    @memset(&bytes, 0);
    const received = c.mach_msg(@ptrCast(h), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, destination, 1000, 0);
    if (received != 0 or h.id != 67200 or count.* != 1 or d.name != thread or d.disposition != c.MACH_MSG_TYPE_PORT_SEND) c.atf_tc_fail("saturated right copyout kr=%d", received);
    if (c.mach_port_get_refs(c.mach_task_self(), thread, c.MACH_PORT_RIGHT_SEND, &refs) != 0 or refs != c.MACH_PORT_UREFS_MAX) c.atf_tc_fail("descriptor copyout count=%u", refs);
    _ = c.printf("thread_self_saturation calls=70000 expected=%u observed=%u descriptor_copyout=0\n", @as(u32, c.MACH_PORT_UREFS_MAX), refs);
    if (c.mach_port_destroy(c.mach_task_self(), destination) != 0 or c.mach_port_destroy(c.mach_task_self(), thread) != 0) c.atf_tc_fail("saturation cleanup");
}

const urefs_max: i32 = 65535;
fn limitCheck(label: [*:0]const u8, expected: i32, observed: i32) void {
    if (expected != observed) c.atf_tc_fail("%s expected=%d observed=%d", label, expected, observed);
}
fn limitRefs(name: u32, right: u32, expected: u32) void {
    var refs: u32 = 0;
    limitCheck("get refs", 0, c.mach_port_get_refs(c.mach_task_self(), name, right, &refs));
    limitCheck("urefs", @intCast(expected), @intCast(refs));
}
fn limitPort(right: u32) u32 {
    var name: u32 = 0;
    limitCheck("allocate", 0, c.mach_port_allocate(c.mach_task_self(), right, &name));
    return name;
}
fn limitSendPort() u32 {
    const name = limitPort(c.MACH_PORT_RIGHT_RECEIVE);
    limitCheck("make send", 0, c.mach_port_insert_right(c.mach_task_self(), name, name, c.MACH_MSG_TYPE_MAKE_SEND));
    return name;
}
fn limitDestroy(name: u32) void {
    limitCheck("destroy", 0, c.mach_port_destroy(c.mach_task_self(), name));
}
fn urefsDeltaLimits(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const task = c.mach_task_self();
    for ([_]u32{ c.MACH_PORT_RIGHT_SEND, c.MACH_PORT_RIGHT_DEAD_NAME }) |right| {
        // Landing on MAX and crossing MAX both peg, as XNU-12377 does.
        for ([_]i32{ 1, 2, urefs_max }) |cross| {
            const name = if (right == c.MACH_PORT_RIGHT_SEND) limitSendPort() else limitPort(right);
            limitCheck("to MAX-1", 0, c.mach_port_mod_refs(task, name, right, urefs_max - 2));
            limitRefs(name, right, urefs_max - 1);
            limitCheck("cross MAX", 0, c.mach_port_mod_refs(task, name, right, cross));
            limitRefs(name, right, urefs_max);
            for ([_]i32{ -1, 0, 1, urefs_max, -urefs_max + 1 }) |delta| {
                limitCheck("pegged delta", 0, c.mach_port_mod_refs(task, name, right, delta));
                limitRefs(name, right, urefs_max);
            }
            for ([_]i32{ urefs_max + 1, -urefs_max - 1, std.math.minInt(i32), std.math.maxInt(i32) }) |delta| {
                limitCheck("delta magnitude", invalid_value, c.mach_port_mod_refs(task, name, right, delta));
                limitRefs(name, right, urefs_max);
            }
            limitCheck("deallocate pegged", 0, c.mach_port_deallocate(task, name));
            limitRefs(name, right, urefs_max);
            limitCheck("remove all", 0, c.mach_port_mod_refs(task, name, right, -urefs_max));
            var refs: u32 = 99;
            limitCheck("removed right", if (right == c.MACH_PORT_RIGHT_SEND) 0 else invalid_name, c.mach_port_get_refs(task, name, right, &refs));
            if (right == c.MACH_PORT_RIGHT_SEND) {
                limitCheck("removed send refs", 0, @intCast(refs));
                limitDestroy(name);
            }
        }
    }
    _ = c.printf("urefs_delta_limits send=3 dead=3 pegged_deltas=30 invalid_magnitude=24 deallocate=6 remove_all=6\n");
}
fn limitRequest(name: u32, notify: u32) void {
    var previous: u32 = 0;
    limitCheck("dead name request", 0, c.mach_port_request_notification(c.mach_task_self(), name, c.MACH_NOTIFY_DEAD_NAME, 1, notify, c.MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous));
    limitCheck("previous", 0, @intCast(previous));
}
fn limitNotification(notify: u32, name: u32) void {
    var bytes: [256]u8 align(8) = @splat(0);
    const h: *c.mach_msg_header_t = @ptrCast(&bytes);
    limitCheck("notification receive", 0, c.mach_msg(h, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, bytes.len, notify, 1000, 0));
    limitCheck("notification id", c.MACH_NOTIFY_DEAD_NAME, h.msgh_id);
    const dn: *c.mach_dead_name_notification_t = @ptrCast(&bytes);
    limitCheck("notification name", @intCast(name), @intCast(dn.not_port));
}
fn urefsNotifications(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const task = c.mach_task_self();
    for ([_]i32{ urefs_max - 1, urefs_max }) |initial| {
        const name = limitPort(c.MACH_PORT_RIGHT_DEAD_NAME);
        const notify = limitPort(c.MACH_PORT_RIGHT_RECEIVE);
        limitCheck("dead refs", 0, c.mach_port_mod_refs(task, name, c.MACH_PORT_RIGHT_DEAD_NAME, initial - 1));
        limitRequest(name, notify);
        limitRefs(name, c.MACH_PORT_RIGHT_DEAD_NAME, urefs_max);
        limitNotification(notify, name);
        limitDestroy(name);
        limitDestroy(notify);
    }
    // RECEIVE delta conversion with an unconsumed request at MAX.
    const name = limitSendPort();
    const notify = limitPort(c.MACH_PORT_RIGHT_RECEIVE);
    limitCheck("send refs", 0, c.mach_port_mod_refs(task, name, c.MACH_PORT_RIGHT_SEND, urefs_max - 1));
    limitRequest(name, notify);
    limitCheck("retire receive", 0, c.mach_port_mod_refs(task, name, c.MACH_PORT_RIGHT_RECEIVE, -1));
    limitRefs(name, c.MACH_PORT_RIGHT_DEAD_NAME, urefs_max);
    limitNotification(notify, name);
    limitDestroy(name);
    limitDestroy(notify);
    _ = c.printf("urefs_notifications immediate=2 receive_delta=1 expected=65535 observed=65535\n");
}
fn limitSend(destination: u32, reply: u32, reply_type: u32, descriptor: u32, disposition: u8) void {
    var bytes: [40]u8 align(8) = @splat(0);
    const h: *Header = @ptrCast(&bytes);
    h.* = .{ .bits = c.MACH_MSG_TYPE_COPY_SEND | (reply_type << 8) | (if (descriptor != 0) @as(u32, c.MACH_MSGH_BITS_COMPLEX) else 0), .size = if (descriptor != 0) 40 else 24, .remote = destination, .local = reply, .voucher = 0, .id = 67201 };
    if (descriptor != 0) {
        const count: *u32 = @ptrCast(@alignCast(bytes[24..].ptr));
        count.* = 1;
        const d: *align(1) PortWire = @ptrCast(bytes[28..].ptr);
        d.* = .{ .name = descriptor, .disposition = disposition };
    }
    limitCheck("limit message send", 0, c.mach_msg(@ptrCast(h), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, h.size, 0, 0, 0, 0));
}
fn urefsMoves(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const task = c.mach_task_self();
    const channel = limitSendPort();
    const name = limitSendPort();
    limitCheck("saturate", 0, c.mach_port_mod_refs(task, name, c.MACH_PORT_RIGHT_SEND, urefs_max - 1));
    limitSend(channel, 0, 0, name, c.MACH_MSG_TYPE_MOVE_SEND);
    limitRefs(name, c.MACH_PORT_RIGHT_SEND, urefs_max);
    // MOVE_RECEIVE into the queue leaves a live send-only entry.
    limitSend(channel, 0, 0, name, c.MACH_MSG_TYPE_MOVE_RECEIVE);
    limitCheck("send-only deallocate", 0, c.mach_port_deallocate(task, name));
    limitRefs(name, c.MACH_PORT_RIGHT_SEND, urefs_max);
    limitSend(channel, 0, 0, name, c.MACH_MSG_TYPE_MOVE_SEND);
    limitRefs(name, c.MACH_PORT_RIGHT_SEND, urefs_max);
    // Destroying the queue kills the receive right, exercising right_check.
    const notify = limitPort(c.MACH_PORT_RIGHT_RECEIVE);
    limitRequest(name, notify);
    limitDestroy(channel);
    limitRefs(name, c.MACH_PORT_RIGHT_DEAD_NAME, urefs_max);
    limitNotification(notify, name);
    const other = limitSendPort();
    limitSend(other, name, c.MACH_MSG_TYPE_MOVE_SEND, 0, 0);
    limitRefs(name, c.MACH_PORT_RIGHT_DEAD_NAME, urefs_max);
    limitDestroy(name);
    limitDestroy(notify);
    limitDestroy(other);
    // Same remote/reply name takes copyin_two's two MOVE_SEND path.
    const two = limitSendPort();
    limitCheck("saturate two", 0, c.mach_port_mod_refs(task, two, c.MACH_PORT_RIGHT_SEND, urefs_max - 1));
    var h: Header = .{ .bits = c.MACH_MSG_TYPE_MOVE_SEND | (c.MACH_MSG_TYPE_MOVE_SEND << 8), .size = 24, .remote = two, .local = two, .voucher = 0, .id = 67202 };
    limitCheck("move two", 0, c.mach_msg(@ptrCast(&h), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, 24, 0, 0, 0, 0));
    limitRefs(two, c.MACH_PORT_RIGHT_SEND, urefs_max);
    limitDestroy(two);
    _ = c.printf("urefs_moves move_send=2 send_only_deallocate=1 dead_move=1 move_two=1 right_check=1 expected=65535 observed=65535\n");
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
comptime {
    if (!builtin.is_test) @export(&main, .{ .name = "main" });
}

// Descriptor ownership is escrowed in the message, independently of namespace
// urefs. References: XNU ipc_kmsg_copyin_body/copyout_body/clean_descriptors,
// ipc_right_copyin/copyout. Every endpoint below is distinct from the channel.
const Disposition = enum(u8) { move_receive = 16, move_send = 17, move_once = 18, copy_send = 19, make_send = 20, make_once = 21 };
const DescriptorKind = enum(u8) { port = 0, memory = 1, array = 2 };
const Descriptor = struct {
    kind: DescriptorKind = .port,
    disposition: Disposition = .copy_send,
    count: usize = 1,
    pages: usize = 1,
    deallocate: bool = false,
    urefs: u32 = 1,
    retain_send: bool = true,
    slots: [8]usize = @splat(0),
    inputs: [8]usize = @splat(0),
    names: [8]u32 = @splat(0),
    address: usize = 0,
};
const DescriptorPlan = struct {
    descriptors: [4]Descriptor = @splat(.{}),
    count: usize,
    discard: bool,
    fn generate(seed: u32) DescriptorPlan {
        var g: Generator = .{ .state = seed };
        var p: DescriptorPlan = .{ .count = 1 + g.next() % 4, .discard = g.next() % 3 == 0 };
        for (p.descriptors[0..p.count]) |*d| {
            d.kind = @enumFromInt(g.next() % 3);
            d.disposition = @enumFromInt(16 + g.next() % 6);
            d.count = if (d.kind == .array) 1 + g.next() % 8 else 1;
            d.pages = 1 + g.next() % 3;
            d.deallocate = g.next() % 2 != 0;
            d.urefs = 1 + g.next() % 3;
            d.retain_send = g.next() % 2 != 0;
        }
        return p;
    }
    fn send(p: DescriptorPlan, m: *Model) void {
        for (p.descriptors[0..p.count]) |d| {
            if (d.kind == .memory) continue;
            for (d.inputs[0..d.count]) |slot| switch (d.disposition) {
                .move_receive => m.entries[slot].refs[1] = 0, // limbo, not death
                .move_send => m.entries[slot].refs[0] -= 1,
                .move_once => m.entries[slot].refs[2] = 0,
                .copy_send, .make_send, .make_once => {},
            };
        }
        m.entries[0].queue[0] = 64800;
        m.entries[0].queued = 1;
    }
    fn deliver(p: DescriptorPlan, m: *Model) void {
        m.entries[0].queued = 0;
        for (p.descriptors[0..p.count]) |d| {
            if (d.kind == .memory) continue;
            for (d.slots[0..d.count]) |slot| switch (d.disposition) {
                .move_receive => m.entries[slot].refs[1] = 1,
                .move_send, .copy_send, .make_send => m.entries[slot].refs[0] += 1,
                .move_once, .make_once => {
                    _ = m.add(.once, slot);
                },
            };
        }
    }
    fn release(p: DescriptorPlan, m: *Model) void {
        _ = m.apply(.{ .call = .destroy }, 0);
        for (p.descriptors[0..p.count]) |d| {
            if (d.kind == .memory) continue;
            for (d.slots[0..d.count]) |slot| switch (d.disposition) {
                .move_receive => m.retireReceive(slot),
                .move_once, .make_once => {
                    // Destruction of a carried once right sends the unused-once
                    // notification to its still-live receive endpoint.
                    const e = &m.entries[slot];
                    e.queue[e.queued] = 71;
                    e.queued += 1;
                },
                .move_send, .copy_send, .make_send => {},
            };
        }
    }
};
fn descriptorStep(m: *Model, a: Action, o: ?*Observer) void {
    if (builtin.is_test) {
        std.debug.assert(m.apply(a, 64800) == 0);
    } else if (o) |obs| {
        if (obs.bad) return;
        obs.action = a;
        execute(m, a, 64800, obs);
        obs.step += 1;
    } else std.debug.assert(m.apply(a, 64800) == 0);
}
fn descriptorSetup(p: *DescriptorPlan, m: *Model, o: ?*Observer) void {
    descriptorStep(m, .{ .call = .allocate }, o);
    descriptorStep(m, .{ .call = .insert }, o);
    for (p.descriptors[0..p.count]) |*d| {
        if (d.kind == .memory) continue;
        for (0..d.count) |j| {
            const slot = m.count;
            d.slots[j] = slot;
            d.inputs[j] = slot;
            descriptorStep(m, .{ .call = .allocate }, o);
            if (d.disposition == .move_send or d.disposition == .copy_send or (d.disposition == .move_receive and d.retain_send)) {
                descriptorStep(m, .{ .call = .insert, .slot = slot }, o);
                if (d.urefs > 1) descriptorStep(m, .{ .call = .mod_refs, .slot = slot, .right = .send, .delta = @intCast(d.urefs - 1) }, o);
            }
            if (d.disposition == .move_once) {
                d.inputs[j] = m.count;
                descriptorStep(m, .{ .call = .extract, .slot = slot, .once = true }, o);
            }
            if (d.disposition == .move_receive) {
                // A dependent once witness must stay live in limbo, then become
                // dead if the queued receive right is destroyed.
                descriptorStep(m, .{ .call = .extract, .slot = slot, .once = true }, o);
            }
            d.names[j] = m.entries[d.inputs[j]].name;
        }
    }
}
test "descriptor fixed seeds cover dimensions and escrow transitions" {
    var kinds: [3]usize = @splat(0);
    var dispositions: [2][6]usize = @splat(@splat(0));
    var widths: [8]usize = @splat(0);
    var pages: [2][3]usize = @splat(@splat(0));
    var counts: [4]usize = @splat(0);
    var outcomes: [2]usize = @splat(0);
    for (0..2000) |seed| {
        var p = DescriptorPlan.generate(@intCast(seed));
        try std.testing.expectEqualDeep(p, DescriptorPlan.generate(@intCast(seed)));
        var m: Model = .{};
        descriptorSetup(&p, &m, null);
        const initial = m;
        p.send(&m);
        counts[p.count - 1] += 1;
        outcomes[@intFromBool(p.discard)] += 1;
        for (p.descriptors[0..p.count]) |d| {
            kinds[@intFromEnum(d.kind)] += 1;
            if (d.kind == .memory) {
                pages[@intFromBool(d.deallocate)][d.pages - 1] += 1;
                continue;
            }
            dispositions[@intFromBool(d.kind == .array)][@intFromEnum(d.disposition) - 16] += 1;
            if (d.kind == .array) widths[d.count - 1] += 1;
            for (d.inputs[0..d.count]) |slot| {
                const before = initial.entries[slot].refs;
                var expected = before;
                switch (d.disposition) {
                    .move_receive => expected[1] = 0,
                    .move_send => expected[0] -= 1,
                    .move_once => expected[2] = 0,
                    else => {},
                }
                try std.testing.expectEqualDeep(expected, m.entries[slot].refs);
            }
        }
        const escrow = m;
        if (p.discard) p.release(&m) else p.deliver(&m);
        var new_slot = escrow.count;
        for (p.descriptors[0..p.count]) |d| {
            if (d.kind == .memory) continue;
            for (d.slots[0..d.count]) |slot| {
                var expected = escrow.entries[slot].refs;
                if (p.discard) {
                    if (d.disposition == .move_receive) {
                        expected[4] += expected[0];
                        expected[0] = 0;
                    }
                    if (d.disposition == .move_once or d.disposition == .make_once) try std.testing.expectEqual(@as(i32, 71), m.entries[slot].queue[0]);
                } else switch (d.disposition) {
                    .move_receive => expected[1] = 1,
                    .move_send, .copy_send, .make_send => expected[0] += 1,
                    .move_once, .make_once => {
                        try std.testing.expectEqualDeep([_]u32{ 0, 0, 1, 0, 0 }, m.entries[new_slot].refs);
                        try std.testing.expectEqual(@as(?usize, slot), m.entries[new_slot].owner);
                        new_slot += 1;
                    },
                }
                try std.testing.expectEqualDeep(expected, m.entries[slot].refs);
            }
        }
    }
    for (kinds) |n| try std.testing.expect(n > 0);
    for (counts) |n| try std.testing.expect(n > 0);
    for (outcomes) |n| try std.testing.expect(n > 0);
    for (widths) |n| try std.testing.expect(n > 0);
    for (dispositions) |row| for (row) |n| {
        try std.testing.expect(n > 0);
    };
    for (pages) |row| for (row) |n| {
        try std.testing.expect(n > 0);
    };
}
// LP64 Mach user descriptors have four-byte alignment, and heterogeneous
// descriptor sizes. Do not use a fixed-stride union to pack the wire message.
const PortWire = extern struct { name: u32, pad: u32 = 0, pad2: u16 = 0, disposition: u8, kind: u8 = 0 };
const OolWire = extern struct { address: u64 align(4), deallocate: u8, copy: u8 = 1, disposition: u8 = 0, kind: u8, size: u32 };
comptime {
    if (@sizeOf(PortWire) != 12 or @offsetOf(PortWire, "kind") != 11 or @sizeOf(OolWire) != 16 or @offsetOf(OolWire, "kind") != 11) @compileError("Mach LP64 descriptor layout");
}
fn payloadByte(seed: u32, index: usize, offset: usize) u8 {
    return @truncate(@as(usize, seed) *% 131 +% index *% 47 +% offset *% 17 +% (offset >> 8));
}
fn rangeMapped(address: usize, size: usize) bool {
    var vector: [3]u8 = undefined;
    if (address == 0 or address % 4096 != 0 or size == 0 or size > 12288) return false;
    return c.mincore(@ptrFromInt(address), size, &vector) == 0;
}
fn checkSender(p: *DescriptorPlan, seed: u32, o: *Observer) void {
    for (p.descriptors[0..p.count], 0..) |*d, i| {
        if (d.kind != .memory or d.address == 0) continue;
        // Check every page, not merely the first one. A retained source is
        // overwritten after send to check that receive sees the sent snapshot.
        for (0..d.pages) |page| {
            var vec: u8 = 0;
            const rc = c.mincore(@ptrFromInt(d.address + page * 4096), 4096, &vec);
            o.equal("sender_mapping_rc", 0, i, if (d.deallocate) -1 else 0, rc);
            if (d.deallocate and rc == -1) o.equal("sender_unmapped_errno", 0, i, c.ENOMEM, c.__error().*);
        }
        if (d.deallocate) {
            if (!rangeMapped(d.address, d.pages * 4096)) d.address = 0;
        } else if (rangeMapped(d.address, d.pages * 4096)) {
            const bytes: [*]u8 = @ptrFromInt(d.address);
            for (0..d.pages * 4096) |j| {
                o.equal("sender_bytes", 0, i, payloadByte(seed, i, j), bytes[j]);
                bytes[j] ^= 0xff;
            }
        }
    }
}
fn returnedName(m: *Model, before: Model, d: Descriptor, j: usize, name: u32, once_slot: *usize, o: *Observer) void {
    o.remember(name);
    o.equal("descriptor_name_valid", name, j, 1, @intFromBool(name != 0 and name != 0xffffffff));
    const slot = d.slots[j];
    // Copyout may reuse any vanished input name, including a later slot.
    for (m.entries[0..m.count], 0..) |*e, k| {
        if (k != slot and e.name == name and !e.live()) e.name = 0;
    }
    if (d.disposition == .move_once or d.disposition == .make_once) {
        for (before.entries[0..before.count]) |e| o.equal("descriptor_once_fresh", name, j, 0, @intFromBool(e.live() and e.name == name));
        bindName(m, once_slot.*, name);
        once_slot.* += 1;
    } else if (before.entries[slot].live()) {
        o.equal("descriptor_coalesced_name", name, j, before.entries[slot].name, name);
    } else {
        for (before.entries[0..before.count]) |e| o.equal("descriptor_receive_fresh", name, j, 0, @intFromBool(e.live() and e.name == name));
        bindName(m, slot, name);
    }
}
fn descriptorSeed(seed: u32) bool {
    var p = DescriptorPlan.generate(seed);
    var m: Model = .{};
    var o: Observer = .{ .seed = seed };
    descriptorSetup(&p, &m, &o);
    var wire: [256]u8 align(8) = @splat(0);
    var offset: usize = 28;
    for (p.descriptors[0..p.count], 0..) |*d, i| {
        if (d.kind == .port) {
            const w: PortWire = .{ .name = d.names[0], .disposition = @intFromEnum(d.disposition) };
            @memcpy(wire[offset..][0..12], std.mem.asBytes(&w));
            offset += 12;
        } else {
            if (d.kind == .memory) {
                const ptr = c.mmap(null, d.pages * 4096, c.PROT_READ | c.PROT_WRITE, c.MAP_ANON | c.MAP_PRIVATE, -1, 0);
                o.equal("source_mmap", 0, i, 0, @intFromBool(ptr == c.MAP_FAILED));
                if (ptr != c.MAP_FAILED) {
                    d.address = @intFromPtr(ptr);
                    const bytes: [*]u8 = @ptrCast(ptr);
                    for (0..d.pages * 4096) |j| bytes[j] = payloadByte(seed, i, j);
                }
            }
            const w: OolWire = .{ .address = if (d.kind == .memory) d.address else @intFromPtr(&d.names), .deallocate = @intFromBool(d.kind == .memory and d.deallocate), .disposition = if (d.kind == .array) @intFromEnum(d.disposition) else 0, .kind = @intFromEnum(d.kind), .size = @intCast(if (d.kind == .memory) d.pages * 4096 else d.count) };
            @memcpy(wire[offset..][0..16], std.mem.asBytes(&w));
            offset += 16;
        }
    }
    const h: *Header = @ptrCast(&wire);
    h.* = .{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = @intCast(offset), .remote = m.entries[0].name, .local = 0, .voucher = 0, .id = 64800 };
    const n: *u32 = @ptrCast(@alignCast(wire[24..].ptr));
    n.* = @intCast(p.count);
    if (!o.bad) {
        o.action = .{ .call = .send };
        p.send(&m);
        o.equal("descriptor_send_return", h.remote, 0, 0, c.mach_msg(@ptrCast(&wire), c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, h.size, 0, 0, 0, 0));
        // COPY/MAKE dispositions must leave input urefs unchanged too.
        observe(&o, m, null);
        checkSender(&p, seed, &o);
        o.step += 1;
    }
    if (!o.bad) {
        const before = m;
        if (p.discard) {
            o.action = .{ .call = .destroy };
            p.release(&m);
            o.equal("queued_destroy_return", before.entries[0].name, 0, 0, c.mach_port_destroy(c.mach_task_self(), before.entries[0].name));
            observe(&o, m, null);
            // The carried once release is observable as an exact notification,
            // followed by an empty queue. Also query transferred receive death.
            for (p.descriptors[0..p.count]) |d| {
                if (d.kind == .memory) continue;
                for (d.slots[0..d.count]) |slot| {
                    if (d.disposition == .make_once or d.disposition == .move_once) descriptorStep(&m, .{ .call = .receive, .slot = slot }, &o);
                    descriptorStep(&m, .{ .call = .receive, .slot = slot }, &o);
                }
            }
        } else {
            o.action = .{ .call = .receive };
            p.deliver(&m);
            var received: [256]u8 align(8) = @splat(0);
            const rc = c.mach_msg(@ptrCast(&received), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, received.len, before.entries[0].name, 0, 0);
            o.equal("descriptor_receive_return", 0, 0, 0, rc);
            if (rc == 0) {
                const rh: *Header = @ptrCast(&received);
                const rn: *u32 = @ptrCast(@alignCast(received[24..].ptr));
                o.equal("descriptor_message_id", 0, 0, 64800, rh.id);
                o.equal("descriptor_message_size", 0, 0, @intCast(offset), rh.size);
                o.equal("descriptor_complex", 0, 0, c.MACH_MSGH_BITS_COMPLEX, rh.bits & c.MACH_MSGH_BITS_COMPLEX);
                o.equal("descriptor_count", 0, 0, @intCast(p.count), rn.*);
                var pos: usize = 28;
                var once_slot = before.count;
                for (p.descriptors[0..p.count], 0..) |d, i| {
                    const expected_disp: u8 = switch (d.disposition) {
                        .move_receive => 16,
                        .move_once, .make_once => 18,
                        else => 17,
                    };
                    if (d.kind == .port) {
                        const w: *align(1) const PortWire = @ptrCast(received[pos..].ptr);
                        o.equal("descriptor_kind", 0, i, 0, w.kind);
                        o.equal("descriptor_disposition", 0, i, expected_disp, w.disposition);
                        returnedName(&m, before, d, 0, w.name, &once_slot, &o);
                        pos += 12;
                    } else {
                        const w: *align(1) const OolWire = @ptrCast(received[pos..].ptr);
                        o.equal("descriptor_kind", 0, i, @intFromEnum(d.kind), w.kind);
                        const size = if (d.kind == .memory) d.pages * 4096 else d.count * 4;
                        o.equal("descriptor_size", 0, i, @intCast(if (d.kind == .memory) size else d.count), w.size);
                        const mapped = rangeMapped(@intCast(w.address), size);
                        o.equal("descriptor_mapping", 0, i, 1, @intFromBool(mapped));
                        if (mapped) {
                            if (d.kind == .memory) {
                                const bytes: [*]const u8 = @ptrFromInt(w.address);
                                for (0..size) |j| o.equal("descriptor_bytes", 0, i, payloadByte(seed, i, j), bytes[j]);
                            } else {
                                o.equal("descriptor_disposition", 0, i, expected_disp, w.disposition);
                                const names: [*]const u32 = @ptrFromInt(w.address);
                                for (0..d.count) |j| returnedName(&m, before, d, j, names[j], &once_slot, &o);
                            }
                            o.equal("descriptor_vm_cleanup", 0, i, 0, c.mach_vm_deallocate(c.mach_task_self(), w.address, size));
                        }
                        pos += 16;
                    }
                }
            }
            observe(&o, m, null);
            descriptorStep(&m, .{ .call = .receive }, &o); // queue emptied exactly once
        }
    }
    if (o.bad) {
        _ = c.printf("descriptor_model named_seed=descriptor_seed_%u count=%zu discard=%u\n", seed, p.count, @as(u32, @intFromBool(p.discard)));
        for (p.descriptors[0..p.count], 0..) |d, i| _ = c.printf("descriptor_model seed=%u index=%zu kind=%u disposition=%u names=%zu pages=%zu deallocate=%u urefs=%u retain_send=%u\n", seed, i, @as(u32, @intFromEnum(d.kind)), @as(u32, @intFromEnum(d.disposition)), d.count, d.pages, @as(u32, @intFromBool(d.deallocate)), d.urefs, @as(u32, @intFromBool(d.retain_send)));
        _ = c.fflush(null);
    }
    for (p.descriptors[0..p.count], 0..) |d, i| {
        if (d.kind == .memory and d.address != 0) o.equal("sender_vm_cleanup", 0, i, 0, c.munmap(@ptrFromInt(d.address), d.pages * 4096));
    }
    var clean: Observer = .{ .seed = seed, .step = o.step + 1, .action = .{ .call = .destroy }, .owned = o.owned, .owned_count = o.owned_count };
    cleanup(&clean, &m);
    cleanup_failures += @intFromBool(clean.bad);
    return o.bad or clean.bad;
}
fn descriptorSequences(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var mismatches: u32 = 0;
    cleanup_failures = 0;
    for (0..2000) |seed| mismatches += @intFromBool(descriptorSeed(@intCast(seed)));
    _ = c.printf("descriptor_model summary seeds=2000 mismatches=%u cleanup_failures=%u\n", mismatches, cleanup_failures);
    _ = c.fflush(null);
    if (mismatches != 0) c.atf_tc_fail("descriptor rights or memory differ from model; see named seed and step");
}
