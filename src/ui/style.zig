//! Layout and tones every screen shares, so they stay in step.
pub const screen_width = 1272;
pub const screen_height = 1696;
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
