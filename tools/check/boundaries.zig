//! Fails when a source file imports across an ownership boundary, or has tests that
//! src/tests.zig doesn't list (they'd never run). Run with `zig build check`.
//! Usage: boundaries <src dir>
//!
//! Who may import whom, by top-level folder of src/:
//!   base    Building blocks for everything: memory budgets, checks. Imports only base.
//!   sys     The system: files, processes, time, and the calls behind them (Linux's
//!           own on the Kindle, the C library's elsewhere). Imports only sys.
//!   model   Our data: books, settings, library. Imports only model.
//!   gfx     Pixels and fonts. Imports gfx and sys.
//!   layout  Setting text into pages. Imports layout, model and gfx.
//!   ui      Drawing screens and mapping taps. Imports ui, model, layout and gfx.
//!   kindle  Everything that knows Amazon. Imports kindle, sys and model.
//!   epub    The open EPUB format, read into our model. Imports epub and model.
//!   library The library's index on the user drive: its books found, kept, sorted and
//!           read back in memory of a fixed size. Imports library, sys, model, epub
//!           and kindle.
//!   testing What only the tests use: the pretend Kindle. Imports
//!           testing, kindle, sys and model. No folder above may import it.
//!   screens The screens on the stack: what's shown and what taps do. Imports anything
//!           but testing.
//!   (top)   Files at the top of src/: the App and what it's made of (display, regions,
//!           user data, languages, typefaces), and the programs' roots. The App's parts
//!           import anything but screens and testing, as screens build on them; the
//!           roots (`roots`), which put screens and the App together, or give the tools
//!           what they use, import anything.
//!   text    What a character is (a letter, a mark, a space) and its plain form, by
//!           Unicode's tables. Imports only text; text/unicode.zig alone imports
//!           uucode, noface's one dependency, so the whole of Unicode is reached
//!           through it.
//! Every folder may import base and text.
const std = @import("std");
const assert = std.debug.assert;

const Rule = struct { folder: []const u8, allowed: []const []const u8 };

const rules = [_]Rule{
    .{ .folder = "base", .allowed = &.{"base"} },
    .{ .folder = "text", .allowed = &.{"text"} },
    .{ .folder = "sys", .allowed = &.{"sys"} },
    .{ .folder = "model", .allowed = &.{"model"} },
    .{ .folder = "gfx", .allowed = &.{ "gfx", "sys" } },
    .{ .folder = "layout", .allowed = &.{ "layout", "model", "gfx" } },
    .{ .folder = "ui", .allowed = &.{ "ui", "model", "layout", "gfx" } },
    .{ .folder = "kindle", .allowed = &.{ "kindle", "sys", "model" } },
    .{ .folder = "epub", .allowed = &.{ "epub", "model" } },
    .{ .folder = "library", .allowed = &.{ "library", "sys", "model", "epub", "kindle" } },
    .{ .folder = "testing", .allowed = &.{ "testing", "kindle", "sys", "model" } },
    .{ .folder = "screens", .allowed = &(.{"screens"} ++ app_parts) },
    .{ .folder = "", .allowed = &app_parts },
};

/// What the App's parts at the top of src/, and the screens on them, may use.
const app_parts = .{ "", "sys", "model", "gfx", "layout", "ui", "kindle", "epub", "library" };

/// The files at the top of src/ that put a program together: a program's start, the
/// App's assembly with what the library needs reserved, the tests' lists, and what the
/// tools in tools/ reach src/ through.
const roots = [_][]const u8{
    "main.zig", "setup.zig", "scenarios.zig", "tests.zig", "core.zig", "layouts.zig",
};

const import_prefix = "@import(\"";
/// The one file that may import uucode, Unicode's tables.
const unicode_file = "text/unicode.zig";
const uucode_import = "@import(\"uucode\")";
/// What every folder may import: building blocks with no folder's knowledge in them.
const shared = [_][]const u8{ "base", "text" };
/// The longest path inside src/ an import may resolve to.
const resolved_size_max = 256;

