//! The on-screen keyboard along the bottom of the screen, laid out as the Kindle's own:
//! letters, with shift for a capital or capitals locked; digits and the common symbols
//! (123); the rest of them (#+=). A letter held shows its accented forms in a row over
//! the keys, to tap. What's drawn and where a tap lands are here, for a `State` the
//! typing screen keeps (screens/typing.zig), which says what a key does.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;
const icons = @import("icons.zig");
const unicode = @import("../text/unicode.zig");
const centered = draw.centered; // Named apart from the label's own draw method

/// Which keys show: the letters, the digits and common symbols, or the rest.
pub const Layer = enum { letters, symbols, more };
/// Whether letters come out capitals: off, for the next letter, or until turned off.
pub const Shift = enum { off, once, locked };

/// What the keyboard shows, kept by the screen typing on it.
pub const State = struct {
    layer: Layer = .letters,
    shift: Shift = .off,
    /// A letter held, its accented forms shown over the keys, or none.
    accents: ?Held = null,
};

/// A letter held down: which, and where its key is, for its accents to show over it.
pub const Held = struct { letter: u8, row: u32, center_x: i32 };

pub const Key = union(enum) { char: u21, backspace, space, enter, shift, layer: Layer };

/// The rows of characters on each layer: two full rows, then a shorter one between a
/// key either side. The bottom row is the layer key, space and Search.
const letter_rows = [_][]const u8{ "qwertyuiop", "asdfghjkl", "zxcvbnm" };
const symbol_rows = [_][]const u8{ "1234567890", "-/:;()$&@\"", ".,?!'" };
const more_rows = [_][]const u8{ "[]{}#%^*+=", "_\\|~<>\u{20ac}\u{a3}\u{a5}\u{2022}", ".,?!'" };

/// The accented forms of a letter, shown when it's held, as the Kindle's own keyboard
/// has them for the languages written in Latin letters.
const accent_table = [_]struct { letter: u8, forms: []const u8 }{
    .{ .letter = 'a', .forms = "\u{e0}\u{e1}\u{e2}\u{e4}\u{e3}\u{e5}\u{e6}\u{101}" },
    .{ .letter = 'c', .forms = "\u{e7}\u{107}\u{10d}" },
    .{ .letter = 'e', .forms = "\u{e8}\u{e9}\u{ea}\u{eb}\u{113}\u{117}\u{119}" },
    .{ .letter = 'i', .forms = "\u{ee}\u{ef}\u{ed}\u{12b}\u{12f}\u{ec}" },
    .{ .letter = 'l', .forms = "\u{142}" },
    .{ .letter = 'n', .forms = "\u{f1}\u{144}" },
    .{ .letter = 'o', .forms = "\u{f4}\u{f6}\u{f2}\u{f3}\u{f5}\u{f8}\u{14d}\u{153}" },
    .{ .letter = 's', .forms = "\u{df}\u{15b}\u{161}" },
    .{ .letter = 'u', .forms = "\u{fb}\u{fc}\u{f9}\u{fa}\u{16b}" },
    .{ .letter = 'y', .forms = "\u{ff}\u{fd}" },
    .{ .letter = 'z', .forms = "\u{17e}\u{17a}\u{17c}" },
};

/// The most accented forms a letter has: a row of them fits the screen.
const accents_max = 8;

/// The widest row of keys fills the screen's width inside the tray's edge, so the keys
/// grow with the screen; each takes a fingertip's height.
const widest_row: comptime_int = letter_rows[0].len;
const key_width = (style.screen_width - 2 * tray_pad - (widest_row - 1) * gap) / widest_row;
const key_height = style.fingertip;
const gap = style.space.tiny;
const row_step = key_height + gap;
/// Three rows of characters, then the row with space and Search.
const row_count: u32 = letter_rows.len + 1;
const last_chars: u32 = letter_rows.len - 1; // The short row, between two keys
const bottom_row: u32 = letter_rows.len;
/// The tray's edge round the keys: over the first row, under the last, and either side.
const tray_pad = style.space.snug;
/// The keys' first row, and the keyboard's top: its tray's edge over them. Everything
/// from `top` down is the keyboard's to draw.
const keys_top = style.screen_height - row_count * row_step - tray_pad;
pub const top = keys_top - tray_pad;
/// The keys' first row, as a tap's place is: signed.
const keys_top_y: i32 = keys_top;

