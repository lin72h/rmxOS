// SPDX-License-Identifier: BSD-2-Clause
const abi = @import("file_message.zig");
const c = abi.c;
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "Mach file transfer preserves rights, ioctl list and fcntl mask");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "10");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const port = abi.allocate();
    defer _ = c.close(@intCast(port));
    const fd = c.open("caps-file", c.O_CREAT | c.O_RDWR | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) c.atf_tc_fail("source open failed");
    defer _ = c.close(fd);
    if (c.write(fd, "s", 1) != 1 or c.lseek(fd, 0, c.SEEK_SET) != 0) c.atf_tc_fail("file content setup failed");
    var rights = c.cap_rights_t{ .cr_rights = .{ c.CAP_ALL0, c.CAP_ALL1 } };
    _ = c.__cap_rights_clear(&rights, @as(u64, c.CAP_WRITE), @as(u64, 0));
    if (c.cap_rights_limit(fd, &rights) != 0) c.atf_tc_fail("rights limit failed");
    var ioctl_list = [_]c_ulong{c.FIONREAD};
    if (c.cap_ioctls_limit(fd, &ioctl_list, 1) != 0) c.atf_tc_fail("ioctl limit failed");
    if (c.cap_fcntls_limit(fd, c.CAP_FCNTL_GETFL) != 0) c.atf_tc_fail("fcntl limit failed");
    var source_rights: c.cap_rights_t = undefined;
    if (c.__cap_rights_get(c.CAP_RIGHTS_VERSION, fd, &source_rights) != 0) c.atf_tc_fail("source rights capture failed");
    if (abi.sendFile(port, fd) != 0) c.atf_tc_fail("restricted file send failed");
    var message: abi.Message = undefined;
    if (abi.receiveFile(port, &message) != 0 or message.count != 1 or message.descriptor.kind != 0) c.atf_tc_fail("restricted file receive failed");
    const received: c_int = @intCast(message.descriptor.name);
    defer _ = c.close(received);
    var dest_rights: c.cap_rights_t = undefined;
    var dest_fcntls: c_uint = 0;
    var dest_ioctls: [2]c_ulong = undefined;
    if (c.__cap_rights_get(c.CAP_RIGHTS_VERSION, received, &dest_rights) != 0 or c.cap_fcntls_get(received, &dest_fcntls) != 0) c.atf_tc_fail("received rights capture failed");
    const ioctl_count = c.cap_ioctls_get(received, &dest_ioctls, dest_ioctls.len);
    _ = c.printf("caps source0=0x%lx received0=0x%lx source1=0x%lx received1=0x%lx ioctls=%ld fcntls=0x%x\n", source_rights.cr_rights[0], dest_rights.cr_rights[0], source_rights.cr_rights[1], dest_rights.cr_rights[1], ioctl_count, dest_fcntls);
    if (source_rights.cr_rights[0] != dest_rights.cr_rights[0] or source_rights.cr_rights[1] != dest_rights.cr_rights[1]) c.atf_tc_fail("descriptor rights changed in transfer");
    if (ioctl_count != 1 or dest_ioctls[0] != c.FIONREAD or dest_fcntls != c.CAP_FCNTL_GETFL) c.atf_tc_fail("ioctl or fcntl limits changed in transfer");
    var byte: u8 = 0;
    if (c.read(received, &byte, 1) != 1 or byte != 's') c.atf_tc_fail("preserved read right does not work");
    const written = c.write(received, "x", 1);
    const err = c.__error().*;
    _ = c.printf("write expected_result=-1 observed_result=%ld expected_errno=%d observed_errno=%d\n", written, @as(c_int, c.ENOTCAPABLE), err);
    if (written != -1 or err != c.ENOTCAPABLE) c.atf_tc_fail("removed write right was not preserved");
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "preserve_caps", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return abi.atf_tp_main(argc, argv, &addTests);
}
