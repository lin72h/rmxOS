// SPDX-License-Identifier: BSD-2-Clause
// swift-sdk's program: a dispatch_after of 2 s on a global queue submits to
// the main queue, which prints and exits, under dispatch_main(). With
// "explicit" it first calls libdispatch_init() again, as
// swift-corelibs-foundation's __CFInitialize does. It prints the libdispatch
// it bound first, so the parent can check the binding. "env" prints its
// environment and every loaded object, then exits.
const std = @import("std");
const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("link.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
});
const Object = ?*anyopaque;
const Fn = *const fn (Object) callconv(.c) void;
extern fn libdispatch_init() void;
extern fn dispatch_get_global_queue(c_long, c_ulong) Object;
extern fn dispatch_time(u64, i64) u64;
extern fn dispatch_after_f(u64, Object, Object, Fn) void;
extern fn dispatch_async_f(Object, Object, Fn) void;
extern fn dispatch_main() noreturn;
extern var _dispatch_main_q: u8;
extern var environ: [*:null]?[*:0]const u8;
fn say(text: []const u8) void {
    _ = c.write(1, text.ptr, text.len);
}
fn onMain(_: Object) callconv(.c) void {
    say("main queue ran\n");
    c.exit(0);
}
fn object(info: [*c]c.struct_dl_phdr_info, _: usize, _: ?*anyopaque) callconv(.c) c_int {
    say("obj ");
    say(if (info.*.dlpi_name != null) std.mem.span(info.*.dlpi_name) else "");
    say("\n");
    return 0;
}
fn later(_: Object) callconv(.c) void {
    dispatch_async_f(@ptrCast(&_dispatch_main_q), null, onMain);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc != 2) return 2;
    const mode = std.mem.span(argv[1]);
    // The definition rtld bound, not a canonical PLT address in this program.
    const bound = c.dlsym(c.RTLD_DEFAULT, "libdispatch_init") orelse return 3;
    var info: c.Dl_info = undefined;
    if (c.dladdr(bound, &info) == 0 or info.dli_fname == null) return 3;
    say("lib=");
    say(std.mem.span(info.dli_fname));
    say("\n");
    if (std.mem.eql(u8, mode, "env")) {
        var i: usize = 0;
        while (environ[i]) |e| : (i += 1) {
            say("env ");
            say(std.mem.span(e));
            say("\n");
        }
        _ = c.dl_iterate_phdr(object, null);
        return 0;
    }
    if (std.mem.eql(u8, mode, "explicit")) {
        libdispatch_init();
    } else if (!std.mem.eql(u8, mode, "implicit")) return 2;
    dispatch_after_f(dispatch_time(0, 2 * std.time.ns_per_s), dispatch_get_global_queue(0, 0), null, later);
    dispatch_main();
}
