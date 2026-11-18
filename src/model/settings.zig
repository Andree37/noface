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
    // Each name fits a setting, so whichever is chosen is kept whole
    for (all) |name| assert(name.len <= family_bytes_max);
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
/// counts unless it's added here.
pub const not_layout = [_][]const u8{
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

/// The longest typeface name a font file's name can give: 255 characters of up to
/// three bytes each, as a FAT folder holds them.
pub const family_bytes_max = 255 * 3;

/// A typeface, by its name: the setting keeps the name, so it means the same typeface
/// whatever fonts are found at a start, and one whose file is gone for a while is
/// chosen again when it's back.
pub const Family = struct {
    bytes: [family_bytes_max]u8 = @splat(0), // Past `len`, zeros: equal names, equal families
    len: u16 = 0,

    /// `text` as a family; null when it's longer than any font file's name gives.
    pub fn of(text: []const u8) ?Family {
        if (text.len == 0 or text.len > family_bytes_max) return null;
        var f: Family = .{ .len = @intCast(text.len) };
        @memcpy(f.bytes[0..text.len], text);
        assert(std.mem.eql(u8, f.name(), text));
        return f;
    }

    pub fn name(f: *const Family) []const u8 {
        assert(f.len > 0); // Every family is made by `of`, from a name
        return f.bytes[0..f.len];
    }

    /// Its place among the typefaces on offer, which is the one drawn; the first while
    /// its file is gone.
    pub fn index(f: *const Family) u32 {
        const found = family_named(f.name()) orelse 0;
        assert(found < families.len);
        return found;
    }
};

pub const Settings = struct {
    size: u32 = 2,
    spacing: u32 = 1,
    font: Family = Family.of(builtin_families[0]).?,
    margin: u32 = 1,
    bold: bool = false,
    left_align: bool = false,
    clock: bool = true,
    refresh: bool = false,
    time_left: bool = true,
    /// Open noface when the Kindle starts: the launcher reads it (src/kindle/boot.zig).
    autostart: bool = false,
    bold_starts: bool = false, // The first half of each word's letters in bold
    /// Words broken at their syllables to fill a line. Running mode turns it off: a
    /// word split across lines is hard to follow as the page bounces.
    hyphenate: bool = true,
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
        check.that(s.font.len > 0, "a typeface is named");
    }

    /// The chosen typeface's place among those on offer: see `Family.index`.
    pub fn family_index(s: *const Settings) u32 {
        return s.font.index();
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
    .{ .name = "hyphenate", .field = "hyphenate" },
    .{ .name = "offer-dictionary", .field = "offer_dictionary" },
};

comptime {
    // The defaults are steps on offer.
    const defaults: Settings = .{};
    assert(defaults.size < sizes.len);
    assert(defaults.spacing < spacings.len);
    assert(defaults.margin < margins.len);
    assert(std.mem.eql(u8, defaults.font.name(), builtin_families[0]));
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
    read_lines(content, "", false, &s);
    // Every value read is checked, so all are steps on offer (see `check_steps`).
    assert(s.size < sizes.len);
    assert(s.spacing < spacings.len);
    assert(s.margin < margins.len);
    assert(s.font.len > 0);
    return s;
}

/// Running mode's own settings (screens/reader/run.zig): the ones that lay the page
/// out, saved beside the others as "running-size 4" and so on. Running takes these
/// in place of the reader's own, which are left as they were for when it stops.
const running_prefix = "running-";

/// Running's settings before the reader has changed any: the reader's own, with text
/// big and bold enough to read from a treadmill's console as it bounces, wide line
/// spacing so the eye keeps its line, wide margins so each line is short and the eye's
/// jump back to the next one is too, and no justification, whose uneven gaps lose it.
pub fn running_default(own: Settings) Settings {
    var running = own;
    running.size = 4;
    running.spacing = 3;
    running.margin = 2;
    running.bold = true;
    running.left_align = true;
    running.hyphenate = false;
    assert(running.size < sizes.len);
    assert(running.spacing == spacings.len - 1); // The widest
    return running;
}

/// Running's settings from the settings file, over `running_default(own)`. Only the
/// settings that lay the page out are running's own; the rest are `own`'s.
pub fn parse_running(content: []const u8, own: Settings) Settings {
    var running = running_default(own);
    read_lines(content, running_prefix, true, &running);
    assert(running.size < sizes.len);
    assert(running.font.len > 0);
    return running;
}

/// Swaps the settings that lay the page out between `a` and `b`, the rest staying:
/// running mode taking its own, and giving the reader's back.
pub fn swap_layout(a: *Settings, b: *Settings) void {
    inline for (@typeInfo(Settings).@"struct".field_names) |field| {
        if (comptime moves_breaks(field)) {
            std.mem.swap(@TypeOf(@field(a.*, field)), &@field(a.*, field), &@field(b.*, field));
        }
    }
}

/// Reads "name value" lines whose name is `prefix` and a saved setting's, into `s`:
/// only the settings that lay the page out when `layout_only`.
fn read_lines(
    content: []const u8,
    prefix: []const u8,
    comptime layout_only: bool,
    s: *Settings,
) void {
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const prefixed = words.next() orelse continue;
        const value = words.next() orelse continue;
        if (!std.mem.startsWith(u8, prefixed, prefix)) continue;
        const name = prefixed[prefix.len..];
        inline for (saved) |f| {
            if (layout_only and comptime !moves_breaks(f.field)) {
                // Not running's own: left as the reader's
            } else if (std.mem.eql(u8, name, f.name)) {
                const now = &@field(s.*, f.field);
                if (comptime std.mem.eql(u8, f.field, "font")) {
                    // A name can have spaces ("Open Sans"): the rest of the line
                    const rest = std.mem.trim(u8, line[value.ptr - line.ptr ..], " ");
                    now.* = Family.of(rest) orelse now.*;
                } else switch (@TypeOf(now.*)) {
                    bool => now.* = is_on(value, now.* != f.inverted) != f.inverted,
                    u32 => now.* = step(value, steps_of(f.field), now.*),
                    else => @compileError("settings: how is " ++ f.field ++ " read"),
                }
            }
        }
    }
}

