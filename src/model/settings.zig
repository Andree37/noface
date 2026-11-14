//! The reader's chosen settings: text size, spacing, margins, typeface and toggles,
//! and how they're saved.
const std = @import("std");
const check = @import("../base/check.zig");

/// The Kindle's typefaces, by name. kindle/fonts.zig has their files, in the same order.
pub const builtin_families = [_][]const u8{ "Ember", "Bookerly", "Baskerville", "Serif" };
/// The reader's own typefaces, from the Kindle's fonts folder, come after them.
pub const max_own = 2;
pub const max_families = builtin_families.len + max_own;

var family_storage: [max_families][]const u8 = builtin_families ++ @as([max_own][]const u8, @splat(""));
/// The typefaces offered: the Kindle's, then any of the reader's own found at start.
pub var families: []const []const u8 = family_storage[0..builtin_families.len];

/// Offers one of the reader's own typefaces. False when there's no room or the name is taken.
pub fn add_family(name: []const u8) bool {
    if (families.len == max_families or name.len == 0 or family_named(name) != null) return false;
    family_storage[families.len] = name;
    families = family_storage[0 .. families.len + 1];
    return true;
}

/// Back to the Kindle's typefaces only (for tests).
pub fn reset_families() void {
    families = family_storage[0..builtin_families.len];
}

pub const sizes = [_]f32{ 36, 40, 46, 52, 58, 66 };

pub const spacings = [_]f32{ 1.2, 1.35, 1.5, 1.7 };

pub const margins = [_]i32{ 60, 100, 150, 210 };

/// Settings that don't move where pages break. Every other one does: the saved page
/// breaks are keyed by all the rest (screens/reader/page_store.zig), so a new setting
/// counts unless it's added here. `font` is keyed by its name, as positions can shift.
pub const not_layout = [_][]const u8{ "font", "clock", "refresh", "time_left", "autostart", "offer_dictionary", "lock_picture" };

/// Whether a field of Settings changes where pages break.
pub fn moves_breaks(comptime field: []const u8) bool {
    inline for (not_layout) |name| {
        if (comptime std.mem.eql(u8, name, field)) return false;
    }
    return true;
}

pub const Settings = struct {
    size: usize = 2,
    spacing: usize = 1,
    font: usize = 0,
    margin: usize = 1,
    bold: bool = false,
    left_align: bool = false,
    clock: bool = true,
    refresh: bool = false,
    time_left: bool = true,
    autostart: bool = false, // Open noface when the Kindle starts: device/autostart.sh reads it
    bold_starts: bool = false, // The first half of each word's letters in bold
    offer_dictionary: bool = true, // Ask to download a missing dictionary; "Not now" stops it
    lock_picture: bool = false, // The reader's own picture when locked, instead of the book's cover

    pub fn px(s: Settings) f32 {
        s.check_steps();
        return sizes[s.size];
    }

    pub fn line_height(s: Settings) i32 {
        s.check_steps();
        return @intFromFloat(sizes[s.size] * spacings[s.spacing]);
    }

    /// Parsing clamps every value, so an index out of range is a bug of ours.
    fn check_steps(s: Settings) void {
        check.that(s.size < sizes.len and s.spacing < spacings.len and s.margin < margins.len and s.font < max_families, "settings are within their steps");
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
    // Every setting is saved, so a new one can't be forgotten here
    for (@typeInfo(Settings).@"struct".field_names) |field| {
        for (saved) |f| {
            if (std.mem.eql(u8, f.field, field)) break;
        } else @compileError("settings: say how \"" ++ field ++ "\" is saved, in `saved`");
    }
}

/// How many steps a setting chosen from a list has.
fn steps_of(comptime field: []const u8) usize {
    if (comptime std.mem.eql(u8, field, "size")) return sizes.len;
    if (comptime std.mem.eql(u8, field, "spacing")) return spacings.len;
    if (comptime std.mem.eql(u8, field, "margin")) return margins.len;
    @compileError("settings: how many steps has " ++ field);
}

pub fn parse(content: []const u8) Settings {
    if (looks_old(content)) return from_old_file(content);
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
                    now.* = family_named(std.mem.trim(u8, line[value.ptr - line.ptr ..], " ")) orelse now.*;
                } else switch (@TypeOf(now.*)) {
                    bool => now.* = is_on(value, now.* != f.inverted) != f.inverted,
                    usize => now.* = step(value, steps_of(f.field), now.*),
                    else => @compileError("settings: how is " ++ f.field ++ " read"),
                }
            }
        }
    }
    return s;
}

