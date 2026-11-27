//! The scenario tests, noface-scenarios: plays scripted touches through the real app,
//! on a screen in memory and a clock it moves itself, and checks what came of them.
//! Each scenario gets its own folder under /tmp and a generated book, so nothing of the
//! reader's is read or written, and the screen is never touched.
//!
//! Built for Linux: GitHub runs it on every change, and on the Kindle it's the
//! self-test (`noface-scenarios`), done in seconds.
const std = @import("std");
const crash = @import("sys/crash.zig");
const assert = std.debug.assert;
const folders = @import("sys/dir.zig");
const hyphen = @import("layout/hyphen.zig");
const languages = @import("languages.zig");
const file = @import("sys/file.zig");
const fonts_db = @import("kindle/fonts.zig");
const Font = @import("gfx/font.zig").Font;
const catalog = @import("model/catalog.zig");
const kindle_catalog = @import("kindle/catalog.zig");
const annotation_db = @import("kindle/annotation_db.zig");
const safe = @import("kindle/safe.zig");
const annotations = @import("kindle/annotations.zig");
const settings_model = @import("model/settings.zig");
const dictionary = @import("model/dictionary.zig");
const paths = @import("kindle/paths.zig");
const harness = @import("scenarios/harness.zig");
const RealBook = harness.RealBook;
const play_on = harness.play_on;
const real_ms = harness.real_ms;
const selftest_books_opened_max = harness.selftest_books_opened_max;
const selftest_books_tried_max = harness.selftest_books_tried_max;
const write_snapshots = harness.write_snapshots;
const reading = @import("scenarios/reading.zig");
const words = @import("scenarios/words.zig");
const sheets = @import("scenarios/sheets.zig");
const library = @import("scenarios/library.zig");
const kindle = @import("scenarios/kindle.zig");
const looks = @import("scenarios/looks.zig");
const running = @import("scenarios/running.zig");
const resilience = @import("scenarios/resilience.zig");
const elsewhere = @import("scenarios/elsewhere.zig");

/// Shown a crash's message even mid-scenario (main.zig's panic handler calls it).
pub const show_crashes = harness.show_crashes;

/// Every scenario, by what it's about.
const scenarios = reading.all ++ words.all ++ sheets.all ++ library.all ++ kindle.all ++
    looks.all ++ running.all ++ resilience.all ++ elsewhere.all;

comptime {
    // Each scenario is reported by its name, so no two may share one
    @setEvalBranchQuota(100_000);
    for (scenarios, 0..) |s, index| {
        assert(s.name.len > 0);
        for (scenarios[index + 1 ..]) |other| assert(!std.mem.eql(u8, s.name, other.name));
    }
}

/// The panic handler for noface-scenarios: the message reaches the terminal even
/// when it happens mid-scenario.
pub const panic = std.debug.FullPanic(struct {
    fn crash(msg: []const u8, first: ?usize) noreturn { // usize: Zig's panic handler signature
        show_crashes();
        std.debug.defaultPanic(msg, first);
    }
}.crash);

/// Runs every scenario, printing a line for each. The number that failed.
fn run_scenarios() u32 {
    comptime assert(scenarios.len > 0);
    var failed: u32 = 0;
    for (scenarios) |s| {
        const t0 = real_ms();
        if (s.run()) {
            std.debug.print("ok    {s} ({d} ms)\n", .{ s.name, real_ms() - t0 });
        } else |err| {
            failed += 1;
            std.debug.print("FAIL  {s}: {s}\n", .{ s.name, @errorName(err) });
        }
    }
    assert(failed <= scenarios.len);
    const passed = scenarios.len - failed;
    std.debug.print("{d} of {d} scenarios passed\n", .{ passed, scenarios.len });
    return failed;
}

pub fn main(init: std.process.Init.Minimal) !void {
    harness.write_snapshots = init.environ.getPosix("NOFACE_WRITE_SNAPSHOTS");
    if (run_scenarios() > 0) std.process.exit(1);
}

