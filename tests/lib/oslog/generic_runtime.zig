// Host fixture: check that libc delegates to a runtime loaded after startup.
const Object = extern struct { isa: ?*anyopaque, refs: c_int, xrefs: c_int };
pub export fn _os_object_retain(pointer: *Object) *Object {
    pointer.xrefs += 1;
    return pointer;
}
pub export fn _os_object_release(pointer: *Object) void {
    pointer.xrefs -= 1;
}
