// PID 1's entry point deliberately has no libc, TLS or library constructors.
// FreeBSD/amd64 syscall numbers and ABI: sys/sys/syscall.h, libc/amd64/SYS.h.
const std = @import("std");
const Iovec = extern struct { base: [*:0]const u8, len: usize };
fn call(n: usize, a: usize, b: usize, d: usize, e: usize) isize {
    return asm volatile ("syscall\n\tjnc 1f\n\tnegq %%rax\n1:"
        : [ret] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [d] "{rdx}" (d),
          [e] "{r10}" (e),
        : .{ .rdx = true, .r8 = true, .r9 = true, .r10 = true, .rcx = true, .r11 = true, .memory = true });
}
pub fn fork() isize {
    return asm volatile ("syscall\n\tjc 2f\n\ttestq %%rdx, %%rdx\n\tje 1f\n\txorq %%rax, %%rax\n\tjmp 1f\n2:\n\tnegq %%rax\n1:"
        : [ret] "={rax}" (-> isize),
        : [n] "{rax}" (@as(usize, 2)),
        : .{ .rdx = true, .r8 = true, .r9 = true, .r10 = true, .rcx = true, .r11 = true, .memory = true });
}
fn ptr(p: anytype) usize {
    return @intFromPtr(p);
}
fn vector(s: [:0]const u8) Iovec {
    return .{ .base = s.ptr, .len = s.len + 1 };
}
pub fn mount(kind: [:0]const u8, from: [:0]const u8, path: [:0]const u8) isize {
    const v = [_]Iovec{ vector("fstype"), vector(kind), vector("from"), vector(from), vector("fspath"), vector(path) };
    return call(378, ptr(&v), v.len, 0, 0);
}
fn console(message: []const u8) void {
    const fd = call(5, ptr("/dev/console"), 1 | 0x8000, 0, 0);
    if (fd >= 0) {
        _ = call(4, @intCast(fd), ptr(message.ptr), message.len, 0);
        _ = call(6, @intCast(fd), 0, 0, 0);
    }
}
// One console line naming the dataset that did not mount and its error.
pub fn line(buf: []u8, dataset: []const u8, result: isize, is_volatile: bool) ?[]const u8 {
    return std.fmt.bufPrint(buf, "rmxos: {s}: errno={d}{s}\n", .{ dataset, -result, if (is_volatile) "; using volatile Data (tmpfs)" else "" }) catch null;
}
fn diagnostic(dataset: []const u8, result: isize, is_volatile: bool) void {
    var buf: [512]u8 = undefined;
    console(line(&buf, dataset, result, is_volatile) orelse return);
}
fn stop(message: []const u8) noreturn {
    console(message);
    const ts = [2]isize{ 60, 0 };
    while (true) _ = call(240, ptr(&ts), 0, 0, 0);
}
fn mkdir(path: [:0]const u8, mode: usize) void {
    const rc = call(136, ptr(path.ptr), mode, 0, 0);
    if (rc != 0 and rc != -17) stop("rmxos: cannot create volatile Data directories\n");
}
// Fork, exec path with no arguments or environment, and wait: true only for
// exit status 0 (the first stage stops on anything else).
pub fn run(path: [:0]const u8) bool {
    const child = fork();
    if (child < 0) return false;
    if (child == 0) {
        const args = [_:null]?[*:0]const u8{path.ptr};
        const env = [_:null]?[*:0]const u8{};
        _ = call(59, ptr(path.ptr), ptr(&args), ptr(&env), 0);
        _ = call(1, 127, 0, 0, 0);
        unreachable;
    }
    var status: c_int = 0;
    while (true) {
        const rc = call(7, @intCast(child), ptr(&status), 0, 0);
        if (rc == -4) continue;
        return rc == child and status == 0;
    }
}
pub fn mountfrom(root: *[1024:0]u8) isize {
    return call(390, 0, ptr("vfs.root.mountfrom"), ptr(root), root.len);
}
pub const Root = union(enum) { legacy, sealed: []const u8, unreadable };
// Data.build is written by sealed compose and also read by datasync. A ZFS
// root without that layout mark boots as before, even while mounted read-only.
pub fn classify(count: isize, root: []const u8, has_mark: bool) Root {
    if (count <= 0 or count >= root.len) return .unreadable;
    const value = std.mem.sliceTo(root, 0);
    if (value.len == 0) return .unreadable;
    if (!std.mem.startsWith(u8, value, "zfs:") or !has_mark) return .legacy;
    return .{ .sealed = value[4..] };
}
pub const Data = enum { mounted, volatile_data, failed, legacy, unreadable };
pub fn dataMode(kind: Root, private_result: isize) Data {
    return switch (kind) {
        .legacy => .legacy,
        .unreadable => .unreadable,
        .sealed => if (private_result == 0) .mounted else if (private_result == -2) .volatile_data else .failed,
    };
}
fn sealedMark() bool {
    // access(2), F_OK: existence, with no libc or configuration-file access.
    return call(33, ptr("/System/Library/Templates/Data.build"), 0, 0, 0) == 0;
}
// No usable root name: keep a single-user shell on the console instead of
// starting launchd without Data.
fn rescueShell(message: []const u8) noreturn {
    console(message);
    while (true) {
        const child = fork();
        if (child == 0) {
            _ = call(147, 0, 0, 0, 0);
            const fd = call(5, ptr("/dev/console"), 2, 0, 0);
            if (fd >= 0) {
                for (0..3) |n| _ = call(90, @intCast(fd), n, 0, 0);
                _ = call(54, 0, 0x20007461, 0, 0);
            }
            const args = [_:null]?[*:0]const u8{"-sh"};
            const env = [_:null]?[*:0]const u8{ "PATH=/sbin:/bin:/usr/sbin:/usr/bin", "HOME=/" };
            _ = call(59, ptr("/bin/sh"), ptr(&args), ptr(&env), 0);
            _ = call(1, 127, 0, 0, 0);
            unreachable;
        }
        if (child < 0) {
            const ts = [2]isize{ 1, 0 };
            _ = call(240, ptr(&ts), 0, 0, 0);
            continue;
        }
        var status: c_int = 0;
        while (call(7, @intCast(child), ptr(&status), 0, 0) == -4) {}
    }
}
export fn rmxos_start(stack: [*]const usize) callconv(.c) noreturn {
    const pid1 = call(20, 0, 0, 0, 0) == 1;
    var root: [1024:0]u8 = @splat(0);
    var is_volatile = false;
    const kind: Root = if (pid1) classify(mountfrom(&root), &root, sealedMark()) else .legacy;
    if (kind == .unreadable) rescueShell("rmxos: cannot read vfs.root.mountfrom; single-user shell, Data not mounted\n");
    if (kind == .sealed) {
        const dataset = kind.sealed;
        const end = std.mem.indexOfScalar(u8, dataset, '/') orelse stop("rmxos: invalid root dataset\n");
        const pool = dataset[0..end];
        const names = [_][:0]const u8{ "private", "Users", "Library", "local" };
        const paths = [_][:0]const u8{ "/private", "/Users", "/Library", "/usr/local" };
        for (names, paths, 0..) |name, path, i| {
            var buf: [1100]u8 = undefined;
            const from = std.fmt.bufPrintZ(&buf, "{s}/data/{s}", .{ pool, name }) catch stop("rmxos: dataset name too long\n");
            const rc = mount("zfs", from, path);
            if (rc != 0) {
                if (i == 0 and dataMode(kind, rc) == .volatile_data) {
                    if (mount("tmpfs", "tmpfs", "/private") != 0) stop("rmxos: tmpfs fallback failed\n");
                    mkdir("/private/etc", 0o755);
                    mkdir("/private/var", 0o755);
                    mkdir("/private/tmp", 0o1777);
                    mkdir("/private/var/run", 0o755);
                    const fd = call(5, ptr("/private/var/run/rmxos.volatile-data"), 1 | 0x200 | 0x400, 0o644, 0);
                    if (fd < 0) stop("rmxos: volatile Data marker failed\n");
                    _ = call(6, @intCast(fd), 0, 0, 0);
                    is_volatile = true;
                } else if (i == 0) {
                    diagnostic(from, rc, false);
                    stop("rmxos: Data mount failed; stopped before configuration\n");
                }
                diagnostic(from, rc, is_volatile and i == 0);
            }
        }
        if (!run("/usr/libexec/rmxos-datasync")) stop("rmxos: datasync failed; stopped before launchd\n");
    }
    // Preserve the kernel's single-user argument; volatile Data always offers rescue.
    const argc = stack[0];
    const original: [*]const ?[*:0]const u8 = @ptrCast(stack + 1);
    const rescue = [_:null]?[*:0]const u8{ "/usr/libexec/rmxos-launchd", "-s" };
    const normal = [_:null]?[*:0]const u8{"/usr/libexec/rmxos-launchd"};
    const env = [_:null]?[*:0]const u8{};
    const argv = if (is_volatile) ptr(&rescue) else if (argc > 1) ptr(original) else ptr(&normal);
    _ = call(59, ptr("/usr/libexec/rmxos-launchd"), argv, ptr(&env), 0);
    stop("rmxos: cannot exec launchd\n");
}
fn entry() callconv(.naked) noreturn {
    // FreeBSD supplies the initial argument block in rdi (crt1_s.S).
    asm volatile ("andq $-16, %rsp\n\tcallq rmxos_start");
}
comptime {
    if (!@import("builtin").is_test) @export(&entry, .{ .name = "_start" });
}
