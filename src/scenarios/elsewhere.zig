//! A book the device's own software knows, sent to the Kindle: its place there and on
//! the reader's other devices. One the stock reader left later on this Kindle is opened
//! at; another device's later one is offered on a card; noface's own is kept there as
//! the book closes, and a sync asked for. An EPUB copied over the cable is never asked
//! about.
const std = @import("std");
const assert = std.debug.assert;
const kfx_book = @import("../testing/kfx_book.zig");
const harness = @import("harness.zig");
const Scenario = harness.Scenario;
const Snapshot = harness.Snapshot;
const expect = harness.expect;
const play_on = harness.play_on;
const taps = @import("taps.zig");
const card_row = taps.card_row;
const wait = taps.wait;

/// The sent book, as the scenarios name it.
const sent = [_][]const u8{"book.kfx"};
/// The offer card's rows: Go there, then Stay here (screens/reader/outside_place.zig).
const offer_rows = 2;
const go_there = card_row(offer_rows, 0);
const stay_here = card_row(offer_rows, 1);
/// Long after any run: a place made then is always the later one.
const later_ms = 4_000_000_000_000;
/// The paragraph the places outside noface are at, well into the book.
const there_para = 20;
/// The sync the device is asked for as a book closes.
const sync_asked = "com.lab126.quickactions syncAndCheck 1";

/// A database row: `dataset` (4 Amazon's latest, 8 this Kindle's own), the position of
/// paragraph `there_para`'s start, a later time, and the device that made it.
fn place_row(alloc: std.mem.Allocator, dataset: u32, device: []const u8) ![]const u8 {
    assert(dataset == 4 or dataset == 8);
    const texts = try kfx_book.paragraphs(alloc);
    const position = kfx_book.position_of(&texts, there_para);
    return std.fmt.allocPrint(alloc, "{d}|{d}|{d}|{s}\n", .{ dataset, position, later_ms, device });
}

/// The sent book, its places outside noface as `places` says.
fn sent_with(places: []const u8) harness.Kindle {
    assert(places.len > 0);
    return .{ .books = &sent, .book = .sent, .outside_places = places };
}

pub const all = [_]Scenario{
    .{
        .name = "a sent book opens at the place the stock reader left later on this Kindle, " ++
            "without asking",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const here = try place_row(arena.allocator(), 8, "Local");
                const kindle = sent_with(here);
                const r = try play_on(kindle, &.{wait(500)});
                const opened_there = r.saved.para == there_para;
                try expect(opened_there, "it didn't open at the stock reader's place");
                try expect(r.saved.byte == 0, "it didn't open at the paragraph's start");
            }
        }.run,
    },
    .{
        .name = "another device's later place is offered as a sent book opens: Go there " ++
            "goes to it, Stay here keeps noface's",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const phone = try place_row(arena.allocator(), 4, "Phone");
                const kindle = sent_with(phone);
                const went = try play_on(kindle, &.{ wait(500), go_there });
                // At the page holding the phone's place, whose start the place keeps
                try expect(went.saved.para > 0, "Go there didn't go to the phone's place");
                try expect(went.saved.para <= there_para, "Go there went past the phone's place");
                const stayed = try play_on(kindle, &.{ wait(500), stay_here });
                try expect(stayed.saved.para == 0, "Stay here moved the place");
            }
        }.run,
    },
    .{
        .name = "closing a sent book keeps its place for Amazon and asks a sync; an EPUB " ++
            "copied over is never asked about",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                const kfx: harness.Kindle = .{ .books = &sent, .book = .sent, .sets_into = alloc };
                const closed = try play_on(kfx, &.{wait(500)});
                try expect(closed.annotation_writes > 0, "the place wasn't kept for Amazon");
                try expect(asked(closed.sets, sync_asked), "no sync was asked for");
                const epub = try play_on(.{ .sets_into = alloc }, &.{wait(500)});
                try expect(epub.annotation_writes == 0, "an EPUB's place was written for Amazon");
                try expect(!asked(epub.sets, sync_asked), "a sync was asked for an EPUB");
            }

            fn asked(sets: []const []const u8, wanted: []const u8) bool {
                for (sets) |set| {
                    if (std.mem.eql(u8, set, wanted)) return true;
                }
                return false;
            }
        }.run,
    },
    .{
        .name = "the card offering another device's place looks as it should",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const phone = try place_row(arena.allocator(), 4, "Phone");
                const r = try play_on(.{
                    .books = &sent,
                    .book = .sent,
                    .outside_places = phone,
                    .snapshot = Snapshot.offer,
                }, &.{wait(500)});
                try expect(r.looks_right, "the offer card looks different");
            }
        }.run,
    },
};
