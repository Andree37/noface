//! The reading typefaces' fonts: each made the first time it's asked for, by family,
//! face (bold, italic), reader size and book size, and kept in a fixed table, the one
//! used least lately given up for a new one. Their files are mapped as they're first
//! needed and kept in a table of their own, shared by every font made from them, and
//! unmapped only when no font kept uses them and the room is wanted. However many
//! typefaces there are, and however often the reader changes them, this holds no more.
const std = @import("std");
const assert = std.debug.assert;
const Font = @import("gfx/font.zig").Font;
const fonts_db = @import("kindle/fonts.zig");
const file = @import("sys/file.zig");

/// Fonts kept for the reading face: more than one page can use, so a page never gives
/// up a font it set text in (four faces at each of five book sizes, in one family and
/// reader size).
pub const faces_kept = 32;
/// Fonts kept to show the typefaces' names in themselves: more than the Aa sheet shows
/// at once.
pub const samples_kept = 12;
/// Running's phrase fonts: the phrase's own, bold, and the regular one around it.
const phrase_faces_kept = 2;
/// Files kept: one for each font kept, at most (running's phrase fonts too), and one
/// more, so there's always one to give up when another is needed.
const files_kept = faces_kept + samples_kept + phrase_faces_kept + 1;
/// The size a typeface's name is shown in, on the Aa sheet.
const sample_px = 36;

comptime {
    // Four faces at every book size, the most one page can set text in
    assert(faces_kept > 4 * 5);
    assert(samples_kept >= 6);
    assert(files_kept > faces_kept + samples_kept + phrase_faces_kept);
}

/// Which of a family's four files: bit 0 bold, bit 1 italic.
pub const Which = u2;

/// A font for the reading face, as the reader's settings and the book pick it.
pub const FaceKey = struct {
    family: u32,
    which: Which,
    size: u8, // The reader's size, one of `settings.sizes`
    scale: u8, // The book's size, one of `book.size_scales`
};

const FileSlot = struct {
    family: u32,
    which: Which,
    data: []const u8,
    mapped: bool, // Mapped here, so unmapped when given up; a stand-in isn't
    fonts: u32 = 0, // Fonts kept that are made from it
    used: u64,
};

const FaceSlot = struct { key: FaceKey, font: Font, file: u32, used: u64 };
const SampleSlot = struct { family: u32, font: Font, file: u32, used: u64 };
const PhraseSlot = struct { family: u32, which: Which, px: f32, font: Font, file: u32 };