comptime {
    for (rules) |rule| {
        // A folder may always use its own files, and lists itself first.
        assert(std.mem.eql(u8, rule.allowed[0], rule.folder));
        // Only the tests may use the pretend Kindle.
        if (!std.mem.eql(u8, rule.folder, "testing")) {
            for (rule.allowed) |allowed| assert(!std.mem.eql(u8, allowed, "testing"));
        }
    }
}

/// The top-level folder of a path inside src/, or "" for files at the top.
fn folder_of(path: []const u8) []const u8 {
    assert(path.len > 0);
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return "";
    const folder = path[0..slash];
    assert(folder.len < path.len);
    return folder;
}

/// Where an import in `file` points, relative to src/, or null if it leaves src/.
fn resolve(buffer: []u8, file: []const u8, target: []const u8) ?[]const u8 {
    assert(std.mem.endsWith(u8, file, ".zig"));
    assert(std.mem.endsWith(u8, target, ".zig"));
    const folder = std.fs.path.dirname(file) orelse "";
    const parts: []const []const u8 = &.{ "/src", folder, target };
    const joined = std.fs.path.resolvePosix(std.heap.page_allocator, parts) catch return null;
    if (!std.mem.startsWith(u8, joined, "/src/")) return null;
    const relative = joined["/src/".len..];
    assert(!std.mem.startsWith(u8, relative, "/"));
    if (relative.len > buffer.len) return null;
    @memcpy(buffer[0..relative.len], relative);
    return buffer[0..relative.len];
}

/// Problems in one file, as "file: imports target" lines. Returns how many.
pub fn check(
    file: []const u8,
    source: []const u8,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !u32 {
    assert(std.mem.endsWith(u8, file, ".zig"));
    const out_size_before = out.items.len;
    var found: u32 = 0;
    // Unicode is reached through one file, whatever the folder: roots too
    const imports_uucode = std.mem.indexOf(u8, source, uucode_import) != null;
    if (imports_uucode and !std.mem.eql(u8, file, unicode_file)) {
        found += 1;
        try out.print(allocator, "{s}: imports uucode (only {s} may)\n", .{ file, unicode_file });
    }
    const from = folder_of(file);
    for (roots) |root| {
        if (std.mem.eql(u8, file, root)) return found;
    }
    const rule = for (rules) |r| {
        if (std.mem.eql(u8, r.folder, from)) break r;
    } else return found;
    var at: u32 = 0;
    while (std.mem.indexOfPos(u8, source, at, import_prefix)) |start| {
        const name_start = start + import_prefix.len;
        const end = std.mem.indexOfScalarPos(u8, source, name_start, '"') orelse break;
        at = @intCast(end);
        const target = source[name_start..end];
        if (!std.mem.endsWith(u8, target, ".zig")) continue; // The standard library and modules
        var buffer: [resolved_size_max]u8 = undefined;
        const resolved = resolve(&buffer, file, target) orelse continue;
        const to = folder_of(resolved);
        const everyones = for (shared) |folder| {
            if (std.mem.eql(u8, folder, to)) break true;
        } else false;
        const ok = everyones or for (rule.allowed) |allowed| {
            if (std.mem.eql(u8, allowed, to)) break true;
        } else false;
        if (!ok) {
            found += 1;
            const what = if (to.len == 0) "top-level files" else to;
            const format = "{s}: imports {s} ({s} may not use {s})\n";
            try out.print(allocator, format, .{ file, resolved, from, what });
        }
    }
    // Each problem is a line of its own.
    assert(out.items.len - out_size_before >= found);
    return found;
}

/// Whether a file has tests of its own.
fn has_tests(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "test ") or
        std.mem.indexOf(u8, source, "\ntest \"") != null or
        std.mem.indexOf(u8, source, "\ntest {") != null;
}

