//! The books in the library: the Kindle's own, listed by its catalog, and EPUBs
//! copied over the cable, found here.
const std = @import("std");
const dir = @import("../sys/dir.zig");
const epub = @import("../epub/epub.zig");
const catalog = @import("../model/catalog.zig");
const file = @import("../sys/file.zig");
const kfx = @import("../kindle/kfx.zig");
const state = @import("../sys/state.zig");
const catalog_db = @import("../kindle/catalog.zig");
const app = @import("../app.zig");
const series_screen = @import("series.zig");

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    data: []const u8,
    entries: []catalog.Entry,
    visible: []usize,

    pub fn deinit(l: *Library) void {
        l.arena.deinit();
        file.unmap(l.data);
    }

    pub fn local_count(l: *const Library) usize {
        var n: usize = 0;
        for (l.entries) |e| {
            if (e.is_local()) n += 1;
        }
        return n;
    }
};

/// EPUBs copied over the cable. The Kindle's catalog doesn't list them, so noface finds
/// them itself, reading title and author from each book, and its cover once into a file
/// beside the book's state.
fn add_epubs(a: *app.App, alloc: std.mem.Allocator, catalog_entries: []catalog.Entry) ![]catalog.Entry {
    const paths = dir.find_files(alloc, a.documents, ".epub") catch return catalog_entries;
    if (paths.len == 0) return catalog_entries;
    var out: std.ArrayList(catalog.Entry) = .empty;
    try out.appendSlice(alloc, catalog_entries);
    var path_buf: [320]u8 = undefined;
    var cover_buf: [320]u8 = undefined;
    next: for (paths) |path| {
        for (catalog_entries) |e| {
            if (std.mem.eql(u8, e.path, path)) continue :next;
        }
        const data = file.map(path) catch continue;
        defer file.unmap(data);
        const state_path = try a.state_path(&path_buf, path);
        const cover_path = try state.sibling(&cover_buf, state_path, "cover");
        const have_cover = if (file.map(cover_path)) |c| blk: {
            file.unmap(c);
            break :blk true;
        } else |_| false;
        const about = epub.info(alloc, data, !have_cover) catch continue;
        if (about.cover) |bytes| state.write_small(cover_path, bytes);
        const saved = state.load(state_path);
        try out.append(alloc, .{
            .path = path,
            .title = if (about.title.len > 0) about.title else std.fs.path.stem(path),
            .author = about.author,
            .percent = @min(saved.percent orelse 0, 100),
            .finished = saved.finished,
            .last = saved.opened,
            .seconds_read = saved.seconds,
            .thumbnail = if (have_cover or about.cover != null) try alloc.dupeSentinel(u8, cover_path, 0) else "",
            .kind = "EPUB",
            // The book's own metadata first, else its file name, as for Kindle books
            .series = if (about.series.len > 0) about.series else if (catalog.series_from_file_name(path)) |f| f.name else "",
            .series_index = if (about.series.len > 0) about.series_index else if (catalog.series_from_file_name(path)) |f| f.index else 0,
        });
    }
    return out.items;
}

/// The catalog's downloading flag can stay set long after a download ended, so
/// the file decides: a partial book points past its own end.
pub fn is_complete_book(path: [:0]const u8) bool {
    if (path.len == 0) return false;
    const data = file.map(path) catch return false;
    defer file.unmap(data);
    return kfx.is_complete(data);
}

pub fn load_library(a: *app.App) !Library {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const data = try file.map(a.library_path);
    const entries = try catalog_db.parse(alloc, data);
    var path_buf: [320]u8 = undefined;
    for (entries) |*e| {
        if (e.availability == .downloading and is_complete_book(e.path)) e.availability = .local;
        if (!e.is_local()) continue;
        const saved = state.load(try a.state_path(&path_buf, e.path));
        e.seconds_read = saved.seconds;
        if (state.prefer_kindle(saved, e.kindle_last)) continue;
        if (saved.percent) |p| e.percent = @min(p, 100);
        e.last = @max(e.last, saved.opened);
    }
    const all = try add_epubs(a, alloc, entries);
    series_screen.apply(alloc, a.state_dir, all); // Series set by hand win
    // Allocated before the arena is copied into the result: a block it adds after
    // would be known only to this copy, and never freed
    const visible = try alloc.alloc(usize, all.len);
    return .{ .arena = arena, .data = data, .entries = all, .visible = visible };
}
