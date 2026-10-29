// SPDX-License-Identifier: BSD-2-Clause
// xpc-lite-v1 stage A object-core contracts. SDK citations refer to the staged
// macOS 27 xpc/xpc.h. New entry points are looked up at run time so that a
// library without them fails a named check instead of failing to link.
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cDefine("OS_OBJECT_USE_OBJC", "0");
    @cInclude("Availability.h");
    @cInclude("xpc/xpc.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("dlfcn.h");
    @cInclude("sys/wait.h");
});
const O = c.xpc_object_t;
extern const _xpc_type_dictionary: u8;
extern const _xpc_type_fd: u8;
const Failure = error{ContractViolation};
fn check(label: []const u8, ok: bool) Failure!void {
    if (!ok) {
        std.debug.print("stage_a FAIL {s}\n", .{label});
        return error.ContractViolation;
    }
}
fn entry(comptime T: type, name: [*:0]const u8) Failure!T {
    const raw = c.dlsym(c.RTLD_DEFAULT, name);
    try check("public entry point available", raw != null);
    return @ptrCast(raw);
}
fn refs(o: O, expected: u32) Failure!void {
    if (builtin.os.tag == .freebsd) {
        const raw = c.dlsym(c.RTLD_DEFAULT, "op211_reference_count");
        try check("consumer fixture reference-count projection available", raw != null);
        const f: *const fn (O) callconv(.c) u32 = @ptrCast(raw);
        const observed = f(o);
        std.debug.print("stage_a refs expected={d} observed={d}\n", .{ expected, observed });
        try check("reference count", observed == expected);
    }
}

// xpc.h:1959-1962: an empty dictionary, +1.
pub fn dictionaryCreateEmpty() !void {
    const create = try entry(*const fn () callconv(.c) O, "xpc_dictionary_create_empty");
    const d = create();
    try check("empty dictionary created", d != null);
    try check("dictionary type", c.xpc_get_type(d) == @as(c.xpc_type_t, @ptrCast(&_xpc_type_dictionary)));
    try check("empty count", c.xpc_dictionary_get_count(d) == 0);
    try refs(d, 1);
    c.xpc_dictionary_set_int64(d, "n", 5);
    try check("usable after creation", c.xpc_dictionary_get_count(d) == 1 and c.xpc_dictionary_get_int64(d, "n") == 5);
    c.xpc_release(d);
}

// xpc.h:2618-2621: the dictionary at key, +0; NULL for another type or no key.
pub fn dictionaryGetDictionary() !void {
    const get = try entry(*const fn (O, [*:0]const u8) callconv(.c) O, "xpc_dictionary_get_dictionary");
    const parent = c.xpc_dictionary_create(null, null, 0);
    const child = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_value(parent, "child", child);
    c.xpc_dictionary_set_string(parent, "text", "not a dictionary");
    try check("dictionary value returned", get(parent, "child") == child);
    try refs(child, 2); // caller and parent; the getter adds none.
    try check("other type returns NULL", get(parent, "text") == null);
    try check("absent key returns NULL", get(parent, "absent") == null);
    c.xpc_release(child);
    try check("borrowed value lives in parent", get(parent, "child") == child);
    c.xpc_release(parent);
}

// xpc.h:971-1028: fd_create holds its own duplicate; fd_dup returns a new
// descriptor the caller owns. Local objects only; no message transport.
pub fn fdLocal() !void {
    const create = try entry(*const fn (c_int) callconv(.c) O, "xpc_fd_create");
    const dup = try entry(*const fn (O) callconv(.c) c_int, "xpc_fd_dup");
    var p: [2]c_int = undefined;
    try check("pipe fixture", c.pipe(&p) == 0);
    const boxed = create(p[0]);
    try check("descriptor boxed", boxed != null);
    try check("fd type", c.xpc_get_type(boxed) == @as(c.xpc_type_t, @ptrCast(&_xpc_type_fd)));
    _ = c.close(p[0]);
    const first = dup(boxed);
    const second = dup(boxed);
    try check("dup returns new descriptors", first >= 0 and second >= 0 and first != second);
    c.xpc_release(boxed);
    var byte: u8 = 'A';
    try check("write", c.write(p[1], &byte, 1) == 1);
    byte = 0;
    try check("caller descriptor outlives object", c.read(first, &byte, 1) == 1 and byte == 'A');
    _ = c.close(first);
    byte = 'B';
    try check("write", c.write(p[1], &byte, 1) == 1);
    byte = 0;
    try check("each dup independent", c.read(second, &byte, 1) == 1 and byte == 'B');
    _ = c.close(second);
    _ = c.close(p[1]);
    try check("invalid descriptor refused", create(-1) == null);
}

