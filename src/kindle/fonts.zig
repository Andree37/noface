//! Where the typefaces' files are: the Kindle's own in its system folder, and the
//! reader's in the fonts folder on the Kindle's drive (the one the Kindle itself reads
//! sideloaded fonts from). Noface's families map onto these by index.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const settings = @import("../model/settings.zig");
const file = @import("../sys/file.zig");
const process = @import("../sys/process.zig");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const input = @import("input.zig");

const font_dir = paths.kindle_fonts ++ "/";
pub const own_dir = paths.own_fonts;

/// Which of a family's four files: regular, bold, italic and bold italic, in that order,
/// so bit 0 is bold and bit 1 italic.
const Which = u2;

/// Each family's four files: regular, bold, italic and bold italic.
const faces = [_][4][*:0]const u8{
    .{
        font_dir ++ "Amazon-Ember-Regular.ttf",
        font_dir ++ "Amazon-Ember-Bold.ttf",
        font_dir ++ "Amazon-Ember-RegularItalic.ttf",
        font_dir ++ "Amazon-Ember-BoldItalic.ttf",
    },
    .{
        font_dir ++ "Bookerly-Regular.ttf",
        font_dir ++ "Bookerly-Bold.ttf",
        font_dir ++ "Bookerly-Italic.ttf",
        font_dir ++ "Bookerly-BoldItalic.ttf",
    },
    .{
        font_dir ++ "Baskerville-Regular.ttf",
        font_dir ++ "Baskerville-Bold.ttf",
        font_dir ++ "Baskerville-Italic.ttf",
        font_dir ++ "Baskerville-BoldItalic.ttf",
    },
    .{
        font_dir ++ "AmazonEmberSerif_Rg.ttf",
        font_dir ++ "AmazonEmberSerif_Bd.ttf",
        font_dir ++ "AmazonEmberSerif_RgIt.ttf",
        font_dir ++ "AmazonEmberSerif_BdIt.ttf",
    },
};

comptime {
    if (faces.len != settings.builtin_families.len) {
        @compileError("every family needs its font files");
    }
    assert(std.math.maxInt(Which) + 1 == faces[0].len);
}

/// The reader's own families' files, as many as `find_own` found, in the order they're
/// offered after the Kindle's.
var own: []const [4][:0]const u8 = &.{};

/// The file for a family's weight and slant.
pub fn path(family: u32, bold: bool, italic: bool) [*:0]const u8 {
    const which: Which = @as(Which, @intFromBool(bold)) | @as(Which, @intFromBool(italic)) << 1;
    if (family < faces.len) return faces[family][which];
    // Only a family `find_own` filled in is offered
    assert(family - faces.len < own.len);
    return own[family - faces.len][which];
}

/// What a font file's name says: its family, and which of the four it is (null for
/// weights noface doesn't use, like Light or Medium). "Literata-BoldItalic.ttf" is
/// Literata's bold italic; a name without a style, like "OpenDyslexic.otf", is regular.
pub const Named = struct { family: []const u8, which: ?Which };

/// The most words of a name looked at, and the longest style kept of them.
const name_words_max = 16;
const style_bytes_max = 48;
/// A style is at most three words: "Bold Italic" as "Bold-Italic", or "Extra Light Italic".
const style_words_max = 3;

pub fn named(file_name: []const u8) ?Named {
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return null;
    const extension = file_name[dot + 1 ..];
    const ttf = std.ascii.eqlIgnoreCase(extension, "ttf");
    if (!ttf and !std.ascii.eqlIgnoreCase(extension, "otf")) return null;
    const stem = file_name[0..dot];
    if (stem.len == 0 or stem[0] == '.') return null; // Hidden, like the Mac's "._" files
    // The style is the last word or words ("Bold", "Bold Italic", "Bold-Italic"):
    // try the longest run of trailing words that spells one
    var starts: [name_words_max]u32 = undefined;
    const count = named_words(stem, &starts);
    assert(count <= starts.len);
    var take: u32 = @min(count -| 1, style_words_max);
    while (take > 0) : (take -= 1) {
        const from = starts[count - take];
        assert(from < stem.len);
        var joined: [style_bytes_max]u8 = undefined;
        const style = named_join(stem[from..], &joined);
        // "Roman" is the regular after a dash ("Crimson-Roman"), but part of the name
        // after a space ("Times New Roman")
        const roman_word = take == 1 and std.ascii.eqlIgnoreCase(style, "Roman");
        const roman = roman_word and from > 0 and stem[from - 1] != ' ';
        if (if (roman) @as(??Which, 0) else style_of(style)) |which| {
            const family = std.mem.trimEnd(u8, stem[0..from], "-_ ");
            // The family is the start of the name, before its style
            assert(family.ptr == file_name.ptr);
            return if (family.len > 0) .{ .family = family, .which = which } else null;
        }
    }
    return .{ .family = stem, .which = 0 }; // No style in the name: the regular
}

