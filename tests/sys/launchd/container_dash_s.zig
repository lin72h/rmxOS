// Isolate the legacy bootstrap's runcom fork boundary without executing /etc/rc.
const c = @cImport({
    @cInclude("errno.h");
});
pub export fn fork() c_int {
    c.__error().* = c.EAGAIN;
    return -1;
}
