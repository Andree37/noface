//! The reader's chosen settings: text size, spacing, margins, typeface and toggles,
//! and how they're saved.
const std = @import("std");
const assert = std.debug.assert;
const check = @import("../base/check.zig");

/// The Kindle's typefaces, by name. kindle/fonts.zig has their files, in the same order.
pub const builtin_families = [_][]const u8{ "Ember", "Bookerly", "Baskerville", "Serif" };
/// The typefaces offered: the Kindle's, then the reader's own from the Kindle's fonts
/// folder, as many as are there, found at start.
pub var families: []const []const u8 = &builtin_families;

/// Offers `all`: the Kindle's typefaces, then the reader's own, each name once. `all`
/// must stay as long as it's offered.
pub fn offer_families(all: []const []const u8) void {
    assert(all.len >= builtin_families.len);
    for (builtin_families, all[0..builtin_families.len]) |builtin, name| {
        assert(std.mem.eql(u8, builtin, name));
    }
    families = all;
    // Each name once, so a name picks one typeface
    for (all, 0..) |name, i| assert(family_named(name).? == i);
}

/// Back to the Kindle's typefaces only (for tests).
pub fn reset_families() void {
    families = &builtin_families;
    assert(families.len == builtin_families.len);
}

pub const sizes = [_]f32{ 36, 40, 46, 52, 58, 66 };

pub const spacings = [_]f32{ 1.2, 1.35, 1.5, 1.7 };

pub const margins = [_]i32{ 60, 100, 150, 210 };

/// Settings that don't move where pages break. Every other one does: the saved page
/// breaks are keyed by all the rest (screens/reader/page_store.zig), so a new setting
/// counts unless it's added here. `font` is keyed by its name, as positions can shift.
pub const not_layout = [_][]const u8{
    "font",
    "clock",
    "refresh",
    "time_left",
    "autostart",
    "offer_dictionary",
    "lock_picture",
};

/// Whether a field of Settings changes where pages break.
pub fn moves_breaks(comptime field: []const u8) bool {
    comptime assert(@hasField(Settings, field));
    inline for (not_layout) |name| {
        if (comptime std.mem.eql(u8, name, field)) return false;
    }
    return true;
}

pub const Settings = struct {
    size: u32 = 2,
    spacing: u32 = 1,
    font: u32 = 0,
    margin: u32 = 1,
    bold: bool = false,
    left_align: bool = false,
    clock: bool = true,
    refresh: bool = false,
    time_left: bool = true,
    /// Open noface when the Kindle starts: the launcher reads it (src/kindle/boot.zig).
    autostart: bool = false,
    bold_starts: bool = false, // The first half of each word's letters in bold
    /// Ask to download a missing dictionary; "Not now" stops it.
    offer_dictionary: bool = true,
    /// The reader's own picture when locked, instead of the book's cover.
    lock_picture: bool = false,

    pub fn px(s: Settings) f32 {
        s.check_steps();
        return sizes[s.size];
    }

    pub fn line_height(s: Settings) i32 {
        s.check_steps();
        const height: i32 = @intFromFloat(sizes[s.size] * spacings[s.spacing]);
        // Every spacing is more than single: a line is taller than its text.
        assert(height >= @as(i32, @intFromFloat(sizes[s.size])));
        return height;
    }

    /// Parsing clamps every value, so an index out of range is a bug of ours.
    fn check_steps(s: Settings) void {
        check.that(s.size < sizes.len, "the text size is one of its steps");
        check.that(s.spacing < spacings.len, "the spacing is one of its steps");
        check.that(s.margin < margins.len, "the margin is one of its steps");
        check.that(s.font < families.len, "the typeface is one on offer");
    }
};

/// The settings file: one "name value" per line, for example "font Bookerly" or
/// "bold off". Lines it doesn't know are skipped, and every value is checked.
/// How each setting is written in the settings file, in the file's order. `inverted`
/// keeps a name from before the setting's meaning flipped ("justify" is !left_align).
const Saved = struct { name: []const u8, field: []const u8, inverted: bool = false };
const saved = [_]Saved{
    .{ .name = "size", .field = "size" },
    .{ .name = "spacing", .field = "spacing" },
    .{ .name = "margins", .field = "margin" },
    .{ .name = "font", .field = "font" },
    .{ .name = "bold", .field = "bold" },
    .{ .name = "justify", .field = "left_align", .inverted = true },
    .{ .name = "clock", .field = "clock" },
    .{ .name = "refresh", .field = "refresh" },
    .{ .name = "time-left", .field = "time_left" },
    .{ .name = "autostart", .field = "autostart" },
    .{ .name = "lock-picture", .field = "lock_picture" },
    .{ .name = "bold-starts", .field = "bold_starts" },
    .{ .name = "offer-dictionary", .field = "offer_dictionary" },
};

comptime {
    // The defaults are steps on offer.
    const defaults: Settings = .{};
    assert(defaults.size < sizes.len);
    assert(defaults.spacing < spacings.len);
    assert(defaults.margin < margins.len);
    assert(defaults.font < builtin_families.len);
    for (spacings) |spacing| assert(spacing > 1);
}

comptime {
    // Every setting is saved, so a new one can't be forgotten here
    for (@typeInfo(Settings).@"struct".field_names) |field| {
        for (saved) |f| {
            if (std.mem.eql(u8, f.field, field)) break;
        } else @compileError("settings: say how \"" ++ field ++ "\" is saved, in `saved`");
    }
}

