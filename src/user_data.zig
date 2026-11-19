//! The reader's own files, kept across books and restarts: the settings, the reading
//! speed with the running pace, and the journal of what was read each day. Each is
//! read whole as noface starts and written whole when it changes; what's in memory
//! is the App's (app.zig).
const std = @import("std");
const assert = std.debug.assert;
const settings_model = @import("model/settings.zig");
const stats = @import("model/stats.zig");
const running_model = @import("model/running.zig");
const journal_model = @import("model/journal.zig");
const file = @import("sys/file.zig");
const calls = @import("sys/calls.zig");
const os = @import("sys/os.zig");
/// Lines for noface's log, which the tests keep quiet (main.zig's `std_options`).
const log = std.log.scoped(.user_data);

/// Where each of the reader's files is, in the data folder.
pub const Files = struct {
    settings: [*:0]const u8,
    speed: [*:0]const u8,
    journal: [*:0]const u8,
};

/// The reader's own data in memory, read from its files as noface starts, and the
/// files it's saved back to.
pub const UserData = struct {
    files: Files,
    settings: settings_model.Settings,
    speed: stats.Speed = .{}, // How fast this reader reads, across every book
    /// The running pace (model/running.zig), once running mode has been used: words a
    /// minute while reading on a treadmill, learned apart from `speed`.
    running_pace: ?f64 = null,
    journal: journal_model.Journal = .{}, // What was read each day, for the stats screen

    /// Everything saved in `files`, or what a new reader starts with where a file
    /// isn't there or doesn't read.
    pub fn load(files: Files) UserData {
        const speeds = load_speed(files.speed);
        const u: UserData = .{
            .files = files,
            .settings = load_settings(files.settings),
            .speed = speeds.speed,
            .running_pace = speeds.running_pace,
            .journal = load_journal(files.journal),
        };
        assert(u.journal.len <= u.journal.days.len);
        assert(u.speed.words >= 0);
        return u;
    }

    pub fn save_settings(u: *const UserData) void {
        save_settings_to(u.files.settings, u.settings);
    }

    /// The settings as last saved, for when the ones changed to can't be used.
    pub fn saved_settings(u: *const UserData) settings_model.Settings {
        return load_settings(u.files.settings);
    }

    /// Saves the reading speed and the running pace, after reading teaches them.
    pub fn save_speed(u: *const UserData) void {
        save_speed_to(u.files.speed, .{ .speed = u.speed, .running_pace = u.running_pace });
    }

    pub fn save_journal(u: *const UserData) void {
        save_journal_to(u.files.journal, &u.journal);
    }
};

/// Room for every setting with the longest typeface name a setting holds.
const settings_bytes_max = settings_model.family_bytes_max + 1024;

/// The speed file: the reader's speed, then the running pace once there is one.
const speed_bytes_max = 128;

pub fn load_settings(path: [*:0]const u8) settings_model.Settings {
    var buf: [settings_bytes_max]u8 = undefined;
    const settings = settings_model.parse(file.read_small(path, &buf));
    // Parsing clamps every value to its steps
    assert(settings.size < settings_model.sizes.len);
    assert(settings.font.len > 0);
    return settings;
}

pub fn save_settings_to(path: [*:0]const u8, s: settings_model.Settings) void {
    assert(path[0] != 0);
    var buf: [settings_bytes_max]u8 = undefined;
    const content = settings_model.format(&buf, s);
    // Every setting but the name is a word or a number: the name is the only long one
    assert(content.len > 0);
    file.write_small(path, content);
}

/// How fast the reader reads, and the running pace (model/running.zig) once running
/// mode has been used: words a minute on a treadmill, learned apart from `speed`.
pub const Speeds = struct { speed: stats.Speed, running_pace: ?f64 };

pub fn load_speed(path: [*:0]const u8) Speeds {
    var buf: [speed_bytes_max]u8 = undefined;
    const content = file.read_small(path, &buf);
    const speed = stats.parse(content);
    assert(speed.seconds >= 0); // Parsing starts over on anything else
    assert(speed.words >= 0);
    return .{ .speed = speed, .running_pace = running_model.parse_pace(content) };
}

pub fn save_speed_to(path: [*:0]const u8, speeds: Speeds) void {
    var buf: [speed_bytes_max / 2]u8 = undefined;
    var pace_buf: [speed_bytes_max / 2]u8 = undefined;
    assert(speeds.speed.seconds >= 0);
    assert(speeds.speed.words >= 0);
    const wpm = speeds.running_pace;
    const pace = if (wpm) |w| running_model.format_pace(&pace_buf, w) else "";
    file.write_parts(path, &.{ stats.format(&buf, speeds.speed), pace });
}