/// Whether src/tests.zig lists `file`, so its tests run with `zig build test`.
fn listed(tests_source: []const u8, file: []const u8) bool {
    assert(file.len > 0);
    assert(std.mem.endsWith(u8, file, ".zig"));
    var at: u32 = 0;
    while (std.mem.indexOfPos(u8, tests_source, at, file)) |index| {
        at = @intCast(index + 1);
        const end = index + file.len;
        const quote_before = index > 0 and tests_source[index - 1] == '"';
        const quote_after = end < tests_source.len and tests_source[end] == '"';
        if (quote_before and quote_after) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.Usage;
    const io = init.io;
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    var out: std.ArrayList(u8) = .empty;
    var problems: u32 = 0;
    const tests_source = try dir.readFileAlloc(io, "tests.zig", allocator, .limited(1 << 20));
    var unlisted: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(4 << 20));
        problems += try check(entry.path, source, &out, allocator);
        const is_list = std.mem.eql(u8, entry.path, "tests.zig");
        if (has_tests(source) and !is_list and !listed(tests_source, entry.path)) {
            unlisted += 1;
            const format = "{s}: has tests, but src/tests.zig doesn't list it, so they never run\n";
            try out.print(allocator, format, .{entry.path});
        }
    }
    if (problems + unlisted > 0) {
        std.debug.print("{s}{d} imports cross a boundary, {d} files of tests left out\n", .{
            out.items,
            problems,
            unlisted,
        });
        std.process.exit(1);
    }
    assert(out.items.len == 0);
    std.debug.print("boundaries ok, every test listed\n", .{});
}

test "imports are judged by folder" {
    const expect_problems = struct {
        fn expect_problems(expected: u32, file: []const u8, source: []const u8) !void {
            const allocator = std.testing.allocator;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            try std.testing.expectEqual(expected, try check(file, source, &out, allocator));
        }
    }.expect_problems;
    try expect_problems(0, "model/a.zig", "const b = @import(\"b.zig\");");
    try expect_problems(1, "model/a.zig", "const k = @import(\"../kindle/kfx.zig\");");
    try expect_problems(0, "screens/a.zig", "const k = @import(\"../kindle/kfx.zig\");");
    try expect_problems(1, "ui/a.zig", "const p = @import(\"../sys/os.zig\");");
    try expect_problems(0, "ui/a.zig", "const std = @import(\"std\");");
    try expect_problems(1, "kindle/a.zig", "const f = @import(\"../testing/fake_kindle.zig\");");
    try expect_problems(1, "screens/a.zig", "const f = @import(\"../testing/fake_kindle.zig\");");
    try expect_problems(0, "screens/a.zig", "const a = @import(\"../app.zig\");");
    // The App's parts are below the screens, and the roots above them
    try expect_problems(1, "app.zig", "const r = @import(\"screens/reader.zig\");");
    try expect_problems(1, "display.zig", "const f = @import(\"testing/fake_kindle.zig\");");
    try expect_problems(0, "setup.zig", "const b = @import(\"screens/books.zig\");");
    try expect_problems(0, "tests.zig", "const f = @import(\"testing/fake_kindle.zig\");");
    // Every folder reaches Unicode through text/, and only text/unicode.zig reaches uucode
    try expect_problems(0, "gfx/a.zig", "const u = @import(\"../text/unicode.zig\");");
    try expect_problems(1, "text/a.zig", "const m = @import(\"../model/book.zig\");");
    try expect_problems(0, "text/unicode.zig", "const u = @import(\"uucode\");");
    try expect_problems(1, "model/a.zig", "const u = @import(\"uucode\");");
    try expect_problems(1, "core.zig", "const u = @import(\"uucode\");");
}

test "a file with tests must be listed" {
    try std.testing.expect(has_tests("const x = 1;\ntest \"a\" {}"));
    try std.testing.expect(!has_tests("// a test of nothing\nconst t = 1;"));
    const list = "    _ = @import(\"model/book.zig\");\n";
    try std.testing.expect(listed(list, "model/book.zig"));
    try std.testing.expect(!listed(list, "book.zig"));
    try std.testing.expect(!listed(list, "model/catalog.zig"));
}
