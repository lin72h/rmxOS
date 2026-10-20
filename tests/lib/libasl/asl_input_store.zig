// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/statvfs.h");
    @cInclude("sys/sysctl.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
});
const O = ?*anyopaque;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn asl_input_parse([*:0]const u8, c_int, O, u32) O;
extern fn asl_msg_new(u32) O;
extern fn asl_msg_set_key_val(O, [*:0]const u8, [*:0]const u8) c_int;
extern fn asl_msg_get_val_for_key(O, [*:0]const u8) ?[*:0]const u8;
extern fn asl_msg_release(O) void;
extern fn asl_file_open_write([*:0]const u8, c.mode_t, c.uid_t, c.gid_t, *O) u32;
extern fn asl_file_open_read([*:0]const u8, *O) u32;
extern fn asl_file_save(O, O, *u64) u32;
extern fn asl_file_close(O) u32;
extern fn asl_file_read_set_position(O, u32) u32;
extern fn asl_file_fetch_next(O, *O) u32;
extern fn asl_bsd_receive(c_int, [*]u8, *u64) isize;
const State = extern struct { bytes: [4097]u8 = @splat(0), used: usize = 0 };
extern fn asl_klog_read(c_int, *State, *const fn ([*:0]const u8, usize, O) callconv(.c) void, O) isize;
extern fn op752_klog_state_size() usize;
fn need(ok: bool, what: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s errno=%d", what, c.__error().*);
}
fn set(m: O, key: [*:0]const u8, value: [*:0]const u8) void {
    need(asl_msg_set_key_val(m, key, value) == 0, "set ASL field");
}
fn field(m: O, key: [*:0]const u8, expected: []const u8) void {
    const observed = asl_msg_get_val_for_key(m, key);
    if (observed == null or !std.mem.eql(u8, std.mem.span(observed.?), expected)) c.atf_tc_fail("field=%s expected_len=%zu observed=%s", key, expected.len, observed orelse "<null>");
}
fn writer(path: [*:0]const u8) O {
    // The whole-plan runner repeats cases in one working directory.
    // Each case must read back only the records from its current invocation.
    need(c.unlink(path) == 0 or c.__error().* == c.ENOENT, "fresh fixture store");
    var store: O = null;
    need(asl_file_open_write(path, 0o600, c.getuid(), c.getgid(), &store) == 0 and store != null, "open writer");
    return store;
}
fn save(store: O, m: O) void {
    var id: u64 = 0;
    need(m != null and asl_file_save(store, m, &id) == 0, "store record");
}
fn reader(path: [*:0]const u8) O {
    var store: O = null;
    need(asl_file_open_read(path, &store) == 0 and store != null, "open reader");
    need(asl_file_read_set_position(store, 0) == 0, "first record");
    return store;
}
fn next(store: O) O {
    var m: O = null;
    need(asl_file_fetch_next(store, &m) == 0 and m != null, "read saved record");
    return m;
}
fn end(store: O) void {
    var m: O = null;
    // This file API reaches cursor=0 at EOF and returns INVALID_ARG (1).
    const status = asl_file_fetch_next(store, &m);
    _ = c.printf("asl_store_end expected_status=1 observed_status=%u expected_null=1 observed_null=%u\n", status, @as(u32, @intFromBool(m == null)));
    need(status == 1 and m == null, "no duplicate or extra record");
    need(asl_file_close(store) == 0, "close reader");
}
fn pair(kind: c_int) [2]c_int {
    var fds: [2]c_int = undefined;
    need(c.socketpair(c.AF_UNIX, kind, 0, &fds) == 0, "private socketpair");
    return fds;
}
const prefix = "<14>Jan  1 00:00:00 tag[42]: ";
fn restoreDgram(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const fp = c.fopen("dgram-limit", "r");
    if (fp == null) return;
    var old: c_ulong = 0;
    const got = c.fscanf(fp, "%lu", &old);
    _ = c.fclose(fp);
    if (got == 1) {
        need(c.sysctlbyname("net.local.dgram.maxdgram", null, null, &old, @sizeOf(c_ulong)) == 0, "restore fixture datagram ceiling");
        _ = c.unlink("dgram-limit");
    }
}
fn socketSizes(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const fds = pair(c.SOCK_DGRAM);
    const store = writer("socket.asl");
    const sizes = [_]usize{ 1023, 1024, 4095, 4096, 4097, 8191, 8192 };
    var truncated: u64 = 0;
    const Guard = extern struct { before: [32]u8, line: [8193]u8, after: [32]u8 };
    for (sizes) |size| {
        var wire: [8192]u8 = @splat('x');
        @memcpy(wire[0..prefix.len], prefix);
        var guard: Guard = undefined;
        @memset(std.mem.asBytes(&guard), 0xa5);
        need(c.send(fds[0], &wire, size, 0) == size, "send boundary datagram");
        const n = asl_bsd_receive(fds[1], &guard.line, &truncated);
        need(n == size and guard.line[size] == 0 and truncated == 0, "exact socket length and terminator");
        for ([_]u8{} ++ guard.before ++ guard.after) |byte| need(byte == 0xa5, "receive guard unchanged");
        const m = asl_input_parse(@ptrCast(&guard.line), @intCast(n), null, 2);
        field(m, "Sender", "tag");
        field(m, "PID", "42");
        field(m, "Level", "6");
        field(m, "Facility", "user");
        field(m, "Message", wire[prefix.len..size]);
        save(store, m);
        asl_msg_release(m);
        _ = c.printf("asl_socket expected_bytes=%zu observed_bytes=%zd expected_guard=165 observed_guard=%u truncated=%ju\n", size, n, guard.after[0], truncated);
    }
    // Raise only the guest's Unix transport fixture limit, so oversized
    // datagrams can actually reach the production 8192-byte receive bound.
    var old: c_ulong = 0;
    var old_size: usize = @sizeOf(c_ulong);
    need(c.sysctlbyname("net.local.dgram.maxdgram", &old, &old_size, null, 0) == 0, "read datagram ceiling");
    const fp = c.fopen("dgram-limit", "w");
    need(fp != null, "save fixture ceiling for cleanup");
    _ = c.fprintf(fp, "%lu\n", old);
    need(c.fclose(fp) == 0, "save fixture ceiling");
    var socket_bytes: c_int = 32768;
    need(c.setsockopt(fds[0], c.SOL_SOCKET, c.SO_SNDBUF, &socket_bytes, @sizeOf(c_int)) == 0, "raise private send buffer");
    need(c.setsockopt(fds[1], c.SOL_SOCKET, c.SO_RCVBUF, &socket_bytes, @sizeOf(c_int)) == 0, "raise private receive buffer");
    var raised: c_ulong = @max(old, 16384);
    need(c.sysctlbyname("net.local.dgram.maxdgram", null, null, &raised, @sizeOf(c_ulong)) == 0, "raise fixture datagram ceiling");
    for ([_]usize{ 8193, 9000 }, 1..) |size, count| {
        var wire: [9000]u8 = @splat('t');
        var guard: Guard = undefined;
        @memset(std.mem.asBytes(&guard), 0xa5);
        need(c.send(fds[0], &wire, size, 0) == size, "oversize datagram");
        need(asl_bsd_receive(fds[1], &guard.line, &truncated) == 0 and truncated == count, "truncation counted and discarded");
        for ([_]u8{} ++ guard.before ++ guard.after) |byte| need(byte == 0xa5, "oversize guard unchanged");
    }
    restoreDgram(null);
    _ = c.printf("asl_socket_truncation expected_count=2 observed_count=%ju transport_limit_restored=%lu\n", truncated, old);
    need(asl_file_close(store) == 0, "close socket writer");
    const read = reader("socket.asl");
    for (sizes) |size| {
        const m = next(read);
        var payload: [8192]u8 = @splat('x');
        field(m, "Message", payload[0 .. size - prefix.len]);
        field(m, "Sender", "tag");
        field(m, "PID", "42");
        asl_msg_release(m);
    }
    end(read);
    _ = c.close(fds[0]);
    _ = c.close(fds[1]);
}
const structured = "[example@32473 iut=\"3\" eventSource=\"Application\" text=\"quote\\\" slash\\\\ end\\]\"][timeQuality tzKnown=\"1\"]";
fn rfc5424(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const fds = pair(c.SOCK_DGRAM);
    const store = writer("rfc.asl");
    const records = [_][:0]const u8{
        "<165>1 2000-01-01T00:00:00.123456Z host app 42 ID47 " ++ structured ++ " hello telemetry",
        "<165>1 2000-01-01T02:30:00.123456+02:30 host app 42 ID47 - hello telemetry",
        "<14>1 - - - - - -",
    };
    var truncated: u64 = 0;
    for (records) |wire| {
        need(c.send(fds[0], wire.ptr, wire.len, 0) == wire.len, "RFC datagram send");
        var line: [8193]u8 = undefined;
        const n = asl_bsd_receive(fds[1], &line, &truncated);
        need(n == wire.len and truncated == 0, "RFC receive");
        const m = asl_input_parse(@ptrCast(&line), @intCast(n), null, 2);
        if (std.mem.eql(u8, wire, records[2])) {
            field(m, "PID", "-1");
            need(asl_msg_get_val_for_key(m, "Message") == null, "ASL empty Message normalizes to null");
        }
        save(store, m);
        asl_msg_release(m);
    }
    need(asl_file_close(store) == 0, "close RFC writer");
    const read = reader("rfc.asl");
    for (0..3) |i| {
        const m = next(read);
        if (i < 2) {
            field(m, "Time", "946684800");
            field(m, "TimeNanoSec", "123456000");
            field(m, "Host", "host");
            field(m, "Sender", "app");
            field(m, "PID", "42");
            field(m, "RFC5424.ProcID", "42");
            field(m, "RFC5424.MsgID", "ID47");
            field(m, "Level", "5");
            field(m, "Facility", "local4");
            field(m, "Message", "hello telemetry");
            if (i == 0) {
                field(m, "RFC5424.StructuredData", structured);
                field(m, "RFC5424.SD.13:example@32473.iut", "3");
                field(m, "RFC5424.SD.13:example@32473.eventSource", "Application");
                field(m, "RFC5424.SD.13:example@32473.text", "quote\" slash\\ end]");
                field(m, "RFC5424.SD.11:timeQuality.tzKnown", "1");
            } else field(m, "RFC5424.StructuredData", "-");
        } else {
            field(m, "Host", "-");
            field(m, "Sender", "-");
            field(m, "PID", "4294967295"); // existing uint32 store representation of -1
            field(m, "RFC5424.ProcID", "-");
            field(m, "RFC5424.MsgID", "-");
            field(m, "RFC5424.Timestamp", "-");
            need(asl_msg_get_val_for_key(m, "Message") == null, "no Message for NIL RFC record");
        }
        asl_msg_release(m);
    }
    end(read);
    for ([_][:0]const u8{
        "<14>1 2000-01-01T00:00:00Z h a 1 ID [x a=\"unterminated] msg",
        "<14>1 2000-01-01T00:00:00Z h a 1 ID [x a=\"bad]value\"] msg",
        "<999>1 2000-01-01T00:00:00Z h a 1 ID - msg",
    }) |bad| need(asl_input_parse(bad, @intCast(bad.len), null, 2) == null, "malformed RFC record refused");
    _ = c.close(fds[0]);
    _ = c.close(fds[1]);
    _ = c.printf("asl_rfc expected_records=3 observed_records=3 structured_fields=4\n");
}
const KernelContext = struct { store: O, count: usize = 0 };
fn emitKernel(line: [*:0]const u8, length: usize, context: O) callconv(.c) void {
    const ctx: *KernelContext = @ptrCast(@alignCast(context.?));
    const m = asl_input_parse(line, @intCast(length), null, 4);
    save(ctx.store, m);
    asl_msg_release(m);
    ctx.count += 1;
}
fn kernelSplits(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(op752_klog_state_size() == @sizeOf(State), "kernel state ABI");
    const wire = "<6>kernel first record\n<3>second record with remainder\nlast record\n";
    const store = writer("splits.asl");
    var ctx = KernelContext{ .store = store };
    for (1..wire.len) |offset| {
        var fds: [2]c_int = undefined;
        need(c.pipe(&fds) == 0, "kernel pipe");
        var state = State{};
        need(c.write(fds[1], wire.ptr, offset) == offset, "first split write");
        need(asl_klog_read(fds[0], &state, &emitKernel, &ctx) == offset, "first split read");
        need(c.write(fds[1], wire.ptr + offset, wire.len - offset) == wire.len - offset, "second split write");
        need(asl_klog_read(fds[0], &state, &emitKernel, &ctx) == wire.len - offset, "second split read");
        need(state.used == 0, "no remainder after newline");
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    need(ctx.count == (wire.len - 1) * 3, "three kernel records per split");
    need(asl_file_close(store) == 0, "close split writer");
    const read = reader("splits.asl");
    for (1..wire.len) |_| {
        for ([_][]const u8{ "kernel first record", "second record with remainder", "last record" }) |expected| {
            const m = next(read);
            field(m, "Message", expected);
            field(m, "PID", "0");
            asl_msg_release(m);
        }
    }
    end(read);
    _ = c.printf("asl_klog_split expected_offsets=%zu observed_offsets=%zu expected_records=%zu observed_records=%zu\n", wire.len - 1, wire.len - 1, (wire.len - 1) * 3, ctx.count);
}
fn kernelBurst(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const store = writer("burst.asl");
    var ctx = KernelContext{ .store = store };
    var state = State{};
    var fds: [2]c_int = undefined;
    need(c.pipe(&fds) == 0, "burst pipe");
    var bytes: [4096 + 100 + 1 + 5]u8 = @splat('B');
    @memset(bytes[4096..4196], 'C');
    @memcpy(bytes[4196..], "\ntail\n");
    var written: usize = 0;
    while (written < bytes.len) {
        const n = @min(@as(usize, 997), bytes.len - written);
        need(c.write(fds[1], bytes[written..].ptr, n) == n, "burst write");
        var consumed: usize = 0;
        while (consumed < n) {
            const readn = asl_klog_read(fds[0], &state, &emitKernel, &ctx);
            need(readn > 0, "full buffer makes progress");
            consumed += @intCast(readn);
        }
        written += n;
    }
    need(ctx.count == 3 and state.used == 0, "full-buffer record and remainder exactly once");
    _ = c.close(fds[0]);
    _ = c.close(fds[1]);
    need(asl_file_close(store) == 0, "close burst writer");
    const read = reader("burst.asl");
    for ([_][]const u8{ bytes[0..4096], bytes[4096..4196], "tail" }) |expected| {
        const m = next(read);
        field(m, "Message", expected);
        asl_msg_release(m);
    }
    end(read);
    _ = c.printf("asl_klog_burst input_bytes=%zu expected_records=3 observed_records=%zu\n", bytes.len, ctx.count);
}
fn command(text: [*:0]const u8) void {
    need(c.system(text) == 0, text);
}
fn mdUnit() c_int {
    const fp = c.fopen("md-unit", "r");
    if (fp == null) return -1;
    var unit: c_int = -1;
    const got = c.fscanf(fp, "%d", &unit);
    _ = c.fclose(fp);
    return if (got == 1 and unit >= 0 and unit < 10000) unit else -1;
}
fn cleanupFull(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const unit = mdUnit();
    if (unit >= 0) {
        need(c.unmount("full", 0) == 0 or c.__error().* == c.EINVAL or c.__error().* == c.ENOENT, "cleanup unmount memory filesystem");
        var cmd: [128:0]u8 = undefined;
        _ = c.snprintf(&cmd, cmd.len, "/sbin/mdconfig -d -u %d", unit);
        command(&cmd);
        need(c.unlink("md-unit") == 0, "remove memory disk unit record");
    }
    need(c.rmdir("full") == 0 or c.__error().* == c.ENOENT, "remove memory disk mount directory");
}
fn fullStore(_: [*c]const c.atf_tc_t) callconv(.c) void {
    need(c.getuid() == 0, "memory disk requires guest root");
    need(c.mkdir("full", 0o700) == 0, "mount directory");
    command("/sbin/mdconfig -a -n -t malloc -s 8m > md-unit");
    const unit = mdUnit();
    need(unit >= 0, "allocated memory disk unit");
    var cmd: [256:0]u8 = undefined;
    _ = c.snprintf(&cmd, cmd.len, "/sbin/newfs -U /dev/md%d > newfs.log", unit);
    command(&cmd);
    _ = c.snprintf(&cmd, cmd.len, "/sbin/mount /dev/md%d full", unit);
    command(&cmd);
    const store = writer("full/store.asl");
    var saved: usize = 0;
    for (0..10) |i| {
        const m = asl_msg_new(0);
        var value: [32:0]u8 = undefined;
        _ = c.snprintf(&value, value.len, "%zu", i);
        set(m, "order", &value);
        set(m, "Message", "before");
        save(store, m);
        asl_msg_release(m);
        saved += 1;
    }
    const fill = c.open("full/filler", c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
    need(fill >= 0, "filler open");
    var data: [65536]u8 = @splat(0x53);
    var filled: u64 = 0;
    while (true) {
        const n = c.write(fill, &data, data.len);
        if (n < 0) {
            need(c.__error().* == c.ENOSPC, "actual filesystem full");
            break;
        }
        need(n > 0, "filler progress");
        filled += @intCast(n);
    }
    _ = c.close(fill);
    var failed: bool = false;
    // All strings fit inline. This reaches the MSG record append/flush even
    // with no free filesystem blocks, rather than failing a string append.
    for (0..32) |_| {
        const m = asl_msg_new(0);
        for (0..900) |i| {
            var key: [16:0]u8 = undefined;
            _ = c.snprintf(&key, key.len, "k%03zu", i);
            set(m, &key, "v");
        }
        var value: [32:0]u8 = undefined;
        _ = c.snprintf(&value, value.len, "%zu", saved);
        set(m, "order", &value);
        set(m, "Message", "large");
        var id: u64 = 0;
        const status = asl_file_save(store, m, &id);
        asl_msg_release(m);
        if (status != 0) {
            need(status == 8, "full filesystem returns WRITE_FAILED");
            failed = true;
            break;
        }
        saved += 1;
    }
    need(failed, "bounded full filesystem attempt fails");
    need(asl_file_close(store) == 0, "close failed writer");
    const read = reader("full/store.asl");
    for (0..saved) |i| {
        const m = next(read);
        var value: [32:0]u8 = undefined;
        const n = c.snprintf(&value, value.len, "%zu", i);
        field(m, "order", value[0..@intCast(n)]);
        field(m, "Message", if (i < 10) "before" else "large");
        if (i >= 10) field(m, "k899", "v");
        asl_msg_release(m);
    }
    end(read);
    _ = c.printf("asl_store_full filler_bytes=%ju expected_status=8 observed_status=8 expected_prior_records=%zu observed_prior_records=%zu\n", filled, saved, saved);
    // ATF cleanup unmounts after this process exits and closes its descriptors.
}
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "30");
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
}
var cases: [5]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "socket_sizes", "rfc5424", "kernel_splits", "kernel_burst", "store_full" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &socketSizes, &rfc5424, &kernelSplits, &kernelBurst, &fullStore };
    for (&cases, names, bodies, 0..) |*tc, name, body, i| {
        var err = c.atf_tc_init(tc, name, &head, body, if (i == 4) &cleanupFull else if (i == 0) &restoreDgram else null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
