//! Measures how long each e-ink waveform takes for a full-page flip.
//! Saves the current screen first and restores it when done.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const now_us = core.os.now_us;
const hwtcon = core.hwtcon;

const Case = struct { name: []const u8, waveform: hwtcon.Waveform, mode: hwtcon.UpdateMode };

const cases = [_]Case{
    .{ .name = "GC16 full", .waveform = .gc16, .mode = .full },
    .{ .name = "GC16 partial", .waveform = .gc16, .mode = .partial },
    .{ .name = "GL16 partial", .waveform = .gl16, .mode = .partial },
    .{ .name = "REAGL partial", .waveform = .reagl, .mode = .partial },
    .{ .name = "DU4 partial", .waveform = .du4, .mode = .partial },
    .{ .name = "DU partial", .waveform = .du, .mode = .partial },
    .{ .name = "A2 partial", .waveform = .a2, .mode = .partial },
};

/// Flips per case, alternating between the two pages.
const flips = 4;

/// The fake page's layout: a margin all round, lines of word blocks.
const margin_px = 80;
const line_height_px = 32;
const line_step_px = 64;
const word_width_min_px = 40;
const word_width_spread_px = 140;
const word_gap_px = 24;

comptime {
    // Each case starts from page A and ends on it, so its first flip changes the screen.
    assert(flips % 2 == 0);
    assert(line_height_px < line_step_px);
}

/// Fake page of text: rows of black word-sized blocks on white. `seed` shifts the words.
fn draw_page(pixels: []u8, width: u32, height: u32, stride: u32, seed: u32) void {
    assert(pixels.len == @as(u64, height) * stride);
    @memset(pixels, 0xff);
    var y: u32 = margin_px;
    var line: u32 = seed;
    while (y + line_height_px < height - margin_px) : (y += line_step_px) {
        var x: u32 = margin_px;
        while (x + word_width_min_px < width - margin_px) {
            line = line *% 1103515245 +% 12345;
            const word = word_width_min_px + (line >> 16) % word_width_spread_px;
            const end = @min(x + word, width - margin_px);
            for (y..y + line_height_px) |row| {
                @memset(pixels[row * stride + x .. row * stride + end], 0x00);
            }
            assert(end > x);
            x = end + word_gap_px;
        }
    }
}

pub fn main() !void {
    var screen = try hwtcon.Screen.open();
    std.debug.print("screen {d}x{d} stride {d}\n", .{ screen.width, screen.height, screen.stride });

    const allocator = std.heap.page_allocator;
    const saved = try allocator.alloc(u8, screen.pixels.len);
    const page_a = try allocator.alloc(u8, screen.pixels.len);
    const page_b = try allocator.alloc(u8, screen.pixels.len);
    @memcpy(saved, screen.pixels);
    draw_page(page_a, screen.width, screen.height, screen.stride, 1);
    draw_page(page_b, screen.width, screen.height, screen.stride, 2);
    defer restore_screen(&screen, saved);

    // Blit cost: what a pre-rendered page costs the CPU.
    const blit_start_us = now_us();
    @memcpy(screen.pixels, page_a);
    std.debug.print("blit {d} us\n", .{now_us() - blit_start_us});
    try screen.wait_complete(try screen.update(.gc16, .full));

    for (&cases) |*case| try time_case(&screen, case, page_a, page_b);
}

/// Flips between the two pages in one waveform and mode, and prints how long it took.
fn time_case(
    screen: *hwtcon.Screen,
    case: *const Case,
    page_a: []const u8,
    page_b: []const u8,
) !void {
    assert(page_a.len == screen.pixels.len);
    assert(page_b.len == screen.pixels.len);
    var total_us: u64 = 0;
    var worst_us: u64 = 0;
    for (0..flips) |flip| {
        @memcpy(screen.pixels, if (flip % 2 == 0) page_b else page_a);
        const start_us = now_us();
        const marker = try screen.update(case.waveform, case.mode);
        const queued_us = now_us() - start_us;
        try screen.wait_complete(marker);
        const flip_us = now_us() - start_us;
        total_us += flip_us;
        worst_us = @max(worst_us, flip_us);
        if (flip == 0) std.debug.print("  {s}: queue {d} us\n", .{ case.name, queued_us });
    }
    assert(worst_us <= total_us);
    assert(total_us <= worst_us * flips);
    std.debug.print("{s}: avg {d} ms, worst {d} ms\n", .{
        case.name,
        total_us / flips / 1000,
        worst_us / 1000,
    });
}

/// Puts back the screen as it was before the test, with a full refresh.
fn restore_screen(screen: *hwtcon.Screen, saved: []const u8) void {
    assert(saved.len == screen.pixels.len);
    @memcpy(screen.pixels, saved);
    const marker = screen.update(.gc16, .full) catch return;
    screen.wait_complete(marker) catch {}; // Ignored: the pixels are back; it's the last step.
}
