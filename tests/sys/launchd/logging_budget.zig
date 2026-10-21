// SPDX-License-Identifier: BSD-2-Clause
// Fixture policy only: the kernel feature selects the workload and deadlines.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});
pub const Kernel = enum { release, kasan };
const Work = struct { extra_jobs: u32, job_ms: u32 };
const Settings = struct {
    queue_records: u32,
    tail_seconds: u32,
    layer_seconds: u32,
    release: Work,
    kasan: Work,
    normal_case_seconds: u32,
    cleanup_seconds: u32,
    churn_seconds: u32,
    boot_overhead_seconds: u32,
    max_boot_seconds: u32,
};
pub const Limits = struct {
    jobs: u32,
    queue_records: u32,
    job_ms: u32,
    tail_seconds: u32,
    worker_seconds: u32,
    parent_seconds: u32,
    atf_seconds: u32,
    runner_seconds: u32,
};
pub fn limits(kernel: Kernel) Limits {
    const parsed = std.json.parseFromSlice(Settings, std.heap.page_allocator, @embedFile("logging_budget.json"), .{}) catch unreachable;
    defer parsed.deinit();
    const s = parsed.value;
    const work = if (kernel == .kasan) s.kasan else s.release;
    const jobs = s.queue_records + work.extra_jobs;
    const worker = (jobs * work.job_ms + 999) / 1000 + s.tail_seconds;
    return .{ .jobs = jobs, .queue_records = s.queue_records, .job_ms = work.job_ms, .tail_seconds = s.tail_seconds, .worker_seconds = worker, .parent_seconds = worker + s.layer_seconds, .atf_seconds = worker + 2 * s.layer_seconds, .runner_seconds = worker + 3 * s.layer_seconds };
}
pub fn featureResult(rc: c_int, err: c_int, length: usize, value: c_int) !Kernel {
    if (rc == 0) {
        if (length != @sizeOf(c_int) or value != 1) return error.InvalidKasanFeature;
        return .kasan;
    }
    // FEATURE(kasan) exists only in a KASAN kernel. Other query failures
    // must not silently select the shorter RELEASE deadline.
    if (err == c.ENOENT) return .release;
    return error.KasanFeatureQuery;
}
pub fn running() !Kernel {
    var value: c_int = 0;
    var length: usize = @sizeOf(c_int);
    const rc = c.sysctlbyname("kern.features.kasan", &value, &length, null, 0);
    return featureResult(rc, if (rc == 0) 0 else c.__error().*, length, value);
}
pub fn main() void {
    for ([_]Kernel{ .release, .kasan }) |kernel| {
        const v = limits(kernel);
        _ = c.printf("{\"kernel\":\"%s\",\"jobs\":%u,\"queue_records\":%u,\"job_ms\":%u,\"tail_seconds\":%u,\"worker_seconds\":%u,\"parent_seconds\":%u,\"atf_seconds\":%u,\"runner_seconds\":%u}\n", @tagName(kernel).ptr, v.jobs, v.queue_records, v.job_ms, v.tail_seconds, v.worker_seconds, v.parent_seconds, v.atf_seconds, v.runner_seconds);
    }
}
test "kernel feature is absent on RELEASE and present on KASAN" {
    try std.testing.expectEqual(Kernel.release, try featureResult(-1, c.ENOENT, 4, 0));
    try std.testing.expectEqual(Kernel.kasan, try featureResult(0, 0, @sizeOf(c_int), 1));
    try std.testing.expectError(error.KasanFeatureQuery, featureResult(-1, c.EACCES, 4, 0));
    try std.testing.expectError(error.InvalidKasanFeature, featureResult(0, 0, 1, 1));
    try std.testing.expectError(error.InvalidKasanFeature, featureResult(0, 0, 4, 0));
}
test "both kernel workloads overflow the queue and deadlines nest strictly" {
    const release = limits(.release);
    const kasan = limits(.kasan);
    for ([_]Limits{ release, kasan }) |v| {
        try std.testing.expect(v.jobs > v.queue_records);
        try std.testing.expect(v.worker_seconds < v.parent_seconds);
        try std.testing.expect(v.parent_seconds < v.atf_seconds);
        try std.testing.expect(v.atf_seconds < v.runner_seconds);
    }
    try std.testing.expect(kasan.jobs < release.jobs);
    try std.testing.expect(kasan.worker_seconds > release.worker_seconds);
}
test "running kernel feature query selects a valid workload" {
    const kernel = try running();
    const v = limits(kernel);
    try std.testing.expect(v.jobs > v.queue_records);
    _ = c.printf("logging_budget observed_kernel=%s jobs=%u runner_s=%u\n", @tagName(kernel).ptr, v.jobs, v.runner_seconds);
}
