// Plain key=value profiles, embedded defaults plus an optional local file.
const std = @import("std");
pub const Profile = struct {
    text: []const u8,
    pool: []const u8 = "",
    console: []const u8 = "",
    swap: ?[]const u8 = null,
    owner_now: bool = false,
    requires_sealed: bool = false,

    pub fn parse(text: []const u8) !Profile {
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidProfile;
        var p = Profile{ .text = text };
        var seen: u4 = 0;
        var sealed_seen = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const at = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidProfile;
            const k = line[0..at];
            const v = line[at + 1 ..];
            if (v.len == 0) return error.InvalidProfile;
            const bit: u4 = if (eq(k, "pool")) 1 else if (eq(k, "console")) 2 else if (eq(k, "swap")) 4 else if (eq(k, "owner")) 8 else 0;
            if (bit != 0) {
                if (seen & bit != 0) return error.InvalidProfile;
                seen |= bit;
            }
            if (eq(k, "pool")) p.pool = v else if (eq(k, "console")) p.console = v else if (eq(k, "swap")) {
                p.swap = if (eq(v, "none")) null else v;
            } else if (eq(k, "owner")) {
                if (!eq(v, "now") and !eq(v, "later")) return error.InvalidProfile;
                p.owner_now = eq(v, "now");
            } else if (eq(k, "sealed")) {
                if (sealed_seen or (!eq(v, "yes") and !eq(v, "no"))) return error.InvalidProfile;
                sealed_seen = true;
                p.requires_sealed = eq(v, "yes");
            } else if (eq(k, "rc") or eq(k, "loader")) {
                if (std.mem.indexOfScalar(u8, v, '=') == null) return error.InvalidProfile;
            } else if (eq(k, "data")) {
                var allowed = false;
                for ([_][]const u8{ "/private/", "/Users/", "/Library/", "/usr/local/" }) |root| allowed = allowed or std.mem.startsWith(u8, v, root);
                if (!allowed or std.mem.indexOf(u8, v, "..") != null or v[v.len - 1] == '/' or std.mem.indexOfScalar(u8, v, 0) != null) return error.InvalidProfile;
            } else return error.InvalidProfile;
        }
        if (seen != 15) return error.InvalidProfile;
        return p;
    }
    pub fn builtin(name: []const u8) !Profile {
        if (eq(name, "disk")) return parse(@embedFile("profiles/disk.conf"));
        if (eq(name, "live")) return parse(@embedFile("profiles/live.conf"));
        if (eq(name, "vm")) return parse(@embedFile("profiles/vm.conf"));
        if (eq(name, "plan")) return parse(@embedFile("profiles/plan.conf"));
        return error.InvalidProfile;
    }
    pub fn extras(self: Profile, a: std.mem.Allocator, key: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        var lines = std.mem.splitScalar(u8, self.text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == '=') {
                try out.writer.writeAll(line[key.len + 1 ..]);
                try out.writer.writeByte('\n');
            }
        }
        return out.toOwnedSlice();
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
