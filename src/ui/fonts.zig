//! The interface fonts every screen draws with.
const Font = @import("../gfx/font.zig").Font;

pub const Fonts = struct {
    title: *Font, // UI bold
    small: *Font, // UI regular
    caption: *Font,
    hero: *Font, // Book title, in the reading typeface
    cover: *Font,
    /// The typefaces' regulars at interface size, for showing their names in
    /// themselves: those on the Aa sheet's page of them, from `family_first`. Empty, or
    /// null for one, where the interface font stands in.
    families: []const ?*Font = &.{},
    family_first: u32 = 0,
};