/// The keys either side of the short row, and the layer key: a key and a half wide.
const side_width = key_width + key_width / 2;
const enter_width = 2 * key_width + gap; // Two keys wide
const enter_left = style.screen_width - tray_pad - enter_width;
const space_left = tray_pad + side_width + gap;
const space_width = enter_left - gap - space_left;

/// A key: where across its row, how wide, and what it is.
const Box = struct { x: i32, w: i32, key: Key };
/// A layer's keys, row by row.
const Layout = [row_count][]const Box;

const layouts = [_]Layout{ lay_out(.letters), lay_out(.symbols), lay_out(.more) };

comptime {
    // Every key is on the screen, below the status strip.
    assert(keys_top > style.status_height);
    assert(keys_top + row_count * row_step <= style.screen_height);
    assert(space_width > 2 * key_width); // Space is the widest key, as it's the most used
    // A key's face, shadow and all, fits inside its tap area.
    assert(key_height > 2 * inset + shadow_drop);
    assert(key_width > 2 * inset);
    // Each layer's rows fit the screen, their keys apart and in order
    for (layouts) |layout| for (layout) |row| {
        for (row[0 .. row.len - 1], row[1..]) |left, right| assert(left.x + left.w < right.x);
        assert(row[0].x >= tray_pad);
        assert(row[row.len - 1].x + row[row.len - 1].w <= style.screen_width - tray_pad);
    };
    // A letter's accents fit one row of keys
    for (accent_table) |a| assert(count_of(a.forms) <= accents_max);
    assert(accents_max * (key_width + gap) - gap <= style.screen_width - 2 * tray_pad);
}

/// How many characters `row` has: written here, so it's UTF-8 or doesn't build.
fn count_of(comptime row: []const u8) comptime_int {
    return std.unicode.utf8CountCodepoints(row) catch @compileError("not UTF-8: " ++ row);
}

/// The characters of `row`, decoded, as keys.
fn decoded(comptime row: []const u8) [count_of(row)]u21 {
    @setEvalBranchQuota(10_000);
    var out: [count_of(row)]u21 = undefined;
    const view = std.unicode.Utf8View.init(row) catch @compileError("not UTF-8: " ++ row);
    var it = view.iterator();
    var i = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) out[i] = cp;
    assert(i == out.len);
    return out;
}

/// Keys for `chars`, centred on the screen, each a key wide.
fn centred_row(comptime chars: []const u21) [chars.len]Box {
    assert(chars.len > 0);
    assert(chars.len <= widest_row);
    const width = chars.len * (key_width + gap) - gap;
    const left = (style.screen_width - width) / 2;
    var boxes: [chars.len]Box = undefined;
    for (chars, &boxes, 0..) |c, *b, i| {
        b.* = .{ .x = left + i * (key_width + gap), .w = key_width, .key = .{ .char = c } };
    }
    return boxes;
}

