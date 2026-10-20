// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("mach/mach.h");
    @cInclude("servers/bootstrap.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("dirent.h");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("errno.h");
});
const O = ?*anyopaque;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
extern fn asl_file_open_read([*:0]const u8, *O) u32;
extern fn asl_file_read_set_position(O, u32) u32;
extern fn asl_file_fetch_next(O, *O) u32;
extern fn asl_file_close(O) u32;
extern fn asl_msg_get_val_for_key(O, [*:0]const u8) ?[*:0]const u8;
extern fn asl_msg_release(O) void;
var root: [256:0]u8 = @splat(0);
var child: c.pid_t = -1;
fn need(ok: bool, text: [*:0]const u8) void {
    if (!ok) {
        if (root[0] != 0) {
            const p = path("daemon.log");
            if (c.fopen(&p, "r")) |file| {
                var line: [4096]u8 = undefined;
                var total: usize = 0;
                while (c.fgets(&line, line.len, file) != null and total < 65536) {
                    _ = c.printf("ASLD_DIAGNOSTIC %s", &line);
                    total += std.mem.span(@as([*:0]const u8, @ptrCast(&line))).len;
                }
                _ = c.fclose(file);
            }
        }
        c.atf_tc_fail("%s errno=%d", text, c.__error().*);
    }
}
fn path(name: [*:0]const u8) [512:0]u8 {
    var p: [512:0]u8 = @splat(0);
    _ = c.snprintf(&p, p.len, "%s/%s", &root, name);
    return p;
}
fn writeFile(name: [*:0]const u8, text: []const u8) void {
    const p = path(name);
    const fd = c.open(&p, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
    need(fd >= 0, "create private fixture file");
    need(c.write(fd, text.ptr, text.len) == text.len, "write private fixture file");
    need(c.close(fd) == 0, "close fixture file");
}
fn prepare() void {
    _ = c.snprintf(&root, root.len, "/tmp/asld766.XXXXXX");
    need(c.mkdtemp(&root) != null, "private root");
    _ = c.printf("asld_private_root=%s\n", &root);
    const p = path("kernel");
    need(c.mkfifo(&p, 0o600) == 0, "private kernel input FIFO");
    writeFile("asl.conf", "# private instance; default store action\n");
    writeFile("syslog.conf", "# no flat file routes\n");
}
fn start(limit: [*:0]const u8, quota: [*:0]const u8) void {
    child = c.fork();
    need(child >= 0, "fork private asld");
    if (child == 0) {
        const p = path("daemon.log");
        const fd = c.open(&p, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
        if (fd < 0) c._exit(127);
        _ = c.dup2(fd, 1);
        _ = c.dup2(fd, 2);
        _ = c.close(fd);
        _ = c.execl("/usr/sbin/asld", "asld", "-private", &root, "-wq_max_bytes", limit, "-mps_limit", quota, "-dup_delay", "0", "-d", @as(?*anyopaque, null));
        c._exit(127);
    }
    const pidfile = c.fopen("op766-child", "w");
    need(pidfile != null, "record own child for cleanup");
    _ = c.fprintf(pidfile, "%d\n", child);
    _ = c.fclose(pidfile);
    const p = path("syslog");
    for (0..400) |_| {
        var status: c_int = 0;
        need(c.waitpid(child, &status, c.WNOHANG) == 0, "asld remains alive during startup");
        if (c.access(&p, c.F_OK) == 0) {
            _ = c.usleep(100000);
            return;
        }
        _ = c.usleep(10000);
    }
    need(false, "private socket ready within 4 seconds");
}
fn stop() void {
    if (child <= 0) return;
    _ = c.kill(child, c.SIGTERM);
    var status: c_int = 0;
    need(c.waitpid(child, &status, 0) == child, "reap private asld");
    child = -1;
    _ = c.unlink("op766-child");
}
fn send(wire: []const u8) void {
    sendTo("syslog", wire);
}
fn sendTo(socket: [*:0]const u8, wire: []const u8) void {
    const fd = c.socket(c.AF_UNIX, c.SOCK_DGRAM, 0);
    need(fd >= 0, "sender socket");
    defer _ = c.close(fd);
    var address = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    _ = c.snprintf(&address.sun_path, address.sun_path.len, "%s/%s", &root, socket);
    address.sun_len = @intCast(@sizeOf(c.struct_sockaddr_un));
    need(c.sendto(fd, wire.ptr, wire.len, 0, @ptrCast(&address), address.sun_len) == wire.len, "send private datagram");
}
fn value(m: O, key: [*:0]const u8) ?[]const u8 {
    const p = asl_msg_get_val_for_key(m, key) orelse return null;
    return std.mem.span(p);
}
fn eq(m: O, key: [*:0]const u8, expected: []const u8) bool {
    return if (value(m, key)) |v| std.mem.eql(u8, v, expected) else false;
}
fn number(m: O, key: [*:0]const u8) u64 {
    return std.fmt.parseInt(u64, value(m, key) orelse return 0, 10) catch 0;
}
const Facts = struct {
    data: usize = 0,
    status: usize = 0,
    dropped: u64 = 0,
    notices: u64 = 0,
    malformed: u64 = 0,
    parse: u64 = 0,
    rejected: u64 = 0,
    summaries: usize = 0,
    expired: u64 = 0,
    expired_bytes: u64 = 0,
    failures: u64 = 0,
    config_notices: usize = 0,
    timestamp_records: usize = 0,
    bom: usize = 0,
    legacy: usize = 0,
};
var receive_start: c.time_t = 0;
fn scan() Facts {
    var facts = Facts{};
    const p = path("store");
    const dir = c.opendir(&p) orelse return facts;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".asl")) continue;
        var file: [768:0]u8 = @splat(0);
        _ = c.snprintf(&file, file.len, "%s/%s", &p, &entry.*.d_name);
        var store: O = null;
        if (asl_file_open_read(&file, &store) != 0) continue;
        defer _ = asl_file_close(store);
        if (asl_file_read_set_position(store, 0) != 0) continue;
        var m: O = null;
        while (asl_file_fetch_next(store, &m) == 0 and m != null) {
            defer asl_msg_release(m);
            if (eq(m, "com.rmxos.asld.record", "status")) {
                facts.status += 1;
                facts.dropped = @max(facts.dropped, number(m, "dropped_wq") + number(m, "dropped_kern_quota"));
                facts.malformed = @max(facts.malformed, number(m, "native_malformed"));
                facts.parse = @max(facts.parse, number(m, "dropped_parse"));
                facts.rejected = @max(facts.rejected, number(m, "config_rejected"));
                const keys = [_][*:0]const u8{ "dropped_wq", "dropped_kern_quota", "dropped_parse", "bsd_in_truncated", "store_failed", "store_fallback_memory", "file_action_failed", "native_malformed", "dup_suppressed", "config_rejected" };
                for (keys) |key| need(value(m, key) != null, "status exposes every counter");
            } else if (eq(m, "com.rmxos.asld.record", "work queue drained")) {
                facts.notices += number(m, "dropped_wq");
            } else if (eq(m, "com.rmxos.asld.record", "kernel quota exceeded")) {
                facts.notices += number(m, "dropped_kern_quota");
            } else if (eq(m, "com.rmxos.aslmanager.record", "summary")) {
                facts.summaries += 1;
                facts.expired += number(m, "expired_files");
                facts.expired_bytes += number(m, "expired_bytes");
                facts.failures += number(m, "failures");
            } else if (value(m, "Message")) |message| {
                if (std.mem.startsWith(u8, message, "Unsupported syslog.conf line")) facts.config_notices += 1;
                if (std.mem.startsWith(u8, message, "payload")) facts.data += 1;
                if (std.mem.eql(u8, message, "1 hello")) facts.legacy += 1;
                if (std.mem.eql(u8, message, "bom text")) facts.bom += 1;
                if (value(m, "RFC5424.Timestamp")) |timestamp| {
                    if (std.mem.eql(u8, timestamp, "1969-12-31T23:59:59Z") or std.mem.eql(u8, timestamp, "1970-01-01T00:00:00Z")) {
                        const when = number(m, "Time");
                        need(when >= receive_start and when <= c.time(null) + 2, "nonpositive RFC timestamp gets receive Time");
                        facts.timestamp_records += 1;
                    }
                }
            }
        }
    }
    return facts;
}
fn statusAfter() Facts {
    _ = c.usleep(1200000);
    need(c.kill(child, c.SIGUSR1) == 0, "request telemetry snapshot");
    for (0..100) |_| {
        const f = scan();
        if (f.status > 0) return f;
        _ = c.usleep(20000);
    }
    need(false, "SIGUSR1 status written within 2 seconds");
    return .{};
}
fn workQueue(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    start("1", "500");
    for (0..100) |_| send("<14>payload work queue");
    const f = statusAfter();
    need(f.data == 0 and f.dropped == 100 and f.notices == 100, "work queue exact drops and episode notice bypass limit");
    _ = c.printf("asld_wq sent=100 stored=%zu dropped=%ju notice_dropped=%ju\n", f.data, f.dropped, f.notices);
    stop();
}
fn kernelQuota(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    start("10000000", "3");
    const p = path("kernel");
    const fd = c.open(&p, c.O_WRONLY);
    need(fd >= 0, "open kernel FIFO sender");
    var wire: [100 * 18]u8 = undefined;
    const record = "<6>payload kernel\n";
    for (0..100) |i| @memcpy(wire[i * record.len ..][0..record.len], record);
    need(c.write(fd, &wire, 100 * record.len) == 100 * record.len, "one FIFO burst in one read");
    _ = c.close(fd);
    const f = statusAfter();
    need(f.data == 3 and f.dropped == 97 and f.notices == 97, "kernel exact quota and per-second drop notice");
    _ = c.printf("asld_kernel sent=100 stored=%zu dropped=%ju notice_dropped=%ju\n", f.data, f.dropped, f.notices);
    stop();
}
fn nativeMalformed(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    start("10000000", "500");
    var service: [128:0]u8 = @splat(0);
    _ = c.snprintf(&service, service.len, "com.rmxos.asld.private.%d", child);
    var port: u32 = 0;
    need(c.bootstrap_look_up(c.bootstrap_port, &service, &port) == 0, "private native service");
    var reply: u32 = 0;
    need(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &reply) == 0, "native reply receive right");
    var head = std.mem.zeroes(c.mach_msg_header_t);
    head.msgh_bits = c.MACH_MSG_TYPE_COPY_SEND | (c.MACH_MSG_TYPE_MAKE_SEND_ONCE << 8);
    head.msgh_remote_port = port;
    head.msgh_local_port = reply;
    head.msgh_size = @sizeOf(c.mach_msg_header_t);
    head.msgh_id = 123456;
    need(c.mach_msg(&head, c.MACH_SEND_MSG, head.msgh_size, 0, 0, 0, 0) == 0, "send invalid native routine");
    var response: [128]u8 align(8) = @splat(0);
    need(c.mach_msg(@ptrCast(&response), c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, response.len, reply, 2000, 0) == 0, "native refusal replies");
    const f = statusAfter();
    need(f.malformed == 1, "native refusal counted once");
    need(c.mach_port_deallocate(c.mach_task_self(), port) == 0, "release service right");
    need(c.mach_port_destroy(c.mach_task_self(), reply) == 0, "destroy native reply port");
    stop();
}
fn earlyTime(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    start("10000000", "500");
    receive_start = c.time(null);
    send("<14>1 1969-12-31T23:59:59Z host app 42 ID - payload before epoch");
    send("<14>1 1970-01-01T00:00:00Z host app 42 ID - payload epoch");
    const f = statusAfter();
    need(f.timestamp_records == 2 and f.parse == 0, "both early timestamps retained with receive Time");
    stop();
}
fn legacyHeader(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    start("10000000", "500");
    send("<13>1 hello");
    send("<13>1 invalid-timestamp host app 42 ID - refused");
    const f = statusAfter();
    need(f.legacy == 1 and f.parse == 1, "short legacy header stored and complete invalid RFC counted once");
    stop();
}
fn bom(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    start("10000000", "500");
    send("<14>1 2000-01-01T00:00:00Z host app 42 ID - \xef\xbb\xbfbom text");
    const f = statusAfter();
    need(f.bom == 1 and f.parse == 0, "RFC encoding BOM absent from stored text");
    stop();
}
fn runManager(archive: bool) void {
    const pid = c.fork();
    need(pid >= 0, "fork manager");
    if (pid == 0) {
        const store = path("store");
        const out = path("manager.log");
        const fd = c.open(&out, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
        if (fd < 0) c._exit(127);
        _ = c.dup2(fd, 1);
        _ = c.dup2(fd, 2);
        _ = c.close(fd);
        if (archive) {
            const dest = path("archive");
            _ = c.execl("/usr/sbin/aslmanager", "aslmanager", "-once", "-s", &store, "-asldb", "-a", &dest, "-store_ttl", "1", @as(?*anyopaque, null));
        } else {
            _ = c.execl("/usr/sbin/aslmanager", "aslmanager", "-once", "-s", &store, "-asldb", "-store_ttl", "1", @as(?*anyopaque, null));
        }
        c._exit(127);
    }
    var status: c_int = 0;
    need(c.waitpid(pid, &status, 0) == pid and status == 0, "manager completes and saves summary without debug flags");
}
fn managerSummary(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    const store = path("store");
    need(c.mkdir(&store, 0o700) == 0, "private manager store");
    writeFile("store/2000.01.01.asl", "expired data\n");
    runManager(false);
    const old = path("store/2000.01.01.asl");
    need(c.access(&old, c.F_OK) != 0, "expired file removed");
    const f = scan();
    need(f.summaries == 1 and f.expired == 1 and f.expired_bytes == 13 and f.failures == 0, "one default-run summary with exact expired files and bytes");
}
fn managerArchive(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    const store = path("store");
    const archive = path("archive");
    need(c.mkdir(&store, 0o700) == 0 and c.mkdir(&archive, 0o700) == 0, "private archive fixture");
    writeFile("store/2000.01.01.asl", "expired data\n");
    writeFile("archive/2000.01.01.asl", "existing archive\n");
    runManager(true);
    const old = path("store/2000.01.01.asl");
    need(c.access(&old, c.F_OK) == 0, "failed archive copy preserves source");
    const f = scan();
    need(f.summaries == 1 and f.expired == 0 and f.failures == 1, "archive copy failure counted once in summary");
}
fn fileMatches(name: [*:0]const u8, text: [*:0]const u8) usize {
    const p = path(name);
    const file = c.fopen(&p, "r") orelse return 0;
    defer _ = c.fclose(file);
    var line: [8193]u8 = undefined;
    var count: usize = 0;
    while (c.fgets(&line, line.len, file) != null) {
        if (c.strstr(&line, text) != null) count += 1;
    }
    return count;
}
fn grammarInclude(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    const dir = path("include");
    need(c.mkdir(&dir, 0o700) == 0, "include directory");
    var config: [2048:0]u8 = @splat(0);
    var n = c.snprintf(&config, config.len, "include %s\nunknown_directive %s/forbidden\n", &dir, &root);
    writeFile("syslog.conf", config[0..@intCast(n)]);
    n = c.snprintf(&config, config.len, "user.=debug %s/one\n", &root);
    writeFile("include/a.conf", config[0..@intCast(n)]);
    n = c.snprintf(&config, config.len, "local0.info %s/two\n", &root);
    writeFile("include/b.conf", config[0..@intCast(n)]);
    // A file without .conf must not be read.
    writeFile("include/ignored", "invalid directive\n");
    start("10000000", "500");
    send("<15>1 2000-01-01T00:00:00Z host app 42 ID - grammar_debug");
    send("<14>1 2000-01-01T00:00:00Z host app 42 ID - grammar_info");
    send("<134>1 2000-01-01T00:00:00Z host app 42 ID - grammar_local");
    const f = statusAfter();
    need(f.rejected == 1 and f.config_notices == 1, "unknown directive counted and logged once");
    need(fileMatches("one", "grammar_debug") == 1 and fileMatches("one", "grammar_info") == 0, "equals-debug is exact, not threshold");
    need(fileMatches("two", "grammar_local") == 1, "second include routes independently");
    const forbidden = path("forbidden");
    need(c.access(&forbidden, c.F_OK) != 0, "unknown directive never becomes destination");
    stop();
}
fn grammarInstalled(_: [*c]const c.atf_tc_t) callconv(.c) void {
    prepare();
    const installed = c.fopen("/etc/syslog.conf", "r");
    need(installed != null, "installed syslog.conf available");
    const actual_config = path("syslog.conf");
    const reference_config = path("reference.conf");
    const actual = c.fopen(&actual_config, "w");
    const reference = c.fopen(&reference_config, "w");
    need(actual != null and reference != null, "private route comparison configurations");
    var line: [4096]u8 = undefined;
    var routes: usize = 0;
    while (c.fgets(&line, line.len, installed) != null) {
        var selector: [2048:0]u8 = @splat(0);
        var destination: [2048:0]u8 = @splat(0);
        if (c.sscanf(&line, "%2047s %2047s", &selector, &destination) != 2) continue;
        if (selector[0] == '#' or selector[0] == '!') continue;
        if (std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&selector))), "include")) continue;
        // Redirect each installed route to a private file, preserving selectors.
        _ = c.fprintf(actual, "%s %s/actual.%zu\n", &selector, &root, routes);
        _ = c.fprintf(reference, "%s %s/reference.%zu\n", &selector, &root, routes);
        routes += 1;
    }
    _ = c.fclose(installed);
    need(c.fclose(actual) == 0 and c.fclose(reference) == 0 and routes > 0, "installed selectors projected without devd blocks or global includes");
    start("10000000", "0");
    const pid = c.fork();
    need(pid >= 0, "fork reference syslogd");
    if (pid == 0) {
        const socket = path("reference.socket");
        const privileged = path("reference.priv");
        const pidfile = path("reference.pid");
        const logfile = path("reference.log");
        const fd = c.open(&logfile, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
        if (fd < 0) c._exit(127);
        _ = c.dup2(fd, 1);
        _ = c.dup2(fd, 2);
        _ = c.close(fd);
        _ = c.execl("/usr/sbin/syslogd", "syslogd", "-F", "-ss", "-cc", "-k", "-p", &socket, "-S", &privileged, "-P", &pidfile, "-f", &reference_config, @as(?*anyopaque, null));
        c._exit(127);
    }
    const socket = path("reference.socket");
    var ready = false;
    for (0..200) |_| {
        if (c.access(&socket, c.F_OK) == 0) {
            ready = true;
            break;
        }
        _ = c.usleep(10000);
    }
    need(ready, "private reference syslogd socket ready");
    for (0..24) |facility| {
        for (0..8) |level| {
            var message: [256:0]u8 = @splat(0);
            const n = c.snprintf(&message, message.len, "<%zu>1 2000-01-01T00:00:00Z host app 42 ID - route_%zu_%zu", facility * 8 + level, facility, level);
            send(message[0..@intCast(n)]);
            sendTo("reference.socket", message[0..@intCast(n)]);
        }
    }
    _ = statusAfter();
    _ = c.kill(pid, c.SIGTERM);
    var status: c_int = 0;
    need(c.waitpid(pid, &status, 0) == pid, "reap reference logger");
    stop();
    for (0..routes) |route| {
        var a: [64:0]u8 = @splat(0);
        var b: [64:0]u8 = @splat(0);
        _ = c.snprintf(&a, a.len, "actual.%zu", route);
        _ = c.snprintf(&b, b.len, "reference.%zu", route);
        for (0..24) |facility| {
            for (0..8) |level| {
                var token: [64:0]u8 = @splat(0);
                _ = c.snprintf(&token, token.len, "route_%zu_%zu", facility, level);
                const observed = fileMatches(&a, &token);
                const expected = fileMatches(&b, &token);
                if (observed != expected) c.atf_tc_fail("installed route=%zu facility=%zu level=%zu expected=%zu observed=%zu", route, facility, level, expected, observed);
            }
        }
    }
    _ = c.printf("asld_installed_routes routes=%zu inputs=192 private_syslogd_comparison=complete\n", routes);
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const file = c.fopen("op766-child", "r");
    if (file == null) return;
    var pid: c.pid_t = -1;
    const parsed = c.fscanf(file, "%d", &pid);
    _ = c.fclose(file);
    if (parsed == 1 and pid > 1) _ = c.kill(pid, c.SIGTERM);
    _ = c.unlink("op766-child");
}
fn testHead(tc: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(tc, "timeout", "%s", "30");
    _ = c.atf_tc_set_md_var(tc, "require.user", "%s", "root");
}
var cases: [10]c.atf_tc_t = undefined;
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "work_queue", "kernel_quota", "native_malformed", "early_time", "legacy_header", "bom", "manager_summary", "manager_archive", "grammar_include", "grammar_installed" };
    const bodies = [_]*const fn ([*c]const c.atf_tc_t) callconv(.c) void{ &workQueue, &kernelQuota, &nativeMalformed, &earlyTime, &legacyHeader, &bom, &managerSummary, &managerArchive, &grammarInclude, &grammarInstalled };
    for (&cases, names, bodies) |*tc, name, body| {
        var err = c.atf_tc_init(tc, name, &testHead, body, &cleanup, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        err = c.atf_tp_add_tc(tp, tc);
        if (c.atf_is_error(err)) return err;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
