// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const inventory = @import("fd_inventory.zig");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("launch.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/ndr.h");
    @cInclude("mach/mig_errors.h");
    @cInclude("servers/bootstrap.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/wait.h");
    @cInclude("pthread.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
    @cInclude("sys/resource.h");
    @cInclude("signal.h");
    @cInclude("time.h");
});
const O = ?*anyopaque;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn launch_data_pack(c.launch_data_t, [*]u8, usize, ?[*]c_int, usize, ?*usize) usize;
extern fn launch_data_new_errno(c_int) c.launch_data_t;
extern fn launchd_fdopen(c_int, c_int) O;
extern fn launchd_msg_send(O, c.launch_data_t) c_int;
extern fn launchd_msg_recv(O, *const fn (c.launch_data_t, O) callconv(.c) void, O) c_int;
extern fn mig_get_reply_port() u32;
extern fn op674_get_reply(u32, *usize, *u32, *u32) c_int;
extern fn xpc_pipe_try_receive(u32, *O, *u32, *const fn (*Header, *Header) callconv(.c) c_int, u32, c_int) c_int;
extern fn notifyd_mach_receive_error(c_int, *Header) void;
extern fn notifyd_mach_send_result(c_int, *Header) void;
extern fn dispatch_queue_create([*:0]const u8, O) O;
extern fn dispatch_async_f(O, O, *const fn (O) callconv(.c) void) void;
extern fn dispatch_source_create(O, usize, usize, O) O;
extern var _dispatch_source_type_mach_recv: u8;
extern fn dispatch_resume(O) void;
extern fn dispatch_source_cancel(O) void;
extern fn dispatch_release(O) void;
extern fn dispatch_mig_server(O, usize, *const fn (*Header, *Header) callconv(.c) c_int) c_int;
const Header = extern struct { bits: u32, size: u32, remote: u32, local: u32, voucher: u32 = 0, id: i32 };
const Ool = extern struct { address: usize, deallocate: u8 = 0, copy: u8 = c.MACH_MSG_VIRTUAL_COPY, pad: u8 = 0, kind: u8 = c.MACH_MSG_OOL_DESCRIPTOR, size: u32 };
const Ports = extern struct { address: usize = 0, deallocate: u8 = 0, copy: u8 = c.MACH_MSG_VIRTUAL_COPY, disposition: u8 = c.MACH_MSG_TYPE_MOVE_SEND, kind: u8 = c.MACH_MSG_OOL_PORTS_DESCRIPTOR, count: u32 = 0 };
const Port = extern struct { name: u32, pad: u32 = 0, pad2: u16 = 0, disposition: u8, kind: u8 = c.MACH_MSG_PORT_DESCRIPTOR };
fn put(bytes: []u8, offset: usize, value: anytype) void {
    const T = @TypeOf(value);
    const p: *align(1) T = @ptrCast(bytes[offset..].ptr);
    p.* = value;
}
fn check(ok: bool, what: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", what);
}
fn kr(result: c_int, what: [*:0]const u8) void {
    if (result != 0) c.atf_tc_fail("%s kr=%d", what, result);
}
fn alloc(size: usize) usize {
    var address: usize = 0;
    kr(c.mach_vm_allocate(c.mach_task_self(), &address, size, 1), "mapping allocate");
    return address;
}
fn freeMap(address: usize, size: usize) void {
    kr(c.mach_vm_deallocate(c.mach_task_self(), address, size), "mapping release");
}
fn port() u32 {
    var p: u32 = 0;
    kr(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &p), "receive allocate");
    return p;
}
fn makeSend(p: u32) void {
    kr(c.mach_port_insert_right(c.mach_task_self(), p, p, c.MACH_MSG_TYPE_MAKE_SEND), "make send");
}
fn destroy(p: u32) void {
    kr(c.mach_port_destroy(c.mach_task_self(), p), "port destroy");
}
fn refs(p: u32) u32 {
    var n: u32 = 0;
    kr(c.mach_port_get_refs(c.mach_task_self(), p, c.MACH_PORT_RIGHT_SEND, &n), "send refs");
    return n;
}
fn send(bytes: []u8) void {
    const h: *align(1) Header = @ptrCast(bytes.ptr);
    kr(c.mach_msg(@ptrCast(@alignCast(bytes.ptr)), c.MACH_SEND_MSG, h.size, 0, 0, 0, 0), "message send");
}
fn receive(bytes: []u8, p: u32) c_int {
    return c.mach_msg(@ptrCast(@alignCast(bytes.ptr)), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @intCast(bytes.len), p, 5000, 0);
}
const Maps = struct { count: usize = 0, bytes: u64 = 0 };
fn maps(pid: c_int) Maps {
    var cmd: [96]u8 = undefined;
    _ = c.snprintf(&cmd, cmd.len, "/usr/bin/procstat -v %d", pid);
    const fp = c.popen(&cmd, "r");
    check(fp != null, "procstat open");
    var line: [2048]u8 = undefined;
    var result: Maps = .{};
    while (c.fgets(&line, line.len, fp) != null) {
        var observed: c_int = 0;
        var start: c_ulonglong = 0;
        var end: c_ulonglong = 0;
        if (c.sscanf(&line, "%d %llx %llx", &observed, &start, &end) == 3 and observed == pid) {
            check(end >= start, "map extent");
            result.count += 1;
            result.bytes += end - start;
        }
    }
    check(c.pclose(fp) == 0 and result.count > 0, "procstat complete nonempty inventory");
    return result;
}
fn ports(pid: c_int) usize {
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_FILEDESC, pid };
    var bytes: [128 * 1024]u8 = undefined;
    var length: usize = bytes.len;
    check(c.sysctl(&mib, mib.len, &bytes, &length, null, 0) == 0, "port inventory");
    return inventory.countPorts(bytes[0..length]) catch c.atf_tc_fail("invalid port records");
}
fn sameMaps(before: Maps, after: Maps, label: [*:0]const u8) void {
    _ = c.printf("%s maps_before=%zu maps_after=%zu bytes_before=%llu bytes_after=%llu\n", label, before.count, after.count, @as(c_ulonglong, before.bytes), @as(c_ulonglong, after.bytes));
    check(before.count == after.count and before.bytes == after.bytes, "mapping inventory changed");
}
fn ordinary() void {
    const q = c.launch_data_new_string("GetResourceUsageSelf");
    check(q != null, "ordinary allocation");
    const r = c.launch_msg(q);
    check(r != null and c.launch_data_get_type(r) == c.LAUNCH_DATA_OPAQUE, "ordinary launchd reply");
    c.launch_data_free(q);
    c.launch_data_free(r);
}
const SocketState = struct { channel: O, calls: u32 = 0, large: bool = false };
fn socketCallback(q: c.launch_data_t, value: O) callconv(.c) void {
    const state: *SocketState = @ptrCast(@alignCast(value.?));
    if (state.calls == 0) {
        if (c.launch_data_get_type(q) != c.LAUNCH_DATA_OPAQUE or c.launch_data_get_opaque_size(q) != 2 * 1024 * 1024) c._exit(21);
        const p: [*]const u8 = @ptrCast(c.launch_data_get_opaque(q));
        if (p[0] != 0x6a or p[2 * 1024 * 1024 - 1] != 0x6a) c._exit(22);
        state.large = true;
    }
    const r = launch_data_new_errno(0);
    if (r == null or launchd_msg_send(state.channel, r) != 0) c._exit(23);
    c.launch_data_free(r);
    state.calls += 1;
}
fn socketLarge(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var path: [96]u8 = undefined;
    _ = c.snprintf(&path, path.len, "/tmp/op674-socket-%d", c.getpid());
    var address = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    address.sun_len = @sizeOf(@TypeOf(address));
    const p = std.mem.span(@as([*:0]u8, @ptrCast(&path)));
    @memcpy(address.sun_path[0..p.len], p);
    _ = c.unlink(&path);
    const listener = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    check(listener >= 0, "socket listener");
    check(c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))) == 0 and c.listen(listener, 1) == 0, "socket bind/listen");
    const child = c.fork();
    check(child >= 0, "socket server fork");
    if (child == 0) {
        const accepted = c.accept(listener, null, null);
        if (accepted < 0) c._exit(20);
        var state: SocketState = .{ .channel = launchd_fdopen(accepted, -1) };
        while (state.calls < 2) {
            if (launchd_msg_recv(state.channel, &socketCallback, &state) < 0 and c.__error().* != c.EAGAIN) c._exit(24);
        }
        c._exit(if (state.large) 0 else 25);
    }
    _ = c.close(listener);
    const saved = c.bootstrap_port;
    c.bootstrap_port = 0;
    check(c.setenv("LAUNCHD_SOCKET", &path, 1) == 0, "socket path environment");
    const memory = alloc(2 * 1024 * 1024);
    @memset(@as([*]u8, @ptrFromInt(memory))[0 .. 2 * 1024 * 1024], 0x6a);
    const q = c.launch_data_new_opaque(@ptrFromInt(memory), 2 * 1024 * 1024);
    check(q != null, "large opaque request");
    const r = c.launch_msg(q);
    check(r != null and c.launch_data_get_type(r) == c.LAUNCH_DATA_ERRNO and c.launch_data_get_errno(r) == 0, "large socket round trip");
    c.launch_data_free(r);
    c.launch_data_free(q);
    freeMap(memory, 2 * 1024 * 1024);
    const fd = c.open("/dev/null", c.O_RDONLY);
    check(fd >= 0, "refusal caller fd");
    const fdq = c.launch_data_new_fd(fd);
    check(c.launch_msg(fdq) == null and c.__error().* == c.ENOTSUP, "socket FD refusal");
    check(c.fcntl(fd, c.F_GETFD) >= 0, "socket refusal preserves caller fd");
    c.launch_data_free(fdq);
    _ = c.close(fd);
    const recovery = c.launch_data_new_string("recovery");
    const rr = c.launch_msg(recovery);
    check(rr != null and c.launch_data_get_errno(rr) == 0, "socket recovery");
    c.launch_data_free(recovery);
    c.launch_data_free(rr);
    var status: c_int = 0;
    check(c.waitpid(child, &status, 0) == child and status == 0, "socket server completed two requests");
    c.bootstrap_port = saved;
    _ = c.unlink(&path);
    _ = c.printf("ownership_socket payload_bytes=2097152 fd_errno=%d recovery=0\n", c.ENOTSUP);
}
fn launchdNoReply(_: [*c]const c.atf_tc_t) callconv(.c) void {
    ordinary();
    ordinary();
    const memory = alloc(4096);
    const q = c.launch_data_new_string("GetResourceUsageSelf");
    const count = launch_data_pack(q, @as([*]u8, @ptrFromInt(memory)), 4096, null, 0, null);
    check(count > 0, "no reply request pack");
    c.launch_data_free(q);
    _ = maps(1);
    const before = maps(1);
    const rights_before = ports(1);
    for (0..100) |_| {
        var bytes: [88]u8 align(8) = @splat(0);
        put(&bytes, 0, Header{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = bytes.len, .remote = c.bootstrap_port, .local = 0, .id = 437 });
        put(&bytes, 24, @as(u32, 3));
        put(&bytes, 28, Ool{ .address = memory, .size = @intCast(count) });
        put(&bytes, 44, Ports{});
        put(&bytes, 60, Port{ .name = 0, .disposition = c.MACH_MSG_TYPE_COPY_SEND });
        put(&bytes, 72, c.NDR_record);
        put(&bytes, 80, @as(u32, @intCast(count)));
        send(&bytes);
    }
    // A same-port synchronous ordinary RPC is a FIFO service barrier.
    ordinary();
    const after = maps(1);
    const rights_after = ports(1);
    _ = c.printf("ownership_launchd_no_reply requests=100 ports_before=%zu ports_after=%zu\n", rights_before, rights_after);
    sameMaps(before, after, "ownership_launchd_no_reply");
    check(rights_before == rights_after, "no reply launchd rights");
    freeMap(memory, 4096);
}
const ReplyServer = struct { endpoint: u32, watch: u32, ready: std.atomic.Value(bool) = .init(false), done: std.atomic.Value(bool) = .init(false), release: std.atomic.Value(bool) = .init(false), failed: std.atomic.Value(bool) = .init(false) };
fn replyServer(value: O) callconv(.c) O {
    const s: *ReplyServer = @ptrCast(@alignCast(value.?));
    s.ready.store(true, .seq_cst);
    for (0..101) |_| {
        var request: [256]u8 align(8) = @splat(0);
        if (receive(&request, s.endpoint) != 0) {
            s.failed.store(true, .seq_cst);
            break;
        }
        const input: *Header = @ptrCast(&request);
        var response: [64]u8 align(8) = @splat(0);
        const memory = alloc(4096);
        put(&response, 0, Header{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_MOVE_SEND_ONCE, .size = response.len, .remote = input.remote, .local = 0, .id = input.id + 101 });
        put(&response, 24, @as(u32, 2));
        put(&response, 28, Ool{ .address = memory, .deallocate = 1, .size = 4096 });
        put(&response, 44, Port{ .name = s.watch, .disposition = c.MACH_MSG_TYPE_MAKE_SEND });
        put(&response, 56, c.NDR_record);
        send(&response);
    }
    s.done.store(true, .seq_cst);
    while (!s.release.load(.seq_cst)) _ = c.usleep(1000);
    return null;
}
fn mismatchedReply(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var server: ReplyServer = .{ .endpoint = port(), .watch = port() };
    makeSend(server.endpoint);
    makeSend(server.watch);
    _ = mig_get_reply_port();
    var thread: c.pthread_t = undefined;
    check(c.pthread_create(&thread, null, &replyServer, &server) == 0, "reply server thread");
    while (!server.ready.load(.seq_cst)) _ = c.usleep(1000);
    var data: usize = 0;
    var count: u32 = 0;
    var right: u32 = 0;
    check(op674_get_reply(server.endpoint, &data, &count, &right) == c.MIG_REPLY_MISMATCH, "warm mismatched ID");
    _ = maps(c.getpid());
    _ = ports(c.getpid());
    const before = maps(c.getpid());
    const rights_before = ports(c.getpid());
    for (0..100) |_| {
        check(op674_get_reply(server.endpoint, &data, &count, &right) == c.MIG_REPLY_MISMATCH, "generated reply ID rejection");
        check(data == 0 and count == 0 and right == 0, "rejected outputs unpublished");
    }
    while (!server.done.load(.seq_cst)) _ = c.usleep(1000);
    const after = maps(c.getpid());
    const rights_after = ports(c.getpid());
    const send_refs = refs(server.watch);
    server.release.store(true, .seq_cst);
    check(c.pthread_join(thread, null) == 0, "reply server join");
    _ = c.printf("ownership_mig_mismatch requests=100 ports_before=%zu ports_after=%zu expected_send_refs=1 observed_send_refs=%u\n", rights_before, rights_after, send_refs);
    sameMaps(before, after, "ownership_mig_mismatch");
    check(!server.failed.load(.seq_cst) and rights_before == rights_after and send_refs == 1, "generated reject release");
    destroy(server.endpoint);
    destroy(server.watch);
}
fn notifyPid() c_int {
    const fp = c.popen("/usr/bin/pgrep -x notifyd", "r");
    check(fp != null, "notifyd PID query");
    var pid: c_int = 0;
    check(c.fscanf(fp, "%d", &pid) == 1 and pid > 1, "notifyd PID");
    check(c.pclose(fp) == 0, "notifyd PID status");
    return pid;
}
fn notifyRequest(server: u32, memory: usize, reply: u32, watch: u32, bad: bool) c_int {
    var bytes: [256]u8 align(8) = @splat(0);
    const size: u32 = if (bad) 68 else 56;
    put(&bytes, 0, Header{ .bits = @as(u32, c.MACH_MSGH_BITS_COMPLEX) | c.MACH_MSG_TYPE_COPY_SEND | (c.MACH_MSG_TYPE_MAKE_SEND_ONCE << 8), .size = size, .remote = server, .local = reply, .id = 78945668 });
    put(&bytes, 24, @as(u32, if (bad) 2 else 1));
    put(&bytes, 28, Ool{ .address = memory, .size = 8192 });
    const offset: usize = if (bad) 56 else 44;
    if (bad) {
        makeSend(watch);
        put(&bytes, 44, Port{ .name = watch, .disposition = c.MACH_MSG_TYPE_MOVE_SEND });
    }
    put(&bytes, offset, c.NDR_record);
    put(&bytes, offset + 8, @as(u32, 8192));
    send(&bytes);
    kr(receive(&bytes, reply), "notify error reply receive");
    const ret: *align(1) const c_int = @ptrCast(bytes[32..].ptr);
    return ret.*;
}
fn notifyRejected(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var server: u32 = 0;
    kr(c.bootstrap_look_up(c.bootstrap_port, "com.apple.system.notification_center", &server), "notify service lookup");
    const pid = notifyPid();
    const reply = port();
    const watch = port();
    const memory = alloc(8192);
    const name: [*]u8 = @ptrFromInt(memory);
    @memset(name[0..8192], 'n');
    name[8191] = 0;
    kr(notifyRequest(server, memory, reply, watch, false), "notify warm request");
    kr(notifyRequest(server, memory, reply, watch, false), "notify warm barrier");
    _ = maps(pid);
    const before = maps(pid);
    const rights_before = ports(pid);
    for (0..100) |_| check(notifyRequest(server, memory, reply, watch, true) == c.MIG_BAD_ARGUMENTS, "notify descriptor-count error");
    kr(notifyRequest(server, memory, reply, watch, false), "notify recovery barrier");
    const after = maps(pid);
    const rights_after = ports(pid);
    _ = c.printf("ownership_notify_rejected requests=100 expected_error=%d ports_before=%zu ports_after=%zu\n", c.MIG_BAD_ARGUMENTS, rights_before, rights_after);
    sameMaps(before, after, "ownership_notify_rejected");
    check(rights_before == rights_after and refs(watch) == 0, "notify rejected request rights release");
    destroy(reply);
    destroy(watch);
    kr(c.mach_port_deallocate(c.mach_task_self(), server), "notify lookup release");
    freeMap(memory, 8192);
}
var direct_mode: u32 = 0;
var direct_destination: u32 = 0;
var direct_watch: u32 = 0;
fn directDemux(_: *Header, response: *Header) callconv(.c) c_int {
    const bytes: [*]u8 = @ptrCast(response);
    if (direct_mode == 4) {
        response.* = .{ .bits = 0, .size = 36, .remote = 0, .local = 0, .id = 67424 };
        put(bytes[0..36], 24, c.NDR_record);
        put(bytes[0..36], 32, @as(c_int, c.MIG_BAD_ARGUMENTS));
        return 1;
    }
    const memory = alloc(4096);
    makeSend(direct_watch);
    const len: usize = if (direct_mode == 3) 68 else 56;
    response.* = .{ .bits = @as(u32, c.MACH_MSGH_BITS_COMPLEX) | c.MACH_MSG_TYPE_MOVE_SEND, .size = @intCast(len), .remote = if (direct_mode == 0) 0 else direct_destination, .local = 0, .id = 67420 };
    put(bytes[0..len], 24, @as(u32, if (direct_mode == 3) 3 else 2));
    put(bytes[0..len], 28, Ool{ .address = memory, .deallocate = 1, .size = 4096 });
    put(bytes[0..len], 44, Port{ .name = direct_watch, .disposition = c.MACH_MSG_TYPE_MOVE_SEND });
    if (direct_mode == 3) put(bytes[0..len], 56, Port{ .name = 0x7ffffffe, .disposition = c.MACH_MSG_TYPE_MOVE_SEND });
    return 1;
}
fn xpcUnsent(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const service = port();
    makeSend(service);
    direct_watch = port();
    makeSend(direct_watch);
    const request_memory = alloc(4096);
    for (0..5) |mode| {
        direct_mode = @intCast(mode);
        direct_destination = port();
        makeSend(direct_destination);
        if (mode == 1) kr(c.mach_port_mod_refs(c.mach_task_self(), direct_destination, c.MACH_PORT_RIGHT_RECEIVE, -1), "dead reply destination");
        if (mode == 2) {
            // Default qlimit is five: fill it without waiting on a receiver.
            for (0..5) |_| {
                var h: Header = .{ .bits = c.MACH_MSG_TYPE_COPY_SEND, .size = 24, .remote = direct_destination, .local = 0, .id = 67421 };
                send(std.mem.asBytes(&h));
            }
        }
        _ = maps(c.getpid());
        const before = maps(c.getpid());
        const rights_before = refs(direct_watch);
        var request: [56]u8 align(8) = @splat(0);
        put(&request, 0, Header{ .bits = @as(u32, c.MACH_MSG_TYPE_COPY_SEND) | (if (mode == 4) @as(u32, c.MACH_MSGH_BITS_COMPLEX) else 0), .size = if (mode == 4) 56 else 24, .remote = service, .local = 0, .id = 67422 });
        if (mode == 4) {
            put(&request, 24, @as(u32, 2));
            put(&request, 28, Ool{ .address = request_memory, .size = 4096 });
            put(&request, 44, Port{ .name = direct_watch, .disposition = c.MACH_MSG_TYPE_COPY_SEND });
        }
        send(&request);
        var object: O = null;
        var remote: u32 = 0;
        check(xpc_pipe_try_receive(service, &object, &remote, &directDemux, 8192, 0) == 1, "XPC demux handled");
        const after = maps(c.getpid());
        const rights_after = refs(direct_watch);
        _ = c.printf("ownership_xpc_unsent mode=%u expected_send_refs=%u observed_send_refs=%u\n", direct_mode, rights_before, rights_after);
        sameMaps(before, after, "ownership_xpc_unsent");
        check(rights_before == rights_after, "XPC send-result right ownership");
        if (mode == 1) {
            var typ: u32 = 0;
            check(c.mach_port_type(c.mach_task_self(), direct_destination, &typ) == c.KERN_INVALID_NAME, "dead destination right released");
        } else destroy(direct_destination);
    }
    destroy(direct_watch);
    destroy(service);
    freeMap(request_memory, 4096);
}
var drain_entered: std.atomic.Value(bool) = .init(false);
var drain_release: std.atomic.Value(bool) = .init(false);
var demux_calls: u32 = 0;
fn holdQueue(_: O) callconv(.c) void {
    drain_entered.store(true, .seq_cst);
    while (!drain_release.load(.seq_cst)) _ = c.usleep(1000);
}
fn unexpectedDemux(_: *Header, _: *Header) callconv(.c) c_int {
    demux_calls += 1;
    return 0;
}
fn dispatchLarge(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const service = port();
    makeSend(service);
    const watch = port();
    makeSend(watch);
    const memory = alloc(4096);
    const q = dispatch_queue_create("op674.mig.receive", null);
    check(q != null, "dispatch target queue");
    dispatch_async_f(q, null, &holdQueue);
    while (!drain_entered.load(.seq_cst)) _ = c.usleep(1000);
    const source = dispatch_source_create(&_dispatch_source_type_mach_recv, service, 0, q);
    check(source != null, "dispatch receive source");
    // The blocked target queue prevents manager installation/claiming. Resume
    // clears suspension so the public MIG server can consume this port directly.
    dispatch_resume(source);
    _ = maps(c.getpid());
    var before: Maps = .{};
    const rights_before = refs(watch);
    // Warm the diagnostic allocation/logging path before measuring ownership.
    for (0..11) |i| {
        var bytes: [4096]u8 align(8) = @splat(0);
        put(&bytes, 0, Header{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = bytes.len, .remote = service, .local = 0, .id = 67430 });
        put(&bytes, 24, @as(u32, 2));
        put(&bytes, 28, Ool{ .address = memory, .size = 4096 });
        put(&bytes, 44, Port{ .name = watch, .disposition = c.MACH_MSG_TYPE_COPY_SEND });
        send(&bytes);
        check(dispatch_mig_server(source, 128, &unexpectedDemux) == c.MACH_RCV_TOO_LARGE, "dispatch oversized receive status");
        check(refs(watch) == rights_before, "dispatch discarded receive rights");
        if (i == 0) before = maps(c.getpid());
    }
    const after = maps(c.getpid());
    drain_release.store(true, .seq_cst);
    dispatch_source_cancel(source);
    dispatch_release(source);
    dispatch_release(q);
    _ = c.printf("ownership_dispatch_large requests=10 expected_demux=0 observed_demux=%u expected_send_refs=%u observed_send_refs=%u\n", demux_calls, rights_before, refs(watch));
    sameMaps(before, after, "ownership_dispatch_large");
    check(demux_calls == 0, "oversized request must not demux");
    freeMap(memory, 4096);
    destroy(watch);
    // The canceled source owns its registration lifetime; exit cleans up the
    // receive name after asynchronous cancellation has completed.
}
fn rejectedLaunchRequest(memory: usize, reply: u32, watch: u32) void {
    var names = [_]u32{watch};
    var bytes: [256]u8 align(8) = @splat(0);
    put(&bytes, 0, Header{ .bits = @as(u32, c.MACH_MSGH_BITS_COMPLEX) | c.MACH_MSG_TYPE_COPY_SEND | (c.MACH_MSG_TYPE_MAKE_SEND_ONCE << 8), .size = 88, .remote = c.bootstrap_port, .local = reply, .id = 437 });
    put(&bytes, 24, @as(u32, 3));
    put(&bytes, 28, Ool{ .address = memory, .size = 8192 });
    put(&bytes, 44, Ports{ .address = @intFromPtr(&names), .disposition = c.MACH_MSG_TYPE_COPY_SEND, .count = 1 });
    put(&bytes, 60, Port{ .name = watch, .disposition = c.MACH_MSG_TYPE_COPY_SEND });
    put(&bytes, 72, c.NDR_record);
    put(&bytes, 80, @as(u32, 8192));
    put(&bytes, 84, @as(u32, 1));
    send(&bytes);
    kr(receive(&bytes, reply), "handler rejection reply");
    const h: *Header = @ptrCast(&bytes);
    const code: *align(1) const c_int = @ptrCast(bytes[32..].ptr);
    check(h.id == 537 and h.bits & c.MACH_MSGH_BITS_COMPLEX == 0 and code.* == c.KERN_NOT_SUPPORTED, "handler rejected received descriptors");
}
fn launchdHandlerRejected(_: [*c]const c.atf_tc_t) callconv(.c) void {
    ordinary();
    const reply = port();
    const watch = port();
    makeSend(watch);
    const memory = alloc(8192);
    @memset(@as([*]u8, @ptrFromInt(memory))[0..8192], 0xa5);
    rejectedLaunchRequest(memory, reply, watch);
    rejectedLaunchRequest(memory, reply, watch);
    ordinary();
    _ = maps(1);
    const before = maps(1);
    const rights_before = ports(1);
    for (0..100) |_| rejectedLaunchRequest(memory, reply, watch);
    ordinary();
    const after = maps(1);
    const rights_after = ports(1);
    _ = c.printf("ownership_launchd_handler requests=100 expected_error=%d ports_before=%zu ports_after=%zu expected_send_refs=1 observed_send_refs=%u recovery=0\n", c.KERN_NOT_SUPPORTED, rights_before, rights_after, refs(watch));
    sameMaps(before, after, "ownership_launchd_handler");
    check(rights_before == rights_after and refs(watch) == 1, "handler error release inventory");
    destroy(reply);
    destroy(watch);
    freeMap(memory, 8192);
}
fn notMig(_: *Header, _: *Header) callconv(.c) c_int {
    return 0;
}
fn malformedXpcRequest(service: u32, memory: usize, reply: u32, watch: u32) void {
    var bytes: [56]u8 align(8) = @splat(0);
    put(&bytes, 0, Header{ .bits = @as(u32, c.MACH_MSGH_BITS_COMPLEX) | c.MACH_MSG_TYPE_COPY_SEND | (c.MACH_MSG_TYPE_MAKE_SEND_ONCE << 8), .size = bytes.len, .remote = service, .local = reply, .id = 69901 });
    put(&bytes, 24, @as(u32, 2));
    put(&bytes, 28, Ool{ .address = memory, .size = 4096 });
    put(&bytes, 44, Port{ .name = watch, .disposition = c.MACH_MSG_TYPE_COPY_SEND });
    send(&bytes);
    var object: O = null;
    var remote: u32 = 0;
    check(xpc_pipe_try_receive(service, &object, &remote, &notMig, 8192, 0) == c.EINVAL and object == null, "malformed non-XPC rejection");
}
fn xpcMalformed(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const service = port();
    const reply = port();
    const watch = port();
    makeSend(service);
    makeSend(watch);
    const memory = alloc(4096);
    @memset(@as([*]u8, @ptrFromInt(memory))[0..4096], 0xa5);
    malformedXpcRequest(service, memory, reply, watch);
    _ = maps(c.getpid());
    _ = ports(c.getpid());
    const before = maps(c.getpid());
    const rights_before = ports(c.getpid());
    for (0..100) |_| malformedXpcRequest(service, memory, reply, watch);
    const after = maps(c.getpid());
    const rights_after = ports(c.getpid());
    _ = c.printf("ownership_xpc_malformed requests=100 expected_error=%d ports_before=%zu ports_after=%zu expected_send_refs=1 observed_send_refs=%u\n", c.EINVAL, rights_before, rights_after, refs(watch));
    sameMaps(before, after, "ownership_xpc_malformed");
    check(rights_before == rights_after and refs(watch) == 1, "malformed XPC release inventory");
    freeMap(memory, 4096);
    destroy(service);
    destroy(reply);
    destroy(watch);
}
fn bodyErrorOnce(service: u32, memory: usize, watch: u32, file: c_int) c_int {
    var bytes: [256]u8 align(8) = @splat(0);
    put(&bytes, 0, Header{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = 68, .remote = service, .local = 0, .id = 69902 });
    put(&bytes, 24, @as(u32, 3));
    put(&bytes, 28, Ool{ .address = memory, .size = 4096 });
    put(&bytes, 44, Port{ .name = watch, .disposition = c.MACH_MSG_TYPE_COPY_SEND });
    put(&bytes, 56, Port{ .name = @intCast(file), .disposition = c.MACH_MSG_TYPE_COPY_SEND });
    send(&bytes);
    var limit: c.struct_rlimit = undefined;
    check(c.getrlimit(c.RLIMIT_NOFILE, &limit) == 0, "get descriptor limit");
    var small = limit;
    small.rlim_cur = @min(limit.rlim_cur, 128);
    check(c.setrlimit(c.RLIMIT_NOFILE, &small) == 0, "limit test receiver descriptors");
    var filled: [128]c_int = undefined;
    var count: usize = 0;
    while (count < filled.len) {
        const fd = c.dup(file);
        if (fd < 0) break;
        filled[count] = fd;
        count += 1;
    }
    const exhausted = count < filled.len and c.__error().* == c.EMFILE;
    const status = receive(&bytes, service);
    for (filled[0..count]) |fd| _ = c.close(fd);
    check(c.setrlimit(c.RLIMIT_NOFILE, &limit) == 0, "restore test descriptor limit");
    check(exhausted and status & ~@as(c_int, c.MACH_MSG_MASK) == c.MACH_RCV_BODY_ERROR, "real partial body receive");
    const ool: *align(1) const Ool = @ptrCast(bytes[28..].ptr);
    check(ool.address != 0 and ool.size == 4096, "partial receive handed over OOL mapping");
    notifyd_mach_receive_error(status, @ptrCast(&bytes));
    check(refs(watch) == 1, "partial receive cleanup send refs");
    return status;
}
fn notifyBodyError(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const service = port();
    const watch = port();
    makeSend(service);
    makeSend(watch);
    const memory = alloc(4096);
    const file = c.open("/dev/null", c.O_RDONLY);
    check(file >= 0, "body error file descriptor");
    _ = bodyErrorOnce(service, memory, watch, file);
    _ = maps(c.getpid());
    const before = maps(c.getpid());
    const rights_before = ports(c.getpid());
    var status: c_int = 0;
    for (0..100) |_| status = bodyErrorOnce(service, memory, watch, file);
    const after = maps(c.getpid());
    const rights_after = ports(c.getpid());
    _ = c.printf("ownership_notify_body_error requests=100 expected_base=0x%x observed_result=0x%x ports_before=%zu ports_after=%zu expected_send_refs=1 observed_send_refs=%u\n", @as(c_uint, c.MACH_RCV_BODY_ERROR), @as(c_uint, @bitCast(status)), rights_before, rights_after, refs(watch));
    sameMaps(before, after, "ownership_notify_body_error");
    check(rights_before == rights_after, "body error cleanup port inventory");
    _ = c.close(file);
    freeMap(memory, 4096);
    destroy(watch);
    destroy(service);
}
const InterruptedSender = struct {
    destination: u32,
    watch: u32,
    requested: std.atomic.Value(u32) = .init(0),
    ready: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(u32) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    statuses: [101]c_int = @splat(0),
};
var interrupts: std.atomic.Value(u32) = .init(0);
fn interruptHandler(_: c_int) callconv(.c) void {
    _ = interrupts.fetchAdd(1, .seq_cst);
}
fn interruptedSender(value: O) callconv(.c) O {
    const s: *InterruptedSender = @ptrCast(@alignCast(value.?));
    for (0..101) |i| {
        while (s.requested.load(.seq_cst) <= i) _ = c.usleep(1000);
        var bytes: [56]u8 align(8) = @splat(0);
        const memory = alloc(4096);
        makeSend(s.watch);
        put(&bytes, 0, Header{ .bits = c.MACH_MSGH_BITS_COMPLEX | c.MACH_MSG_TYPE_COPY_SEND, .size = bytes.len, .remote = s.destination, .local = 0, .id = 69903 });
        put(&bytes, 24, @as(u32, 2));
        put(&bytes, 28, Ool{ .address = memory, .deallocate = 1, .size = 4096 });
        put(&bytes, 44, Port{ .name = s.watch, .disposition = c.MACH_MSG_TYPE_MOVE_SEND });
        s.ready.store(@intCast(i + 1), .seq_cst);
        const status = c.mach_msg(@ptrCast(&bytes), c.MACH_SEND_MSG | c.MACH_SEND_INTERRUPT, bytes.len, 0, 0, 0, 0);
        s.statuses[i] = status;
        notifyd_mach_send_result(status, @ptrCast(&bytes));
        s.done.store(@intCast(i + 1), .seq_cst);
    }
    while (!s.release.load(.seq_cst)) _ = c.usleep(1000);
    return null;
}
fn monotonic() i64 {
    var t: c.struct_timespec = undefined;
    check(c.clock_gettime(c.CLOCK_MONOTONIC, &t) == 0, "monotonic clock");
    return t.tv_sec * 1_000_000_000 + t.tv_nsec;
}
fn interruptOne(s: *InterruptedSender, thread: c.pthread_t, number: u32) void {
    s.requested.store(number, .seq_cst);
    const end = monotonic() + 10_000_000_000;
    while (s.ready.load(.seq_cst) < number and monotonic() < end) _ = c.usleep(1000);
    while (s.done.load(.seq_cst) < number and monotonic() < end) {
        check(c.pthread_kill(thread, c.SIGUSR1) == 0, "directed sender signal");
        _ = c.usleep(1000);
    }
    check(s.done.load(.seq_cst) == number and s.statuses[number - 1] & ~@as(c_int, c.MACH_MSG_MASK) == c.MACH_SEND_INTERRUPTED, "real interrupted reply send");
}
fn notifyInterrupted(_: [*c]const c.atf_tc_t) callconv(.c) void {
    var action = std.mem.zeroes(c.struct_sigaction);
    action.__sigaction_u.__sa_handler = &interruptHandler;
    _ = c.sigemptyset(&action.sa_mask);
    check(c.sigaction(c.SIGUSR1, &action, null) == 0, "sender signal handler");
    var s: InterruptedSender = .{ .destination = port(), .watch = port() };
    makeSend(s.destination);
    makeSend(s.watch);
    for (0..5) |_| {
        var h: Header = .{ .bits = c.MACH_MSG_TYPE_COPY_SEND, .size = 24, .remote = s.destination, .local = 0, .id = 69904 };
        send(std.mem.asBytes(&h));
    }
    var thread: c.pthread_t = undefined;
    check(c.pthread_create(&thread, null, &interruptedSender, &s) == 0, "interrupted sender thread");
    interruptOne(&s, thread, 1);
    _ = maps(c.getpid());
    const before = maps(c.getpid());
    const rights_before = ports(c.getpid());
    for (2..102) |i| interruptOne(&s, thread, @intCast(i));
    const after = maps(c.getpid());
    const rights_after = ports(c.getpid());
    _ = c.printf("ownership_notify_interrupted requests=100 expected_base=0x%x observed_result=0x%x ports_before=%zu ports_after=%zu expected_send_refs=1 observed_send_refs=%u handler_calls=%u\n", @as(c_uint, c.MACH_SEND_INTERRUPTED), @as(c_uint, @bitCast(s.statuses[100])), rights_before, rights_after, refs(s.watch), interrupts.load(.seq_cst));
    sameMaps(before, after, "ownership_notify_interrupted");
    check(rights_before == rights_after and refs(s.watch) == 1 and refs(s.destination) == 1 and interrupts.load(.seq_cst) >= 101, "interrupted reply release inventory");
    s.release.store(true, .seq_cst);
    check(c.pthread_join(thread, null) == 0, "interrupted sender join");
    destroy(s.watch);
    destroy(s.destination);
}
var cases: [10]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "90");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "socket_large", "launchd_no_reply", "mig_mismatch", "notify_rejected", "xpc_unsent", "dispatch_large", "launchd_handler_rejected", "xpc_malformed", "notify_body_error", "notify_interrupted" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &socketLarge, &launchdNoReply, &mismatchedReply, &notifyRejected, &xpcUnsent, &dispatchLarge, &launchdHandlerRejected, &xpcMalformed, &notifyBodyError, &notifyInterrupted };
    for (names, bodies, 0..) |name, body, i| {
        var e = c.atf_tc_init(&cases[i], name, &head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(e)) return e;
        e = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(e)) return e;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
