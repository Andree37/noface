//! Finding files under a folder.
const std = @import("std");
const assert = std.debug.assert;
const sys = @import("calls.zig");
const file = @import("file.zig");
const os = @import("os.zig");
const process = @import("process.zig");

/// How deep below the root folders are walked: as deep as a path can go, each folder
/// adding at least "/x". A folder past it couldn't be opened, so none is missed.
const depth_max: u32 = file.path_bytes_max / 2;

/// The most folders looked at in one walk (each listing at most `calls.each_entry`'s
/// names): a Kindle holds far fewer. A walk that reaches it stops there, and says so.
const steps_max: u32 = 1 << 24;

/// What a walk found, and whether it stopped short of the end: a folder that couldn't
/// be listed for want of memory, or past `steps_max` names.
pub const Walked = struct { files: u32 = 0, cut_short: bool = false };

/// Calls `each(context, path)` for every file under `root` whose name ends with `suffix`
/// (ignoring case), as it's found. Hidden folders and the Kindle's ".sdr" sidecar
/// folders are skipped. `alloc` holds only the folders on the way down and the names of
/// those still to walk beside them, never the files.
pub fn walk(
    alloc: std.mem.Allocator,
    root: []const u8,
    suffix: []const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), [:0]const u8) void,
) !Walked {
    assert(root.len > 0);
    assert(suffix.len > 0);
    var walked: Walked = .{};
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |*frame| frame.free(alloc);
        stack.deinit(alloc);
    }
    try stack.append(alloc, try Frame.open(alloc, root, suffix, &walked, context, each));
    for (0..steps_max) |_| {
        const top = &stack.items[stack.items.len - 1];
        if (top.folder_next == top.folders.items.len) {
            top.free(alloc);
            stack.items.len -= 1;
            if (stack.items.len == 0) return walked;
            continue;
        }
        const name = top.folders.items[top.folder_next];
        top.folder_next += 1;
        var path_buffer: [file.path_bytes_max]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ top.path, name }) catch
            continue; // Longer than Linux opens: it can't hold a book either
        assert(stack.items.len <= depth_max); // Each level adds to a path that fits
        const frame = Frame.open(alloc, path, suffix, &walked, context, each) catch {
            walked.cut_short = true;
            continue;
        };
        stack.append(alloc, frame) catch {
            var dropped = frame;
            dropped.free(alloc);
            walked.cut_short = true;
        };
    }
    walked.cut_short = true;
    return walked;
}

/// The paths of the files under `root` whose names end with `suffix`, in `alloc`.
pub fn find_files(alloc: std.mem.Allocator, root: []const u8, suffix: []const u8) ![][:0]u8 {
    assert(root.len > 0);
    assert(suffix.len > 0);
    var found: Found = .{ .alloc = alloc };
    errdefer {
        for (found.list.items) |path| alloc.free(path);
        found.list.deinit(alloc);
    }
    const walked = try walk(alloc, root, suffix, &found, Found.add);
    if (found.failed) return error.OutOfMemory;
    // What was found is listed; that it isn't everything is said
    if (walked.cut_short) std.debug.print("walk: {s} only partly listed\n", .{root});
    assert(found.list.items.len == walked.files);
    return found.list.toOwnedSlice(alloc);
}

const Found = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList([:0]u8) = .empty,
    failed: bool = false,

    fn add(found: *Found, path: [:0]const u8) void {
        assert(path.len > 0);
        const copy = found.alloc.dupeSentinel(u8, path, 0) catch {
            found.failed = true;
            return;
        };
        found.list.append(found.alloc, copy) catch {
            found.alloc.free(copy);
            found.failed = true;
            return;
        };
        assert(found.list.items.len > 0);
    }
};

