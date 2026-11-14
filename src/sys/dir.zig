//! Finding files under a folder.
const std = @import("std");
const assert = std.debug.assert;
const sys = @import("calls.zig");

/// How deep below the root folder files are looked for: the root's folders are 1.
const depth_max = 6;

/// The most entries looked at in one search. A Kindle holds far fewer files.
const steps_max = 1 << 24;

/// Paths of the files under `root` whose names end with `suffix`. Hidden folders
/// and the Kindle's ".sdr" sidecar folders are skipped.
pub fn find_files(
    alloc: std.mem.Allocator,
    root: []const u8,
    suffix: []const u8,
) ![][:0]u8 {
    assert(root.len > 0);
    assert(suffix.len > 0);
    var out: std.ArrayList([:0]u8) = .empty;
    try walk(alloc, root, suffix, &out);
    return out.toOwnedSlice(alloc);
}

const Entry = struct { name: []const u8, is_dir: bool };
const Collect = struct {
    alloc: std.mem.Allocator,
    list: *std.ArrayList(Entry),
    failed: bool = false,
};

fn collect(context: *Collect, name: []const u8, is_dir: bool) void {
    // What calls.each_entry passes on: never an empty name, "." or ".."
    assert(name.len > 0);
    assert(!std.mem.eql(u8, name, "."));
    assert(!std.mem.eql(u8, name, ".."));
    const copy = context.alloc.dupe(u8, name) catch {
        context.failed = true;
        return;
    };
    context.list.append(context.alloc, .{ .name = copy, .is_dir = is_dir }) catch {
        context.failed = true;
    };
}

/// A folder being walked: its path, its entries, and the next entry to look at.
const Frame = struct {
    path: [:0]u8,
    entries: std.ArrayList(Entry) = .empty,
    entry_next: u32 = 0,
};

/// Walks the folders under `root` depth first, in the order each folder lists them,
/// with a stack of one frame per folder open, as deep as `depth_max`.
fn walk(
    alloc: std.mem.Allocator,
    root: []const u8,
    suffix: []const u8,
    out: *std.ArrayList([:0]u8),
) !void {
    var stack: [depth_max + 1]Frame = undefined;
    var stack_count: u32 = 0;
    defer for (stack[0..stack_count]) |*frame| walk_frame_free(alloc, frame);
    stack[0] = try walk_frame(alloc, root);
    stack_count = 1;
    for (0..steps_max) |_| {
        if (stack_count == 0) return;
        assert(stack_count <= stack.len);
        const top = &stack[stack_count - 1];
        if (top.entry_next == top.entries.items.len) {
            walk_frame_free(alloc, top);
            stack_count -= 1;
            continue;
        }
        assert(top.entry_next < top.entries.items.len);
        const entry = top.entries.items[top.entry_next];
        top.entry_next += 1;
        if (entry.name[0] == '.') continue;
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ top.path, entry.name });
        defer alloc.free(full);
        if (entry.is_dir) {
            // Its depth is the number of folders open above it
            if (std.mem.endsWith(u8, entry.name, ".sdr")) continue;
            if (stack_count > depth_max) continue;
            stack[stack_count] = try walk_frame(alloc, full);
            stack_count += 1;
        } else if (std.ascii.endsWithIgnoreCase(entry.name, suffix)) {
            try out.append(alloc, try alloc.dupeSentinel(u8, full, 0));
        }
    }
    return error.TooManyFiles;
}

/// Lists the folder at `dir`, for walking.
fn walk_frame(alloc: std.mem.Allocator, dir: []const u8) !Frame {
    assert(dir.len > 0);
    var frame = Frame{ .path = try alloc.dupeSentinel(u8, dir, 0) };
    var context = Collect{ .alloc = alloc, .list = &frame.entries };
    sys.each_entry(frame.path, &context, collect);
    if (context.failed) {
        walk_frame_free(alloc, &frame);
        return error.OutOfMemory;
    }
    assert(frame.entry_next == 0);
    return frame;
}

fn walk_frame_free(alloc: std.mem.Allocator, frame: *Frame) void {
    assert(frame.entry_next <= frame.entries.items.len);
    for (frame.entries.items) |entry| alloc.free(entry.name);
    frame.entries.deinit(alloc);
    alloc.free(frame.path);
}
