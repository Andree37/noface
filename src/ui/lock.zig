//! The lock screen's drawing, and what it keeps from one lock to the next. The lock
//! screen (screens/lock.zig) chooses what to show, the reader's own picture, a book's
//! cover, or its title, and when; this file draws the title for a book without a
//! cover, and holds the screens it keeps.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

/// The title drawn for a book without a cover: this far in from either side, its first
/// line this far over the screen's middle, and the author this far under its last.
const title_side = style.space.tall;
const title_rise = style.space.band;
const title_top = style.screen_height / 2 - title_rise;
const title_lines_max = 4;
const author_gap = style.space.medium;

comptime {
    assert(title_lines_max > 0);
    assert(style.screen_width > 2 * title_side);
    assert(title_top > 0);
}

/// What the lock screen shows: the reader's own picture, a book's cover (or its title,
/// for one without), or the title on white for no book. Pictures and books are told
/// apart by a hash, so a replaced picture or another book is drawn again.
pub const Shown = union(enum) { picture: u64, book: u64, no_book };

/// What the lock screen keeps from one lock to the next, in the App: two whole screens,
/// made as noface starts (setup.zig), and what's drawn in them. Only the lock screen
/// uses it (screens/lock.zig).
pub const Kept = struct {
    saved: []u8, // The screen under it, to put back on waking
    cover: []u8, // What the lock screen last drew, full screen
    shown: ?Shown = null, // What `cover` holds, so it isn't drawn again; null at first
    picture_bad: ?u64 = null, // A picture of the reader's that didn't decode, by its hash

    /// Room for a screen of `pixels` under the lock screen and one for what it draws,
    /// made in `alloc`.
    pub fn init(alloc: std.mem.Allocator, pixels: u32) !Kept {
        assert(pixels > 0);
        const saved = try alloc.alloc(u8, pixels);
        errdefer alloc.free(saved);
        const cover = try alloc.alloc(u8, pixels);
        const kept: Kept = .{ .saved = saved, .cover = cover };
        assert(kept.saved.len == kept.cover.len);
        return kept;
    }

    /// Lets go of both screens, made in `alloc` by `init`.
    pub fn release(k: *Kept, alloc: std.mem.Allocator) void {
        assert(k.saved.len == k.cover.len); // As made
        alloc.free(k.saved);
        alloc.free(k.cover);
        k.* = undefined;
    }
};

/// No cover: the title, wrapped, and the author under it, on white over the whole
/// page. Nothing but white for no book.
pub fn render_title(fonts: Fonts, page: Page, title: ?[]const u8, author: []const u8) void {
    assert(page.width == style.screen_width);
    assert(page.height > title_top);
    @memset(page.buf, style.white); // The whole buffer, as it's put on screen whole
    const t = title orelse return;
    const width_available: f32 = @floatFromInt(page.width - 2 * title_side);
    const font = fonts.hero;
    const step = font.line_height;
    // Ignored below: what's drawn of the title names the book; the author's place
    // under it isn't known then, so it's left out rather than drawn over it
    const lines = draw.wrapped(
        font,
        page,
        title_side,
        title_top,
        step,
        t,
        width_available,
        title_lines_max,
    ) catch return; // Ignored: as said above
    assert(lines <= title_lines_max);
    if (author.len > 0) {
        const author_top = title_top + @as(i32, @intCast(lines)) * step + author_gap;
        draw.clipped(
            fonts.small,
            page,
            title_side,
            author_top,
            author,
            width_available,
        ) catch {}; // Ignored: without the author, the title still says which book it is.
    }
}
