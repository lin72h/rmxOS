// SPDX-License-Identifier: BSD-2-Clause
// Freestanding kernel probe: report facts; the ATF program validates them.
extern fn rmx_fixture_space() ?*anyopaque;
extern fn rmx_fixture_entry(u32) ?*anyopaque;
extern fn rmx_fixture_object(*anyopaque) ?*anyopaque;
extern fn rmx_fixture_owned(*anyopaque) c_int;
extern fn rmx_fixture_unlock(*anyopaque) void;
extern fn ipc_object_translate(?*anyopaque, u32, u32, *?*anyopaque) c_int;
const Observation = extern struct { result: c_int, owned: c_int };
export fn rmx_translate_observe(name: u32, out: *Observation) c_int {
    const entry = rmx_fixture_entry(name) orelse return 2;
    var object = rmx_fixture_object(entry) orelse return 2;
    // Deliberately exercise the equality condition without undefined test data.
    var output: ?*anyopaque = object;
    out.result = ipc_object_translate(rmx_fixture_space(), name, 1, &output);
    out.owned = 0;
    if (out.result == 0) {
        object = output orelse return 2;
        out.owned = rmx_fixture_owned(object);
        if (out.owned != 0) rmx_fixture_unlock(object);
    }
    return 0;
}
