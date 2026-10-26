// SPDX-License-Identifier: BSD-2-Clause
// Freestanding kernel fixture. Layouts and constants follow sys/{module,kernel}.h.
const Event = *const fn (?*anyopaque, c_int, ?*anyopaque) callconv(.c) c_int;
const Module = extern struct { name: [*:0]const u8, event: Event, private: ?*anyopaque };
const Metadata = extern struct { version: c_int = 1, kind: c_int, data: *const anyopaque, name: [*:0]const u8 };
const Sysinit = extern struct { subsystem: u32, order: u32, next: ?*anyopaque = null, func: *const fn (*const anyopaque) callconv(.c) void, data: *const anyopaque };
extern fn log(c_int, [*:0]const u8, ...) void;
extern fn module_register_init(*const anyopaque) callconv(.c) void;
fn event(_: ?*anyopaque, kind: c_int, _: ?*anyopaque) callconv(.c) c_int {
    if (kind == 0) {
        log(5, "op767 kernel fixture loaded\n");
    } else if (kind == 1) {
        log(5, "op767 kernel fixture unloaded\n");
    }
    return 0;
}
var op767_module: Module = .{ .name = "op767_logger", .event = event, .private = null };
var op767_metadata: Metadata = .{ .kind = 2, .data = &op767_module, .name = "op767_logger" };
export var op767_metadata_ptr: *Metadata linksection("set_modmetadata_set") = &op767_metadata;
var op767_sysinit: Sysinit = .{ .subsystem = 0x3100000, .order = 0x1000000, .func = module_register_init, .data = &op767_module };
export var op767_sysinit_ptr: *Sysinit linksection("set_sysinit_set") = &op767_sysinit;
