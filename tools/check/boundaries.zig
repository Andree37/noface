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
//!   testing What only the tests and the simulator use: the pretend Kindle. Imports
//!           testing, kindle, sys and model. No folder above may import it.
//!   screens, and files at the top of src/: may import anything.
//! Every folder may import base.
const std = @import("std");

const Rule = struct { folder: []const u8, allowed: []const []const u8 };

const rules = [_]Rule{
    .{ .folder = "base", .allowed = &.{"base"} },
    .{ .folder = "sys", .allowed = &.{"sys"} },
    .{ .folder = "model", .allowed = &.{"model"} },
    .{ .folder = "gfx", .allowed = &.{ "gfx", "sys" } },
    .{ .folder = "layout", .allowed = &.{ "layout", "model", "gfx" } },
    .{ .folder = "ui", .allowed = &.{ "ui", "model", "layout", "gfx" } },
    .{ .folder = "kindle", .allowed = &.{ "kindle", "sys", "model" } },
    .{ .folder = "epub", .allowed = &.{ "epub", "model" } },
    .{ .folder = "testing", .allowed = &.{ "testing", "kindle", "sys", "model" } },
};

/// The top-level folder of a path inside src/, or "" for files at the top.
fn folderOf(path: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

/// Where an import in `file` points, relative to src/, or null if it leaves src/.
fn resolve(buf: []u8, file: []const u8, target: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(file) orelse "";
    const joined = std.fs.path.resolvePosix(std.heap.page_allocator, &.{ "/src", dir, target }) catch return null;
    if (!std.mem.startsWith(u8, joined, "/src/")) return null;
    const rel = joined["/src/".len..];
    if (rel.len > buf.len) return null;
    @memcpy(buf[0..rel.len], rel);
    return buf[0..rel.len];
}

/// Problems in one file, as "file: imports target" lines. Returns how many.
pub fn check(file: []const u8, source: []const u8, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !usize {
    const from = folderOf(file);
    const rule = for (rules) |r| {
        if (std.mem.eql(u8, r.folder, from)) break r;
    } else return 0;
    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, "@import(\"")) |start| {
        const name_start = start + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, source, name_start, '"') orelse break;
        at = end;
        const target = source[name_start..end];
        if (!std.mem.endsWith(u8, target, ".zig")) continue; // std and other modules
        var buf: [256]u8 = undefined;
        const resolved = resolve(&buf, file, target) orelse continue;
        const to = folderOf(resolved);
        const ok = std.mem.eql(u8, to, "base") or for (rule.allowed) |a| {
            if (std.mem.eql(u8, a, to)) break true;
        } else false;
        if (!ok) {
            found += 1;
            try out.print(alloc, "{s}: imports {s} ({s} may not use {s})\n", .{ file, resolved, from, if (to.len == 0) "top-level files" else to });
        }
    }
    return found;
}

/// Whether a file has tests of its own.
fn hasTests(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "test ") or std.mem.indexOf(u8, source, "\ntest \"") != null or
        std.mem.indexOf(u8, source, "\ntest {") != null;
}

/// Whether src/tests.zig lists `file`, so its tests run with `zig build test`.
fn listed(tests_source: []const u8, file: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, tests_source, at, file)) |i| {
        at = i + 1;
        const quoted = i > 0 and tests_source[i - 1] == '"' and i + file.len < tests_source.len and tests_source[i + file.len] == '"';
        if (quoted) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 2) return error.Usage;
    const io = init.io;
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    var out: std.ArrayList(u8) = .empty;
    var problems: usize = 0;
    const tests_source = try dir.readFileAlloc(io, "tests.zig", alloc, .limited(1 << 20));
    var unlisted: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source = try dir.readFileAlloc(io, entry.path, alloc, .limited(4 << 20));
        problems += try check(entry.path, source, &out, alloc);
        if (hasTests(source) and !std.mem.eql(u8, entry.path, "tests.zig") and !listed(tests_source, entry.path)) {
            unlisted += 1;
            try out.print(alloc, "{s}: has tests, but src/tests.zig doesn't list it, so they never run\n", .{entry.path});
        }
    }
    if (problems + unlisted > 0) {
        std.debug.print("{s}{d} imports cross a boundary, {d} files of tests left out\n", .{ out.items, problems, unlisted });
        std.process.exit(1);
    }
    std.debug.print("boundaries ok, every test listed\n", .{});
}

test "imports are judged by folder" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), try check("model/a.zig", "const b = @import(\"b.zig\");", &out, alloc));
    try std.testing.expectEqual(@as(usize, 1), try check("model/a.zig", "const k = @import(\"../kindle/kfx.zig\");", &out, alloc));
    try std.testing.expectEqual(@as(usize, 0), try check("screens/a.zig", "const k = @import(\"../kindle/kfx.zig\");", &out, alloc));
    try std.testing.expectEqual(@as(usize, 1), try check("ui/a.zig", "const p = @import(\"../sys/os.zig\");", &out, alloc));
    try std.testing.expectEqual(@as(usize, 0), try check("ui/a.zig", "const std = @import(\"std\");", &out, alloc));
    try std.testing.expectEqual(@as(usize, 1), try check("kindle/a.zig", "const f = @import(\"../testing/fake_kindle.zig\");", &out, alloc));
}

test "a file with tests must be listed" {
    try std.testing.expect(hasTests("const x = 1;\ntest \"a\" {}"));
    try std.testing.expect(!hasTests("// a test of nothing\nconst t = 1;"));
    const list = "    _ = @import(\"model/book.zig\");\n";
    try std.testing.expect(listed(list, "model/book.zig"));
    try std.testing.expect(!listed(list, "book.zig"));
    try std.testing.expect(!listed(list, "model/catalog.zig"));
}
