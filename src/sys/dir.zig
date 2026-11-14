//! Finding files under a folder.
const std = @import("std");
const sys = @import("calls.zig");

const max_depth = 6;

/// Paths of the files under `root` whose names end with `suffix`. Hidden folders
/// and the Kindle's ".sdr" sidecar folders are skipped.
pub fn find_files(alloc: std.mem.Allocator, root: []const u8, suffix: []const u8) ![][:0]u8 {
    var out: std.ArrayList([:0]u8) = .empty;
    try walk(alloc, root, suffix, 0, &out);
    return out.toOwnedSlice(alloc);
}

const Entry = struct { name: []const u8, is_dir: bool };
const Collect = struct {
    alloc: std.mem.Allocator,
    list: *std.ArrayList(Entry),
    failed: bool = false,
};

fn collect(c: *Collect, name: []const u8, is_dir: bool) void {
    const copy = c.alloc.dupe(u8, name) catch {
        c.failed = true;
        return;
    };
    c.list.append(c.alloc, .{ .name = copy, .is_dir = is_dir }) catch {
        c.failed = true;
    };
}

fn walk(alloc: std.mem.Allocator, dir: []const u8, suffix: []const u8, depth: u32, out: *std.ArrayList([:0]u8)) !void {
    if (depth > max_depth) return;
    const path = try alloc.dupeSentinel(u8, dir, 0);
    defer alloc.free(path);
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| alloc.free(e.name);
        entries.deinit(alloc);
    }
    var c = Collect{ .alloc = alloc, .list = &entries };
    sys.each_entry(path, &c, collect);
    if (c.failed) return error.OutOfMemory;
    for (entries.items) |e| {
        if (e.name[0] == '.') continue;
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, e.name });
        defer alloc.free(full);
        if (e.is_dir) {
            if (!std.mem.endsWith(u8, e.name, ".sdr")) try walk(alloc, full, suffix, depth + 1, out);
        } else if (std.ascii.endsWithIgnoreCase(e.name, suffix)) {
            try out.append(alloc, try alloc.dupeSentinel(u8, full, 0));
        }
    }
}