pub fn format(buf: []u8, s: Settings) []const u8 {
    assert(s.font.len > 0);
    var w: std.Io.Writer = .fixed(buf);
    write_lines(&w, "", false, s, null) catch return "";
    return w.buffered();
}

/// The reader's own settings, then running's (`parse_running`): only where the reader
/// changed them, so better defaults for running reach those who never did.
pub fn format_with_running(buf: []u8, own: Settings, running: Settings) []const u8 {
    assert(own.font.len > 0);
    assert(running.font.len > 0);
    var w: std.Io.Writer = .fixed(buf);
    write_lines(&w, "", false, own, null) catch return "";
    write_lines(&w, running_prefix, true, running, running_default(own)) catch return "";
    return w.buffered();
}

/// Writes `s` as "name value" lines, each name after `prefix`: only the settings that
/// lay the page out when `layout_only`, and only those that differ from `unless`.
fn write_lines(
    w: *std.Io.Writer,
    comptime prefix: []const u8,
    comptime layout_only: bool,
    s: Settings,
    unless: ?Settings,
) std.Io.Writer.Error!void {
    inline for (saved) |f| {
        const value = @field(s, f.field);
        const name = prefix ++ f.name;
        const as_default = if (unless) |d| std.meta.eql(value, @field(d, f.field)) else false;
        if (as_default) {
            // Read back as the default, so not written
        } else if (layout_only and comptime !moves_breaks(f.field)) {
            // Not running's own: saved as the reader's
        } else if (comptime std.mem.eql(u8, f.field, "font")) {
            try w.print(name ++ " {s}\n", .{value.name()});
        } else switch (@TypeOf(value)) {
            bool => try w.print(name ++ " {s}\n", .{on_off(value != f.inverted)}),
            u32 => try w.print(name ++ " {d}\n", .{value}),
            else => @compileError("settings: how is " ++ f.field ++ " written"),
        }
    }
}

fn step(value: []const u8, count: u32, fallback: u32) u32 {
    assert(count > 0);
    const n = std.fmt.parseInt(u32, value, 10) catch return fallback;
    const chosen = if (n < count) n else fallback;
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
        .font = Family.of("Baskerville").?,
        .margin = 3,
        .bold = true,
        .left_align = true,
        .clock = false,
        .refresh = true,
        .time_left = false,
        .autostart = true,
        .lock_picture = true,
        .bold_starts = true,
        .hyphenate = false,
        .offer_dictionary = false,
    };
    try std.testing.expectEqual(s, parse(format(&buf, s)));
    try std.testing.expectEqual(Settings{}, parse(format(&buf, .{})));
    try std.testing.expect(std.mem.indexOf(u8, format(&buf, s), "font Baskerville\n") != null);
}

test "running's settings are saved beside the reader's own, and swap with them" {
    var buf: [1024]u8 = undefined;
    const own = Settings{ .size = 1, .font = Family.of("Bookerly").?, .clock = false };
    var running = running_default(own);
    running.size = 5;
    const content = format_with_running(&buf, own, running);
    // The reader's own read as before, past running's lines
    try std.testing.expectEqual(own, parse(content));
    const read = parse_running(content, own);
    try std.testing.expectEqual(running, read);
    // Only what differs from running's defaults is written
    try std.testing.expect(std.mem.indexOf(u8, content, "running-size 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "running-spacing") == null);
    // A file from before running mode: running's defaults, over the reader's typeface
    const plain = parse_running(format(&buf, own), own);
    try std.testing.expectEqual(running_default(own), plain);
    try std.testing.expectEqualStrings("Bookerly", plain.font.name());
    // Swapped in, running lays the page out; the clock, not one of those, stays
    var active = own;
    var kept = read;
    kept.clock = true;
    swap_layout(&active, &kept);
    try std.testing.expectEqual(@as(u32, 5), active.size);
    try std.testing.expect(active.bold);
    try std.testing.expect(!active.clock);
    try std.testing.expectEqual(own.size, kept.size);
    swap_layout(&active, &kept);
    try std.testing.expectEqual(own, active);
}

test "bad or unknown lines change nothing; a typeface not on offer is kept by name" {
    const s = parse("size 99\nbold maybe\ncolour red\nspacing 2\n");
    try std.testing.expectEqual(Settings{ .spacing = 2 }, s);
    const comic = parse("font Comic\n");
    try std.testing.expectEqualStrings("Comic", comic.font.name());
    try std.testing.expectEqual(@as(u32, 0), comic.family_index()); // The first, meanwhile
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
    try std.testing.expectEqual(all.len - 1, s.family_index());
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(s.font, parse(format(&buf, s)).font);
    try std.testing.expectEqual(builtin_families.len + 7, parse("font Own 7\n").family_index());
    reset_families();
    // Its file gone since: the first typeface, and its name kept for when it's back
    try std.testing.expectEqual(@as(u32, 0), s.family_index());
    try std.testing.expectEqualStrings("Open Sans", parse(format(&buf, s)).font.name());
}

test "every name kept out of the page-break key is a setting" {
    inline for (not_layout) |name| try std.testing.expect(@hasField(Settings, name));
    try std.testing.expect(moves_breaks("size"));
    try std.testing.expect(moves_breaks("bold_starts"));
    try std.testing.expect(!moves_breaks("clock"));
}
