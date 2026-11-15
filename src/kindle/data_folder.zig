//! The app sits in /mnt/us/noface, which an update replaces whole. Settings, reading
//! positions, stats, notes, the battery log and the dictionaries sit apart, in
//! /mnt/us/noface-data, which no update touches. Installs from before the split kept
//! both in /mnt/us/noface: what isn't the app is moved across, each time the launcher
//! starts and before it starts noface, all of it in one run however many files there
//! are, so noface never writes a file in noface-data before the old one is moved. The
//! first time it goes through a temporary folder, renamed when done, so a run cut short
//! finishes next time.
//!
//! When noface-data already has a name being moved (noface-data made by hand for a
//! dictionary, or an older launcher that moved only part of the folder before noface
//! wrote fresh files), the one in noface-data stays, as what noface has read and written
//! since, and the old one is kept beside it in noface-data/pre-split, and logged:
//! nothing is left behind in the app folder for an update to delete.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const calls = @import("../sys/calls.zig");
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");
const process = @import("../sys/process.zig");
const state = @import("../sys/state.zig");

const failed = os.failed;

/// The most names gathered from the app folder at once: it holds a dozen, an old install
/// a few hundred. More are moved a batch at a time.
const names_max = 512;
/// The most batches in one run: far more files than any install has ever had.
const batches_max = 256;
/// The longest name moved; longer ones stay where they are.
const name_bytes_max = 255;
/// The folder in noface-data that keeps an old file whose name noface-data already had.
const pre_split = "pre-split";
/// The longest folder path handled: the data folder, its moving one and pre-split.
const dir_bytes_max = 128;
/// A path in the app folder, the data folder, the moving one or pre-split, with a name
/// of the longest kind.
const path_bytes_max = dir_bytes_max + 1 + pre_split.len + 1 + name_bytes_max + 1;

comptime {
    assert(paths.app_dir.len < dir_bytes_max);
    assert(paths.data_dir.len + ".moving".len < dir_bytes_max);
    assert(names_max * batches_max >= 100_000);
}

/// The names in the app folder still to move, gathered before any is moved, as moving
/// them changes the listing. A folder with more than fit is gathered again once these
/// have moved.
const Names = struct {
    bytes: [names_max][name_bytes_max]u8 = undefined,
    lengths: [names_max]u8 = undefined,
    count: u32 = 0,
    /// Whether a name to move was left out for want of room.
    full: bool = false,

    fn add(names: *Names, name: []const u8, is_dir: bool) void {
        _ = is_dir; // Folders are moved as files are
        assert(name.len > 0);
        // As the shell's "$APP"/.[!.]* had it: ".." and names starting so stay
        if (std.mem.startsWith(u8, name, "..")) return;
        if (name.len > name_bytes_max or is_app(name)) return;
        if (names.count == names_max) {
            names.full = true;
            return;
        }
        @memcpy(names.bytes[names.count][0..name.len], name);
        names.lengths[names.count] = @intCast(name.len);
        names.count += 1;
        assert(names.count <= names_max);
    }

    fn get(names: *const Names, index: u32) []const u8 {
        assert(index < names.count);
        assert(names.lengths[index] > 0);
        return names.bytes[index][0..names.lengths[index]];
    }
};

/// Whether a name in the app folder is part of the app, or the install's log, which
/// stay. Everything else is the reader's.
pub fn is_app(name: []const u8) bool {
    assert(name.len > 0);
    assert(std.mem.indexOfScalar(u8, name, '/') == null); // A name, not a path
    const app_names = [_][]const u8{
        "noface",                "noface.new", "jxr2pgm",                "selftest",
        "noface-autostart.conf", "LICENSE.md", "THIRD_PARTY_NOTICES.md", "VERSION",
        "kpm",                   "launch.log",
    };
    for (app_names) |app_name| {
        if (std.mem.eql(u8, name, app_name)) return true;
    }
    // The launcher, and the scripts of older versions
    if (std.mem.startsWith(u8, name, "noface-")) return true;
    if (std.mem.endsWith(u8, name, ".sh")) return true;
    return false;
}