/// A folder being walked: its path, and the names of its folders still to walk. Its
/// files were passed on as it was listed.
const Frame = struct {
    path: [:0]u8,
    folders: std.ArrayList([]u8) = .empty,
    folder_next: u32 = 0,

    /// Lists the folder at `dir`, passing on its files and keeping its folders' names.
    fn open(
        alloc: std.mem.Allocator,
        dir: []const u8,
        suffix: []const u8,
        walked: *Walked,
        context: anytype,
        comptime each: fn (@TypeOf(context), [:0]const u8) void,
    ) !Frame {
        assert(dir.len > 0);
        assert(dir.len < file.path_bytes_max);
        var frame = Frame{ .path = try alloc.dupeSentinel(u8, dir, 0) };
        errdefer frame.free(alloc);
        const Listing = struct {
            alloc: std.mem.Allocator,
            frame: *Frame,
            suffix: []const u8,
            walked: *Walked,
            context: @TypeOf(context),
            failed: bool = false,

            fn entry(l: *@This(), name: []const u8, is_dir: bool) void {
                assert(name.len > 0); // What calls.each_entry passes on: never "." or ".."
                if (name[0] == '.') return;
                if (is_dir) {
                    if (std.mem.endsWith(u8, name, ".sdr")) return;
                    const copy = l.alloc.dupe(u8, name) catch {
                        l.failed = true;
                        return;
                    };
                    l.frame.folders.append(l.alloc, copy) catch {
                        l.alloc.free(copy);
                        l.failed = true;
                    };
                    return;
                }
                if (!std.ascii.endsWithIgnoreCase(name, l.suffix)) return;
                var path_buffer: [file.path_bytes_max]u8 = undefined;
                const format = "{s}/{s}";
                const path = std.fmt.bufPrintSentinel(&path_buffer, format, .{
                    l.frame.path,
                    name,
                }, 0) catch return; // Longer than Linux opens
                l.walked.files += 1;
                each(l.context, path);
            }
        };
        var listing: Listing = .{
            .alloc = alloc,
            .frame = &frame,
            .suffix = suffix,
            .walked = walked,
            .context = context,
        };
        // A folder not listed whole: what's past where it stopped isn't known to be gone
        if (!sys.each_entry(frame.path, &listing, Listing.entry)) walked.cut_short = true;
        if (listing.failed) return error.OutOfMemory;
        assert(frame.folder_next == 0);
        return frame;
    }

    fn free(frame: *Frame, alloc: std.mem.Allocator) void {
        assert(frame.folder_next <= frame.folders.items.len);
        for (frame.folders.items) |name| alloc.free(name);
        frame.folders.deinit(alloc);
        alloc.free(frame.path);
    }
};

test "files are found however deep their folders are, past the six levels once walked" {
    const linux = sys;
    var root_buffer: [64]u8 = undefined;
    const root = try std.fmt.bufPrintSentinel(&root_buffer, "/tmp/noface-dir-test-{d}", .{
        linux.getpid(),
    }, 0);
    var path_buffer: [file.path_bytes_max]u8 = undefined;
    @memcpy(path_buffer[0..root.len], root);
    var len: u32 = @intCast(root.len);
    path_buffer[len] = 0;
    _ = linux.mkdir(path_buffer[0..len :0], 0o755); // Ignored: the walk below says
    // Twenty folders deep, an EPUB at each level
    for (0..20) |level| {
        const name = try std.fmt.bufPrintSentinel(path_buffer[len..], "/b{d}.epub", .{level}, 0);
        const rc = linux.open(path_buffer[0 .. len + name.len :0], .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
        }, 0o644);
        try std.testing.expect(!os.failed(rc));
        _ = linux.close(@intCast(rc));
        const folder = try std.fmt.bufPrintSentinel(path_buffer[len..], "/d{d}", .{level}, 0);
        len += @intCast(folder.len);
        _ = linux.mkdir(path_buffer[0..len :0], 0o755);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try find_files(arena.allocator(), root, ".EPUB");
    try std.testing.expectEqual(@as(usize, 20), found.len);
    const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", root };
    var out: [64]u8 = undefined;
    _ = process.run(&argv, &out); // Ignored: only /tmp is left fuller
}