/// Where each word of `stem` starts, as many as `starts` holds; returns how many.
fn named_words(stem: []const u8, starts: []u32) u32 {
    assert(starts.len > 0);
    assert(stem.len <= std.math.maxInt(u32));
    var count: u32 = 0;
    var index: u32 = 0;
    while (index < stem.len and count < starts.len) {
        while (index < stem.len and is_separator(stem[index])) index += 1;
        if (index == stem.len) break;
        starts[count] = index;
        count += 1;
        while (index < stem.len and !is_separator(stem[index])) index += 1;
    }
    assert(count <= starts.len);
    return count;
}

/// The words of `words` run together without their separators, as much as `joined` holds.
fn named_join(words: []const u8, joined: []u8) []const u8 {
    // Joined from the start of a word, so there's at least its first letter
    assert(words.len > 0);
    assert(!is_separator(words[0]));
    var length: u32 = 0;
    for (words) |c| {
        if (is_separator(c)) continue;
        if (length == joined.len) break;
        joined[length] = c;
        length += 1;
    }
    assert(length > 0);
    return joined[0..length];
}

fn is_separator(c: u8) bool {
    return c == '-' or c == '_' or c == ' ';
}

/// Which of the four a style word is; null inside for weights noface doesn't use,
/// null outside for a word that isn't a style at all.
fn style_of(word: []const u8) ??Which {
    assert(word.len > 0);
    const styles = [_]struct { []const u8, ?Which }{
        .{ "Regular", 0 },           .{ "Rg", 0 },                  .{ "Book", 0 },
        .{ "Bold", 1 },              .{ "Bd", 1 },                  .{ "Italic", 2 },
        .{ "It", 2 },                .{ "Oblique", 2 },             .{ "RegularItalic", 2 },
        .{ "BoldItalic", 3 },        .{ "BdIt", 3 },                .{ "BoldOblique", 3 },
        .{ "Thin", null },           .{ "ExtraLight", null },       .{ "Light", null },
        .{ "Medium", null },         .{ "SemiBold", null },         .{ "ExtraBold", null },
        .{ "Black", null },          .{ "LightItalic", null },      .{ "MediumItalic", null },
        .{ "SemiBoldItalic", null }, .{ "ExtraBoldItalic", null },  .{ "BlackItalic", null },
        .{ "ThinItalic", null },     .{ "ExtraLightItalic", null },
    };
    // Every style fits what `named` joins its words into
    comptime for (styles) |style| assert(style[0].len <= style_bytes_max);
    for (styles) |style| {
        if (std.ascii.eqlIgnoreCase(word, style[0])) return style[1];
    }
    return null;
}

/// One family's files as found, by which of the four each is.
const Found = struct { name: []const u8, files: [4]?[]const u8 = @splat(null) };