/// `noface selftest`, on the reader's Kindle: the scenarios, then this Kindle's own
/// fonts, dictionaries and a few of its books, opened in memory with nothing saved
/// where the reader's things are. True when everything passed.
pub fn selftest() bool {
    comptime assert(scenarios.len > 0);
    comptime assert(selftest_books_opened_max <= selftest_books_tried_max);
    var ok = run_scenarios() == 0;
    std.debug.print("\nthis Kindle\n", .{});
    ok = selftest_files() and ok;
    ok = selftest_books() and ok;
    const result = if (ok) "everything passed" else "something failed (see FAIL above)";
    std.debug.print("\nselftest: {s}\n", .{result});
    return ok;
}

/// This Kindle's own fonts, the dictionaries if installed, and the picture helper.
fn selftest_files() bool {
    comptime assert(settings_model.builtin_families.len > 0);
    var ok = true;
    for (settings_model.builtin_families, 0..) |name, i| {
        const path = (fonts_db.Offered{}).path(@intCast(i), false, false);
        const usable = if (file.map(path)) |data| usable: {
            defer file.unmap(data);
            break :usable Font.usable(data);
        } else |_| false;
        std.debug.print("{s}  font {s}\n", .{ if (usable) "ok  " else "FAIL", name });
        ok = ok and usable;
    }
    // A crash's report names the build, to read it in that build's symbols
    var id_buffer: [crash.build_id_bytes_max]u8 = undefined;
    const id = crash.build_id(&id_buffer);
    std.debug.print("{s}  build ID, {d} bytes\n", .{ if (id.len > 0) "ok  " else "FAIL", id.len });
    ok = ok and id.len > 0;
    // Each language's, by the name the app looks it up by
    for (std.enums.values(hyphen.Lang)) |lang| {
        const name = languages.dictionary_file(lang);
        var buf: [file.own_path_bytes_max]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(
            &buf,
            paths.data_dir ++ "/{s}",
            .{name},
            0,
        ) catch continue;
        const data = file.map(path) catch {
            std.debug.print("--    {s} not installed\n", .{name});
            continue;
        };
        defer file.unmap(data); // Tens of MB each, in an address space the scenarios crowd
        const readable = dictionary.Dictionary.open(data) != null;
        std.debug.print("{s}  {s}\n", .{ if (readable) "ok  " else "FAIL", name });
        ok = ok and readable;
    }
    const helper = file.exists(paths.jxr_helper);
    std.debug.print("{s}  picture helper (jxr2pgm)\n", .{if (helper) "ok  " else "FAIL"});
    return ok and helper;
}

/// A few of the reader's books, each opened to its first page with its own highlights
/// and bookmarks: they come from outside noface, and must never stop a book opening.
// Assertions: it lists the reader's own books, outside data, and reports on them
fn selftest_books() bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A list that can't be read opens no book: said, and failed, so a run that opened
    // none never reports everything passed
    var ok = true;
    if (selftest_epubs(alloc)) |epubs| {
        ok = selftest_open("epub", epubs) and ok;
    } else |err| {
        std.debug.print("FAIL  listing epub books: {s}\n", .{@errorName(err)});
        ok = false;
    }
    if (selftest_kindle_books(alloc)) |kindle_books| {
        ok = selftest_open("kfx", kindle_books) and ok;
    } else |err| {
        std.debug.print("FAIL  listing kfx books: {s}\n", .{@errorName(err)});
        ok = false;
    }
    return ok;
}

/// The first EPUBs in the documents folder. Their notes are in noface's own files,
/// beside places a run never reads, so they open without any.
fn selftest_epubs(alloc: std.mem.Allocator) ![]const RealBook {
    const found = try folders.find_files(alloc, paths.documents, ".epub");
    const books = try alloc.alloc(RealBook, @min(found.len, selftest_books_tried_max));
    assert(books.len <= selftest_books_tried_max);
    for (books, found[0..books.len]) |*book, path| {
        assert(std.fs.path.isAbsolute(path));
        const name = std.fs.path.stem(path);
        book.* = .{ .entry = .{
            .path = path,
            .title = name,
            .author = "",
            .percent = 0,
            .last = 0,
            .kind = "EPUB",
        } };
    }
    return books;
}