/// Moves what isn't the app out of the app folder, into the data folder.
pub fn migrate() void {
    const done = migrate_between(paths.app_dir, paths.data_dir);
    const data = paths.data_dir;
    if (done.moved > 0) std.debug.print("data: moved {d} to {s}\n", .{ done.moved, data });
    if (done.aside > 0) {
        const format = "data: {d} were in {s} already: the older ones are in {s}/{s}\n";
        std.debug.print(format, .{ done.aside, data, data, pre_split });
    }
}

/// What a run moved: `aside` of the `moved` went to pre-split, the name being taken.
const Moved = struct { moved: u32 = 0, aside: u32 = 0 };

/// Moves what isn't the app out of `app_dir` into `data_dir`, a batch of names at a
/// time until none is left.
fn migrate_between(app_dir: [:0]const u8, data_dir: [:0]const u8) Moved {
    assert(app_dir[0] == '/');
    assert(data_dir[0] == '/');
    assert(app_dir.len < dir_bytes_max);
    assert(data_dir.len + ".moving".len < dir_bytes_max);
    var moving_buffer: [dir_bytes_max]u8 = undefined;
    // Fits, as asserted above
    const moving_dir = std.fmt.bufPrintSentinel(&moving_buffer, "{s}.moving", .{data_dir}, 0) catch
        return .{};
    const fresh = !file.exists(data_dir);
    // There already, from a run cut short: then it's carried on with
    if (fresh) _ = calls.mkdir(moving_dir, 0o755);
    const dirs: Dirs = .{ .app = app_dir, .target = if (fresh) moving_dir else data_dir };
    var done: Moved = .{};
    var names: Names = .{};
    for (0..batches_max) |_| {
        names = .{};
        calls.each_entry(app_dir, &names, Names.add);
        var moved_now: u32 = 0;
        for (0..names.count) |index| {
            const outcome = move(names.get(@intCast(index)), dirs);
            if (outcome != .stayed) moved_now += 1;
            if (outcome == .moved_aside) done.aside += 1;
        }
        done.moved += moved_now;
        // Every name gathered, or none of a full batch could move: nothing more to do
        if (!names.full or moved_now == 0) break;
    } else {
        std.debug.print("data: stopped after {d}, some left in {s}\n", .{ done.moved, app_dir });
    }
    if (fresh) {
        if (failed(calls.rename(moving_dir, data_dir))) {
            std.debug.print("data: couldn't make {s}\n", .{data_dir});
        }
    }
    assert(done.moved <= names_max * batches_max);
    assert(done.aside <= done.moved);
    return done;
}

/// Where a name is moved from and to.
const Dirs = struct { app: []const u8, target: []const u8 };

/// Where `move` put a name.
const Outcome = enum { moved, moved_aside, stayed };

/// Moves `name` from the app folder into the target folder; when the target already
/// has that name, into its pre-split folder instead.
fn move(name: []const u8, dirs: Dirs) Outcome {
    assert(name.len > 0);
    assert(name.len <= name_bytes_max);
    assert(dirs.app.len < dir_bytes_max);
    assert(dirs.target.len < dir_bytes_max);
    var source_buffer: [path_bytes_max]u8 = undefined;
    var target_buffer: [path_bytes_max]u8 = undefined;
    // Each fits: the folders and the name are bounded, and path_bytes_max sums them
    const source = std.fmt.bufPrintSentinel(&source_buffer, "{s}/{s}", .{ dirs.app, name }, 0) catch
        return .stayed;
    const into = .{ dirs.target, name };
    var target = std.fmt.bufPrintSentinel(&target_buffer, "{s}/{s}", into, 0) catch
        return .stayed;
    const taken = file.exists(target);
    if (taken) {
        const aside_format = "{s}/" ++ pre_split;
        const at = .{dirs.target};
        const aside = std.fmt.bufPrintSentinel(&target_buffer, aside_format, at, 0) catch
            return .stayed;
        _ = calls.mkdir(aside, 0o755); // There already: then it's used
        const args = .{ dirs.target, name };
        target = std.fmt.bufPrintSentinel(&target_buffer, aside_format ++ "/{s}", args, 0) catch
            return .stayed;
        if (file.exists(target)) {
            const twice = "data: kept {s} in the app folder: {s} has it twice\n";
            std.debug.print(twice, .{ name, dirs.target });
            return .stayed;
        }
    }
    assert(std.mem.endsWith(u8, source, name));
    assert(std.mem.endsWith(u8, target, name));
    if (failed(calls.rename(source, target))) {
        std.debug.print("data: couldn't move {s}\n", .{name});
        return .stayed;
    }
    return if (taken) .moved_aside else .moved;
}

