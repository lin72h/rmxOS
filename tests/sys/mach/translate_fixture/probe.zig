// SPDX-License-Identifier: BSD-2-Clause
// Freestanding kernel probe: report facts; the ATF program validates them.
extern fn rmx_fixture_space() ?*anyopaque;
extern fn rmx_fixture_entry(u32) ?*anyopaque;
extern fn rmx_fixture_object(*anyopaque) ?*anyopaque;
extern fn rmx_fixture_owned(*anyopaque) c_int;
extern fn rmx_fixture_unlock(*anyopaque) void;
extern fn ipc_object_translate(?*anyopaque, u32, u32, *?*anyopaque) c_int;
const Observation = extern struct { result: c_int, owned: c_int };
extern var M_TEMP: u8;
extern fn malloc(usize, *anyopaque, c_int) ?*anyopaque;
extern fn free(*anyopaque, *anyopaque) void;
extern fn rmx_fixture_proc_size() usize;
extern fn rmx_fixture_bsdinfo_size() usize;
extern fn rmx_fixture_proc_copy(*anyopaque) void;
extern fn rmx_fixture_proc_set_fd(*anyopaque, ?*anyopaque) void;
extern fn rmx_fixture_proc_set_group(*anyopaque, ?*anyopaque) void;
extern fn rmx_fixture_nfiles(*anyopaque) c_int;
extern fn proc_pidbsdinfo(*anyopaque, *anyopaque, c_int) c_int;
export fn rmx_proc_observe(_: u32, out: *Observation) c_int {
    const snapshot = malloc(rmx_fixture_proc_size(), &M_TEMP, 2) orelse return 12;
    defer free(snapshot, &M_TEMP);
    const info = malloc(rmx_fixture_bsdinfo_size(), &M_TEMP, 2) orelse return 12;
    defer free(info, &M_TEMP);
    rmx_fixture_proc_copy(snapshot);
    rmx_fixture_proc_set_fd(snapshot, null);
    rmx_fixture_proc_set_group(snapshot, null);
    out.result = proc_pidbsdinfo(snapshot, info, 0);
    out.owned = rmx_fixture_nfiles(info);
    return 0;
}
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
