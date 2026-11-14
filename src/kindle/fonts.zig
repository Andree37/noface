//! Where the typefaces' files are: the Kindle's own in its system folder, and the
//! reader's in the fonts folder on the Kindle's drive (the one the Kindle itself reads
//! sideloaded fonts from). Noface's families map onto these by index.
const std = @import("std");
const paths = @import("paths.zig");
const settings = @import("../model/settings.zig");
const file = @import("../sys/file.zig");
const process = @import("../sys/process.zig");
const linux = @import("../sys/calls.zig");

const font_dir = "/usr/java/lib/fonts/";
pub const own_dir = paths.own_fonts;

/// Each family's four files: regular, bold, italic and bold italic.
const faces = [_][4][*:0]const u8{
    .{ font_dir ++ "Amazon-Ember-Regular.ttf", font_dir ++ "Amazon-Ember-Bold.ttf", font_dir ++ "Amazon-Ember-RegularItalic.ttf", font_dir ++ "Amazon-Ember-BoldItalic.ttf" },
    .{ font_dir ++ "Bookerly-Regular.ttf", font_dir ++ "Bookerly-Bold.ttf", font_dir ++ "Bookerly-Italic.ttf", font_dir ++ "Bookerly-BoldItalic.ttf" },
    .{ font_dir ++ "Baskerville-Regular.ttf", font_dir ++ "Baskerville-Bold.ttf", font_dir ++ "Baskerville-Italic.ttf", font_dir ++ "Baskerville-BoldItalic.ttf" },
    .{ font_dir ++ "AmazonEmberSerif_Rg.ttf", font_dir ++ "AmazonEmberSerif_Bd.ttf", font_dir ++ "AmazonEmberSerif_RgIt.ttf", font_dir ++ "AmazonEmberSerif_BdIt.ttf" },
};

comptime {
    if (faces.len != settings.builtin_families.len) @compileError("every family needs its font files");
}

/// The reader's own families' files, found by `find_own`.
var own: [settings.max_own][4][:0]const u8 = undefined;

/// The file for a family's weight and slant.
pub fn path(family: usize, bold: bool, italic: bool) [*:0]const u8 {
    const which = @as(usize, @intFromBool(bold)) | @as(usize, @intFromBool(italic)) << 1;
    if (family < faces.len) return faces[family][which];
    return own[family - faces.len][which];
}

/// What a font file's name says: its family, and which of the four it is (null for
/// weights noface doesn't use, like Light or Medium). "Literata-BoldItalic.ttf" is
/// Literata's bold italic; a name without a style, like "OpenDyslexic.otf", is regular.
pub const Named = struct { family: []const u8, which: ?usize };

pub fn named(file_name: []const u8) ?Named {
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return null;
    const ext = file_name[dot + 1 ..];
    if (!std.ascii.eqlIgnoreCase(ext, "ttf") and !std.ascii.eqlIgnoreCase(ext, "otf")) return null;
    const stem = file_name[0..dot];
    if (stem.len == 0 or stem[0] == '.') return null; // Hidden, like the Mac's "._" files
    // The style is the last word or words ("Bold", "Bold Italic", "Bold-Italic"):
    // try the longest run of trailing words that spells one
    var starts: [16]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < stem.len and n < starts.len) {
        while (i < stem.len and is_separator(stem[i])) i += 1;
        if (i == stem.len) break;
        starts[n] = i;
        n += 1;
        while (i < stem.len and !is_separator(stem[i])) i += 1;
    }
    var take: usize = @min(n -| 1, 3);
    while (take > 0) : (take -= 1) {
        const from = starts[n - take];
        var joined: [48]u8 = undefined;
        var len: usize = 0;
        for (stem[from..]) |c| {
            if (is_separator(c)) continue;
            if (len == joined.len) break;
            joined[len] = c;
            len += 1;
        }
        // "Roman" is the regular after a dash ("Crimson-Roman"), but part of the name
        // after a space ("Times New Roman")
        const roman = take == 1 and std.ascii.eqlIgnoreCase(joined[0..len], "Roman") and from > 0 and stem[from - 1] != ' ';
        if (if (roman) @as(??usize, 0) else style_of(joined[0..len])) |which| {
            const family = std.mem.trimEnd(u8, stem[0..from], "-_ ");
            return if (family.len > 0) .{ .family = family, .which = which } else null;
        }
    }
    return .{ .family = stem, .which = 0 }; // No style in the name: the regular
}

fn is_separator(c: u8) bool {
    return c == '-' or c == '_' or c == ' ';
}