/// The journal saved at `path`: every day is in the file, which is mapped, never read
/// whole into memory; the journal keeps its latest days.
pub fn load_journal(path: [*:0]const u8) journal_model.Journal {
    const content = file.map(path) catch return .{};
    defer file.unmap(content);
    const journal = journal_model.parse(content);
    assert(journal.len <= journal.days.len); // The latest days, the rest in the file
    return journal;
}

/// Saves the journal: the days already in the file and older than memory holds, as
/// they are, then the days memory holds. Not saved when the file is there but can't be
/// read: written over, the days only it holds would be lost.
pub fn save_journal_to(path: [*:0]const u8, journal: *const journal_model.Journal) void {
    var buf: [journal_model.max_format_bytes]u8 = undefined;
    assert(journal.len <= journal.days.len);
    const content = journal_model.format(&buf, journal);
    assert(content.len >= journal_model.tag_line_bytes); // Sized for the longest journal
    const old: ?[]const u8 = file.map(path) catch |err| switch (err) {
        // No file yet, or nothing in it: nothing older to keep
        error.NotFound, error.EmptyFile => null,
        error.OpenFailed, error.SeekFailed, error.MmapFailed => {
            log.info("journal not saved: {s}", .{@errorName(err)});
            return;
        },
    };
    defer if (old) |o| file.unmap(o);
    const first_day: ?i32 = if (journal.len > 0) journal.days[0].day else null;
    // No file, or nothing in it, has no day to keep
    const older = journal_model.older_lines(old orelse "", first_day);
    const parts = [_][]const u8{
        content[0..journal_model.tag_line_bytes],
        older[0],
        older[1], // A line break, when the file's last line had none
        content[journal_model.tag_line_bytes..],
    };
    file.write_parts(path, &parts);
}

/// A path in /tmp for a test's file, "/tmp/noface-<name>-<pid>", none there yet.
fn test_path(buffer: []u8, name: []const u8) ![:0]u8 {
    const fields = .{ name, calls.getpid() };
    const path = try std.fmt.bufPrintSentinel(buffer, "/tmp/noface-{s}-{d}", fields, 0);
    _ = calls.unlink(path); // Ignored: only there after a run that stopped
    return path;
}

test "a journal that's there but can't be read is never written over" {
    var path_buffer: [64]u8 = undefined;
    const path = try test_path(&path_buffer, "journal-unreadable");
    defer _ = calls.unlink(path); // Ignored: only /tmp is left fuller
    var journal: journal_model.Journal = .{};
    journal.add(20_000, 600, 3);
    save_journal_to(path, &journal);
    try std.testing.expectEqual(1, load_journal(path).len);
    // A link to itself is there but can't be opened, as on a drive that fails a read
    _ = calls.unlink(path); // Ignored: checked by the link made in its place
    try std.testing.expect(!os.failed(calls.symlink(path, path)));
    journal.add(20_001, 600, 3);
    save_journal_to(path, &journal);
    // Still the link: nothing was renamed over it
    try std.testing.expectError(error.OpenFailed, file.map(path));
}

test "the longest typeface name a setting holds saves and comes back" {
    defer settings_model.reset_families();
    var path_buffer: [64]u8 = undefined;
    const path = try test_path(&path_buffer, "settings-test");
    defer _ = calls.unlink(path); // Ignored: only /tmp is left fuller
    // The longest a font file's name can make one: 255 characters, three bytes each
    const long: [255 * 3]u8 = comptime blk: {
        var name: [255 * 3]u8 = undefined;
        for (0..255) |i| name[i * 3 ..][0..3].* = "\u{6587}".*;
        break :blk name;
    };
    const kept = settings_model.builtin_families;
    settings_model.offer_families(&(kept ++ .{&long}));
    var s = settings_model.Settings{};
    s.font = settings_model.Family.of(&long).?;
    save_settings_to(path, s);
    try std.testing.expectEqual(s.font, load_settings(path).font);
    try std.testing.expect(s.family_index() + 1 == settings_model.families.len);
}

test "the speed and the running pace save and come back" {
    var path_buffer: [64]u8 = undefined;
    const path = try test_path(&path_buffer, "speed-test");
    defer _ = calls.unlink(path); // Ignored: only /tmp is left fuller
    // Values the files hold to their decimals exactly, at a speed and pace in bounds
    const speeds: Speeds = .{
        .speed = .{ .pages = 10, .words = 3000, .seconds = 600 },
        .running_pace = 150,
    };
    save_speed_to(path, speeds);
    const back = load_speed(path);
    try std.testing.expectEqual(speeds.speed.pages, back.speed.pages);
    try std.testing.expectEqual(speeds.speed.words, back.speed.words);
    try std.testing.expectEqual(speeds.speed.seconds, back.speed.seconds);
    try std.testing.expectEqual(speeds.running_pace, back.running_pace);
}