fn lay_out(comptime layer: Layer) Layout {
    const rows = switch (layer) {
        .letters => letter_rows,
        .symbols => symbol_rows,
        .more => more_rows,
    };
    // Left of the short row: shift on the letters; on the symbols, the other symbols
    const short_left: Key = switch (layer) {
        .letters => .shift,
        .symbols => .{ .layer = .more },
        .more => .{ .layer = .symbols },
    };
    const bottom_left: Key = if (layer == .letters) .{ .layer = .symbols } else .{
        .layer = .letters,
    };
    assert(rows.len == letter_rows.len); // Three rows of characters on every layer
    const first = centred_row(&decoded(rows[0]));
    const second = centred_row(&decoded(rows[1]));
    const short_chars = centred_row(&decoded(rows[2]));
    const backspace_x = style.screen_width - tray_pad - side_width;
    const short = [_]Box{.{ .x = tray_pad, .w = side_width, .key = short_left }} ++ short_chars ++
        [_]Box{.{ .x = backspace_x, .w = side_width, .key = .backspace }};
    const bottom = [_]Box{
        .{ .x = tray_pad, .w = side_width, .key = bottom_left },
        .{ .x = space_left, .w = space_width, .key = .space },
        .{ .x = enter_left, .w = enter_width, .key = .enter },
    };
    const kept = struct {
        const a = first;
        const b = second;
        const c = short;
        const d = bottom;
    };
    return .{ &kept.a, &kept.b, &kept.c, &kept.d };
}

/// The row a tap at `y` is on, or null above the keys or below them.
fn row_at(y: i32) ?u32 {
    if (y < keys_top_y) return null;
    const row: u32 = @intCast(@divTrunc(y - keys_top_y, row_step));
    if (row >= row_count) return null;
    assert(keys_top_y + @as(i32, @intCast(row)) * row_step <= y); // On it, not under it
    return row;
}

/// The key of `boxes` a tap at `x` is on: each takes the gap after it too.
fn box_at(boxes: []const Box, x: i32) ?Box {
    assert(boxes.len > 0);
    for (boxes) |b| {
        if (x >= b.x and x < b.x + b.w + gap) return b;
    }
    return null;
}

/// The key under a tap at (`x`, `y`) as `state` shows the keys, or null for none. With
/// a letter's accents shown, see `accent_at` first.
pub fn hit(state: State, x: i32, y: i32) ?Key {
    assert(@backingInt(state.layer) < layouts.len);
    const row = row_at(y) orelse return null;
    const b = box_at(layouts[@backingInt(state.layer)][row], x) orelse return null;
    return b.key;
}

/// The letter under a hold at (`x`, `y`), if it has accents to show.
pub fn held_letter(state: State, x: i32, y: i32) ?Held {
    assert(state.accents == null); // One letter's accents show at a time
    const row = row_at(y) orelse return null;
    const b = box_at(layouts[@backingInt(state.layer)][row], x) orelse return null;
    const c = switch (b.key) {
        .char => |c| c,
        .backspace, .space, .enter, .shift, .layer => return null,
    };
    if (c >= 0x80) return null;
    const letter: u8 = @intCast(c);
    if (forms_of(letter) == null) return null;
    return .{ .letter = letter, .row = row, .center_x = b.x + @divTrunc(b.w, 2) };
}

/// A letter's accented forms, decoded, or null when it has none.
fn forms_of(letter: u8) ?[]const u21 {
    assert(letter < 0x80); // A key's own letter, before any accent
    inline for (accent_table) |a| {
        if (a.letter == letter) {
            const kept = struct {
                const forms = decoded(a.forms);
            };
            return &kept.forms;
        }
    }
    return null;
}

/// The row the accents of a letter on row `held_row` show on: the row over it, or for
/// the top row, the one under it.
fn accents_row(held_row: u32) u32 {
    assert(held_row < row_count);
    return if (held_row > 0) held_row - 1 else held_row + 1;
}

/// Where the accents of `held` are: a row of keys centred over it, kept on the screen.
fn accents_left(held: Held, count: u32) i32 {
    assert(count > 0);
    assert(count <= accents_max);
    const width: i32 = @intCast(count * (key_width + gap) - gap);
    const left = held.center_x - @divTrunc(width, 2);
    return std.math.clamp(left, tray_pad, style.screen_width - tray_pad - width);
}

