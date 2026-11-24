//! What's drawn and shown: the screen, the open book's pages as last drawn (the page
//! cache), and the overlay a sheet is composed in before it's put on screen. Every
//! draw onto the screen and every refresh of the panel goes through here.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("gfx/page.zig").Page;
const hwtcon = @import("kindle/hwtcon.zig");
const text = @import("layout/text.zig");
const library = @import("ui/library.zig");
const style = @import("ui/style.zig");
const page_cache = @import("layout/page_cache.zig");

/// How many pages the cache keeps drawn (layout/page_cache.zig picks which).
pub const slots_count = page_cache.slots;
/// Whole screens a display keeps for good: its page slots, and its overlay.
pub const screens_kept = slots_count + 1;

/// The outline `flash` draws round a book, its bars this thick.
const flash_bar_px = style.flash_bar;

/// A cached page: which it is (null: none), its pixels and where its words are, and how
/// many times a page has been drawn into it, so pixels lent from it are known stale
/// once another is (`Backdrop`).
pub const Slot = struct { page: ?u32 = null, buf: []u8, hits: text.Hits = .{}, drawn: u32 = 0 };

/// What a sheet is drawn over, and what comes back when it closes: a whole screen of
/// pixels the sheet doesn't own, only borrows. Pixels lent from the page cache say which
/// slot they're in and how many times it had been drawn into, and every use checks it
/// hasn't been since: another page drawn there would show under the sheet instead.
pub const Backdrop = struct {
    pixels: []const u8,
    lent: ?Lent = null, // Null: owned by whoever opened the sheet, and kept still for it

    pub const Lent = struct { slot: u32, drawn: u32 };

    /// Whether it's a whole screen kept apart from what's shown, and, if lent, still
    /// the screen it was then: no other page drawn into its slot since.
    pub fn holds(b: Backdrop, d: *const Display) bool {
        if (b.pixels.len != d.screen.pixels.len) return false;
        if (b.pixels.ptr == d.screen.pixels.ptr) return false;
        const l = b.lent orelse return true;
        if (l.slot >= d.slots.len) return false;
        const slot = &d.slots[l.slot];
        return slot.buf.ptr == b.pixels.ptr and slot.drawn == l.drawn;
    }

    /// The pixels, checked still the screen they were when lent.
    pub fn get(b: Backdrop, d: *const Display) []const u8 {
        assert(b.holds(d));
        assert(b.pixels.len == d.screen.pixels.len);
        return b.pixels;
    }
};

