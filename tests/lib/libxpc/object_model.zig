// SPDX-License-Identifier: BSD-2-Clause
// Public API contracts. SDK citations refer to staged macOS 27 xpc/xpc.h.
// Portable run: zig test object_model.zig -lc --sysroot "$SDK" -I"$SDK/usr/include" -L"$SDK/usr/lib" -lSystem
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
    @cInclude("stdio.h");
});
const O = c.xpc_object_t;
// Zig cannot import extern objects with incomplete C struct types. These are
// the public header's backing symbols; only their addresses are used.
extern const _xpc_bool_true: u8;
extern const _xpc_bool_false: u8;
extern const _xpc_type_bool: u8;
const Failure = error{ContractViolation};
fn check(label: []const u8, ok: bool) Failure!void {
    if (!ok) {
        std.debug.print("object_model FAIL {s}\n", .{label});
        return error.ContractViolation;
    }
}
fn string(o: O, expected: [:0]const u8) Failure!void {
    const p = c.xpc_string_get_string_ptr(o);
    try check("retained/copied string contents", p != null and c.strcmp(p, expected.ptr) == 0);
}
fn refs(o: O, expected: u32) Failure!void {
    if (builtin.os.tag == .freebsd) {
        const raw = c.dlsym(c.RTLD_DEFAULT, "op211_reference_count");
        try check("consumer fixture reference-count projection available", raw != null);
        const f: *const fn (O) callconv(.c) u32 = @ptrCast(raw);
        const observed = f(o);
        std.debug.print("object_model refs expected={d} observed={d}\n", .{ expected, observed });
        try check("collection owns exactly its reference(s)", observed == expected);
    }
}

