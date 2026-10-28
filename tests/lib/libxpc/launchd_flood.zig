// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cDefine("OS_OBJECT_USE_OBJC", "0");
    @cInclude("Availability.h");
    @cInclude("xpc/xpc.h");
    @cInclude("mach/mach.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});
extern fn op500_pipe_send(c.xpc_object_t, u32, u32, u64) c_int;
fn need(ok: bool, label: [*:0]const u8) void {
    if (!ok) {
        _ = c.printf("op233_launchd FAIL %s\n", label);
        c.exit(1);
    }
}
fn command(cmd: [*:0]const u8) void {
    need(c.system(cmd) == 0, cmd);
}
fn rss() usize {
    const f = c.popen("ps -o rss= -p 1", "r");
    need(f != null, "ps open");
    var buf: [128]u8 = @splat(0);
    need(c.fgets(&buf, buf.len, f) != null, "ps read");
    need(c.pclose(f) == 0, "ps status");
    return @intCast(c.strtoul(&buf, null, 10));
}
pub fn main() void {
    command("test \"$(ps -o comm= -p 1)\" = launchd");
    command("launchctl list >/tmp/op233-list");
    const plist = c.fopen("/tmp/op233-job.plist", "w");
    need(plist != null, "plist create");
    need(c.fputs("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>org.rmxos.op233</string><key>ProgramArguments</key><array><string>/bin/sleep</string><string>60</string></array><key>RunAtLoad</key><true/></dict></plist>\n", plist) >= 0, "plist write");
    need(c.fclose(plist) == 0, "plist close");
    command("launchctl load /tmp/op233-job.plist");
    command("launchctl list org.rmxos.op233");
    command("launchctl unload /tmp/op233-job.plist");
    command("! launchctl list org.rmxos.op233");
    var bootstrap: u32 = 0;
    need(c.task_get_bootstrap_port(c.mach_task_self(), &bootstrap) == 0 and bootstrap != 0, "bootstrap port");
    const obj = c.xpc_dictionary_create(null, null, 0);
    need(obj != null, "dictionary");
    const payload: [4096]u8 = @splat('X');
    c.xpc_dictionary_set_data(obj, "payload", &payload, payload.len);
    for (0..256) |i| need(op500_pipe_send(obj, bootstrap, 0, i) == 0, "warm send");
    command("launchctl list >/tmp/op233-list");
    _ = c.sleep(1);
    const before = rss();
    for (0..10000) |i| need(op500_pipe_send(obj, bootstrap, 0, i) == 0, "bootstrap send");
    command("launchctl list >/tmp/op233-list");
    _ = c.sleep(1);
    const after = rss();
    _ = c.printf("op233_launchd pid=1 messages=10000 rss_before=%zu rss_after=%zu\n", before, after);
    c.xpc_release(obj);
    _ = c.mach_port_deallocate(c.mach_task_self(), bootstrap);
    _ = c.unlink("/tmp/op233-list");
    _ = c.unlink("/tmp/op233-job.plist");
    need(before > 0 and after <= before, "launchd RSS flat");
}
