//! Shows real book pages in each e-ink waveform so they can be compared by eye.
//! Saves the screen first and restores it when done.
const std = @import("std");
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

const Case = struct { name: []const u8, wf: hwtcon.Waveform, mode: hwtcon.UpdateMode, mono: bool };

const cases = [_]Case{
    .{ .name = "1 of 7: GC16 full", .wf = .gc16, .mode = .full, .mono = false },
    .{ .name = "2 of 7: GC16 partial", .wf = .gc16, .mode = .partial, .mono = false },
    .{ .name = "3 of 7: REAGL", .wf = .reagl, .mode = .partial, .mono = false },
    .{ .name = "4 of 7: GL16", .wf = .gl16, .mode = .partial, .mono = false },
    .{ .name = "5 of 7: DU4", .wf = .du4, .mode = .partial, .mono = false },
    .{ .name = "6 of 7: DU", .wf = .du, .mode = .partial, .mono = true },
    .{ .name = "7 of 7: A2", .wf = .a2, .mode = .partial, .mono = true },
};

var stop_requested = std.atomic.Value(bool).init(false);

fn on_signal(_: linux.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

/// Stop cleanly on TERM, INT or HUP so the screen still gets restored.
fn install_signals() void {
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler = .{ .handler = on_signal };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |sig| _ = linux.sigaction(sig, &act, null);
}

fn show(screen: *hwtcon.Screen, src: []const u8, wf: hwtcon.Waveform, mode: hwtcon.UpdateMode) !u64 {
    @memcpy(screen.pixels, src);
    const t0 = now_us();
    try screen.wait_complete(try screen.update(wf, mode));
    return now_us() - t0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 3) return error.Usage;

    const alloc = std.heap.page_allocator;
    const book = try kfx.parse(alloc, try file.map(argv[1]));
    const ttf = try file.map(argv[2]);

    var screen = try hwtcon.Screen.open();
    const size = screen.pixels.len;

    // 10pt at the panel's 300 ppi is about 42 px.
    var font = try Font.init(alloc, ttf, 46, 1.35);
    var label_font = try Font.init(alloc, ttf, 30, 1.2);
    const layout = text.Layout{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60 };

    const a = try alloc.alloc(u8, size);
    const b = try alloc.alloc(u8, size);
    const shown = try alloc.alloc(u8, size);
    const shown_b = try alloc.alloc(u8, size);
    const page = Page{ .buf = a, .width = screen.width, .height = screen.height, .stride = screen.stride };
    const page_b = Page{ .buf = b, .width = screen.width, .height = screen.height, .stride = screen.stride };

    // Skip front matter: start in the first long text block.
    var start: book_model.Pos = .{};
    for (book.paragraphs, 0..) |p, i| {
        if (p.text.len > 2000) {
            start.para = i;
            break;
        }
    }

    const r0 = now_us();
    const next = try text.render_page(&font, page, book.paragraphs, start, layout, null);
    const r1 = now_us();
    _ = try text.render_page(&font, page_b, book.paragraphs, next, layout, null);
    const r2 = now_us();
    std.debug.print("render cold {d} us, warm {d} us\n", .{ r1 - r0, r2 - r1 });

    install_signals();
    const saved = try alloc.alloc(u8, size);
    @memcpy(saved, screen.pixels);
    defer {
        @memcpy(screen.pixels, saved);
        if (screen.update(.gc16, .full)) |m| {
            screen.wait_complete(m) catch {};
        } else |_| {}
    }

    for (cases) |c| {
        if (stop_requested.load(.acquire)) break;
        for ([_][]const u8{ a, b }, [_][]u8{ shown, shown_b }) |src, dst| {
            if (c.mono) text.threshold(src, dst) else @memcpy(dst, src);
            const label = Page{ .buf = dst, .width = screen.width, .height = screen.height, .stride = screen.stride };
            try label_font.draw(label, 100, @intCast(screen.height - 70), c.name);
        }
        // Clean start, so any ghosting comes from this mode alone.
        _ = try show(&screen, shown, .gc16, .full);
        sleep_ms(1000);
        const flip = try show(&screen, shown_b, c.wf, c.mode);
        std.debug.print("{s}: {d} ms\n", .{ c.name, flip / 1000 });
        sleep_ms(4000);
    }
    std.debug.print("finished, restoring\n", .{});
}
