// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/exception_types.h");
    @cInclude("mach/mach_vm.h");
    @cInclude("sys/linker.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
    @cInclude("signal.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Port = extern struct { name: u32, pad: u32 = 0, pad2: u16 = 0, disposition: u8, kind: u8 = c.MACH_MSG_PORT_DESCRIPTOR };
const Packet = extern struct { header: c.mach_msg_header_t, count: u32, port: Port, trailer: [128]u8 = @splat(0) };
const Action = extern struct { present: u32 = 0, behavior: i32 = 0, flavor: i32 = 0 };
const Projection = extern struct { special: [3]u32 = @splat(0), mask: u32 = 0, behavior: i32 = 0, flavor: i32 = 0, exception: u32 = 0, crash: Action = .{} };
const selectors = [_]i32{ c.TASK_SEATBELT_PORT, c.TASK_ACCESS_PORT, c.TASK_DEBUG_CONTROL_PORT };
const launch_mask: u32 = c.EXC_MASK_CRASH | c.EXC_MASK_GUARD | c.EXC_MASK_RESOURCE;
const launch_behavior: i32 = @bitCast(@as(u32, c.EXCEPTION_STATE_IDENTITY) | c.MACH_EXCEPTION_CODES);
var cases: [5]c.atf_tc_t = undefined;
var label: [*:0]const u8 = undefined;
var index: usize = 0;
var mismatch = false;
var executable: [*:0]const u8 = undefined;
fn fact(expected: i64, observed: i64) void {
    _ = c.printf("mach516 case=%s fact=%zu expected=%lld observed=%lld\n", label, index, @as(c_longlong, expected), @as(c_longlong, observed));
    index += 1;
    mismatch = mismatch or expected != observed;
}
fn setup(ok: bool) void {
    if (!ok) c.atf_tc_fail("child setter test setup failed");
}
fn alloc() u32 {
    var p: u32 = 0;
    setup(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p) == 0);
    setup(c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND) == 0);
    return p;
}
const Observation = extern struct { result: i32 = 0, owned: i32 = 0 };
fn load(t: [*c]const c.atf_tc_t) void {
    var path: [4096]u8 = undefined;
    const n = c.snprintf(&path, path.len, "%s/rmx_translate_fixture.ko", c.atf_tc_get_config_var(t, "srcdir"));
    setup(n > 0 and n < path.len and c.kldload(&path) >= 0);
}
fn refs(p: u32) u32 {
    var result: Observation = .{};
    var size: usize = @sizeOf(Observation);
    setup(c.sysctlbyname("debug.rmx_child_send_count", &result, &size, &p, @sizeOf(u32)) == 0 and size == @sizeOf(Observation) and result.result == 0);
    return @intCast(result.owned);
}
fn project() Projection {
    var result: Projection = .{};
    for (selectors, 0..) |selector, i| {
        setup(c.task_get_special_port(c.mach_task_self(), selector, &result.special[i]) == 0);
    }
    var masks: [16]u32 = @splat(0);
    var ports: [16]u32 = @splat(0);
    var behaviors: [16]i32 = @splat(0);
    var flavors: [16]i32 = @splat(0);
    var count: u32 = 16;
    // EXC_MASK_ALL includes GUARD/RESOURCE; CRASH is checked separately by
    // the setter result while preserving the public EXC_MASK_ALL meaning.
    setup(c.task_get_exception_ports(c.mach_task_self(), c.EXC_MASK_GUARD | c.EXC_MASK_RESOURCE, &masks, &count, &ports, &behaviors, &flavors) == 0);
    for (0..count) |i| {
        result.mask |= masks[i];
        if (ports[i] != 0) {
            result.exception = ports[i];
            result.behavior = behaviors[i];
            result.flavor = flavors[i];
        }
    }
    var crash_index: u32 = c.EXC_CRASH;
    var crash_size: usize = @sizeOf(Action);
    setup(c.sysctlbyname("debug.rmx_child_crash", &result.crash, &crash_size, &crash_index, @sizeOf(u32)) == 0 and crash_size == @sizeOf(Action));
    return result;
}
fn sendTask(destination: u32) void {
    var p: Packet = std.mem.zeroes(Packet);
    p.header.msgh_bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND;
    p.header.msgh_size = @offsetOf(Packet, "trailer");
    p.header.msgh_remote_port = destination;
    p.header.msgh_id = 516;
    p.count = 1;
    p.port = .{ .name = c.mach_task_self(), .disposition = c.MACH_MSG_TYPE_COPY_SEND };
    setup(c.mach_msg(&p.header, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, p.header.msgh_size, 0, 0, 1000, 0) == 0);
}
const Child = struct { pid: c.pid_t, task: u32, command: c_int, result: c_int };
fn child() Child {
    const channel = alloc();
    setup(c.task_set_special_port(c.mach_task_self(), c.TASK_BOOTSTRAP_PORT, channel) == 0);
    var command: [2]c_int = undefined;
    var result: [2]c_int = undefined;
    setup(c.pipe(&command) == 0 and c.pipe(&result) == 0);
    const pid = c.fork();
    setup(pid >= 0);
    if (pid == 0) {
        _ = c.close(command[1]);
        _ = c.close(result[0]);
        var bootstrap: u32 = 0;
        setup(c.task_get_special_port(c.mach_task_self(), c.TASK_BOOTSTRAP_PORT, &bootstrap) == 0);
        sendTask(bootstrap);
        var mode: u8 = 0;
        setup(c.read(command[0], &mode, 1) == 1);
        if (mode == 'x') c._exit(0);
        if (mode == 'e') {
            // The helper is setuid and remains blocked on the same native
            // command pipe after committed exec; Mach names are not reused.
            var input: [24]u8 = undefined;
            var output: [24]u8 = undefined;
            _ = c.snprintf(&input, input.len, "%d", command[0]);
            _ = c.snprintf(&output, output.len, "%d", result[1]);
            _ = c.execl("./op516-setid-helper", "op516-setid-helper", "--op516-exec", &input, &output, @as(?*anyopaque, null));
            c._exit(99);
        }
        const projection = project();
        for (projection.special, 0..) |port, i| {
            if (port != 0) {
                var message = std.mem.zeroes(c.mach_msg_header_t);
                message.msgh_bits = c.MACH_MSG_TYPE_COPY_SEND;
                message.msgh_remote_port = port;
                message.msgh_size = @sizeOf(c.mach_msg_header_t);
                message.msgh_id = @intCast(51600 + i);
                setup(c.mach_msg(&message, c.MACH_SEND_MSG | c.MACH_SEND_TIMEOUT, message.msgh_size, 0, 0, 1000, 0) == 0);
            }
        }
        setup(c.write(result[1], &projection, @sizeOf(Projection)) == @sizeOf(Projection));
        c._exit(0);
    }
    _ = c.close(command[0]);
    _ = c.close(result[1]);
    var p: Packet = undefined;
    setup(c.mach_msg(&p.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Packet), channel, 1000, 0) == 0);
    return .{ .pid = pid, .task = p.port.name, .command = command[1], .result = result[0] };
}
fn finish(kid: Child, mode: u8) Projection {
    setup(c.write(kid.command, &mode, 1) == 1);
    var p: Projection = .{};
    if (mode != 'x') setup(c.read(kid.result, &p, @sizeOf(Projection)) == @sizeOf(Projection));
    var status: c_int = 0;
    setup(c.waitpid(kid.pid, &status, 0) == kid.pid and status == 0);
    _ = c.close(kid.command);
    _ = c.close(kid.result);
    return p;
}
fn unchanged(before: Projection, after: Projection) void {
    for (0..3) |i| fact(before.special[i], after.special[i]);
    fact(before.exception, after.exception);
    fact(before.behavior, after.behavior);
    fact(before.flavor, after.flavor);
    fact(before.crash.present, after.crash.present);
    fact(before.crash.behavior, after.crash.behavior);
    fact(before.crash.flavor, after.crash.flavor);
}
fn done() void {
    if (mismatch) c.atf_tc_fail("child task setter observations differ");
}
fn special(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    label = "special";
    index = 0;
    mismatch = false;
    const before = project();
    const kid = child();
    var ports: [3]u32 = undefined;
    for (selectors, 0..) |selector, i| {
        ports[i] = alloc();
        fact(0, c.task_set_special_port(kid.task, selector, ports[i]));
    }
    const seatbelt_before = refs(ports[0]);
    fact(c.KERN_NO_ACCESS, c.task_set_special_port(kid.task, c.TASK_SEATBELT_PORT, ports[0]));
    fact(seatbelt_before, refs(ports[0]));
    const access_before = refs(ports[1]);
    fact(c.KERN_NO_ACCESS, c.task_set_special_port(kid.task, c.TASK_ACCESS_PORT, ports[1]));
    fact(access_before, refs(ports[1]));

    const observed = finish(kid, 'p');
    // Names belong to the child space; non-null state is the projection,
    // parent input-right counts establish the held configuration rights.
    for (0..3) |i| {
        fact(1, @intFromBool(observed.special[i] != 0));
        var received: Packet = undefined;
        const rc = c.mach_msg(&received.header, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(Packet), ports[i], 100, 0);
        fact(0, rc);
        fact(@intCast(51600 + i), if (rc == 0) received.header.msgh_id else 0);
    }

    unchanged(before, project());
    done();
}
fn exception(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    label = "exception";
    index = 0;
    mismatch = false;
    const before = project();
    const kid = child();
    const port = alloc();
    const right_before = refs(port);
    fact(0, c.task_set_exception_ports(kid.task, launch_mask, port, launch_behavior, c.x86_THREAD_STATE));
    fact(right_before + 3, refs(port));
    const observed = finish(kid, 'p');
    fact(c.EXC_MASK_GUARD | c.EXC_MASK_RESOURCE, observed.mask);
    fact(1, @intFromBool(observed.exception != 0));
    fact(launch_behavior, observed.behavior);
    fact(c.x86_THREAD_STATE, observed.flavor);
    fact(1, observed.crash.present);
    fact(launch_behavior, observed.crash.behavior);
    fact(c.x86_THREAD_STATE, observed.crash.flavor);
    unchanged(before, project());
    done();
}
fn refused(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    label = "refused";
    index = 0;
    mismatch = false;
    const before = project();
    const kid = child();
    const port = alloc();
    const count = refs(port);
    fact(c.KERN_INVALID_ARGUMENT, c.task_set_special_port(kid.task, 999, port));
    fact(count, refs(port));
    fact(c.KERN_NOT_SUPPORTED, c.task_set_special_port(kid.task, c.TASK_BOOTSTRAP_PORT, port));
    fact(count, refs(port));
    fact(c.KERN_INVALID_ARGUMENT, c.task_set_exception_ports(kid.task, 0x40000000, port, launch_behavior, c.x86_THREAD_STATE));
    fact(count, refs(port));
    fact(c.KERN_INVALID_ARGUMENT, c.task_set_exception_ports(kid.task, launch_mask, port, 0x1234, c.x86_THREAD_STATE));
    fact(count, refs(port));
    fact(c.KERN_INVALID_ARGUMENT, c.task_set_exception_ports(kid.task, launch_mask, port, launch_behavior, 999));
    fact(count, refs(port));
    var got: u32 = 0;
    fact(c.KERN_NOT_SUPPORTED, c.task_get_special_port(kid.task, c.TASK_DEBUG_CONTROL_PORT, &got));
    var kind: u32 = 0;
    fact(c.KERN_NOT_SUPPORTED, c.mach_port_type(kid.task, port, &kind));
    var allocated: u32 = 0;
    fact(c.KERN_NOT_SUPPORTED, c.mach_port_allocate(kid.task, c.MACH_PORT_RIGHT_RECEIVE, &allocated));
    fact(0, @intFromBool(allocated != 0));
    if (allocated != 0) _ = c.mach_port_destroy(c.mach_task_self(), allocated);
    var address: c.mach_vm_address_t = 0;

    fact(c.KERN_NOT_SUPPORTED, c.mach_vm_allocate(kid.task, &address, 4096, 1));
    // Raw host-family request on a task destination must fail before any
    // converter; a complex descriptor also checks refusal right ownership.
    var request: Packet = std.mem.zeroes(Packet);
    const reply = alloc();
    request.header.msgh_bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND | (c.MACH_MSG_TYPE_MAKE_SEND_ONCE << 8);
    request.header.msgh_size = @offsetOf(Packet, "trailer");
    request.header.msgh_remote_port = kid.task;
    request.header.msgh_local_port = reply;
    request.header.msgh_id = 200;
    request.count = 1;
    request.port = .{ .name = port, .disposition = c.MACH_MSG_TYPE_COPY_SEND };
    const rc = c.mach_msg(&request.header, c.MACH_SEND_MSG | c.MACH_RCV_MSG | c.MACH_SEND_TIMEOUT | c.MACH_RCV_TIMEOUT, request.header.msgh_size, @sizeOf(Packet), reply, 1000, 0);
    fact(0, rc);
    const Error = extern struct { header: c.mach_msg_header_t, ndr: [8]u8, result: i32 };
    fact(c.MIG_BAD_ID, (@as(*Error, @ptrCast(&request))).result);
    fact(count, refs(port));
    _ = finish(kid, 'p');
    unchanged(before, project());
    done();
}
fn staleExit(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    label = "stale_exit";
    index = 0;
    mismatch = false;
    const before = project();
    const kid = child();
    const port = alloc();
    _ = finish(kid, 'x');
    const count = refs(port);
    const a = c.task_set_special_port(kid.task, c.TASK_DEBUG_CONTROL_PORT, port);
    const b = c.task_set_exception_ports(kid.task, launch_mask, port, launch_behavior, c.x86_THREAD_STATE);
    fact(1, @intFromBool(a == c.KERN_INVALID_TASK or a == c.MACH_SEND_INVALID_DEST));
    fact(1, @intFromBool(b == c.KERN_INVALID_TASK or b == c.MACH_SEND_INVALID_DEST));
    fact(count, refs(port));
    unchanged(before, project());
    done();
}
fn staleExec(t: [*c]const c.atf_tc_t) callconv(.c) void {
    load(t);
    label = "stale_exec";
    index = 0;
    mismatch = false;
    const input = c.open(executable, c.O_RDONLY);
    const output = c.open("./op516-setid-helper", c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o755));
    setup(input >= 0 and output >= 0);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = c.read(input, &buffer, buffer.len);
        setup(n >= 0);
        if (n == 0) break;
        setup(c.write(output, &buffer, @intCast(n)) == n);
    }
    _ = c.close(input);
    setup(c.fchown(output, 65534, 65534) == 0 and c.fchmod(output, 0o4755) == 0);
    _ = c.close(output);
    const before = project();
    const kid = child();
    var mode: u8 = 'e';
    setup(c.write(kid.command, &mode, 1) == 1);
    var uid: c.uid_t = 0;
    setup(c.read(kid.result, &uid, @sizeOf(c.uid_t)) == @sizeOf(c.uid_t));
    fact(65534, uid);
    const port = alloc();
    const count = refs(port);
    const a = c.task_set_special_port(kid.task, c.TASK_DEBUG_CONTROL_PORT, port);
    const b = c.task_set_exception_ports(kid.task, launch_mask, port, launch_behavior, c.x86_THREAD_STATE);
    fact(1, @intFromBool(a == c.KERN_INVALID_TASK or a == c.MACH_SEND_INVALID_DEST));
    fact(1, @intFromBool(b == c.KERN_INVALID_TASK or b == c.MACH_SEND_INVALID_DEST));
    fact(count, refs(port));
    const observed = finish(kid, 'p');
    fact(0, observed.special[2]);
    fact(0, observed.exception);
    unchanged(before, project());
    _ = c.unlink("./op516-setid-helper");
    done();
}
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const module = c.kldfind("rmx_translate_fixture.ko");
    if (module >= 0) _ = c.kldunload(module);
    _ = c.unlink("./op516-setid-helper");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "special", "exception", "refused", "stale_exit", "stale_exec" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &special, &exception, &refused, &staleExit, &staleExec };
    for (names, bodies, 0..) |name, body, i| {
        const err = c.atf_tc_init(&cases[i], name, &head, body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        _ = c.atf_tp_add_tc(tp, &cases[i]);
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--op516-exec")) {
        const input = c.atoi(argv[2]);
        const output = c.atoi(argv[3]);
        const uid = c.geteuid();
        setup(c.write(output, &uid, @sizeOf(c.uid_t)) == @sizeOf(c.uid_t));
        var mode: u8 = 0;
        setup(c.read(input, &mode, 1) == 1);
        const p = project();
        setup(c.write(output, &p, @sizeOf(Projection)) == @sizeOf(Projection));
        return 0;
    }
    executable = argv[0];
    return atf_tp_main(argc, argv, &add);
}
