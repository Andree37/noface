//! Layout and tones every screen shares, so they stay in step.
const std = @import("std");
const assert = std.debug.assert;
const device = @import("../model/device.zig");

comptime {
    // The steps grow, each from the one before
    const steps = [_]comptime_int{
        space.hair,  space.tiny, space.small, space.snug, space.medium,
        space.roomy, space.wide, space.wider, space.band, space.tall,
    };
    for (steps[0 .. steps.len - 1], steps[1..]) |smaller, larger| assert(smaller < larger);
    // A fingertip's taps, about 8.5 mm, whatever the density
    assert(fingertip * 254 >= screen.dpi * 84);
}

/// The screen every layout is worked out for. For now, the one Kindle noface knows;
/// its size comes from the device's own facts (model/device.zig), never typed in here.
pub const screen = device.screen(device.target);
/// As untyped numbers, as layout arithmetic takes them in signed and unsigned alike.
pub const screen_width: comptime_int = screen.width_px;
pub const screen_height: comptime_int = screen.height_px;
/// A length in typographic points, a 72nd of an inch, as this screen's pixels. Every
/// size in the interface is written in points, here and nowhere else, so it's the same
/// size on any Kindle, whatever its density; the screens build theirs from the names
/// below, never from numbers of their own.
pub fn pt(comptime points: comptime_float) comptime_int {
    comptime assert(points >= 0);
    return comptime screen.px_from_pt(points);
}

/// The steps every gap, inset and band is made of, smallest to largest: each about
/// twice or one and a half times the one before, so two sizes either match or differ
/// enough to be seen.
pub const space = struct {
    pub const hair = pt(1); // A line's breadth apart
    pub const tiny = pt(2);
    pub const small = pt(3);
    pub const snug = pt(4);
    pub const medium = pt(6);
    pub const roomy = pt(8);
    pub const wide = pt(12);
    pub const wider = pt(16);
    pub const band = pt(24); // A fingertip
    pub const tall = pt(32);
};

/// The sizes of the interface's text, in points, so text is the same printed size on
/// every Kindle. The reading text's own sizes are the reader's (model/settings.zig).
pub const text = struct {
    pub const caption = pt(6.25);
    pub const footer = pt(6.75);
    pub const small = pt(8.25);
    pub const title = pt(8.25);
    pub const sample = pt(8.75); // A typeface's name in itself, a note's text
    pub const body = pt(11);
    pub const hero = pt(13.5);
    pub const phrase = pt(20.25); // Running mode's phrase, read from a stride away
};

/// The interface's lines, as a share of their text's size: a line of `size` text and
/// the next are this far apart.
pub const leading = 1.2;
pub fn line_step(comptime size: comptime_int) comptime_int {
    comptime assert(size > 0);
    return @intFromFloat(@round(size * leading));
}

pub const margin = pt(17.25); // Left and right edge of interface text
/// The least a control takes taps across: about 8.5 mm, a fingertip.
pub const fingertip = space.band;
/// The reading page: its text's room under the clock and over the footer, a
/// paragraph's first-line indent, the line under a highlight (its thickness, and how
/// far up from the foot of its line's height it sits, under the descenders), and how
/// far round a note's mark a tap still opens it, the mark being small.
pub const reading = struct {
    pub const top = pt(21.5);
    pub const bottom = pt(36);
    pub const indent = pt(14.5);
    pub const underline_thick = underline;
    pub const underline_above_foot = pt(2.5);
    pub const mark_reach = pt(7.25);

    comptime {
        assert(underline_above_foot > underline_thick); // Within its line's height
        assert(top < bottom); // The footer takes more than the clock
    }
};

/// A book's cover as the library shows it, in the grid and as the book to continue,
/// which is the larger: covers are decoded at these sizes (ui/covers.zig).
pub const cover = struct {
    pub const width = pt(60.5);
    pub const height = pt(80);
    pub const hero_width = pt(64.75);
    pub const hero_height = pt(85.75);

    comptime {
        assert(hero_width > width);
        assert(hero_height > height);
    }
};

/// A button with a word or two on it: an inch across.
pub const button_width = pt(72);
/// A slider's bar runs this far in from each edge of the screen.
pub const slider_inset = pt(26.5);

/// The clock, battery and Wi-Fi strip along the top of the home screen and the
/// screens opened over it, which stay under it.
pub const status_height = pt(23);

/// The clock over a page, in a band from the screen's top, and the line through its
/// middle that the toolbar's clock and status icons sit on too, so the time stays put
/// as the toolbar opens and closes over the page.
pub const page_clock = struct {
    pub const top = space.snug;
    pub const height = space.wide;
    pub const middle = top + height / 2;
};

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
pub const type_paper = 0xf0; // A typed cover's paper: a shade off white, read as one
pub const track = 0xb8; // A progress bar's track, under its black fill
pub const past_days = 0x90; // The reading chart's days before today
pub const placeholder = 0x90; // Tint over a search field's hint
// The keyboard: a light tray, keys white on it with a soft shadow, and the keys that
// aren't letters (delete, shift, the layers) a step darker
pub const key_tray = 0xe2;
pub const key_shadow = 0xa8;
pub const key_special = 0xc4;

// Shapes
pub const stroke = pt(0.5); // A thin line: a rule, an icon's stroke
/// The finest line the panel draws: one pixel on any screen, for a gray rule that only
/// divides.
pub const fine_line = 1;
pub const border = pt(0.75); // Outline of boxes and cards
pub const underline = pt(1.25); // Under the selected choice, and a highlight's words
pub const flash_bar = pt(1.5); // The outline round a book as it's tapped, at once
pub const sheet_corner = pt(8.75); // A sheet rising from the bottom
pub const button_corner = pt(5.75); // Buttons, bubbles and tiles
pub const key_corner = pt(3.25); // Keyboard keys
pub const bar_corner = pt(2.5); // The bars of a chart

/// A point of the screen: the middle of a control's taps, where a script or a test taps
/// it by name (screens/places.zig), so it follows the control wherever layout puts it.
pub const Point = struct { x: i32, y: i32 };

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
