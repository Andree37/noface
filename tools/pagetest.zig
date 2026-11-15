//! Shows real book pages in each e-ink waveform so they can be compared by eye.
//! Saves the screen first and restores it when done.
const std = @import("std");
const assert = std.debug.assert;
const book_model = core.book;
const Page = core.page.Page;
const Font = core.font.Font;
const core = @import("core");
const now_us = core.os.now_us;
const sleep_ms = core.os.sleep_ms;
const linux = std.os.linux;
const file = core.file;
const hwtcon = core.hwtcon;
const kfx = core.kfx;
const text = core.text;

const Case = struct {
    name: []const u8,
    waveform: hwtcon.Waveform,
    mode: hwtcon.UpdateMode,
    /// Shown in black and white only, as these waveforms can't draw grays.
    mono: bool,
};

const cases = [_]Case{
    .{ .name = "1 of 7: GC16 full", .waveform = .gc16, .mode = .full, .mono = false },
    .{ .name = "2 of 7: GC16 partial", .waveform = .gc16, .mode = .partial, .mono = false },
    .{ .name = "3 of 7: REAGL", .waveform = .reagl, .mode = .partial, .mono = false },
    .{ .name = "4 of 7: GL16", .waveform = .gl16, .mode = .partial, .mono = false },
    .{ .name = "5 of 7: DU4", .waveform = .du4, .mode = .partial, .mono = false },
    .{ .name = "6 of 7: DU", .waveform = .du, .mode = .partial, .mono = true },
    .{ .name = "7 of 7: A2", .waveform = .a2, .mode = .partial, .mono = true },
};

/// Front matter is skipped: the pages start in the first paragraph longer than this.
const long_paragraph_size_min = 2000;
/// How long the clean page and then the page in the case's waveform stay up.
const settle_ms = 1000;
const look_ms = 4000;

comptime {
    // Each case's label says which of how many it is.
    assert(cases.len == 7);
    for (cases, 1..) |case, number| {
        assert(case.name[0] == '0' + number);
        if (case.mono) assert(case.waveform == .du or case.waveform == .a2);
    }
}

var stop_requested = std.atomic.Value(bool).init(false);

fn on_signal(signal: linux.SIG) callconv(.c) void {
    assert(signal == .TERM or signal == .INT or signal == .HUP);
    stop_requested.store(true, .release);
}

/// Stop cleanly on TERM, INT or HUP so the screen still gets restored.
fn install_signals() void {
    assert(!stop_requested.load(.acquire));
    var action = std.mem.zeroes(linux.Sigaction);
    action.handler = .{ .handler = on_signal };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |signal| _ = linux.sigaction(signal, &action, null);
}

/// Shows `source` in one waveform and mode, and returns how long the refresh took.
fn show(
    screen: *hwtcon.Screen,
    source: []const u8,
    waveform: hwtcon.Waveform,
    mode: hwtcon.UpdateMode,
) !u64 {
    assert(source.len == screen.pixels.len);
    @memcpy(screen.pixels, source);
    const start_us = now_us();
    try screen.wait_complete(try screen.update(waveform, mode));
    const end_us = now_us();
    assert(end_us >= start_us);
    return end_us - start_us;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 3) return error.Usage;

    const allocator = std.heap.page_allocator;
    const book = try kfx.parse(allocator, try file.map(argv[1]));
    const font_file = try file.map(argv[2]);

    var screen = try hwtcon.Screen.open();
    const size = screen.pixels.len;

    // 10pt at the panel's 300 ppi is about 42 px.
    var font = try Font.init(font_file, 46, 1.35);
    var label_font = try Font.init(font_file, 30, 1.2);
    const layout = text.Layout{
        .margin_x = 100,
        .margin_top = 90,
        .margin_bottom = 150,
        .indent = 60,
    };

    const pages = [2][]u8{ try allocator.alloc(u8, size), try allocator.alloc(u8, size) };
    const shown = [2][]u8{ try allocator.alloc(u8, size), try allocator.alloc(u8, size) };
    const page_a = screen_page(&screen, pages[0]);
    const page_b = screen_page(&screen, pages[1]);

    // Skip front matter: start in the first long text block.
    var start: book_model.Pos = .{};
    for (book.paragraphs, 0..) |paragraph, index| {
        if (paragraph.text.len > long_paragraph_size_min) {
            start.para = index;
            break;
        }
    }
    if (start.para > 0) assert(book.paragraphs[start.para].text.len > long_paragraph_size_min);

    const render_start_us = now_us();
    const next = try text.render_page(&font, page_a, book.paragraphs, start, layout, null);
    const render_cold_us = now_us();
    assert(next.para >= start.para); // A page never ends before it starts
    _ = try text.render_page(&font, page_b, book.paragraphs, next, layout, null);
    const render_warm_us = now_us();
    std.debug.print("render cold {d} us, warm {d} us\n", .{
        render_cold_us - render_start_us,
        render_warm_us - render_cold_us,
    });

    install_signals();
    const saved = try allocator.alloc(u8, size);
    @memcpy(saved, screen.pixels);
    defer restore_screen(&screen, saved);

    for (&cases) |*case| {
        if (stop_requested.load(.acquire)) break;
        try show_case(&screen, &label_font, case, pages, shown);
    }
    std.debug.print("finished, restoring\n", .{});
}

/// A page the size of the screen, drawn into `pixels` rather than on it.
fn screen_page(screen: *const hwtcon.Screen, pixels: []u8) Page {
    assert(pixels.len == screen.pixels.len);
    assert(pixels.len == @as(u64, screen.height) * screen.stride);
    return .{
        .buf = pixels,
        .width = screen.width,
        .height = screen.height,
        .stride = screen.stride,
    };
}

/// Labels both pages with the case, shows the first cleanly, then flips to the second
/// in the case's waveform, so any ghosting comes from that waveform alone.
fn show_case(
    screen: *hwtcon.Screen,
    label_font: *Font,
    case: *const Case,
    pages: [2][]u8,
    shown: [2][]u8,
) !void {
    assert(shown[0].len == screen.pixels.len);
    assert(shown[1].len == screen.pixels.len);
    for (pages, shown) |source, target| {
        if (case.mono) text.threshold(source, target) else @memcpy(target, source);
        const label_baseline = screen.height - 70;
        const label = screen_page(screen, target);
        try label_font.draw(label, 100, @intCast(label_baseline), case.name);
    }
    // Clean start, so any ghosting comes from this mode alone.
    _ = try show(screen, shown[0], .gc16, .full);
    sleep_ms(settle_ms);
    const flip_us = try show(screen, shown[1], case.waveform, case.mode);
    std.debug.print("{s}: {d} ms\n", .{ case.name, flip_us / 1000 });
    sleep_ms(look_ms);
}

/// Puts back the screen as it was before the test, with a full refresh.
fn restore_screen(screen: *hwtcon.Screen, saved: []const u8) void {
    assert(saved.len == screen.pixels.len);
    @memcpy(screen.pixels, saved);
    const marker = screen.update(.gc16, .full) catch return;
    screen.wait_complete(marker) catch {}; // Ignored: the pixels are back; it's the last step.
}