/// The Kindle books read last, from the book list, with their notes as the database
/// has them: those with highlights first.
fn selftest_kindle_books(alloc: std.mem.Allocator) ![]const RealBook {
    const list_path = paths.data_dir ++ "/" ++ paths.data.library;
    const mapped = file.map(list_path) catch |err| switch (err) {
        error.NotFound, error.EmptyFile => return &.{}, // Not exported yet, or no books
        error.OpenFailed, error.SeekFailed, error.MmapFailed => return err,
    };
    const list = try alloc.dupe(u8, mapped); // The entries keep slices of it
    file.unmap(mapped);
    const entries = try kindle_catalog.parse(alloc, list);
    std.sort.block(catalog.Entry, entries, {}, read_later);
    var books: std.ArrayList(RealBook) = .empty;
    const page = try alloc.create(annotation_db.Page);
    for (entries) |entry| {
        if (books.items.len == selftest_books_tried_max) break;
        if (!entry.is_local() or entry.is_epub()) continue;
        if (!file.exists(entry.path)) continue; // Gone since the list was written
        if (!safe.safe_id(entry.key)) continue; // One the notes database can't name
        // Notes that can't be read never stop a book opening: it opens without them
        const highlights = try all_lines(alloc, entry.key, .highlight, page);
        const bookmarks = try all_lines(alloc, entry.key, .bookmark, page);
        try books.append(alloc, .{
            .entry = entry,
            .highlights = highlights orelse "",
            .bookmarks = bookmarks orelse "",
            .notes_unreadable = highlights == null or bookmarks == null,
        });
    }
    std.sort.block(RealBook, books.items, {}, more_highlighted);
    assert(books.items.len <= selftest_books_tried_max);
    assert(books.items.len <= entries.len); // Each one of the list's
    return books.items;
}

/// Every "id|start|end" line the database has of a book's `kind` of notes, a page at a
/// time through `page`, as the pretend Kindle is to answer them; null when it gave no
/// whole answer.
fn all_lines(
    alloc: std.mem.Allocator,
    key: []const u8,
    kind: annotations.Kind,
    page: *annotation_db.Page,
) !?[]const u8 {
    assert(annotation_db.page_rows > 0);
    var lines: std.ArrayList(u8) = .empty;
    var after: annotation_db.After = .{};
    // A page at a time, until one isn't full
    for (0..std.math.maxInt(u32)) |_| {
        const read = annotation_db.read_page(key, kind, page, &after) orelse return null;
        try lines.appendSlice(alloc, read.lines);
        if (read.rows < annotation_db.page_rows) break;
    }
    return lines.items;
}

fn read_later(_: void, a: catalog.Entry, b: catalog.Entry) bool {
    return a.last > b.last;
}

fn more_highlighted(_: void, a: RealBook, b: RealBook) bool {
    return a.highlights.len > 0 and b.highlights.len == 0;
}

/// Opens up to `selftest_books_opened_max` of `books`. Protected ones (most bought from
/// Amazon) open in the Kindle's own reader instead, so they're passed over, not failed.
fn selftest_open(kind: []const u8, books: []const RealBook) bool {
    assert(books.len <= selftest_books_tried_max);
    if (books.len == 0) {
        // Said, so a run with nothing of this kind to open is told from one that passed
        std.debug.print("--    no {s} books to open\n", .{kind});
        return true;
    }
    var ok = true;
    var opened: u32 = 0;
    // Named by kind and number, not title: this report is pasted into public issues
    for (books, 1..) |book, number| {
        assert(opened <= selftest_books_opened_max);
        if (opened == selftest_books_opened_max) break;
        if (play_on(.{ .real_book = book }, &.{})) |r| {
            const highlights = std.mem.count(u8, book.highlights, "\n");
            const line = "ok    opened {s} book {d} ({d} ms, {d} highlights)\n";
            std.debug.print(line, .{ kind, number, r.ms, highlights });
            opened += 1;
        } else |err| switch (err) {
            error.Encrypted, error.Compressed, error.NotKfx => {
                const why = @errorName(err);
                const line = "--    {s} book {d}: not one noface opens ({s})\n";
                std.debug.print(line, .{ kind, number, why });
            },
            else => {
                const line = "FAIL  opened {s} book {d}: {s}\n";
                std.debug.print(line, .{ kind, number, @errorName(err) });
                ok = false;
            },
        }
    }
    return ok;
}
