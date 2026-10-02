// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = @cImport({
    @cInclude("atf-c.h");
    @cInclude("launch.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("dlfcn.h");
    @cInclude("errno.h");
});
extern fn atf_tp_main(c_int, [*c][*c]u8, *const fn ([*c]c.atf_tp_t) callconv(.c) c.atf_error_t) c_int;
const Api = struct {
    handle: *anyopaque,
    alloc: *const @TypeOf(c.launch_data_alloc),
    string: *const @TypeOf(c.launch_data_new_string),
    insert: *const @TypeOf(c.launch_data_dict_insert),
    lookup: *const @TypeOf(c.launch_data_dict_lookup),
    kind: *const @TypeOf(c.launch_data_get_type),
    text: *const @TypeOf(c.launch_data_get_string),
    err: *const @TypeOf(c.launch_data_get_errno),
    free: *const @TypeOf(c.launch_data_free),
    msg: *const @TypeOf(c.launch_msg),
    fn load() ?Api {
        const handle = c.dlopen("/usr/lib/liblaunch.so.5", c.RTLD_NOW | c.RTLD_LOCAL) orelse return null;
        var api: Api = undefined;
        api.handle = handle;
        inline for (.{ .{ "alloc", "launch_data_alloc" }, .{ "string", "launch_data_new_string" }, .{ "insert", "launch_data_dict_insert" }, .{ "lookup", "launch_data_dict_lookup" }, .{ "kind", "launch_data_get_type" }, .{ "text", "launch_data_get_string" }, .{ "err", "launch_data_get_errno" }, .{ "free", "launch_data_free" }, .{ "msg", "launch_msg" } }) |pair| {
            const symbol = c.dlsym(handle, pair[1]) orelse {
                _ = c.dlclose(handle);
                return null;
            };
            @field(api, pair[0]) = @ptrCast(symbol);
        }
        return api;
    }
    fn request(api: Api, key: [*:0]const u8, label: [*:0]const u8) c.launch_data_t {
        const request_data = api.alloc(c.LAUNCH_DATA_DICTIONARY) orelse return null;
        defer api.free(request_data);
        const value = api.string(label) orelse return null;
        if (!api.insert(request_data, value, key)) {
            api.free(value);
            return null;
        }
        return api.msg(request_data);
    }
};
var tc: c.atf_tc_t = undefined;
fn head(t: [*c]c.atf_tc_t) callconv(.c) void {
    _ = c.atf_tc_set_md_var(t, "descr", "%s", "GetJob returns the requested Label instead of the caller's job");
    _ = c.atf_tc_set_md_var(t, "timeout", "%s", "20");
    _ = c.atf_tc_set_md_var(t, "require.user", "%s", "root");
}
fn body(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const api = Api.load() orelse c.atf_tc_fail("staged liblaunch load/binding failed");
    defer _ = c.dlclose(api.handle);
    const symbol = c.dlsym(api.handle, "bootstrap_port") orelse c.atf_tc_fail("bootstrap_port missing");
    const port: *const u32 = @ptrCast(@alignCast(symbol));
    if (port.* == 0) c.atf_tc_fail("MIG bootstrap port unavailable; socket fallback cannot cover this handler");
    const record = c.fopen("created-jobs", "w") orelse c.atf_tc_fail("cleanup record failed");
    defer _ = c.fclose(record);
    var labels: [2][128]u8 = undefined;
    for (&labels, 0..) |*label, index| {
        const size = c.snprintf(label, label.len, "com.rmxos.atf.getjob.%d.%zu", c.getpid(), index);
        if (size < 0 or size >= label.len) c.atf_tc_fail("label formatting failed");
        const absent = api.request("GetJob", @ptrCast(label)) orelse c.atf_tc_fail("missing-job request failed");
        if (api.kind(absent) != c.LAUNCH_DATA_ERRNO or api.err(absent) != c.ESRCH) c.atf_tc_fail("fresh label did not return ESRCH");
        api.free(absent);
        // Record before submission so cleanup also covers a delayed reply.
        if (c.fprintf(record, "%s\n", label) < 0 or c.fflush(record) != 0) c.atf_tc_fail("cleanup record write failed");
        const job = api.alloc(c.LAUNCH_DATA_DICTIONARY) orelse c.atf_tc_fail("job allocation failed");
        const job_label = api.string(@ptrCast(label)) orelse c.atf_tc_fail("Label allocation failed");
        const program = api.string("/usr/bin/true") orelse c.atf_tc_fail("Program allocation failed");
        if (!api.insert(job, job_label, "Label") or !api.insert(job, program, "Program")) c.atf_tc_fail("job setup failed");
        const submit = api.alloc(c.LAUNCH_DATA_DICTIONARY) orelse c.atf_tc_fail("request allocation failed");
        if (!api.insert(submit, job, "SubmitJob")) c.atf_tc_fail("SubmitJob setup failed");
        const reply = api.msg(submit) orelse c.atf_tc_fail("SubmitJob reply missing");
        if (api.kind(reply) != c.LAUNCH_DATA_ERRNO or api.err(reply) != 0) c.atf_tc_fail("SubmitJob failed");
        api.free(reply);
        api.free(submit);
    }
    for (&labels) |*label| {
        const reply = api.request("GetJob", @ptrCast(label)) orelse c.atf_tc_fail("GetJob reply missing");
        if (api.kind(reply) != c.LAUNCH_DATA_DICTIONARY) c.atf_tc_fail("GetJob reply is not a dictionary");
        const value = api.lookup(reply, "Label") orelse c.atf_tc_fail("GetJob Label missing");
        if (api.kind(value) != c.LAUNCH_DATA_STRING) c.atf_tc_fail("GetJob Label is not a string");
        const actual = api.text(value);
        if (actual == null) c.atf_tc_fail("GetJob Label string missing");
        _ = c.printf("getjob expected_label=%s observed_label=%s\n", label, actual);
        if (!std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(label))), std.mem.span(actual))) c.atf_tc_fail("GetJob exported a different job");
        api.free(reply);
    }
}
fn cleanup(_: [*c]const c.atf_tc_t) callconv(.c) void {
    const record = c.fopen("created-jobs", "r") orelse return;
    defer _ = c.fclose(record);
    const api = Api.load() orelse return;
    defer _ = c.dlclose(api.handle);
    var label: [128]u8 = undefined;
    while (c.fgets(&label, label.len, record) != null) {
        const length = std.mem.len(@as([*:0]const u8, @ptrCast(&label)));
        if (length == 0 or label[length - 1] != '\n') continue;
        label[length - 1] = 0;
        if (!std.mem.startsWith(u8, label[0 .. length - 1], "com.rmxos.atf.getjob.")) continue;
        const reply = api.request("RemoveJob", @ptrCast(&label)) orelse continue;
        api.free(reply);
    }
}
fn addTests(tp: [*c]c.atf_tp_t) callconv(.c) c.atf_error_t {
    const err = c.atf_tc_init(&tc, "named_job", &head, &body, &cleanup, c.atf_tp_get_config(tp));
    if (c.atf_is_error(err)) return err;
    return c.atf_tp_add_tc(tp, &tc);
}
pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    return atf_tp_main(argc, argv, &addTests);
}
