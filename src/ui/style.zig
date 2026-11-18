//! Layout and tones every screen shares, so they stay in step.
const std = @import("std");
const assert = std.debug.assert;
const device = @import("../model/device.zig");

/// The screen every layout is worked out for. For now, the one Kindle noface knows;
/// its size comes from the device's own facts (model/device.zig), never typed in here.
pub const screen = device.screen(.paperwhite_12);
/// As untyped numbers, as layout arithmetic takes them in signed and unsigned alike.
pub const screen_width: comptime_int = screen.width_px;
pub const screen_height: comptime_int = screen.height_px;
pub const margin = 72; // Left and right edge of interface text

/// The clock, battery and Wi-Fi strip along the top of the home screen and the
/// screens opened over it, which stay under it.
pub const status_height = 96;

// Tones. A tint lightens what's already drawn toward white by this much.
pub const black = 0x00;
pub const white = 0xff;
pub const rule = 0xb0; // Thin dividing lines, and a sheet's grab bar
pub const faded = 0x50; // Tint over choices that aren't selected
pub const quiet = 0x60; // Tint over secondary text: a caption, a hint, a sample
pub const disabled = 0xc8; // Tint over a control that can't be used now
pub const finished_cover = 0xa0; // Tint over the cover of a book that's been read
pub const note_rule = 0xa0; // The line under a footnote's header
pub const panel_rule = 0x80; // The line across the quick panel

// Shapes
pub const border = 3; // Outline of boxes and cards
pub const underline = 5; // Under the selected choice
pub const sheet_corner = 36; // A sheet rising from the bottom
pub const button_corner = 24; // Buttons, bubbles and tiles
pub const key_corner = 14; // Keyboard keys
pub const bar_corner = 10; // The bars of a chart

/// A rectangle of the screen, in its pixels: where something is drawn, and so where it
/// takes taps.
pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    /// Whether a touch at (`px`, `py`) falls in it.
    pub fn contains(r: Rect, px: i32, py: i32) bool {
        assert(r.x + r.w <= screen_width);
        assert(r.y + r.h <= screen_height);
        if (px < 0 or py < 0) return false;
        const x: u32 = @intCast(px);
        const y: u32 = @intCast(py);
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }
};