// xpc.h:2002-2005: a NULL value removes the key; removing an absent key is a no-op.
pub fn setValueNullRemoves() !void {
    const d = c.xpc_dictionary_create(null, null, 0);
    const v = c.xpc_int64_create(9);
    c.xpc_dictionary_set_value(d, "k", v);
    try refs(v, 2);
    c.xpc_dictionary_set_value(d, "k", null);
    try check("NULL removes the key", c.xpc_dictionary_get_value(d, "k") == null and c.xpc_dictionary_get_count(d) == 0);
    try refs(v, 1);
    c.xpc_dictionary_set_value(d, "absent", null);
    try check("absent removal is a no-op", c.xpc_dictionary_get_count(d) == 0);
    c.xpc_dictionary_set_value(d, "k", v);
    try check("key can be set again", c.xpc_dictionary_get_value(d, "k") == v and c.xpc_dictionary_get_count(d) == 1);
    c.xpc_release(d);
    try refs(v, 1);
    c.xpc_release(v);
}

// rmxOS arrays link through the element: an object is in one array at a time.
// A second insert is refused with a message and leaves both arrays unchanged.
fn insertTwice() u8 {
    const v = c.xpc_string_create("member");
    const a = c.xpc_array_create(null, 0);
    const b = c.xpc_array_create(null, 0);
    c.xpc_array_append_value(a, v);
    c.xpc_array_append_value(b, v);
    c.xpc_array_append_value(a, v);
    c.xpc_array_set_value(b, c.XPC_ARRAY_APPEND, v);
    if (c.xpc_array_get_count(a) != 1 or c.xpc_array_get_value(a, 0) != v) return 1;
    if (c.xpc_array_get_count(b) != 0) return 2;
    c.xpc_release(a);
    // Out of the first array, the object may join another.
    c.xpc_array_append_value(b, v);
    if (c.xpc_array_get_count(b) != 1 or c.xpc_array_get_value(b, 0) != v) return 3;
    c.xpc_release(b);
    c.xpc_release(v);
    return 0;
}
pub fn secondArrayInsertRefused() !void {
    var p: [2]c_int = undefined;
    try check("pipe fixture", c.pipe(&p) == 0);
    const pid = c.fork();
    try check("fork", pid >= 0);
    if (pid == 0) {
        _ = c.close(p[0]);
        _ = c.dup2(p[1], 2);
        c._exit(insertTwice());
    }
    _ = c.close(p[1]);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = c.read(p[0], &buf[len], buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    _ = c.close(p[0]);
    var status: c_int = 0;
    try check("child reaped", c.waitpid(pid, &status, 0) == pid);
    const exited = (status & 0x7f) == 0;
    const code = (status >> 8) & 0xff;
    std.debug.print("stage_a child exited={} code={d} stderr=\"{s}\"\n", .{ exited, code, buf[0..len] });
    try check("child completed", exited);
    try check("first array intact (count 1, same element)", code != 1);
    try check("second insert refused (count 0)", code != 2);
    try check("released element joins another array", code == 0);
    try check("refusal message", std.mem.indexOf(u8, buf[0..len], "already in an array") != null);
}

test "dictionaryCreateEmpty" {
    try dictionaryCreateEmpty();
}
test "dictionaryGetDictionary" {
    try dictionaryGetDictionary();
}
test "fdLocal" {
    try fdLocal();
}
test "setValueNullRemoves" {
    try setValueNullRemoves();
}
test "secondArrayInsertRefused" {
    try secondArrayInsertRefused();
}

const atf = if (builtin.is_test) struct {} else @cImport({
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t) c_int;
const names = [_][*:0]const u8{ "dictionaryCreateEmpty", "dictionaryGetDictionary", "fdLocal", "setValueNullRemoves", "secondArrayInsertRefused" };
const functions = [_]*const fn () anyerror!void{ &dictionaryCreateEmpty, &dictionaryGetDictionary, &fdLocal, &setValueNullRemoves, &secondArrayInsertRefused };
var cases: if (builtin.is_test) void else [names.len]atf.atf_tc_t = undefined;
fn body(t: [*c]const atf.atf_tc_t) callconv(.c) void {
    _ = c.alarm(15);
    for (names, functions) |name, f| if (std.mem.eql(u8, std.mem.span(atf.atf_tc_get_ident(t)), std.mem.span(name))) {
        f() catch atf.atf_tc_fail("stage A contract failed; see named check");
        return;
    };
    atf.atf_tc_fail("unknown case");
}
fn add(tp: [*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t {
    for (names, 0..) |name, i| {
        const err = atf.atf_tc_init(&cases[i], name, null, &body, null, atf.atf_tp_get_config(tp));
        if (atf.atf_is_error(err)) return err;
        _ = atf.atf_tp_add_tc(tp, &cases[i]);
    }
    return atf.atf_no_error();
}
pub fn main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return atf_tp_main(argc, argv, &add);
}
comptime {
    if (!builtin.is_test) @export(&main, .{ .name = "main" });
}
