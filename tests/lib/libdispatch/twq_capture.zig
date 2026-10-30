// SPDX-License-Identifier: BSD-2-Clause
// Runs one upstream libdispatch test program (swift-corelibs-libdispatch's
// tests/) under libthr's workqueue trace and records what happened:
//   twq_capture <cap_seconds> <program> [args...]
// - "twq before"/"twq after": sysctl kern.twq around the run;
// - "upstream": every line the program prints (its stdout is line-buffered
//   through stdbuf, so it stays in order with the trace on stderr);
// - "segment": per "Testing ..." header of the program, the trace counts
//   (requests, refusals, spawns, claims, redrives, peak live workers);
// - "trace": for a segment that printed [FAIL] or was cut by the cap, its
//   first and last 150 trace lines.
// It reports facts only; the validator decides.
const std = @import("std");
const c = @cImport({
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const keep = 150;
const max_line = 1024;

fn out(text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        const n = c.write(1, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}
fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    out(std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return);
}
fn now_ms() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn sysctl(comptime label: []const u8) void {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return;
    const pid = c.fork();
    if (pid == 0) {
        _ = c.dup2(fds[1], 1);
        _ = c.dup2(fds[1], 2);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        const argv = [_:null]?[*:0]const u8{ "/sbin/sysctl", "kern.twq" };
        _ = c.execv("/sbin/sysctl", @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    var lines = Lines{};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fds[0], &buf, buf.len);
        if (n <= 0) break;
        lines.feed(buf[0..@intCast(n)], struct {
            fn f(l: []const u8) void {
                say("twq " ++ label ++ " {s}", .{l});
            }
        }.f);
    }
    _ = c.close(fds[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

// Splits a byte stream into lines, longer ones cut at max_line.
const Lines = struct {
    buf: [max_line]u8 = undefined,
    len: usize = 0,
    fn feed(self: *Lines, data: []const u8, comptime sink: fn ([]const u8) void) void {
        for (data) |b| {
            if (b == '\n') {
                sink(self.buf[0..self.len]);
                self.len = 0;
            } else if (self.len < self.buf.len) {
                self.buf[self.len] = b;
                self.len += 1;
            }
        }
    }
};

const Stored = struct { text: [max_line]u8 = undefined, len: usize = 0 };
var first: [keep]Stored = undefined;
var last: [keep]Stored = undefined;
const Segment = struct {
    index: u32 = 0,
    name: [256]u8 = undefined,
    name_len: usize = 0,
    trace_lines: u64 = 0,
    requests: u64 = 0,
    refused: u64 = 0,
    spawned: u64 = 0,
    claims: u64 = 0,
    redrives: u64 = 0,
    max_live: u64 = 0,
    failed: bool = false,
};
var seg = Segment{};

fn field(line: []const u8, comptime key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, line, " " ++ key ++ "=") orelse return null;
    const start = at + key.len + 2;
    var end = start;
    while (end < line.len and line[end] >= '0' and line[end] <= '9') end += 1;
    return std.fmt.parseInt(u64, line[start..end], 10) catch null;
}

fn store(line: []const u8) void {
    const i = seg.trace_lines;
    var slot: *Stored = if (i < keep) &first[@intCast(i)] else &last[@intCast((i - keep) % keep)];
    slot.len = @min(line.len, max_line);
    @memcpy(slot.text[0..slot.len], line[0..slot.len]);
}

fn traceLine(line: []const u8) void {
    store(line);
    seg.trace_lines += 1;
    if (std.mem.indexOf(u8, line, "event=addthreads-ready ") != null or
        std.mem.indexOf(u8, line, "event=reaper-redrive-ready ") != null)
    {
        const requested = field(line, "requested") orelse 0;
        const admitted = field(line, "admitted") orelse 0;
        const pending = field(line, "pending") orelse 0;
        if (std.mem.indexOf(u8, line, "reaper-redrive") != null) seg.redrives += 1 else seg.requests += 1;
        if (admitted == 0 and (requested > 0 or pending > 0)) seg.refused += 1;
    }
    if (std.mem.indexOf(u8, line, "event=spawned ") != null) seg.spawned += 1;
    if (std.mem.indexOf(u8, line, "event=worker-claim ") != null) seg.claims += 1;
    if (field(line, "live_workers")) |l| seg.max_live = @max(seg.max_live, l);
}

fn closeSegment(cut: bool) void {
    const failed = seg.failed or cut;
    say("segment index={d} name=\"{s}\" trace_lines={d} requests={d} refused={d} spawned={d} claims={d} redrives={d} max_live_workers={d} failed={d} cut={d}", .{ seg.index, seg.name[0..seg.name_len], seg.trace_lines, seg.requests, seg.refused, seg.spawned, seg.claims, seg.redrives, seg.max_live, @intFromBool(seg.failed), @intFromBool(cut) });
    if (failed) {
        const head = @min(seg.trace_lines, keep);
        for (first[0..@intCast(head)]) |s| say("trace segment={d} {s}", .{ seg.index, s.text[0..s.len] });
        if (seg.trace_lines > keep) {
            const tail = @min(seg.trace_lines - keep, keep);
            if (seg.trace_lines - keep > keep) say("trace segment={d} ... {d} lines not shown ...", .{ seg.index, seg.trace_lines - 2 * keep });
            var k: u64 = seg.trace_lines - tail;
            while (k < seg.trace_lines) : (k += 1) {
                const s = last[@intCast((k - keep) % keep)];
                say("trace segment={d} {s}", .{ seg.index, s.text[0..s.len] });
            }
        }
    }
    const next = seg.index + 1;
    seg = Segment{ .index = next };
}

fn programLine(line: []const u8) void {
    if (std.mem.startsWith(u8, line, "[libthr-twq] ")) return traceLine(line);
    if (std.mem.startsWith(u8, line, "Testing ")) {
        closeSegment(false);
        seg.name_len = @min(line.len, seg.name.len);
        @memcpy(seg.name[0..seg.name_len], line[0..seg.name_len]);
    }
    if (std.mem.startsWith(u8, line, "[FAIL]")) seg.failed = true;
    say("upstream {s}", .{line});
}

pub export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    if (argc < 3) return 2;
    const cap_s = std.fmt.parseInt(i64, std.mem.span(argv[1]), 10) catch return 2;
    sysctl("before");
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return 3;
    const pid = c.fork();
    if (pid < 0) return 3;
    if (pid == 0) {
        _ = c.dup2(fds[1], 1);
        _ = c.dup2(fds[1], 2);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        // Its own process group, so the cap kills every process it starts.
        _ = c.setpgid(0, 0);
        _ = c.setenv("LIBPTHREAD_TWQ_TRACE", "1", 1);
        _ = c.setenv("_STDBUF_O", "L", 1);
        _ = c.setenv("LD_PRELOAD", "/usr/lib/libstdbuf.so", 1);
        _ = c.execv(argv[2], @ptrCast(argv + 2));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    const started = now_ms();
    var lines = Lines{};
    var buf: [65536]u8 = undefined;
    var cut = false;
    while (true) {
        const left = cap_s * 1000 - (now_ms() - started);
        if (left <= 0) {
            cut = true;
            _ = c.kill(-pid, c.SIGKILL);
            break;
        }
        var p = c.struct_pollfd{ .fd = fds[0], .events = c.POLLIN, .revents = 0 };
        const r = c.poll(&p, 1, @intCast(@min(left, 1000)));
        if (r < 0) break;
        if (r == 0) continue;
        const n = c.read(fds[0], &buf, buf.len);
        if (n <= 0) break;
        lines.feed(buf[0..@intCast(n)], programLine);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    // Drain what the killed program left in the pipe.
    while (true) {
        const n = c.read(fds[0], &buf, buf.len);
        if (n <= 0) break;
        lines.feed(buf[0..@intCast(n)], programLine);
    }
    _ = c.close(fds[0]);
    closeSegment(cut);
    say("upstream status={d} exited={d} exit_code={d} signaled={d} timed_out={d} elapsed_ms={d}", .{ status, @intFromBool(c.WIFEXITED(status)), if (c.WIFEXITED(status)) c.WEXITSTATUS(status) else -1, @intFromBool(c.WIFSIGNALED(status)), @intFromBool(cut), now_ms() - started });
    sysctl("after");
    return 0;
}