/// The accented form under a tap at (`x`, `y`), with a letter's accents shown, or null
/// when the tap is elsewhere.
pub fn accent_at(state: State, x: i32, y: i32) ?u21 {
    const held = state.accents orelse return null;
    const forms = forms_of(held.letter).?; // Shown only for a letter that has some
    assert(forms.len <= accents_max);
    const row = row_at(y) orelse return null;
    if (row != accents_row(held.row)) return null;
    const left = accents_left(held, @intCast(forms.len));
    if (x < left) return null;
    const index: u32 = @intCast(@divTrunc(x - left, key_width + gap));
    if (index >= forms.len) return null;
    return forms[index];
}

/// The middle of a key's taps, on the first layer that has it: a letter on the
/// letters, a digit or symbol on the symbols. Space, backspace and Search are in the
/// same place on every layer.
pub fn place(target: Key) style.Point {
    for (layouts, 0..) |layout, l| for (layout, 0..) |row, r| for (row) |b| {
        if (!std.meta.eql(b.key, target)) continue;
        const point: style.Point = .{
            .x = b.x + @divTrunc(b.w, 2),
            .y = keys_top_y + @as(i32, @intCast(r)) * row_step + key_height / 2,
        };
        const shown: State = .{ .layer = @fromBackingInt(@intCast(l)) };
        assert(std.meta.eql(hit(shown, point.x, point.y), target));
        return point;
    };
    unreachable; // A key the keyboard has
}

/// The middle of the accented form `index` of `held`'s, for the tests to tap.
pub fn accent_place(held: Held, index: u32) style.Point {
    const forms = forms_of(held.letter).?;
    assert(index < forms.len);
    const left = accents_left(held, @intCast(forms.len));
    const point: style.Point = .{
        .x = left + @as(i32, @intCast(index)) * (key_width + gap) + key_width / 2,
        .y = keys_top_y + @as(i32, @intCast(accents_row(held.row))) * row_step + key_height / 2,
    };
    assert(accent_at(.{ .accents = held }, point.x, point.y) == forms[index]);
    return point;
}

/// The character a key types with `shift` as it is: a letter in capitals while shifted.
pub fn typed(c: u21, shift: Shift) u21 {
    assert(c <= unicode.code_point_max);
    if (shift == .off or !unicode.is_letter(c)) return c;
    const capital = unicode.uppercase(c);
    assert(capital <= unicode.code_point_max);
    return capital;
}

// The keys sit on a light gray tray, white with rounded corners and a soft shadow
const tray = 0xe2;
const shadow = 0xa8;
const special = 0xc4; // Delete, shift and the layer keys: a step darker than letters
const corner = style.key_corner;
// Drawn a little inside their tap area, so neighbours have a clear gap
const inset = style.space.hair;
/// How far a key's shadow shows under its face.
const shadow_drop = style.space.hair;
/// The ring round an accented form, so the row of them stands out over the keys.
const ring = style.space.tiny;

comptime {
    // The backspace and shift icons stay inside their keys
    assert(side_width / 2 >= icons.backspace_left);
    assert(side_width / 2 >= icons.backspace_right);
}

fn key_face(page: Page, x: i32, y: u32, w: i32, face: u8) void {
    assert(x + inset >= 0);
    assert(w > 2 * inset);
    const left: u32 = @intCast(x + inset);
    const width: u32 = @intCast(w - 2 * inset);
    const height = key_height - 2 * inset;
    page.round_rect(left, y + inset + shadow_drop, width, height, corner, shadow);
    page.round_rect(left, y + inset, width, height, corner, face);
}

fn label(fonts: Fonts, page: Page, x: i32, y: u32, w: i32, text: []const u8) !void {
    assert(y >= keys_top);
    assert(text.len > 0);
    const center_x: f32 = @floatFromInt(x + @divTrunc(w, 2));
    const baseline = fonts.small.centred_baseline(@intCast(y), key_height);
    try draw.centered(fonts.small, page, center_x, baseline, text);
}