pub const Display = struct {
    screen: *hwtcon.Screen,
    /// The open book's pages as last drawn, a page each (screens/reader/session.zig owns
    /// what's in them: only it draws into them and reads their words).
    slots: [slots_count]Slot,
    /// A whole screen of scratch, for composing one draw before it's copied to the
    /// screen (`compose`, `put_composed`): a screen's while it draws, good for nothing
    /// after, so nothing keeps anything in it.
    overlay: []u8,

    /// A display for `screen`, its page cache and overlay made in `alloc`. The screen
    /// is the one every layout is worked out for (style.screen): checked here, where the
    /// real screen meets the layout, so code may read its size from either.
    pub fn init(alloc: std.mem.Allocator, screen: *hwtcon.Screen) !Display {
        assert(screen.width == style.screen_width);
        assert(screen.height == style.screen_height);
        const pixels = screen.pixels.len;
        assert(pixels > 0);
        var slots: [slots_count]Slot = undefined;
        for (&slots) |*s| s.* = .{ .buf = try alloc.alloc(u8, pixels) };
        const overlay = try alloc.alloc(u8, pixels);
        const d: Display = .{ .screen = screen, .slots = slots, .overlay = overlay };
        assert(d.overlay.len == pixels);
        assert(d.slots.len + 1 == screens_kept); // As setup.zig counts them
        return d;
    }

    /// Lets go of the page cache and the overlay, made in `alloc` by `init`.
    pub fn release(d: *Display, alloc: std.mem.Allocator) void {
        for (&d.slots) |*slot| {
            assert(slot.buf.len == d.screen.pixels.len); // As made
            alloc.free(slot.buf);
        }
        assert(d.overlay.len == d.screen.pixels.len);
        alloc.free(d.overlay);
        d.* = undefined;
    }

    /// A whole screen's pixels in `buf`, as a page to draw on.
    pub fn page(d: *const Display, buf: []u8) Page {
        // A row of the screen's memory holds at least a row of pixels
        assert(d.screen.width > 0);
        assert(d.screen.stride >= d.screen.width);
        return .{
            .buf = buf,
            .width = d.screen.width,
            .height = d.screen.height,
            .stride = d.screen.stride,
        };
    }

    /// The screen's own pixels, as a page to draw on before a part of it is shown.
    pub fn on_screen(d: *const Display) Page {
        return d.page(d.screen.pixels);
    }

    /// The overlay, holding `under`, for a sheet to be drawn over it before
    /// `put_composed` puts the whole on screen.
    pub fn compose(d: *Display, under: Backdrop) Page {
        assert(d.overlay.len == d.screen.pixels.len);
        @memcpy(d.overlay, under.get(d));
        return d.page(d.overlay);
    }

    /// The overlay as it is, for a draw that sets every pixel itself before
    /// `put_composed` puts it on screen.
    pub fn compose_whole(d: *Display) Page {
        assert(d.overlay.len == d.screen.pixels.len);
        return d.page(d.overlay);
    }

    /// What was composed in the overlay, onto the screen; shown by the caller, over
    /// what it changed.
    pub fn put_composed(d: *Display) void {
        assert(d.overlay.len == d.screen.pixels.len);
        @memcpy(d.screen.pixels, d.overlay);
    }

    /// `under` back on the whole screen, as it was before a sheet went over it; shown by
    /// the caller, over what the sheet covered.
    pub fn put_back(d: *Display, under: Backdrop) void {
        @memcpy(d.screen.pixels, under.get(d));
    }

    /// A whole screen drawn elsewhere, onto the screen and shown with `refresh`.
    pub fn present(d: *Display, buf: []const u8, refresh: hwtcon.Refresh) !void {
        assert(buf.len == d.screen.pixels.len); // A whole screen, drawn elsewhere
        assert(buf.ptr != d.screen.pixels.ptr); // Not the screen itself
        @memcpy(d.screen.pixels, buf);
        try d.screen.wait_complete(try d.screen.show(refresh));
    }

    /// Outlines a book at once, using the fastest waveform, and waits so it can't
    /// collide with what's drawn next.
    pub fn flash(d: *Display, r: library.Rect) void {
        const target = d.on_screen();
        const t = flash_bar_px;
        // The outline's four bars lie inside the book, and the book on the screen
        assert(r.w >= t);
        assert(r.h >= t);
        assert(r.x + r.w <= d.screen.width);
        assert(r.y + r.h <= d.screen.height);
        target.fill_rect(r.x, r.y, r.w, t, 0x00);
        target.fill_rect(r.x, r.y + r.h - t, r.w, t, 0x00);
        target.fill_rect(r.x, r.y, t, r.h, 0x00);
        target.fill_rect(r.x + r.w - t, r.y, t, r.h, 0x00);
        const marker = d.screen.show_region(r.x, r.y, r.w, r.h, .quick) catch return;
        d.screen.wait_complete(marker) catch {}; // Ignored: the outline is shown either way.
    }

    /// Refreshes part of the screen with the page waveform, and waits for it.
    pub fn show_rect(d: *Display, left: u32, top: u32, width: u32, height: u32) !void {
        // The same as the screen checks for every update, said where it's asked for
        assert(width > 0);
        assert(height > 0);
        assert(left + width <= d.screen.width);
        assert(top + height <= d.screen.height);
        try d.screen.wait_complete(try d.screen.show_region(left, top, width, height, .page));
    }

    /// Refreshes a full-width band of the screen, and waits for it.
    pub fn show_band(d: *Display, top: u32, height: u32) !void {
        assert(height > 0);
        assert(top + height <= d.screen.height);
        try d.show_rect(0, top, d.screen.width, height);
    }

    /// Settles a band after a drag: its smooth edges come back, without a flash. Full
    /// mode would drive every pixel, but on this panel full mode always flashes.
    pub fn clean_band(d: *Display, top: u32, height: u32) !void {
        assert(height > 0);
        assert(top + height <= d.screen.height);
        try d.clean_rect(0, top, d.screen.width, height);
    }

    pub fn clean_rect(d: *Display, left: u32, top: u32, width: u32, height: u32) !void {
        // The same as the screen checks for every update, said where it's asked for
        assert(width > 0);
        assert(height > 0);
        assert(left + width <= d.screen.width);
        assert(top + height <= d.screen.height);
        const marker = try d.screen.show_region(left, top, width, height, .clean);
        try d.screen.wait_complete(marker);
    }

    /// The cached page buffer holding `page`, if any.
    pub fn slot_for(d: *Display, page_index: u32) ?*Slot {
        assert(d.slots.len > 0);
        for (&d.slots) |*slot| {
            assert(slot.buf.len == d.screen.pixels.len); // Each holds a whole screen
            const held = slot.page orelse continue;
            if (held == page_index) return slot;
        }
        return null;
    }

    /// The slot to draw page `page_index` into, a page of the window around `center`
    /// given up for it if none is free (layout/page_cache.zig). It holds no page until
    /// `end_draw`, and pixels lent from it before now are known stale: a draw that
    /// fails leaves it empty, never half of another page that still looks cached.
    pub fn begin_draw(d: *Display, page_index: u32, center: u32) *Slot {
        assert(d.slot_for(page_index) == null); // Drawn only when not cached already
        var cached: [slots_count]?u32 = undefined;
        for (&d.slots, &cached) |*slot, *c| c.* = slot.page;
        const victim = page_cache.victim(cached, center);
        assert(victim < d.slots.len);
        const slot = &d.slots[victim];
        slot.page = null;
        slot.drawn +%= 1;
        slot.hits.clear();
        return slot;
    }

    /// The slot `begin_draw` gave, drawn whole: it now holds page `page_index`.
    pub fn end_draw(d: *Display, slot: *Slot, page_index: u32) void {
        assert(slot.page == null); // As `begin_draw` left it
        assert(d.slot_for(page_index) == null);
        slot.page = page_index;
        assert(d.slot_for(page_index).? == slot);
    }

    /// The screen as it is now, kept in a page slot given up for it and lent as a
    /// backdrop: for a card over a screen nobody else keeps, such as the page a book
    /// just closed on (no book is open, so its pages are free).
    pub fn keep_screen(d: *Display) Backdrop {
        const slot = &d.slots[0];
        assert(slot.buf.len == d.screen.pixels.len);
        slot.page = null;
        slot.drawn +%= 1; // Lent before now: stale
        slot.hits.clear();
        @memcpy(slot.buf, d.screen.pixels);
        const kept: Backdrop = .{ .pixels = slot.buf, .lent = .{ .slot = 0, .drawn = slot.drawn } };
        assert(kept.holds(d));
        return kept;
    }

    /// Drops every cached page, after anything that changes how pages look.
    pub fn forget_pages(d: *Display) void {
        for (&d.slots) |*slot| {
            assert(slot.buf.len == d.screen.pixels.len); // Each holds a whole screen
            slot.page = null;
        }
    }
};