/// Groups file names into families, alphabetically, as many as there are.
pub fn group(alloc: std.mem.Allocator, names: []const []const u8) ![]Found {
    var out: std.ArrayList(Found) = .empty;
    for (names) |name| {
        const font = named(name) orelse continue;
        const which = font.which orelse continue;
        assert(font.family.len > 0);
        const at = for (out.items, 0..) |found, index| {
            if (std.mem.eql(u8, found.name, font.family)) break index;
        } else blk: {
            try out.append(alloc, .{ .name = try alloc.dupe(u8, font.family) });
            break :blk out.items.len - 1;
        };
        assert(at < out.items.len);
        const files = &out.items[at].files;
        if (files[which] == null) files[which] = try alloc.dupe(u8, name);
    }
    std.mem.sort(Found, out.items, {}, struct {
        fn less(_: void, x: Found, y: Found) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.less);
    assert(out.items.len <= names.len);
    return out.items;
}

/// A family's four files, any missing filled from the others: bold italic from bold,
/// italic or regular; the rest from regular, or whichever there is.
pub fn complete(files: [4]?[]const u8) [4][]const u8 {
    // `group` makes a family for a file it has, so there's always one
    assert(files[0] != null or files[1] != null or files[2] != null or files[3] != null);
    const any = files[0] orelse files[1] orelse files[2] orelse files[3].?;
    const regular = files[0] orelse any;
    if (files[0]) |given| assert(regular.ptr == given.ptr);
    return .{
        regular,
        files[1] orelse regular,
        files[2] orelse regular,
        files[3] orelse files[1] orelse files[2] orelse regular,
    };
}

/// Finds the reader's own typefaces in the fonts folder and offers them after the
/// Kindle's, every one there is. Files that `usable` turns down (not fonts noface can
/// set text in) are left out, and a name already offered is offered once. Called
/// once, before the settings are read, so a chosen one is found by name. The lists are
/// kept in `alloc`'s memory for good; with no room for another, the rest are left out.
pub fn find_own(alloc: std.mem.Allocator, usable_font: *const fn ([]const u8) bool) void {
    assert(own.len == 0);
    assert(settings.families.len == settings.builtin_families.len);
    const names = list_dir(alloc, own_dir);
    const found = group(alloc, names) catch return;
    var own_list: std.ArrayList([4][:0]const u8) = .empty;
    var offered: std.ArrayList([]const u8) = .empty;
    offered.appendSlice(alloc, &settings.builtin_families) catch return;
    // Each family's trials take up to seconds, before the loop that beats first turns: a
    // folder of many keeps the watchdog told noface is alive, as a library build does
    var beat_us = os.now_us();
    for (found) |family| {
        input.beat_when_due(paths.heartbeat, &beat_us);
        if (find_own_offered(offered.items, family.name)) continue;
        // Its name is what the settings keep: one longer than they hold can't be chosen
        if (family.name.len > settings.family_bytes_max) {
            std.debug.print("fonts: {s} left out, its name is too long\n", .{family.name});
            continue;
        }
        var full: [4][:0]const u8 = undefined;
        if (!find_own_usable(alloc, &family, usable_font, &full)) {
            std.debug.print("fonts: {s} can't be used\n", .{family.name});
            continue;
        }
        own_list.ensureUnusedCapacity(alloc, 1) catch break;
        offered.ensureUnusedCapacity(alloc, 1) catch break;
        own_list.appendAssumeCapacity(full);
        offered.appendAssumeCapacity(family.name);
        std.debug.print("fonts: added {s}\n", .{family.name});
    }
    assert(offered.items.len == settings.builtin_families.len + own_list.items.len);
    own = own_list.items;
    settings.offer_families(offered.items);
}

fn find_own_offered(offered: []const []const u8, name: []const u8) bool {
    assert(offered.len >= settings.builtin_families.len);
    assert(name.len > 0);
    for (offered) |other| {
        if (std.mem.eql(u8, other, name)) return true;
    }
    return false;
}

/// Whether every one of a family's four files opens, and sets text without crashing
/// the font library; their full paths go into `full`.
fn find_own_usable(
    alloc: std.mem.Allocator,
    family: *const Found,
    usable_font: *const fn ([]const u8) bool,
    full: *[4][:0]const u8,
) bool {
    assert(family.name.len > 0);
    const files = complete(family.files);
    for (full, files) |*full_path, name| {
        assert(name.len > 0);
        const format = "{s}/{s}";
        full_path.* = std.fmt.allocPrintSentinel(alloc, format, .{ own_dir, name }, 0) catch {
            return false;
        };
        const data = file.map(full_path.*) catch return false;
        // Mapped again when chosen: a folder of many fonts keeps none of them mapped
        defer file.unmap(data);
        // Tried in a child process: a damaged font can crash the font library
        const trial = FontTrial{ .data = data, .check = usable_font };
        if (!process.survives(trial, FontTrial.run)) return false;
    }
    return true;
}

const FontTrial = struct {
    data: []const u8,
    check: *const fn ([]const u8) bool,
    fn run(trial: FontTrial) bool {
        return trial.check(trial.data);
    }
};

/// The names of the files in `dir`, as many as there are room for in `alloc`.
fn list_dir(alloc: std.mem.Allocator, dir: [*:0]const u8) []const []const u8 {
    assert(dir[0] != 0);
    const Into = struct {
        alloc: std.mem.Allocator,
        out: std.ArrayList([]const u8) = .empty,
        fn add(into: *@This(), name: []const u8, is_dir: bool) void {
            // `each_entry` passes no empty names
            assert(name.len > 0);
            if (is_dir) return;
            into.out.ensureUnusedCapacity(into.alloc, 1) catch return;
            const kept = into.alloc.dupe(u8, name) catch return;
            into.out.appendAssumeCapacity(kept);
            assert(into.out.items.len > 0);
        }
    };
    var into = Into{ .alloc = alloc };
    linux.each_entry(dir, &into, Into.add);
    return into.out.items;
}

test "a font file's name says its family and style" {
    const literata = named("Literata-BoldItalic.ttf").?;
    try std.testing.expectEqualStrings("Literata", literata.family);
    try std.testing.expectEqual(@as(?Which, 3), literata.which);
    try std.testing.expectEqual(@as(?Which, 0), named("OpenDyslexic.otf").?.which);
    try std.testing.expectEqualStrings("OpenDyslexic", named("OpenDyslexic.otf").?.family);
    try std.testing.expectEqual(@as(?Which, null), named("Literata-Light.ttf").?.which);
    try std.testing.expectEqualStrings("Open Sans", named("Open Sans Bold.ttf").?.family);
    try std.testing.expect(named("Readme.txt") == null);
    try std.testing.expect(named("._Literata-Regular.ttf") == null);
    const atkinson = named("Atkinson-Hyperlegible.ttf").?;
    try std.testing.expectEqualStrings("Atkinson-Hyperlegible", atkinson.family);
}

test "styles of several words, and family names that end like a style" {
    const georgia = named("Georgia Bold Italic.ttf").?;
    try std.testing.expectEqualStrings("Georgia", georgia.family);
    try std.testing.expectEqual(@as(?Which, 3), georgia.which);
    try std.testing.expectEqual(@as(?Which, 1), named("Georgia Bold.ttf").?.which);
    try std.testing.expectEqualStrings("Times New Roman", named("Times New Roman.ttf").?.family);
    const times = named("Times New Roman Bold.ttf").?;
    try std.testing.expectEqualStrings("Times New Roman", times.family);
    try std.testing.expectEqual(@as(?Which, 1), times.which);
    try std.testing.expectEqual(@as(?Which, 3), named("Literata-Bold-Italic.otf").?.which);
    const crimson = named("Crimson-Roman.otf").?;
    try std.testing.expectEqualStrings("Crimson", crimson.family);
    try std.testing.expectEqual(@as(?Which, 0), crimson.which);
    try std.testing.expectEqualStrings("XCharter", named("XCharter_Roman.otf").?.family);
}

test "files group into families, and missing styles borrow from the others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const names = [_][]const u8{
        "Readme.txt",
        "Literata-Bold.ttf",
        "Literata-Light.ttf",
        "Literata-Regular.ttf",
        "Atkinson.otf",
    };
    const got = try group(arena.allocator(), &names);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("Atkinson", got[0].name);
    const literata = complete(got[1].files);
    try std.testing.expectEqualStrings("Literata-Regular.ttf", literata[0]);
    try std.testing.expectEqualStrings("Literata-Bold.ttf", literata[1]);
    try std.testing.expectEqualStrings("Literata-Regular.ttf", literata[2]);
    try std.testing.expectEqualStrings("Literata-Bold.ttf", literata[3]);
}

test "every family in the folder is grouped, however many" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var names: [300][]const u8 = undefined;
    for (&names, 0..) |*name, i| {
        const styles = [_][]const u8{ "Regular", "Bold", "Italic" };
        const style = styles[i % 3];
        name.* = try std.fmt.allocPrint(alloc, "Family{d:0>3}-{s}.ttf", .{ i / 3, style });
    }
    const got = try group(alloc, &names);
    try std.testing.expectEqual(@as(usize, 100), got.len);
    try std.testing.expectEqualStrings("Family000", got[0].name);
    try std.testing.expectEqualStrings("Family099", got[99].name);
    try std.testing.expectEqualStrings("Family099-Italic.ttf", got[99].files[2].?);
}