/// Which of the four a style word is; null inside for weights noface doesn't use,
/// null outside for a word that isn't a style at all.
fn style_of(word: []const u8) ??usize {
    const styles = [_]struct { []const u8, ?usize }{
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
    for (styles) |st| {
        if (std.ascii.eqlIgnoreCase(word, st[0])) return st[1];
    }
    return null;
}

/// One family's files as found, by which of the four each is.
const Found = struct { name: []const u8, files: [4]?[]const u8 = @splat(null) };

/// Groups file names into families, alphabetically, the first `max` of them.
pub fn group(alloc: std.mem.Allocator, names: []const []const u8, out: []Found) ![]Found {
    var n: usize = 0;
    for (names) |name| {
        const f = named(name) orelse continue;
        const which = f.which orelse continue;
        const at = for (out[0..n], 0..) |g, i| {
            if (std.mem.eql(u8, g.name, f.family)) break i;
        } else blk: {
            if (n == out.len) continue;
            out[n] = .{ .name = try alloc.dupe(u8, f.family) };
            n += 1;
            break :blk n - 1;
        };
        if (out[at].files[which] == null) out[at].files[which] = try alloc.dupe(u8, name);
    }
    std.mem.sort(Found, out[0..n], {}, struct {
        fn less(_: void, x: Found, y: Found) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.less);
    return out[0..n];
}

/// A family's four files, any missing filled from the others: bold italic from bold,
/// italic or regular; the rest from regular, or whichever there is.
pub fn complete(files: [4]?[]const u8) [4][]const u8 {
    const any = files[0] orelse files[1] orelse files[2] orelse files[3].?;
    const regular = files[0] orelse any;
    return .{
        regular,
        files[1] orelse regular,
        files[2] orelse regular,
        files[3] orelse files[1] orelse files[2] orelse regular,
    };
}

/// Finds the reader's own typefaces in the fonts folder and offers them. Files that
/// `usable` turns down (not fonts noface can set text in) are left out. Called once,
/// before the settings are read, so a chosen one is found by name.
pub fn find_own(alloc: std.mem.Allocator, usable_font: *const fn ([]const u8) bool) void {
    var names_buf: [64][]const u8 = undefined;
    const names = list_dir(alloc, own_dir, &names_buf);
    var found_buf: [8]Found = undefined;
    const found = group(alloc, names, &found_buf) catch return;
    var added: usize = 0;
    for (found) |f| {
        if (added == settings.max_own) {
            std.debug.print("fonts: {s} left out, only {d} of your own fit\n", .{ f.name, settings.max_own });
            continue;
        }
        const files = complete(f.files);
        var full: [4][:0]const u8 = undefined;
        const usable = for (&full, files) |*p, name| {
            p.* = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ own_dir, name }, 0) catch break false;
            const data = file.map(p.*) catch break false;
            // Tried in a child process: a damaged font can crash the font library
            if (!process.survives(FontTrial{ .data = data, .check = usable_font }, FontTrial.run)) break false;
        } else true;
        if (!usable) {
            std.debug.print("fonts: {s} can't be used\n", .{f.name});
            continue;
        }
        if (!settings.add_family(f.name)) continue;
        own[added] = full;
        added += 1;
        std.debug.print("fonts: added {s}\n", .{f.name});
    }
}

const FontTrial = struct {
    data: []const u8,
    check: *const fn ([]const u8) bool,
    fn run(t: FontTrial) bool {
        return t.check(t.data);
    }
};

/// The names of the files in `dir`.
fn list_dir(alloc: std.mem.Allocator, dir: [*:0]const u8, out: [][]const u8) [][]const u8 {
    const Into = struct {
        alloc: std.mem.Allocator,
        out: [][]const u8,
        n: usize = 0,
        fn add(into: *@This(), name: []const u8, is_dir: bool) void {
            if (is_dir or into.n == into.out.len) return;
            into.out[into.n] = into.alloc.dupe(u8, name) catch return;
            into.n += 1;
        }
    };
    var into = Into{ .alloc = alloc, .out = out };
    linux.each_entry(dir, &into, Into.add);
    return out[0..into.n];
}

test "a font file's name says its family and style" {
    const lit = named("Literata-BoldItalic.ttf").?;
    try std.testing.expectEqualStrings("Literata", lit.family);
    try std.testing.expectEqual(@as(?usize, 3), lit.which);
    try std.testing.expectEqual(@as(?usize, 0), named("OpenDyslexic.otf").?.which);
    try std.testing.expectEqualStrings("OpenDyslexic", named("OpenDyslexic.otf").?.family);
    try std.testing.expectEqual(@as(?usize, null), named("Literata-Light.ttf").?.which);
    try std.testing.expectEqualStrings("Open Sans", named("Open Sans Bold.ttf").?.family);
    try std.testing.expect(named("Readme.txt") == null);
    try std.testing.expect(named("._Literata-Regular.ttf") == null);
    try std.testing.expectEqualStrings("Atkinson-Hyperlegible", named("Atkinson-Hyperlegible.ttf").?.family);
}

test "styles of several words, and family names that end like a style" {
    const georgia = named("Georgia Bold Italic.ttf").?;
    try std.testing.expectEqualStrings("Georgia", georgia.family);
    try std.testing.expectEqual(@as(?usize, 3), georgia.which);
    try std.testing.expectEqual(@as(?usize, 1), named("Georgia Bold.ttf").?.which);
    try std.testing.expectEqualStrings("Times New Roman", named("Times New Roman.ttf").?.family);
    const times = named("Times New Roman Bold.ttf").?;
    try std.testing.expectEqualStrings("Times New Roman", times.family);
    try std.testing.expectEqual(@as(?usize, 1), times.which);
    try std.testing.expectEqual(@as(?usize, 3), named("Literata-Bold-Italic.otf").?.which);
    const crimson = named("Crimson-Roman.otf").?;
    try std.testing.expectEqualStrings("Crimson", crimson.family);
    try std.testing.expectEqual(@as(?usize, 0), crimson.which);
    try std.testing.expectEqualStrings("XCharter", named("XCharter_Roman.otf").?.family);
}

test "files group into families, and missing styles borrow from the others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: [4]Found = undefined;
    const got = try group(arena.allocator(), &.{ "Readme.txt", "Literata-Bold.ttf", "Literata-Light.ttf", "Literata-Regular.ttf", "Atkinson.otf" }, &out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("Atkinson", got[0].name);
    const lit = complete(got[1].files);
    try std.testing.expectEqualStrings("Literata-Regular.ttf", lit[0]);
    try std.testing.expectEqualStrings("Literata-Bold.ttf", lit[1]);
    try std.testing.expectEqualStrings("Literata-Regular.ttf", lit[2]);
    try std.testing.expectEqualStrings("Literata-Bold.ttf", lit[3]);
}
