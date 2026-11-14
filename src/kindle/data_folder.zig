//! The app sits in /mnt/us/noface, which an update replaces whole. Settings, reading
//! positions, stats, notes, the battery log and the dictionaries sit apart, in
//! /mnt/us/noface-data, which no update touches. Installs from before the split kept
//! both in /mnt/us/noface: what isn't the app is moved across, each time the launcher
//! starts. The first time it goes through a temporary folder, renamed when done, so a
//! run cut short finishes next time; if noface-data already exists (made by hand for a
//! dictionary, say), anything old is moved in unless the same name is already there.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const calls = @import("../sys/calls.zig");
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");

const failed = os.failed;

/// The most names looked at in the app folder: it holds a dozen, an old install a few
/// dozen more.
const names_max = 512;
/// The longest name moved; longer ones stay where they are.
const name_bytes_max = 255;
const moving_dir = paths.data_dir ++ ".moving";
/// A path in the data folder or the moving one, with a name of the longest kind.
const path_bytes_max = moving_dir.len + 1 + name_bytes_max + 1;

/// The names in the app folder, gathered before any is moved, as moving them changes
/// the listing.
const Names = struct {
    bytes: [names_max][name_bytes_max]u8 = undefined,
    lengths: [names_max]u8 = undefined,
    count: u32 = 0,

    fn add(names: *Names, name: []const u8, is_dir: bool) void {
        _ = is_dir; // Folders are moved as files are
        assert(name.len > 0);
        if (names.count == names_max or name.len > name_bytes_max) return;
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
    var names: Names = .{};
    calls.each_entry(paths.app_dir, &names, Names.add);
    assert(names.count <= names_max);
    const fresh = !file.exists(paths.data_dir);
    // There already, from a run cut short: then it's carried on with
    if (fresh) _ = calls.mkdir(moving_dir, 0o755);
    const target_dir = if (fresh) moving_dir else paths.data_dir;
    var moved: u32 = 0;
    for (0..names.count) |index| {
        const name = names.get(@intCast(index));
        // As the shell's "$APP"/.[!.]* had it: ".." and names starting so stay
        if (std.mem.startsWith(u8, name, "..")) continue;
        if (is_app(name)) continue;
        if (move(name, target_dir, !fresh)) moved += 1;
    }
    if (fresh) {
        if (failed(calls.rename(moving_dir, paths.data_dir))) {
            std.debug.print("data: couldn't make {s}\n", .{paths.data_dir});
        }
    }
    if (moved > 0) std.debug.print("data: moved {d} to {s}\n", .{ moved, paths.data_dir });
    assert(moved <= names.count);
}

/// Moves `name` from the app folder into `target_dir`, unless `keep_existing` and
/// the target already has one. True when it moved.
fn move(name: []const u8, target_dir: []const u8, keep_existing: bool) bool {
    assert(name.len > 0);
    assert(target_dir[0] == '/');
    var source_buffer: [paths.app_dir.len + 1 + name_bytes_max + 1]u8 = undefined;
    var target_buffer: [path_bytes_max]u8 = undefined;
    const format = "{s}/{s}";
    const app_dir = paths.app_dir;
    const source = std.fmt.bufPrintSentinel(&source_buffer, format, .{ app_dir, name }, 0) catch
        return false;
    const target = std.fmt.bufPrintSentinel(&target_buffer, format, .{ target_dir, name }, 0) catch
        return false;
    assert(std.mem.endsWith(u8, source, name));
    assert(std.mem.endsWith(u8, target, name));
    if (keep_existing and file.exists(target)) return false;
    if (failed(calls.rename(source, target))) {
        std.debug.print("data: couldn't move {s}\n", .{name});
        return false;
    }
    return true;
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
