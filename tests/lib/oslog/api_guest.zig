// Real libc/Mach/logd acceptance. No send replacement is linked here.
const std = @import("std");
const a = std.heap.page_allocator;
const io = std.Io.Threaded.global_single_threaded.io();
const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("sys/types.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("asl.h");
    @cInclude("atf-c.h");
    @cInclude("os/log.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("errno.h");
});
extern var _os_log_default: u8;
extern var _os_log_disabled: u8;
extern fn api_emit(c.os_log_t, c.os_log_type_t, [*:0]const u8, [*:0]const u8) void;
extern fn api_five(c.os_log_t) void;
extern fn api_wide(c.os_log_t) void;
extern fn arc4random_buf(?*anyopaque, usize) void;
extern fn atf_tp_main(c_int, [*c][*c]u8, ?*const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const root = "/usr/tests/lib/oslog/oracle";
fn probeRoot() [*:0]const u8 {
    return if (c.getenv("OP207_PROBE_ROOT")) |p| @ptrCast(p) else root;
}
fn mode() [*:0]const u8 {
    return if (c.getenv("OP207_HOST") != null) "host_adapter" else "real_mach";
}
const Row = struct { eventMessage: []const u8, formatString: []const u8, messageType: []const u8, op: u32 };
const Record = struct { message: []const u8, format: []const u8, kind: []const u8, subsystem: []const u8, category: []const u8, image: []const u8 };
var floor: usize = 0;
fn begin() void {
    const path: [*:0]const u8 = if (c.getenv("RMX_ASL_TEST_STORE")) |s| @ptrCast(s) else "/var/db/logd";
    const store = c.asl_open_path(path, 0);
    need(store != null, "open case boundary");
    defer c.asl_release(store);
    var last: usize = 0;
    const result = c.asl_match(store, null, &last, std.math.maxInt(usize), 1, 0, -1);
    defer c.asl_release(result);
    floor = if (c.asl_next(result)) |m| std.fmt.parseInt(usize, val(m, "ASLMessageID"), 10) catch unreachable else 0;
}
fn need(ok: bool, text: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s errno=%d", text, c.__error().*);
}
fn z(s: []const u8) [:0]const u8 {
    return a.dupeZ(u8, s) catch unreachable;
}
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn val(m: c.asl_object_t, key: [*:0]const u8) []const u8 {
    const p = c.asl_get(m, key);
    need(p != null, key);
    return a.dupe(u8, std.mem.span(p)) catch unreachable;
}
fn spawn(path: [*:0]const u8, arg: ?[*:0]const u8, output: [*:0]const u8, cwd: ?[*:0]const u8) c.pid_t {
    const pid = c.fork();
    need(pid >= 0, "fork probe");
    if (pid == 0) {
        const fd = c.open(output, c.O_CREAT | c.O_TRUNC | c.O_WRONLY, @as(c_uint, 0o600));
        if (fd < 0 or c.dup2(fd, 1) < 0 or c.dup2(fd, 2) < 0) c._exit(90);
        _ = c.close(fd);
        if (cwd) |dir| {
            if (c.chdir(dir) != 0) c._exit(91);
        }
        const argv = [_:null]?[*:0]const u8{ path, arg, null };
        _ = c.execv(path, @ptrCast(@constCast(&argv)));
        c._exit(92);
    }
    var status: c_int = 0;
    need(c.waitpid(pid, &status, 0) == pid and status == 0, "probe exit status");
    return pid;
}
fn query(pid: c.pid_t) []Record {
    const path: [*:0]const u8 = if (c.getenv("RMX_ASL_TEST_STORE")) |s| @ptrCast(s) else "/var/db/logd";
    const store = c.asl_open_path(path, 0);
    need(store != null, "open real logd store");
    defer c.asl_release(store);
    const q = c.asl_new(c.ASL_TYPE_QUERY);
    defer c.asl_release(q);
    const list = c.asl_new(c.ASL_TYPE_LIST);
    defer c.asl_release(list);
    const pidtext = std.fmt.allocPrintSentinel(a, "{d}", .{pid}, 0) catch unreachable;
    need(c.asl_set_query(q, "PID", pidtext, c.ASL_QUERY_OP_EQUAL) == 0, "PID query");
    c.asl_append(list, q);
    if (floor != 0) {
        const boundary = c.asl_new(c.ASL_TYPE_QUERY);
        defer c.asl_release(boundary);
        const id = std.fmt.allocPrintSentinel(a, "{d}", .{floor}, 0) catch unreachable;
        need(c.asl_set_query(boundary, "ASLMessageID", id, c.ASL_QUERY_OP_NUMERIC | c.ASL_QUERY_OP_LESS_EQUAL) == 0, "case ID boundary");
        c.asl_append(list, boundary);
    }
    var rows: std.ArrayList(Record) = .empty;
    var start: usize = std.math.maxInt(usize);
    pages: while (true) {
        var last: usize = 0;
        const result = c.asl_match(store, list, &last, start, 32, 0, -1);
        defer c.asl_release(result);
        var visited: usize = 0;
        while (c.asl_next(result)) |m| {
            visited += 1;
            const id = std.fmt.parseInt(usize, val(m, "ASLMessageID"), 10) catch unreachable;
            if (id <= floor) break :pages;
            if (c.asl_get(m, "org.rmxos.logd.type") == null) continue;
            for ([_][*:0]const u8{ "org.rmxos.logd.threadID", "org.rmxos.logd.machTimestamp", "org.rmxos.logd.senderImagePC", "org.rmxos.logd.traceID" }) |key| need(val(m, key).len != 0, "nonempty numeric/trace field");
            need(val(m, "org.rmxos.logd.senderImagePath").len != 0, "sender image path");
            need(val(m, "org.rmxos.logd.senderImageBuildID").len != 0, "sender ELF build ID");
            rows.append(a, .{ .message = val(m, "Message"), .format = val(m, "org.rmxos.logd.formatString"), .kind = val(m, "org.rmxos.logd.type"), .subsystem = val(m, "org.rmxos.logd.subsystem"), .category = val(m, "org.rmxos.logd.category"), .image = val(m, "org.rmxos.logd.senderImagePath") }) catch unreachable;
        }
        if (visited == 0 or last <= 1 or last <= floor or last >= start) break;
        start = last - 1;
    }
    return rows.toOwnedSlice(a) catch unreachable;
}
fn await(pid: c.pid_t, count: usize) []Record {
    var observed: usize = 0;
    for (0..101) |_| {
        const rows = query(pid);
        observed = rows.len;
        if (rows.len == count) return rows;
        need(rows.len < count, "duplicate or disabled/debug record");
        _ = c.usleep(100000);
    }
    c.atf_tc_fail("store expected_count=%zu observed_count=%zu case_floor=%zu", count, observed, floor);
    unreachable;
}
fn read(path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch {
        c.atf_tc_fail("read %s", z(path).ptr);
        unreachable;
    };
}
fn oracle(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    const p963 = spawn(z(std.fmt.allocPrint(a, "{s}/build/op963/probe", .{probeRoot()}) catch unreachable), "base", "probe963.stdout", probeRoot());
    const pdecoder = spawn(z(std.fmt.allocPrint(a, "{s}/build/op963/probe", .{probeRoot()}) catch unreachable), "decoder", "decoder.stdout", probeRoot());
    const p970 = spawn(z(std.fmt.allocPrint(a, "{s}/build/op970/probe", .{probeRoot()}) catch unreachable), null, "probe970.stdout", probeRoot());
    var actual: std.ArrayList(Record) = .empty;
    actual.appendSlice(a, await(p963, 31)) catch unreachable;
    actual.appendSlice(a, await(pdecoder, 3)) catch unreachable;
    actual.appendSlice(a, await(p970, 40)) catch unreachable;
    const parsed = std.json.parseFromSlice([]Row, a, @embedFile("oracle.json"), .{}) catch unreachable;
    const stdout963 = read("probe963.stdout");
    const marker = " pointer=";
    const pointer_begin = (std.mem.indexOf(u8, stdout963, marker) orelse unreachable) + marker.len;
    const finish = std.mem.indexOfScalarPos(u8, stdout963, pointer_begin, '\n') orelse unreachable;
    const pointer = stdout963[pointer_begin..finish];
    var count: usize = 0;
    for (parsed.value, 0..) |row, index| {
        var message = row.eventMessage;
        if (std.mem.indexOf(u8, row.formatString, " privacy p=") != null)
            message = std.fmt.allocPrint(a, "rmxop963-20261023T041823Z privacy p=[{s}]", .{pointer}) catch unreachable;
        if (std.mem.indexOf(u8, row.formatString, " A03 ") != null)
            message = "rmxop970-20261023T052953Z A03 value=[<private>]";
        const kind = if (eq(row.messageType, "Info")) "1" else if (eq(row.messageType, "Error")) "16" else if (eq(row.messageType, "Fault")) "17" else "0";
        const default_log = std.mem.indexOf(u8, message, "log=OS_LOG_DEFAULT") != null;
        const subsystem = if (default_log) "" else if (row.op == 963) "org.rmxos.op963" else "org.rmxos.op970";
        var matches: usize = 0;
        for (actual.items) |r| {
            if (eq(r.message, message) and eq(r.format, row.formatString) and eq(r.kind, kind) and eq(r.subsystem, subsystem) and eq(r.category, if (default_log) "" else "test")) {
                const image = if (std.mem.indexOf(u8, row.formatString, " A02 ") != null) "/libfoo.dylib" else "/probe";
                need(std.mem.endsWith(u8, r.image, image), "sender image is the caller image");
                matches += 1;
            }
        }
        if (matches != 1) c.atf_tc_fail("oracle row=%zu matches=%zu format=%s", index, matches, z(row.formatString).ptr);
        count += 1;
    }
    _ = c.printf("op207 %s oracle=%zu/74 debug=off disabled=none pointer=observed A03=writable-private\n", mode(), count);
}
fn scan(path: []const u8, private: []const u8) void {
    need(!fileHas(path, private), "private canary absent from file");
}
fn fileHas(path: []const u8, token: []const u8) bool {
    need(token.len > 0 and token.len <= 128, "canary token size");
    const fp = c.fopen(z(path), "rb") orelse {
        c.atf_tc_fail("open scan %s", z(path).ptr);
        unreachable;
    };
    defer _ = c.fclose(fp);
    var buffer: [65536 + 128]u8 = undefined;
    var kept: usize = 0;
    while (true) {
        const n = c.fread(buffer[kept..].ptr, 1, 65536, fp);
        const total = kept + n;
        if (std.mem.indexOf(u8, buffer[0..total], token) != null) return true;
        if (n == 0) {
            need(c.ferror(fp) == 0, "scan read error");
            return false;
        }
        kept = @min(token.len - 1, total);
        std.mem.copyForwards(u8, buffer[0..kept], buffer[total - kept .. total]);
    }
}
fn barrier(log: c.os_log_t) void {
    const empty = [_]u8{ 0, 0 };
    c._os_log_impl(null, log, 0, "op207 barrier", &empty, empty.len);
}
fn objects(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    api_emit(@ptrCast(&_os_log_default), 0, "preexisting-private", "preexisting-public");
    _ = await(c.getpid(), 1);
    begin(); // A saved record with this PID must not affect this case.
    const log = c.os_log_create("org.rmxos.op207", "objects");
    need(log != null and log == c.os_log_create("org.rmxos.op207", "objects"), "interned log object");
    need(c.os_retain(log) == @as(?*anyopaque, @ptrCast(log)), "immortal retain");
    c.os_release(log);
    const disabled: c.os_log_t = @ptrCast(&_os_log_disabled);
    for ([_]u8{ 0, 1, 16, 17 }) |kind| {
        need(c.os_log_type_enabled(log, kind), "enabled type");
        need(!c.os_log_type_enabled(disabled, kind), "disabled object");
    }
    need(!c.os_log_type_enabled(log, 2), "debug disabled");
    api_five(log);
    api_five(disabled);
    api_wide(log);
    barrier(log);
    const rows = await(c.getpid(), 5);
    var barriers: usize = 0;
    for (rows) |r| {
        if (eq(r.message, "op207 barrier")) barriers += 1;
    }
    need(barriers == 1, "four enabled emissions followed by one barrier");
    _ = c.printf("op207 %s objects=interned lifetime=immortal emitted=4 debug=0 disabled=0 capital_S=refused\n", mode());
}
fn canary(_: [*c]const c.atf_tc_t) callconv(.c) void {
    begin();
    const seed_path = if (c.getenv("OP207_CANARY_SEED")) |p| std.mem.span(p) else "/usr/tests/lib/oslog/canary_seed";
    const seed = std.mem.trim(u8, read(seed_path), "\r\n ");
    need(seed.len == 48, "host-random canary fixture");
    var nonce: [8]u8 = undefined;
    arc4random_buf(&nonce, nonce.len);
    const private = std.fmt.allocPrintSentinel(a, "private-{s}-{d}-{x}", .{ seed, c.getpid(), nonce }, 0) catch unreachable;
    const public = std.fmt.allocPrintSentinel(a, "public-{s}-{d}-{x}", .{ seed, c.getpid(), nonce }, 0) catch unreachable;
    api_emit(@ptrCast(&_os_log_default), 0, private, public);
    barrier(@ptrCast(&_os_log_default));
    const rows = await(c.getpid(), 2);
    var public_count: usize = 0;
    var barriers: usize = 0;
    for (rows) |r| {
        need(std.mem.indexOf(u8, r.message, private) == null, "store private canary absent");
        if (std.mem.indexOf(u8, r.message, public) != null) public_count += 1;
        if (eq(r.message, "op207 barrier")) barriers += 1;
    }
    need(public_count == 1 and barriers == 1, "one canary followed by one barrier");
    const path = if (c.getenv("RMX_ASL_TEST_STORE")) |s| std.mem.span(s) else "/var/db/logd";
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch unreachable;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch unreachable) |entry| {
        if (entry.kind == .file) scan(std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name }) catch unreachable, private);
    }
    var text_found = false;
    for (0..101) |_| {
        const text_path = if (c.getenv("OP207_TEXT_LOG")) |p| std.mem.span(p) else "/var/log/messages";
        need(!fileHas(text_path, private), "text log private canary absent");
        if (fileHas(text_path, public)) {
            text_found = true;
            break;
        }
        _ = c.usleep(100000);
    }
    need(text_found, "text log public canary present");
    if (c.getenv("OP207_HOST") == null) {
        _ = spawn("/sbin/dmesg", "-a", "console-buffer.txt", null);
        scan("console-buffer.txt", private);
    }
    _ = c.printf("op207 %s canary store=public-only text=public-only console=%s public_control=%s\n", mode(), if (c.getenv("OP207_HOST") == null) @as([*:0]const u8, "private-absent") else "not-checked", public.ptr);
    // A console positive control; logd itself has no console rule.
}
var cases: [3]c.atf_tc_t = undefined;
fn head(tc: [*c]c.atf_tc_t) callconv(.c) void {
    if (c.getenv("OP207_HOST") == null) _ = c.atf_tc_set_md_var(tc, "require.user", "root");
    _ = c.atf_tc_set_md_var(tc, "timeout", "60");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "objects", "oracle", "canary" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ objects, oracle, canary };
    for (&cases, names, bodies) |*tc, name, body| {
        var err = c.atf_tc_init(tc, name, head, body, null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, add);
}