/// The keys of `state`'s layer, and over them a held letter's accents.
pub fn render(fonts: Fonts, page: Page, state: State) !void {
    assert(page.height > keys_top);
    assert(page.width >= enter_left + enter_width);
    page.fill_rect(0, top, page.width, page.height - top, tray);
    for (layouts[@backingInt(state.layer)], 0..) |row, r| {
        const y: u32 = keys_top + @as(u32, @intCast(r)) * row_step;
        for (row) |b| try render_key(fonts, page, b, y, state.shift);
    }
    if (state.accents) |held| try render_accents(fonts, page, held, state.shift);
}

fn render_key(fonts: Fonts, page: Page, b: Box, y: u32, shift: Shift) !void {
    assert(y >= keys_top);
    assert(b.w > 0);
    const cx: f32 = @floatFromInt(b.x + @divTrunc(b.w, 2));
    const cy: f32 = @floatFromInt(y + key_height / 2);
    switch (b.key) {
        .char => |c| {
            key_face(page, b.x, y, b.w, style.white);
            var bytes: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(typed(c, shift), &bytes) catch return;
            try label(fonts, page, b.x, y, b.w, bytes[0..length]);
        },
        .space => {
            key_face(page, b.x, y, b.w, style.white);
            try label(fonts, page, b.x, y, b.w, "space");
        },
        .backspace => {
            key_face(page, b.x, y, b.w, special);
            icons.backspace(page, cx, cy);
        },
        .layer => |to| {
            key_face(page, b.x, y, b.w, special);
            const text = switch (to) {
                .letters => "ABC",
                .symbols => "123",
                .more => "#+=",
            };
            try label(fonts, page, b.x, y, b.w, text);
        },
        .shift => switch (shift) {
            .off => {
                key_face(page, b.x, y, b.w, special);
                icons.shift(page, cx, cy, false);
            },
            // On: black like a key that's on, its arrow in white
            .once, .locked => {
                key_face(page, b.x, y, b.w, style.black);
                const arrow = WhiteShift{ .locked = shift == .locked };
                const x: i32 = @intFromFloat(cx);
                const y_mid: i32 = @intFromFloat(cy);
                try icons.draw_white(page, side_width, key_height, x, y_mid, arrow);
            },
        },
        .enter => try render_enter(fonts, page, b, y),
    }
}

/// The shift arrow, drawn in white on a black key.
const WhiteShift = struct {
    locked: bool,
    pub fn draw(s: WhiteShift, tile: Page, cx: f32, cy: f32) !void {
        assert(tile.width == side_width); // Drawn on a tile the size of the key
        assert(tile.height == key_height);
        icons.shift(tile, cx, cy, s.locked);
    }
};

/// The main key: black like a key that's on, shadow and all, its label in white.
fn render_enter(fonts: Fonts, page: Page, b: Box, y: u32) !void {
    assert(b.w == enter_width);
    key_face(page, b.x, y, b.w, style.black);
    const Label = struct {
        fonts: Fonts,
        pub fn draw(l: @This(), t: Page, cx: f32, _: f32) !void {
            // Drawn on a tile the size of the key.
            assert(t.width == enter_width);
            assert(t.height == key_height);
            // Centred in the key, as the other keys' labels are
            const baseline = l.fonts.title.centred_baseline(0, key_height);
            try centered(l.fonts.title, t, cx, baseline, "Search");
        }
    };
    const cx = b.x + @divTrunc(b.w, 2);
    const cy: i32 = @intCast(y + key_height / 2);
    try icons.draw_white(page, enter_width, key_height, cx, cy, Label{ .fonts = fonts });
}

