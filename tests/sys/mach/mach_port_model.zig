// SPDX-License-Identifier: BSD-2-Clause
// The oracle is independent of the kernel and of numeric descriptor allocation.
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("op644_extract.h");
    @cInclude("stdio.h");
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
    entries: [60]Entry = @splat(.{}),
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
var cases: [3]c.atf_tc_t = undefined;
var cleanup_failures: u32 = 0;
const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32, id: i32 };
const Observer = struct {
    seed: u32,
    step: usize = 0,
    action: Action = .{ .call = .allocate },
    bad: bool = false,
    owned: [60]u32 = @splat(0),
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
        _ = c.fflush(c.stdout);
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
fn inventory(o: *Observer, m: Model) void {
    o.action = .{ .call = .names };
    var names: [*c]u32 = null;
    var types: [*c]u32 = null;
    var n: u32 = 0;
    var t: u32 = 0;
    const rc = c.mach_port_names(c.mach_task_self(), &names, &n, &types, &t);
    o.equal("names_rc", 0, 0, 0, rc);
    if (rc != 0) return;
    defer _ = c.mach_vm_deallocate(c.mach_task_self(), @intFromPtr(names), @as(u64, n) * 4);
    defer _ = c.mach_vm_deallocate(c.mach_task_self(), @intFromPtr(types), @as(u64, t) * 4);
    o.equal("names_counts", 0, 0, n, t);
    if (n != t) return;
    for (m.entries[0..m.count]) |e| {
        if (e.name == 0) continue;
        var count: u32 = 0;
        for (0..n) |i| if (names[i] == e.name) {
            count += 1;
            o.equal("names_type", e.name, 0, e.ty(), types[i]);
        };
        o.equal("names_presence", e.name, 0, @intFromBool(e.live()), count);
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
fn cleanup(o: *Observer, m: *Model, check_names: bool) void {
    for (o.owned[0..o.owned_count]) |name| {
        var ty: u32 = 0;
        const rc = c.mach_port_type(c.mach_task_self(), name, &ty);
        if (rc == 0) o.equal("cleanup_destroy", name, 0, 0, c.mach_port_destroy(c.mach_task_self(), name));
    }
    m.* = .{ .count = o.owned_count };
    for (o.owned[0..o.owned_count], 0..) |name, i| m.entries[i].name = name;
    observe(o, m.*, null);
    if (check_names) inventory(o, m.*);
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
    if (!shortest) inventory(&o, m);
    var clean: Observer = .{ .seed = seed, .step = 30, .action = .{ .call = .destroy } };
    clean.owned = o.owned;
    clean.owned_count = o.owned_count;
    clean.suppress_field = o.first_field;
    clean.suppress_expected = o.first_expected;
    clean.suppress_observed = o.first_observed;
    cleanup(&clean, &m, !shortest);
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
    inventory(&o, m);
    var clean: Observer = .{ .seed = 0, .step = 2, .action = .{ .call = .destroy }, .owned = o.owned, .owned_count = o.owned_count, .suppress_field = o.first_field, .suppress_expected = o.first_expected, .suppress_observed = o.first_observed };
    cleanup(&clean, &m, true);
    if (o.bad or clean.bad) c.atf_tc_fail("allocated receive name must be enumerated and disappear after cleanup");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "sequences", "extract_make_send", "names_inventory" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &sequences, &extractMakeSend, &namesInventory };
    for (names, bodies, 0..) |name, body, i| {
        const err = c.atf_tc_init(&cases[i], name, &head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
comptime {
    if (!builtin.is_test) @export(&main, .{ .name = "main" });
}
