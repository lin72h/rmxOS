// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("launch.h");
    @cInclude("mach/mach.h");
    @cInclude("servers/bootstrap.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/user.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
});
extern fn launch_data_pack(c.launch_data_t, [*]u8, usize, ?[*]c_int, usize, ?*usize) usize;
extern fn vproc_mig_ipc_request(c.mach_port_t, usize, u32, ?[*]u32, u32, *usize, *u32, *?[*]u32, *u32, c.mach_port_t) c_int;
extern fn mig_allocate(*usize, usize) void;
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
fn check(ok: bool, message: [*:0]const u8) void {
    if (!ok) c.atf_tc_fail("%s", message);
}
fn ordinary() void {
    const q = c.launch_data_new_string("GetResourceUsageSelf");
    check(q != null, "request allocation");
    defer c.launch_data_free(q);
    const r = c.launch_msg(q);
    check(r != null, "ordinary launch_msg reply");
    defer c.launch_data_free(r);
    check(c.launch_data_get_type(r) == c.LAUNCH_DATA_OPAQUE, "ordinary reply type");
}
fn portCount() usize {
    // rmxOS uses FD-backed ports; mach_port_names is not implemented.
    // ipc_entry.c exports KF_TYPE_PORT=17 and KF_TYPE_PORTSET=18 here.
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_FILEDESC, c.getpid() };
    var bytes: [65536]u8 align(@alignOf(c.kinfo_file)) = undefined;
    var size: usize = bytes.len;
    check(c.sysctl(&mib, mib.len, &bytes, &size, null, 0) == 0, "port inventory sysctl");
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < size) {
        check(size - offset >= @sizeOf(c.kinfo_file), "file inventory record size");
        const f: *align(1) const c.kinfo_file = @ptrCast(&bytes[offset]);
        check(f.kf_structsize >= @sizeOf(c.kinfo_file) and f.kf_structsize <= size - offset, "file inventory extent");
        if (f.kf_type == 17 or f.kf_type == 18) count += 1;
        offset += @intCast(f.kf_structsize);
    }
    return count;
}
fn launchdFdCount() usize {
    const fp = c.popen("/usr/bin/procstat -f 1", "r");
    check(fp != null, "procstat launchd descriptors");
    var line: [2048]u8 = undefined;
    var count: usize = 0;
    while (c.fgets(&line, line.len, fp) != null) {
        var pid: c_int = 0;
        var comm: [64]u8 = undefined;
        var fd: [32]u8 = undefined;
        if (c.sscanf(&line, "%d %63s %31s", &pid, &comm, &fd) == 3 and pid == 1 and fd[0] >= '0' and fd[0] <= '9') count += 1;
    }
    check(c.pclose(fp) == 0 and count > 0, "procstat successful nonempty inventory");
    return count;
}
fn plain(_: [*c]const c.atf_tc_t) callconv(.c) void {
    ordinary();
    const before = portCount();
    ordinary();
    const after = portCount();
    _ = c.printf("legacy_plain ports_before=%zu ports_after=%zu\n", before, after);
    check(before == after, "plain request port inventory unchanged");
}
fn refused(_: [*c]const c.atf_tc_t) callconv(.c) void {
    ordinary();
    const before = portCount();
    const fd = c.open("/dev/null", c.O_RDONLY);
    check(fd >= 0, "open test FD");
    defer _ = c.close(fd);
    const q = c.launch_data_new_fd(fd);
    check(q != null, "FD node allocation");
    defer c.launch_data_free(q);
    const r = c.launch_msg(q);
    const err = c.__error().*;
    check(r == null and err == c.ENOTSUP, "FD launch_msg must return ENOTSUP");
    var bytes: [256]u8 = undefined;
    var fds = [_]c_int{ 1234, 5678 };
    var used: usize = 0;
    check(launch_data_pack(q, &bytes, bytes.len, &fds, 0, &used) == 0 and c.__error().* == c.ENOTSUP, "zero-capacity pack refuses FD");
    check(used == 0 and fds[0] == 1234 and fds[1] == 5678, "pack must not store a descriptor");
    const after = portCount();
    _ = c.printf("legacy_refused errno_expected=%d errno_observed=%d ports_before=%zu ports_after=%zu\n", c.ENOTSUP, err, before, after);
    check(before == after, "refusal port inventory unchanged");
    check(c.fcntl(fd, c.F_GETFD) >= 0, "refusal preserves caller FD");
    ordinary();
}
fn sockets(_: [*c]const c.atf_tc_t) callconv(.c) void {
    ordinary();
    const job = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY);
    const q = c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY);
    check(job != null and q != null, "Sockets dictionaries");
    defer c.launch_data_free(q);
    check(c.launch_data_dict_insert(job, c.launch_data_new_string("org.rmx.op666.sockets"), "Label"), "job label");
    check(c.launch_data_dict_insert(job, c.launch_data_new_string("/usr/bin/true"), "Program"), "job program");
    check(c.launch_data_dict_insert(job, c.launch_data_alloc(c.LAUNCH_DATA_DICTIONARY), "Sockets"), "Sockets key");
    check(c.launch_data_dict_insert(q, job, "SubmitJob"), "submit job");
    const r = c.launch_msg(q);
    check(r != null, "Sockets refusal reply");
    defer c.launch_data_free(r);
    check(c.launch_data_get_type(r) == c.LAUNCH_DATA_ERRNO and c.launch_data_get_errno(r) == c.ENOTSUP, "Sockets job must return ENOTSUP");
    _ = c.printf("legacy_sockets errno_expected=%d errno_observed=%d\n", c.ENOTSUP, c.launch_data_get_errno(r));
    ordinary();
}
fn rawArray(_: [*c]const c.atf_tc_t) callconv(.c) void {
    ordinary();
    const before = launchdFdCount();
    const ports_before = portCount();
    var port: u32 = 0;
    check(c.mach_port_allocate(c.mach_task_self(), c.MACH_PORT_RIGHT_RECEIVE, &port) == 0, "raw receive right");
    defer _ = c.mach_port_destroy(c.mach_task_self(), port);
    check(c.mach_port_insert_right(c.mach_task_self(), port, port, c.MACH_MSG_TYPE_MAKE_SEND) == 0, "raw send right");
    var address: usize = 0;
    mig_allocate(&address, 4096);
    check(address != 0, "raw request mapping");
    const q = c.launch_data_new_string("GetResourceUsageSelf");
    check(q != null, "raw request node");
    defer c.launch_data_free(q);
    const size = launch_data_pack(q, @ptrFromInt(address), 4096, null, 0, null);
    check(size > 0, "raw request packing");
    var names = [_]u32{port};
    var reply: usize = 0;
    var reply_count: u32 = 0;
    var reply_names: ?[*]u32 = null;
    var reply_names_count: u32 = 0;
    const rc = vproc_mig_ipc_request(c.bootstrap_port, address, @intCast(size), &names, 1, &reply, &reply_count, &reply_names, &reply_names_count, 0);
    check(rc == c.KERN_NOT_SUPPORTED, "raw array must return KERN_NOT_SUPPORTED");
    check(reply == 0 and reply_names == null, "refusal has no acquired reply resources");
    var typ: u32 = 0;
    check(c.mach_port_type(c.mach_task_self(), port, &typ) == 0 and typ & c.MACH_PORT_TYPE_SEND == 0, "request send right moved");
    ordinary();
    const after = launchdFdCount();
    check(c.mach_port_destroy(c.mach_task_self(), port) == 0, "raw receive cleanup");
    port = 0;
    const ports_after = portCount();
    _ = c.printf("legacy_array rc_expected=%d rc_observed=%d launchd_fds_before=%zu launchd_fds_after=%zu ports_before=%zu ports_after=%zu\n", c.KERN_NOT_SUPPORTED, rc, before, after, ports_before, ports_after);
    check(before == after and ports_before == ports_after, "array refusal releases only acquired resources");
}
var cases: [4]c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "25");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const names = [_][*:0]const u8{ "plain_request", "descriptor_refused", "sockets_refused", "port_array_refused" };
    const bodies = .{ &plain, &refused, &sockets, &rawArray };
    inline for (0..4) |i| {
        const err = c.atf_tc_init(&cases[i], names[i], &head, bodies[i], null, c.atf_tp_get_config(tp));
        if (c.atf_is_error(err)) return err;
        const added = c.atf_tp_add_tc(tp, &cases[i]);
        if (c.atf_is_error(added)) return added;
    }
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