test "the app's own files stay, the reader's move" {
    try std.testing.expect(is_app("noface"));
    try std.testing.expect(is_app("noface-launch"));
    try std.testing.expect(is_app("noface-autostart.conf"));
    try std.testing.expect(is_app("data.sh"));
    try std.testing.expect(is_app("kpm"));
    try std.testing.expect(is_app("launch.log"));
    try std.testing.expect(!is_app("settings"));
    try std.testing.expect(!is_app("dict-en"));
    try std.testing.expect(!is_app("noface.log"));
    try std.testing.expect(!is_app(".positions"));
}

/// Writes `text` as a new file at `path`, for the test.
fn write_file(path: [:0]const u8, text: []const u8) !void {
    assert(path[0] == '/');
    assert(text.len > 0);
    const rc = calls.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (failed(rc)) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    defer _ = calls.close(fd);
    if (calls.write(fd, text.ptr, text.len) != text.len) return error.CantWrite;
}

test "an old install's thousand files all move in one run, none lost to a newer one" {
    var buffer: [3][96]u8 = undefined;
    const pid = calls.getpid();
    const root = try std.fmt.bufPrintSentinel(&buffer[0], "/tmp/noface-migrate-{d}", .{pid}, 0);
    const app = try std.fmt.bufPrintSentinel(&buffer[1], "{s}/noface", .{root}, 0);
    const data = try std.fmt.bufPrintSentinel(&buffer[2], "{s}/noface-data", .{root}, 0);
    try std.testing.expect(!failed(calls.mkdir(root, 0o755)));
    defer {
        var out: [64]u8 = undefined;
        // The test's own folder under /tmp, named for this process
        _ = process.run(&.{ "/bin/rm", "-rf", root }, &out);
    }
    try std.testing.expect(!failed(calls.mkdir(app, 0o755)));
    try std.testing.expect(!failed(calls.mkdir(data, 0o755)));
    var path: [160:0]u8 = undefined;
    const files_count = 1000;
    for (0..files_count) |index| {
        const name = try std.fmt.bufPrintSentinel(&path, "{s}/state-{d}", .{ app, index }, 0);
        try write_file(name, "old");
    }
    const launcher = try std.fmt.bufPrintSentinel(&path, "{s}/noface-launch", .{app}, 0);
    try write_file(launcher, "app");
    // A fresh one noface wrote since an older launcher's partial move
    try write_file(try std.fmt.bufPrintSentinel(&path, "{s}/state-999", .{data}, 0), "new");
    const done = migrate_between(app, data);
    try std.testing.expectEqual(@as(u32, files_count), done.moved);
    try std.testing.expectEqual(@as(u32, 1), done.aside);
    for (0..files_count) |index| {
        const moved = try std.fmt.bufPrintSentinel(&path, "{s}/state-{d}", .{ data, index }, 0);
        try std.testing.expect(file.exists(moved));
        const left = try std.fmt.bufPrintSentinel(&path, "{s}/state-{d}", .{ app, index }, 0);
        try std.testing.expect(!file.exists(left));
    }
    const app_kept = try std.fmt.bufPrintSentinel(&path, "{s}/noface-launch", .{app}, 0);
    try std.testing.expect(file.exists(app_kept)); // The app's own stay
    // The newer one keeps its name; the old one is kept beside it, not left behind
    var said: [8]u8 = undefined;
    const kept = try std.fmt.bufPrintSentinel(&path, "{s}/state-999", .{data}, 0);
    try std.testing.expectEqualStrings("new", state.read_small(kept, &said));
    const old = try std.fmt.bufPrintSentinel(&path, "{s}/pre-split/state-999", .{data}, 0);
    try std.testing.expectEqualStrings("old", state.read_small(old, &said));
}