/// A held letter's accented forms, in a row of keys over its own, each ringed in black.
fn render_accents(fonts: Fonts, page: Page, held: Held, shift: Shift) !void {
    const forms = forms_of(held.letter).?; // Shown only for a letter that has some
    assert(forms.len <= accents_max);
    const left = accents_left(held, @intCast(forms.len));
    const y: u32 = keys_top + accents_row(held.row) * row_step;
    for (forms, 0..) |form, i| {
        const x = left + @as(i32, @intCast(i)) * (key_width + gap);
        const ring_left: u32 = @intCast(x + inset - ring);
        const ring_width: u32 = @intCast(key_width - 2 * inset + 2 * ring);
        const ring_height = key_height - 2 * inset + 2 * ring;
        const ring_top = y + inset - ring;
        page.round_rect(ring_left, ring_top, ring_width, ring_height, corner + ring, style.black);
        key_face(page, x, y, key_width, style.white);
        var bytes: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(typed(form, shift), &bytes) catch continue;
        try label(fonts, page, x, y, key_width, bytes[0..length]);
    }
}

test "every key of every layer is where it's tapped" {
    for (layouts, 0..) |layout, l| for (layout, 0..) |row, r| for (row) |b| {
        const x = b.x + @divTrunc(b.w, 2);
        const y = keys_top_y + @as(i32, @intCast(r)) * row_step + key_height / 2;
        const state: State = .{ .layer = @fromBackingInt(@intCast(l)) };
        try std.testing.expectEqual(b.key, hit(state, x, y).?);
    };
    try std.testing.expect(hit(.{}, style.screen_width / 2, keys_top - 1) == null);
}

test "the layers hold letters, digits and symbols, and the keys between them" {
    const q = place(.{ .char = 'q' });
    try std.testing.expectEqual(Key{ .char = 'q' }, hit(.{}, q.x, q.y).?);
    // The digits are on the symbols: where the letters have q, the symbols have 1
    try std.testing.expectEqual(q, place(.{ .char = '1' }));
    // The euro, after six other symbols on the second row of the rest
    const euro_x = place(.{ .char = '_' }).x + 6 * (key_width + gap);
    const more: State = .{ .layer = .more };
    const euro = hit(more, euro_x, place(.{ .char = '_' }).y).?;
    try std.testing.expectEqual(Key{ .char = 0x20ac }, euro);
    // Space, backspace and Search sit alike on every layer
    for ([_]Key{ .space, .backspace, .enter }) |k| {
        const p = place(k);
        for ([_]Layer{ .letters, .symbols, .more }) |layer| {
            try std.testing.expectEqual(k, hit(.{ .layer = layer }, p.x, p.y).?);
        }
    }
}

test "a held letter shows its accents, and a tap on one is that form" {
    const e = place(.{ .char = 'e' });
    const held = held_letter(.{}, e.x, e.y).?;
    try std.testing.expectEqual(@as(u8, 'e'), held.letter);
    const shown: State = .{ .accents = held };
    const acute = accent_place(held, 1);
    try std.testing.expectEqual(@as(u21, 0xe9), accent_at(shown, acute.x, acute.y).?); // é
    try std.testing.expect(accent_at(shown, e.x, e.y) == null); // The letter's own key
    // A letter without accents, and a key that isn't a letter, show none
    const t = place(.{ .char = 't' });
    try std.testing.expect(held_letter(.{}, t.x, t.y) == null);
    const sp = place(.space);
    try std.testing.expect(held_letter(.{}, sp.x, sp.y) == null);
    // The top row's accents show under it, and every form of every letter can be tapped
    for (accent_table) |a| {
        const p = place(.{ .char = a.letter });
        const h = held_letter(.{}, p.x, p.y).?;
        for (0..forms_of(a.letter).?.len) |i| _ = accent_place(h, @intCast(i));
    }
}

test "a letter typed while shifted is a capital, accents too; digits and symbols are as they are" {
    try std.testing.expectEqual(@as(u21, 'A'), typed('a', .once));
    try std.testing.expectEqual(@as(u21, 0xc9), typed(0xe9, .locked)); // É
    try std.testing.expectEqual(@as(u21, 'a'), typed('a', .off));
    try std.testing.expectEqual(@as(u21, '1'), typed('1', .locked));
    try std.testing.expectEqual(@as(u21, '?'), typed('?', .once));
}