/// How many steps a setting chosen from a list has.
fn steps_of(comptime field: []const u8) u32 {
    if (comptime std.mem.eql(u8, field, "size")) return sizes.len;
    if (comptime std.mem.eql(u8, field, "spacing")) return spacings.len;
    if (comptime std.mem.eql(u8, field, "margin")) return margins.len;
    @compileError("settings: how many steps has " ++ field);
}

pub fn parse(content: []const u8) Settings {
    var s = Settings{};
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const name = words.next() orelse continue;
        const value = words.next() orelse continue;
        inline for (saved) |f| {
            if (std.mem.eql(u8, name, f.name)) {
                const now = &@field(s, f.field);
                if (comptime std.mem.eql(u8, f.field, "font")) {
                    // A name can have spaces ("Open Sans"): the rest of the line
                    const rest = std.mem.trim(u8, line[value.ptr - line.ptr ..], " ");
                    now.* = family_named(rest) orelse now.*;
                } else switch (@TypeOf(now.*)) {
                    bool => now.* = is_on(value, now.* != f.inverted) != f.inverted,
                    u32 => now.* = step(value, steps_of(f.field), now.*),
                    else => @compileError("settings: how is " ++ f.field ++ " read"),
                }
            }
        }
    }
    // Every value read is checked, so all are steps on offer (see `check_steps`).
    assert(s.size < sizes.len);
    assert(s.spacing < spacings.len);
    assert(s.margin < margins.len);
    assert(s.font < families.len);
    return s;
}

pub fn format(buf: []u8, s: Settings) []const u8 {
    assert(s.font < families.len); // Typefaces are only ever added, outside tests
    var w: std.Io.Writer = .fixed(buf);
    inline for (saved) |f| {
        const value = @field(s, f.field);
        if (comptime std.mem.eql(u8, f.field, "font")) {
            w.print(f.name ++ " {s}\n", .{families[value]}) catch return "";
        } else switch (@TypeOf(value)) {
            bool => w.print(f.name ++ " {s}\n", .{on_off(value != f.inverted)}) catch return "",
            u32 => w.print(f.name ++ " {d}\n", .{value}) catch return "",
            else => @compileError("settings: how is " ++ f.field ++ " written"),
        }
    }
    return w.buffered();
}

fn step(value: []const u8, count: u32, fallback: u32) u32 {
    assert(count > 0);
    const n = std.fmt.parseInt(u32, value, 10) catch return fallback;
    const chosen = if (n < count) n else fallback;
    if (chosen != fallback) assert(chosen < count);
    return chosen;
}

fn family_named(name: []const u8) ?u32 {
    assert(families.len >= builtin_families.len);
    for (families, 0..) |f, i| {
        if (std.mem.eql(u8, f, name)) return @intCast(i);
    }
    return null;
}

fn is_on(value: []const u8, fallback: bool) bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return fallback;
}

fn on_off(on: bool) []const u8 {
    return if (on) "on" else "off";
}

test "settings survive being saved" {
    var buf: [256]u8 = undefined;
    const s = Settings{
        .size = 4,
        .spacing = 3,
        .font = 2,
        .margin = 3,
        .bold = true,
        .left_align = true,
        .clock = false,
        .refresh = true,
        .time_left = false,
        .autostart = true,
        .lock_picture = true,
        .bold_starts = true,
        .offer_dictionary = false,
    };
    try std.testing.expectEqual(s, parse(format(&buf, s)));
    try std.testing.expectEqual(Settings{}, parse(format(&buf, .{})));
    try std.testing.expect(std.mem.indexOf(u8, format(&buf, s), "font Baskerville\n") != null);
}

test "bad or unknown lines change nothing" {
    const s = parse("size 99\nfont Comic\nbold maybe\ncolour red\nspacing 2\n");
    try std.testing.expectEqual(Settings{ .spacing = 2 }, s);
}

test "defaults match the original reader" {
    const s = Settings{};
    try std.testing.expectEqual(@as(f32, 46), s.px());
    try std.testing.expectEqual(@as(i32, 62), s.line_height());
}

test "the reader's own typefaces are offered after the Kindle's, by name" {
    defer reset_families();
    try std.testing.expect(family_named("Bookerly") != null);
    try std.testing.expect(family_named("Open Sans") == null);
    // Many more than the two there once was room for
    var all: [builtin_families.len + 40][]const u8 = undefined;
    var names: [40][8]u8 = undefined;
    @memcpy(all[0..builtin_families.len], &builtin_families);
    for (all[builtin_families.len..], &names, 0..) |*name, *buffer, i| {
        name.* = try std.fmt.bufPrint(buffer, "Own {d}", .{i});
    }
    all[all.len - 1] = "Open Sans";
    offer_families(&all);
    const s = parse("font Open Sans\n");
    try std.testing.expectEqual(all.len - 1, s.font);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(s.font, parse(format(&buf, s)).font);
    try std.testing.expectEqual(builtin_families.len + 7, parse("font Own 7\n").font);
    reset_families();
    // Removed since: the default
    try std.testing.expectEqual(@as(u32, 0), parse("font Open Sans\n").font);
}

test "every name kept out of the page-break key is a setting" {
    inline for (not_layout) |name| try std.testing.expect(@hasField(Settings, name));
    try std.testing.expect(moves_breaks("size"));
    try std.testing.expect(moves_breaks("bold_starts"));
    try std.testing.expect(!moves_breaks("clock"));
}
