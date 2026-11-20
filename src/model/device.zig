//! The Kindles noface knows, and for each the facts about its screen that every layout
//! is worked out from: its size and how densely its pixels sit. What drives a screen
//! (its display driver and refresh modes) is kindle/'s to know; these are plain facts
//! any folder may read. The interface's sizes are pixels at 300 to the inch, the
//! density of every Kindle noface knows (style.zig, which checks it); turning
//! millimetres and points into a screen's pixels is here for when a Kindle of another
//! density joins them.
const std = @import("std");
const assert = std.debug.assert;
/// Which Kindle this build is laid out for (`zig build -Dlayout=<model>`).
const layout = @import("layout");

/// The Kindles noface knows the screens of.
pub const Model = enum { paperwhite_12, basic_11, scribe, basic_10 };

/// The Kindle this build is laid out for, and so the one it runs on: the Paperwhite,
/// unless the build asks for another. The others are known so `zig build layouts` can
/// lay every screen out for each and check it fits.
pub const target: Model = std.meta.stringToEnum(Model, layout.model) orelse
    @compileError("-Dlayout names no Kindle in device.Model");

/// A screen's size in pixels, and its density in pixels to the inch.
pub const Screen = struct {
    width_px: u32,
    height_px: u32,
    dpi: u32,

    /// `mm` millimetres in this screen's pixels, to the nearest.
    pub fn px_from_mm(s: Screen, mm: f32) u32 {
        assert(mm >= 0);
        assert(s.dpi > 0);
        return @intFromFloat(@round(mm * @as(f32, @floatFromInt(s.dpi)) / mm_per_inch));
    }

    /// `pt` typographic points (a 72nd of an inch) in this screen's pixels.
    pub fn px_from_pt(s: Screen, pt: f32) u32 {
        assert(pt >= 0);
        assert(s.dpi > 0);
        return @intFromFloat(@round(pt * @as(f32, @floatFromInt(s.dpi)) / points_per_inch));
    }
};

const mm_per_inch = 25.4;
const points_per_inch = 72;

/// A model's name, as a person would say it.
pub fn name(model: Model) []const u8 {
    const result = switch (model) {
        .paperwhite_12 => "Kindle Paperwhite (12th generation)",
        .basic_11 => "Kindle (11th generation)",
        .scribe => "Kindle Scribe",
        .basic_10 => "Kindle (10th generation)",
    };
    assert(result.len > 0);
    return result;
}

/// A model's screen, as its maker built it.
pub fn screen(model: Model) Screen {
    const s: Screen = switch (model) {
        // About 7.1 inches across its diagonal at 300 pixels to the inch
        .paperwhite_12 => .{ .width_px = 1272, .height_px = 1696, .dpi = 300 },
        // About 6 inches at 300 to the inch
        .basic_11 => .{ .width_px = 1072, .height_px = 1448, .dpi = 300 },
        // About 10.2 inches at 300 to the inch
        .scribe => .{ .width_px = 1860, .height_px = 2480, .dpi = 300 },
        // About 6 inches at 167 to the inch
        .basic_10 => .{ .width_px = 600, .height_px = 800, .dpi = 167 },
    };
    assert(s.width_px < s.height_px); // Held upright
    assert(s.dpi > 0);
    return s;
}

/// The Kindle this build runs on, if its display driver reports that screen's size;
/// null for any other, which this build isn't laid out for and doesn't start on.
pub fn with_screen(width_px: u32, height_px: u32) ?Model {
    const s = screen(target);
    assert(s.width_px < s.height_px); // Asked of a screen held upright
    if (s.width_px == width_px and s.height_px == height_px) return target;
    return null;
}

test "the screen this build is laid out for is told by its size, and no other" {
    const s = screen(target);
    try std.testing.expectEqual(@as(?Model, target), with_screen(s.width_px, s.height_px));
    for (std.enums.values(Model)) |model| {
        if (model == target) continue;
        const other = screen(model);
        const found = with_screen(other.width_px, other.height_px);
        try std.testing.expectEqual(@as(?Model, null), found);
    }
    try std.testing.expectEqual(@as(?Model, null), with_screen(1696, 1272)); // On its side
}

test "physical sizes turn into a screen's pixels by its density" {
    const s = screen(.paperwhite_12);
    try std.testing.expectEqual(@as(u32, 300), s.px_from_mm(25.4)); // An inch
    try std.testing.expectEqual(@as(u32, 300), s.px_from_pt(72));
    try std.testing.expectEqual(@as(u32, 0), s.px_from_mm(0));
    // A fingertip, about 8.5 mm: a hundred pixels on the Paperwhite
    try std.testing.expectEqual(@as(u32, 100), s.px_from_mm(8.5));
}