// xpc.h:363-410, 2026-2032, 1246: borrowed get may be retained independently.
pub fn retainedChild() !void {
    for ([_]bool{ false, true }) |array| {
        const parent = if (array) c.xpc_array_create(null, 0) else c.xpc_dictionary_create(null, null, 0);
        const created = c.xpc_string_create("retained-child");
        if (array) c.xpc_array_append_value(parent, created) else c.xpc_dictionary_set_value(parent, "child", created);
        c.xpc_release(created);
        const child = c.xpc_retain(if (array) c.xpc_array_get_value(parent, 0) else c.xpc_dictionary_get_value(parent, "child"));
        c.xpc_release(parent);
        try string(child, "retained-child");
        try refs(child, 1);
        c.xpc_release(child);
    }
}
// xpc.h:1170-1177, 1221-1229, 2002: every occupied slot retains its value.
pub fn sharedSlots() !void {
    for (0..2) |order| {
        const child = c.xpc_string_create("shared");
        const a = c.xpc_array_create(null, 0);
        const b = c.xpc_array_create(null, 0);
        const d = c.xpc_dictionary_create(null, null, 0);
        c.xpc_array_append_value(a, child);
        c.xpc_array_append_value(a, child);
        c.xpc_array_append_value(b, child);
        c.xpc_dictionary_set_value(d, "child", child);
        try check("duplicate slots count", c.xpc_array_get_count(a) == 2 and c.xpc_array_get_count(b) == 1);
        try check("same object in all slots", c.xpc_array_get_value(a, 0) == child and c.xpc_array_get_value(a, 1) == child and c.xpc_array_get_value(b, 0) == child);
        try refs(child, 5);
        if (order == 0) {
            c.xpc_release(a);
            try string(c.xpc_array_get_value(b, 0), "shared");
            c.xpc_release(d);
            c.xpc_release(b);
        } else {
            c.xpc_release(b);
            try string(c.xpc_array_get_value(a, 1), "shared");
            c.xpc_release(d);
            c.xpc_release(a);
        }
        try string(child, "shared");
        try refs(child, 1);
        c.xpc_release(child);
    }
}
// xpc.h:1918-1934 permits NULL values; 2002-2005 requires replace/delete.
pub fn replaceRemove() !void {
    const a = c.xpc_int64_create(11);
    const b = c.xpc_int64_create(22);
    const keys = [_][*c]const u8{ "a", "b", "c" };
    const values = [_]O{ a, b, a };
    const three = c.xpc_dictionary_create(&keys, &values, 3);
    try check("three input keys count=3", c.xpc_dictionary_get_count(three) == 3);
    const sparse_values = [_]O{ a, null, b };
    const sparse = c.xpc_dictionary_create(&keys, &sparse_values, 3);
    try check("NULL creation value skipped", c.xpc_dictionary_get_count(sparse) == 2 and c.xpc_dictionary_get_value(sparse, "b") == null);
    const d = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_value(d, "k", a);
    c.xpc_dictionary_set_value(d, "k", a);
    try refs(a, 5); // caller, three's two slots, sparse, d.
    c.xpc_dictionary_set_value(d, "k", b);
    try check("replacement value", c.xpc_dictionary_get_int64(d, "k") == 22);
    c.xpc_dictionary_set_value(d, "k", null);
    c.xpc_dictionary_set_value(d, "absent", null);
    try check("NULL removes, absent removal no-op", c.xpc_dictionary_get_value(d, "k") == null and c.xpc_dictionary_get_count(d) == 0);
    const arr = c.xpc_array_create(null, 0);
    c.xpc_array_append_value(arr, a);
    c.xpc_array_set_value(arr, 0, a);
    c.xpc_array_set_value(arr, 0, b);
    try check("array replacement", c.xpc_array_get_int64(arr, 0) == 22);
    c.xpc_release(arr);
    c.xpc_release(d);
    c.xpc_release(sparse);
    c.xpc_release(three);
    try refs(a, 1);
    try refs(b, 1);
    c.xpc_release(a);
    c.xpc_release(b);
}
// xpc.h:1918-1924 key copies, 773-776 data copies; string oracle below.
pub fn inputCopies() !void {
    const key = c.strdup("original-key");
    const bytes: [*]u8 = @ptrCast(c.malloc(4));
    @memcpy(bytes[0..4], "DATA");
    const d = c.xpc_dictionary_create(null, null, 0);
    const n = c.xpc_int64_create(7);
    c.xpc_dictionary_set_value(d, key, n);
    c.xpc_release(n);
    const data = c.xpc_data_create(bytes, 4);
    key[0] = 'X';
    bytes[0] = 'X';
    // Check while the mutated buffers are still allocated for a precise red.
    var bad = false;
    check("dictionary copied key bytes", c.xpc_dictionary_get_int64(d, "original-key") == 7) catch {
        bad = true;
    };
    check("data copied bytes", std.mem.eql(u8, @as([*]const u8, @ptrCast(c.xpc_data_get_bytes_ptr(data)))[0..4], "DATA")) catch {
        bad = true;
    };
    c.free(key);
    c.free(bytes);
    if (bad) return error.ContractViolation;
    try check("key survives input free", c.xpc_dictionary_get_int64(d, "original-key") == 7);
    try check("data survives input free", std.mem.eql(u8, @as([*]const u8, @ptrCast(c.xpc_data_get_bytes_ptr(data)))[0..4], "DATA"));
    c.xpc_release(data);
    c.xpc_release(d);
}
// ORACLE_REQUIRED string-buffer independence: xpc.h:876-888 (not explicit copy wording).
pub fn stringBufferIndependence() !void {
    const text = c.strdup("original-string");
    const s = c.xpc_string_create(text);
    text[0] = 'X';
    try string(s, "original-string");
    c.free(text);
    try string(s, "original-string");
    c.xpc_release(s);
}
// ORACLE_REQUIRED boolean return: xpc.h:164-179, 363-410.
pub fn booleanConstants() !void {
    for ([_]bool{ true, false }) |value| {
        const o = c.xpc_bool_create(value);
        const constant: O = @ptrCast(@constCast(if (value) &_xpc_bool_true else &_xpc_bool_false));
        try check("bool_create returns canonical constant", o == constant);
        try check("constant has Boolean type/value", c.xpc_get_type(constant) == @as(c.xpc_type_t, @ptrCast(&_xpc_type_bool)) and c.xpc_bool_get_value(constant) == value);
        try check("retain constant identity", c.xpc_retain(constant) == constant);
        c.xpc_release(constant);
        c.xpc_release(o);
        try check("constant survives balancing", c.xpc_bool_get_value(constant) == value);
    }
}
// xpc.h:56-58, 398-410, 2002: scalar setters own only the collection ref.
pub fn temporaryBalance() !void {
    const d = c.xpc_dictionary_create(null, null, 0);
    const a = c.xpc_array_create(null, 0);
    c.xpc_dictionary_set_int64(d, "int", -7);
    c.xpc_dictionary_set_uint64(d, "uint", 8);
    c.xpc_dictionary_set_double(d, "double", 1.5);
    c.xpc_dictionary_set_date(d, "date", 1234);
    c.xpc_dictionary_set_string(d, "string", "scalar");
    c.xpc_dictionary_set_data(d, "data", "bytes", 5);
    c.xpc_dictionary_set_bool(d, "bool", true);
    const uuid: [16]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    c.xpc_dictionary_set_uuid(d, "uuid", &uuid);
    c.xpc_array_set_int64(a, c.XPC_ARRAY_APPEND, -7);
    c.xpc_array_set_uint64(a, c.XPC_ARRAY_APPEND, 8);
    c.xpc_array_set_double(a, c.XPC_ARRAY_APPEND, 1.5);
    c.xpc_array_set_date(a, c.XPC_ARRAY_APPEND, 1234);
    c.xpc_array_set_string(a, c.XPC_ARRAY_APPEND, "scalar");
    c.xpc_array_set_data(a, c.XPC_ARRAY_APPEND, "bytes", 5);
    c.xpc_array_set_bool(a, c.XPC_ARRAY_APPEND, true);
    c.xpc_array_set_uuid(a, c.XPC_ARRAY_APPEND, &uuid);
    try check("portable scalar setter values", c.xpc_dictionary_get_int64(d, "int") == -7 and c.xpc_array_get_uint64(a, 1) == 8 and c.xpc_array_get_count(a) == 8);
    try check("all scalar getters preserve inputs", c.xpc_dictionary_get_uint64(d, "uint") == 8 and c.xpc_array_get_int64(a, 0) == -7 and
        c.xpc_dictionary_get_double(d, "double") == 1.5 and c.xpc_array_get_double(a, 2) == 1.5 and
        c.xpc_dictionary_get_date(d, "date") == 1234 and c.xpc_array_get_date(a, 3) == 1234 and
        c.xpc_dictionary_get_bool(d, "bool") and c.xpc_array_get_bool(a, 6));
    try string(c.xpc_dictionary_get_value(d, "string"), "scalar");
    try string(c.xpc_array_get_value(a, 4), "scalar");
    var data_size: usize = 0;
    const dictionary_bytes = c.xpc_dictionary_get_data(d, "data", &data_size);
    try check("dictionary data setter", data_size == 5 and dictionary_bytes != null and std.mem.eql(u8, @as([*]const u8, @ptrCast(dictionary_bytes))[0..5], "bytes"));
    const array_bytes = c.xpc_array_get_data(a, 5, &data_size);
    try check("array data setter", data_size == 5 and array_bytes != null and std.mem.eql(u8, @as([*]const u8, @ptrCast(array_bytes))[0..5], "bytes"));
    try check("UUID setters", std.mem.eql(u8, c.xpc_dictionary_get_uuid(d, "uuid")[0..16], &uuid) and std.mem.eql(u8, c.xpc_array_get_uuid(a, 7)[0..16], &uuid));
    for ([_][*:0]const u8{ "int", "uint", "double", "date", "string", "data" }, 0..) |key, i| {
        try refs(c.xpc_dictionary_get_value(d, key), 1);
        try refs(c.xpc_array_get_value(a, i), 1);
    }
    try refs(c.xpc_dictionary_get_value(d, "uuid"), 1);
    try refs(c.xpc_array_get_value(a, 7), 1);
    // Booleans may be immortal; no numeric count asserted for them.
    c.xpc_release(d);
    c.xpc_release(a);
}
fn copy(o: O) !O {
    const raw = c.dlsym(c.RTLD_DEFAULT, "xpc_copy");
    try check("public xpc_copy entry available", raw != null);
    const f: *const fn (O) callconv(.c) O = @ptrCast(raw);
    const result = f(o);
    try check("supported object copy returned value", result != null);
    return result;
}
// xpc.h:459-467: deep collection copy; scalar identity reuse permitted.
pub fn deepCopy() !void {
    const child = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_int64(child, "n", 1);
    const original = c.xpc_array_create(null, 0);
    c.xpc_array_append_value(original, child);
    c.xpc_release(child);
    const other = try copy(original);
    c.xpc_dictionary_set_int64(c.xpc_array_get_value(original, 0), "n", 2);
    try check("deep copy independent from original mutation", c.xpc_dictionary_get_int64(c.xpc_array_get_value(other, 0), "n") == 1);
    c.xpc_dictionary_set_int64(c.xpc_array_get_value(other, 0), "n", 3);
    try check("original independent from copy mutation", c.xpc_dictionary_get_int64(c.xpc_array_get_value(original, 0), "n") == 2);
    c.xpc_release(original);
    try check("copy survives original release", c.xpc_dictionary_get_int64(c.xpc_array_get_value(other, 0), "n") == 3);
    c.xpc_release(other);
}
// xpc.h:487-495: type-sensitive equality and equal-hash implication.
pub fn valueEquality() !void {
    const a = c.xpc_int64_create(17);
    const b = c.xpc_int64_create(17);
    const u = c.xpc_uint64_create(17);
    try check("distinct scalar objects compare by value", c.xpc_equal(a, b));
    try check("equality implies same hash", c.xpc_hash(a) == c.xpc_hash(b));
    try check("numeric types distinct", !c.xpc_equal(a, u));
    const d1 = c.xpc_dictionary_create(null, null, 0);
    const d2 = c.xpc_dictionary_create(null, null, 0);
    c.xpc_dictionary_set_value(d1, "a", a);
    c.xpc_dictionary_set_value(d1, "b", u);
    c.xpc_dictionary_set_value(d2, "b", u);
    c.xpc_dictionary_set_value(d2, "a", b);
    try check("dictionary insertion order irrelevant", c.xpc_equal(d1, d2) and c.xpc_hash(d1) == c.xpc_hash(d2));
    const aa = [_]O{ a, u };
    const bb = [_]O{ u, b };
    const ar1 = c.xpc_array_create(&aa, 2);
    const ar2 = c.xpc_array_create(&bb, 2);
    try check("array order significant", !c.xpc_equal(ar1, ar2));
    c.xpc_release(ar1);
    c.xpc_release(ar2);
    c.xpc_release(d1);
    c.xpc_release(d2);
    c.xpc_release(a);
    c.xpc_release(b);
    c.xpc_release(u);
}
// ORACLE_REQUIRED floating equality: ordinary equal values are documented;
// signed-zero and NaN outcomes are observations, not guessed expectations.
pub fn floatingEquality() !void {
    const a = c.xpc_double_create(1.5);
    const b = c.xpc_double_create(1.5);
    const zero = c.xpc_double_create(0.0);
    const negative = c.xpc_double_create(-0.0);
    const nan1 = c.xpc_double_create(std.math.nan(f64));
    const nan2 = c.xpc_double_create(std.math.nan(f64));
    std.debug.print("ORACLE floating ordinary_equal={} signed_zero_equal={} nan_equal={} nan_self={}\n", .{ c.xpc_equal(a, b), c.xpc_equal(zero, negative), c.xpc_equal(nan1, nan2), c.xpc_equal(nan1, nan1) });
    try check("equal ordinary floating values", c.xpc_equal(a, b));
    try check("equal floating hashes", c.xpc_hash(a) == c.xpc_hash(b));
    for ([_]O{ a, b, zero, negative, nan1, nan2 }) |o| c.xpc_release(o);
}
// ORACLE_REQUIRED resource copies: xpc.h:1027-1040, descriptor dup and pointer equality.
pub fn resourceCopies() !void {
    const raw_create = c.dlsym(c.RTLD_DEFAULT, "xpc_fd_create");
    const raw_dup = c.dlsym(c.RTLD_DEFAULT, "xpc_fd_dup");
    try check("public fd constructor and dup available", raw_create != null and raw_dup != null);
    const create: *const fn (c_int) callconv(.c) O = @ptrCast(raw_create);
    const dup: *const fn (O) callconv(.c) c_int = @ptrCast(raw_dup);
    var pipe: [2]c_int = undefined;
    try check("pipe fixture", c.pipe(&pipe) == 0);
    const boxed = create(pipe[0]);
    try check("fd boxed", boxed != null);
    _ = c.close(pipe[0]);
    const other = try copy(boxed);
    std.debug.print("ORACLE resource copy_identity={} copy_equal={}\n", .{ other == boxed, c.xpc_equal(boxed, other) });
    try check("copied fd object has distinct identity/equality", other != boxed and !c.xpc_equal(boxed, other));
    c.xpc_release(boxed);
    const fd = dup(other);
    try check("copy owns descriptor independently", fd >= 0);
    var byte: u8 = 'Q';
    try check("resource write", c.write(pipe[1], &byte, 1) == 1);
    byte = 0;
    try check("resource copy readable after source closed/released", c.read(fd, &byte, 1) == 1 and byte == 'Q');
    _ = c.close(fd);
    _ = c.close(pipe[1]);
    c.xpc_release(other);
}