test "a page drawn into the cache is cached once drawn whole; pixels lent before are stale" {
    const alloc = std.testing.allocator;
    var screen = try hwtcon.Screen.fake(alloc, style.screen_width, style.screen_height);
    defer alloc.free(screen.map);
    var d = try Display.init(alloc, &screen);
    defer d.release(alloc);
    // Page 5 drawn whole, and lent to a sheet
    const five = d.begin_draw(5, 5);
    d.end_draw(five, 5);
    const lent: Backdrop = .{
        .pixels = five.buf,
        .lent = .{ .slot = @intCast(five - &d.slots[0]), .drawn = five.drawn },
    };
    try std.testing.expect(lent.holds(&d));
    // Pages 4 and 6 fill the other slots; page 9's draw takes 5's slot and fails
    // before it's done
    d.end_draw(d.begin_draw(4, 5), 4);
    d.end_draw(d.begin_draw(6, 5), 6);
    const nine = d.begin_draw(9, 9);
    try std.testing.expect(nine == five);
    try std.testing.expect(d.slot_for(5) == null);
    try std.testing.expect(d.slot_for(9) == null);
    try std.testing.expect(!lent.holds(&d));
    // Drawn again, it's cached
    const again = d.begin_draw(9, 9);
    d.end_draw(again, 9);
    try std.testing.expect(d.slot_for(9).? == again);
}
