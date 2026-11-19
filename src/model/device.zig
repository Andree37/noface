//! The Kindles noface knows, and for each the facts about its screen that every layout
//! is worked out from: its size and how densely its pixels sit. What drives a screen
//! (its display driver and refresh modes) is kindle/'s to know; these are plain facts
//! any folder may read. The interface's sizes are pixels at 300 to the inch, the
//! density of every Kindle noface knows (style.zig, which checks it); turning
//! millimetres and points into a screen's pixels is here for when a Kindle of another
//! density joins them.
const std = @import("std");
const assert = std.debug.assert;

/// A Kindle noface runs on.
pub const Model = enum { paperwhite_12 };

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
    return switch (model) {
        .paperwhite_12 => "Kindle Paperwhite (12th generation)",
    };
}

/// A model's screen, as its maker built it.
pub fn screen(model: Model) Screen {
    const s: Screen = switch (model) {
        // About 7.1 inches across its diagonal at 300 pixels to the inch
        .paperwhite_12 => .{ .width_px = 1272, .height_px = 1696, .dpi = 300 },
    };
    assert(s.width_px < s.height_px); // Held upright
    assert(s.dpi > 0);
    return s;
}

/// The model with a screen of this size, as its display driver reports it; null for
/// one noface doesn't know, which it doesn't start on.
pub fn with_screen(width_px: u32, height_px: u32) ?Model {
    for (std.enums.values(Model)) |model| {
        const s = screen(model);
        if (s.width_px == width_px and s.height_px == height_px) return model;
    }
    return null;
}

test "every model's screen is told by its size, and no other size is taken for one" {
    for (std.enums.values(Model)) |model| {
        const s = screen(model);
        try std.testing.expectEqual(@as(?Model, model), with_screen(s.width_px, s.height_px));
    }
    try std.testing.expectEqual(@as(?Model, null), with_screen(1072, 1448));
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