test "retainedChild" {
    try retainedChild();
}
test "sharedSlots" {
    try sharedSlots();
}
test "replaceRemove" {
    try replaceRemove();
}
test "inputCopies" {
    try inputCopies();
}
test "stringBufferIndependence ORACLE_REQUIRED" {
    try stringBufferIndependence();
}
test "booleanConstants ORACLE_REQUIRED" {
    try booleanConstants();
}
test "temporaryBalance" {
    try temporaryBalance();
}
test "deepCopy" {
    try deepCopy();
}
test "valueEquality" {
    try valueEquality();
}
test "floatingEquality ORACLE_REQUIRED" {
    try floatingEquality();
}
test "resourceCopies ORACLE_REQUIRED" {
    try resourceCopies();
}

const atf = if (builtin.is_test) struct {} else @cImport({
    @cInclude("atf-c.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]atf.atf_tp_t) callconv(.c) atf.atf_error_t) c_int;
const names = [_][*:0]const u8{ "retainedChild", "sharedSlots", "replaceRemove", "inputCopies", "stringBufferIndependence", "booleanConstants", "temporaryBalance", "deepCopy", "valueEquality", "floatingEquality", "resourceCopies" };
const functions = [_]*const fn () anyerror!void{ &retainedChild, &sharedSlots, &replaceRemove, &inputCopies, &stringBufferIndependence, &booleanConstants, &temporaryBalance, &deepCopy, &valueEquality, &floatingEquality, &resourceCopies };
var cases: if (builtin.is_test) void else [names.len]atf.atf_tc_t = undefined;
fn body(t: [*c]const atf.atf_tc_t) callconv(.c) void {
    _ = c.alarm(15);
    for (names, functions) |name, f| if (std.mem.eql(u8, std.mem.span(atf.atf_tc_get_ident(t)), std.mem.span(name))) {
        f() catch atf.atf_tc_fail("object model contract failed; see named check");
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
