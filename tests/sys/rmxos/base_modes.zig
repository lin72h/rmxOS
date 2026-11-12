// SPDX-License-Identifier: BSD-2-Clause
// Owner, group and mode on the running system for every path in the image's
// list (base_modes.list beside this program). The compose writes the list
// from the world install's log and the overlays' own logs: every set-id or
// sticky path and every directory whose mode is not 0755.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/cdefs.h");
    @cInclude("sys/types.h");
    // sys/time.h's bintime inlines do not translate; hide them as the
    // launchd cases do.
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "0");
    @cInclude("sys/time.h");
    @cUndef("__BSD_VISIBLE");
    @cDefine("__BSD_VISIBLE", "1");
    @cInclude("atf-c.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("grp.h");
    @cInclude("pwd.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});

var buffer: [262144]u8 = undefined;

fn load(path: [*:0]const u8) []const u8 {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) c.atf_tc_fail("open %s", path);
    defer _ = c.close(fd);
    var n: usize = 0;
    while (true) {
        const got = c.read(fd, buffer[n..].ptr, buffer.len - n);
        if (got < 0) c.atf_tc_fail("read %s", path);
        if (got == 0) break;
        n += @intCast(got);
        if (n == buffer.len) c.atf_tc_fail("list larger than %zu bytes", buffer.len);
    }
    return buffer[0..n];
}

fn z(s: []const u8, out: []u8) [*:0]const u8 {
    if (s.len >= out.len) c.atf_tc_fail("field too long");
    @memcpy(out[0..s.len], s);
    out[s.len] = 0;
    return @ptrCast(out.ptr);
}

fn body(t: [*c]const c.atf_tc_t) callconv(.c) void {
    var path_buf: [4096]u8 = undefined;
    _ = c.snprintf(&path_buf, path_buf.len, "%s/base_modes.list", c.atf_tc_get_config_var(t, "srcdir"));
    var lines = std.mem.splitScalar(u8, load(@ptrCast(&path_buf)), '\n');
    const header = lines.next() orelse "";
    const prefix = "rmx-modes-v1 ";
    if (!std.mem.startsWith(u8, header, prefix)) c.atf_tc_fail("list header");
    const declared = std.fmt.parseInt(u32, header[prefix.len..], 10) catch c.atf_tc_fail("list count");
    var rows: u32 = 0;
    var matched: u32 = 0;
    var setid: u32 = 0;
    var strict_dirs: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const mode_s = fields.next() orelse c.atf_tc_fail("row mode");
        const uname = fields.next() orelse c.atf_tc_fail("row uname");
        const gname = fields.next() orelse c.atf_tc_fail("row gname");
        const kind = fields.next() orelse c.atf_tc_fail("row type");
        const path = fields.next() orelse c.atf_tc_fail("row path");
        if (fields.next() != null) c.atf_tc_fail("row fields");
        rows += 1;
        const want_mode = std.fmt.parseInt(u32, mode_s, 8) catch c.atf_tc_fail("row mode value");
        const dir = std.mem.eql(u8, kind, "dir");
        if (want_mode & 0o7000 != 0 and !dir) setid += 1;
        if (dir and want_mode != 0o755) strict_dirs += 1;
        var ub: [64]u8 = undefined;
        var gb: [64]u8 = undefined;
        var pb: [1024]u8 = undefined;
        const pw = c.getpwnam(z(uname, &ub));
        const gr = c.getgrnam(z(gname, &gb));
        const p = z(path, &pb);
        var st: c.struct_stat = undefined;
        const found = c.lstat(p, &st) == 0;
        const kind_ok = found and if (dir) (st.st_mode & c.S_IFMT) == c.S_IFDIR else (st.st_mode & c.S_IFMT) == c.S_IFREG;
        const have_mode: u32 = if (found) @intCast(st.st_mode & 0o7777) else 0;
        const uid_ok = pw != null and found and st.st_uid == pw.*.pw_uid;
        const gid_ok = gr != null and found and st.st_gid == gr.*.gr_gid;
        if (kind_ok and uid_ok and gid_ok and have_mode == want_mode) {
            matched += 1;
        } else {
            _ = c.printf("base_modes path=%s expected_type=%.*s observed_type_ok=%d expected_owner=%.*s:%.*s observed_uid=%d observed_gid=%d expected_mode=%o observed_mode=%o\n", p, @as(c_int, @intCast(kind.len)), kind.ptr, @as(c_int, @intFromBool(kind_ok)), @as(c_int, @intCast(uname.len)), uname.ptr, @as(c_int, @intCast(gname.len)), gname.ptr, if (found) @as(c_int, @intCast(st.st_uid)) else -1, if (found) @as(c_int, @intCast(st.st_gid)) else -1, want_mode, have_mode);
        }
    }
    _ = c.printf("base_modes expected_rows=%u observed_rows=%u expected_matched=%u observed_matched=%u setid_files=%u strict_dirs=%u\n", declared, rows, rows, matched, setid, strict_dirs);
    if (rows != declared) c.atf_tc_fail("list has %u rows, header says %u", rows, declared);
    if (setid == 0 or strict_dirs == 0) c.atf_tc_fail("list holds no set-id file or no directory stricter than 0755");
    if (matched != rows) c.atf_tc_fail("%u of %u listed paths differ in type, owner, group or mode", rows - matched, rows);
}

extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "30");
}
fn add(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "listed_modes", &head, &body, null, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    const added = c.atf_tp_add_tc(tp, &tc);
    if (c.atf_is_error(added)) return added;
    return c.atf_no_error();
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &add);
}