pub fn format(buf: []u8, s: Settings) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    inline for (saved) |f| {
        const value = @field(s, f.field);
        if (comptime std.mem.eql(u8, f.field, "font")) {
            w.print(f.name ++ " {s}\n", .{families[value]}) catch return "";
        } else switch (@TypeOf(value)) {
            bool => w.print(f.name ++ " {s}\n", .{on_off(value != f.inverted)}) catch return "",
            usize => w.print(f.name ++ " {d}\n", .{value}) catch return "",
            else => @compileError("settings: how is " ++ f.field ++ " written"),
        }
    }
    return w.buffered();
}

fn step(value: []const u8, count: usize, fallback: usize) usize {
    const n = std.fmt.parseInt(usize, value, 10) catch return fallback;
    return if (n < count) n else fallback;
}

fn family_named(name: []const u8) ?usize {
    for (families, 0..) |f, i| {
        if (std.mem.eql(u8, f, name)) return i;
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

/// Earlier versions saved settings as numbers in the reading-position file's shape:
/// "a b c d". They're read once, then saved again in the format above.
fn looks_old(content: []const u8) bool {
    const first = std.mem.trimStart(u8, content, " \n");
    return first.len > 0 and std.ascii.isDigit(first[0]);
}

fn from_old_file(content: []const u8) Settings {
    var numbers: [4]usize = @splat(0);
    var words = std.mem.tokenizeAny(u8, content, " \n");
    for (&numbers) |*n| n.* = std.fmt.parseInt(usize, words.next() orelse break, 10) catch 0;
    const a = numbers[0];
    const b = numbers[1];
    const version = numbers[3];
    if (version == 0) return .{};
    if (version != 2) {
        // First version: size, spacing, font index.
        return .{ .size = @min(a, sizes.len - 1), .spacing = @min(b, spacings.len - 1), .font = @min(numbers[2], families.len - 1) };
    }
    // Second version: size, spacing, font and margin in 4 bits each, toggles as bits.
    return .{
        .size = @min(a & 15, sizes.len - 1),
        .spacing = @min((a >> 4) & 15, spacings.len - 1),
        .font = @min((a >> 8) & 15, families.len - 1),
        .margin = @min((a >> 12) & 15, margins.len - 1),
        .bold = b & 1 != 0,
        .left_align = b & 2 != 0,
        .clock = b & 4 == 0,
        .refresh = b & 8 != 0,
        .time_left = b & 16 == 0,
    };
}

test "settings survive being saved" {
    var buf: [256]u8 = undefined;
    const s = Settings{ .size = 4, .spacing = 3, .font = 2, .margin = 3, .bold = true, .left_align = true, .clock = false, .refresh = true, .time_left = false, .autostart = true, .lock_picture = true, .bold_starts = true, .offer_dictionary = false };
    try std.testing.expectEqual(s, parse(format(&buf, s)));
    try std.testing.expectEqual(Settings{}, parse(format(&buf, .{})));
    try std.testing.expect(std.mem.indexOf(u8, format(&buf, s), "font Baskerville\n") != null);
}

test "bad or unknown lines change nothing" {
    const s = parse("size 99\nfont Comic\nbold maybe\ncolour red\nspacing 2\n");
    try std.testing.expectEqual(Settings{ .spacing = 2 }, s);
}

test "settings saved by older versions still load" {
    const first = parse("3 2 1 1\n");
    try std.testing.expectEqual(@as(usize, 3), first.size);
    try std.testing.expectEqual(@as(usize, 2), first.spacing);
    try std.testing.expectEqual(@as(usize, 1), first.font);
    try std.testing.expect(first.clock);
    // The second version, as on the device today: size 3, spacing 1, no flags.
    const second = parse("19 0 0 2\n");
    try std.testing.expectEqual(@as(usize, 3), second.size);
    try std.testing.expectEqual(@as(usize, 1), second.spacing);
    try std.testing.expectEqual(@as(usize, 0), second.margin);
    try std.testing.expect(second.clock and second.time_left);
}

test "defaults match the original reader" {
    const s = Settings{};
    try std.testing.expectEqual(@as(f32, 46), s.px());
    try std.testing.expectEqual(@as(i32, 62), s.line_height());
}

test "the reader's own typefaces are offered after the Kindle's, by name" {
    defer reset_families();
    try std.testing.expect(add_family("Open Sans"));
    try std.testing.expect(!add_family("Bookerly")); // Taken
    const s = parse("font Open Sans\n");
    try std.testing.expectEqual(builtin_families.len, s.font);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(s.font, parse(format(&buf, s)).font);
    reset_families();
    try std.testing.expectEqual(@as(usize, 0), parse("font Open Sans\n").font); // Removed since: the default
}

test "every name kept out of the page-break key is a setting" {
    inline for (not_layout) |name| try std.testing.expect(@hasField(Settings, name));
    try std.testing.expect(moves_breaks("size") and moves_breaks("bold_starts") and !moves_breaks("clock"));
}