pub const Typefaces = struct {
    files: [files_kept]?FileSlot = @splat(null),
    faces: [faces_kept]?FaceSlot = @splat(null),
    samples: [samples_kept]?SampleSlot = @splat(null),
    /// Running mode's phrase fonts, at sizes of their own (screens/reader/run.zig):
    /// the regular one in the first place, the bold in the second.
    phrases: [phrase_faces_kept]?PhraseSlot = @splat(null),
    /// Counts every use, to tell which was used least lately.
    clock: u64 = 0,
    /// Every family's four files, for the tests, which have none of
    /// the Kindle's: null to map each family's own.
    stand_in: ?[4][]const u8 = null,

    /// The font for `key` at `px` pixels, made now if it isn't kept. `pinned`, a font
    /// in use outside of any page, is never the one given up for it.
    pub fn face(t: *Typefaces, key: FaceKey, px: f32, pinned: ?*const Font) !*Font {
        assert(px > 0);
        t.clock += 1;
        for (&t.faces) |*slot| {
            const kept = &(slot.* orelse continue);
            if (!std.meta.eql(kept.key, key)) continue;
            kept.used = t.clock;
            return &kept.font;
        }
        const file_at = try t.file_for(key.family, key.which);
        const font = try Font.init(t.files[file_at].?.data, px, 1);
        const at = least_used(FaceSlot, &t.faces, pinned);
        if (t.faces[at]) |old| t.give_up_file(old.file);
        t.files[file_at].?.fonts += 1;
        t.faces[at] = .{ .key = key, .font = font, .file = file_at, .used = t.clock };
        assert(t.faces[at].?.font.id == font.id);
        assert(t.files[file_at].?.fonts > 0);
        return &t.faces[at].?.font;
    }

    /// Family `family`'s regular at the Aa sheet's size, made now if it isn't kept;
    /// null when it can't be.
    pub fn sample(t: *Typefaces, family: u32) ?*Font {
        t.clock += 1;
        for (&t.samples) |*slot| {
            const kept = &(slot.* orelse continue);
            if (kept.family != family) continue;
            kept.used = t.clock;
            return &kept.font;
        }
        const file_at = t.file_for(family, 0) catch return null;
        const font = Font.init(t.files[file_at].?.data, sample_px, 1.2) catch return null;
        const at = least_used(SampleSlot, &t.samples, null);
        if (t.samples[at]) |old| t.give_up_file(old.file);
        t.files[file_at].?.fonts += 1;
        t.samples[at] = .{ .family = family, .font = font, .file = file_at, .used = t.clock };
        assert(t.samples[at].?.family == family);
        assert(t.files[file_at].?.fonts > 0);
        return &t.samples[at].?.font;
    }

    /// A font running mode sets its phrases in: `family`, bold or not, at `px`, made
    /// now unless it's the one kept for that weight.
    pub fn phrase_face(t: *Typefaces, family: u32, bold: bool, px: f32) !*Font {
        assert(px > 0);
        t.clock += 1;
        const which: Which = @intFromBool(bold);
        const slot = &t.phrases[which];
        if (slot.*) |*kept| {
            if (kept.family == family and kept.px == px) return &kept.font;
        }
        const file_at = try t.file_for(family, which);
        const font = try Font.init(t.files[file_at].?.data, px, 1);
        if (slot.*) |old| t.give_up_file(old.file);
        t.files[file_at].?.fonts += 1;
        slot.* = .{ .family = family, .which = which, .px = px, .font = font, .file = file_at };
        assert(t.files[file_at].?.fonts > 0);
        return &slot.*.?.font;
    }

    /// The place of a family's file in the table: kept, or mapped now into a free
    /// place or one no kept font uses.
    fn file_for(t: *Typefaces, family: u32, which: Which) !u32 {
        assert(t.clock > 0);
        for (&t.files, 0..) |*slot, at| {
            const kept = &(slot.* orelse continue);
            if (kept.family != family or kept.which != which) continue;
            kept.used = t.clock;
            return @intCast(at);
        }
        const bold = which & 1 != 0;
        const italic = which & 2 != 0;
        const data, const mapped = if (t.stand_in) |files|
            .{ files[which], false }
        else
            .{ try file.map(fonts_db.path(family, bold, italic)), true };
        const at = t.file_place();
        if (t.files[at]) |old| {
            if (old.mapped) file.unmap(old.data);
        }
        t.files[at] = .{
            .family = family,
            .which = which,
            .data = data,
            .mapped = mapped,
            .used = t.clock,
        };
        assert(t.files[at].?.fonts == 0);
        return at;
    }

    /// A free place for a file, or the one used least lately that no kept font uses:
    /// there's always one, as there are more places than fonts kept.
    fn file_place(t: *const Typefaces) u32 {
        var best: ?u32 = null;
        for (t.files, 0..) |slot, at| {
            const kept = slot orelse return @intCast(at);
            if (kept.fonts > 0) continue;
            if (best == null or kept.used < t.files[best.?].?.used) best = @intCast(at);
        }
        assert(best != null); // More places than fonts, so one is used by none
        assert(t.files[best.?].?.fonts == 0);
        return best.?;
    }

    /// A font kept from file `at` is given up: the file is one font less in use.
    fn give_up_file(t: *Typefaces, at: u32) void {
        const kept = &t.files[at].?;
        assert(kept.fonts > 0);
        kept.fonts -= 1;
        assert(kept.data.len > 0);
    }

    /// Unmaps every file mapped here and forgets every font: for a test, or an App
    /// going away.
    pub fn release(t: *Typefaces) void {
        for (&t.files) |*slot| {
            if (slot.*) |kept| {
                if (kept.mapped) file.unmap(kept.data);
            }
            slot.* = null;
        }
        t.faces = @splat(null);
        t.samples = @splat(null);
        t.phrases = @splat(null);
        assert(t.files[0] == null);
        assert(t.faces[0] == null);
    }
};

/// A free place in `slots`, or the one used least lately but `pinned`.
fn least_used(comptime Slot: type, slots: []?Slot, pinned: ?*const Font) u32 {
    assert(slots.len > 1); // So one is left besides the pinned
    var best: ?u32 = null;
    for (slots, 0..) |*slot, at| {
        const kept = &(slot.* orelse return @intCast(at));
        if (pinned == &kept.font) continue;
        if (best == null or kept.used < slots[best.?].?.used) best = @intCast(at);
    }
    assert(best != null);
    assert(pinned != &slots[best.?].?.font);
    return best.?;
}

test "fonts past the table's size give up the least used, never the pinned, and share files" {
    const go_regular = @embedFile("testdata/fonts/Go-Regular.ttf");
    const go_bold = @embedFile("testdata/fonts/Go-Bold.ttf");
    var t: Typefaces = .{ .stand_in = .{ go_regular, go_bold, go_regular, go_bold } };
    defer t.release();
    const body = try t.face(.{ .family = 0, .which = 0, .size = 2, .scale = 1 }, 46, null);
    const body_id = body.id;
    // Many more fonts than are kept, over many families and sizes
    for (0..200) |i| {
        const key: FaceKey = .{
            .family = @intCast(i % 9),
            .which = @intCast(i % 4),
            .size = @intCast(i % 6),
            .scale = @intCast(i % 5),
        };
        const font = try t.face(key, 20 + @as(f32, @floatFromInt(i % 30)), body);
        try std.testing.expect(font.line_height > 0);
        _ = t.sample(@intCast(i % 20));
    }
    // The pinned font is where it was, the same font
    try std.testing.expectEqual(body_id, body.id);
    const again = try t.face(.{ .family = 0, .which = 0, .size = 2, .scale = 1 }, 46, null);
    try std.testing.expectEqual(body, again);
    // Every file kept is used by as many fonts as count it
    var counted: [files_kept]u32 = @splat(0);
    for (t.faces) |slot| counted[slot.?.file] += 1;
    for (t.samples) |slot| counted[slot.?.file] += 1;
    for (t.files, counted) |slot, count| {
        if (slot) |kept| try std.testing.expectEqual(count, kept.fonts);
    }
}
