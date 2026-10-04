// Minimal unversioned ASL exports for the native rtld binding regression.
// No ASL/Mach constructors run in this host fixture.
export fn syslog(_: c_int, _: [*:0]const u8) callconv(.c) void {}
export fn asl_open(_: ?[*:0]const u8, _: ?[*:0]const u8, _: u32) callconv(.c) ?*anyopaque {
    return null;
}
