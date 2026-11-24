//! An open book's highlights and bookmarks: the lists the reader shows, where they're
//! kept (note_store.zig), and the marks layout shades, rebuilt from the highlights.
//! Read once as the book opens; highlight.zig and bookmark.zig change them after.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const bookmarks = @import("../../model/bookmarks.zig");
const catalog = @import("../../model/catalog.zig");
const highlights = @import("../../model/highlights.zig");
const note_store = @import("note_store.zig");

pub const BookNotes = struct {
    /// Where highlights and bookmarks are kept, chosen as the book opens.
    store: note_store.NoteStore = .off,
    highlights: std.ArrayList(highlights.Highlight) = .empty,
    /// The ID of every highlight stored for the book as it opened, those its text
    /// couldn't place too: a new highlight never takes one (`highlights.free_id`).
    stored_highlight_ids: []const []const u8 = &.{},
    bookmarks: std.ArrayList(bookmarks.Bookmark) = .empty,
    /// What layout shades, rebuilt from highlights.
    marks: std.ArrayList(book_model.Mark) = .empty,

    /// Chooses where the book's notes are kept and reads them, placed in its text.
    /// Everything read lives in `alloc`, the open book's memory.
    pub fn load(
        n: *BookNotes,
        alloc: std.mem.Allocator,
        entry: *const catalog.Entry,
        files: note_store.Files,
        paragraphs: []const book_model.Paragraph,
    ) !void {
        // Read once, into empty lists, as the book opens
        assert(n.highlights.items.len == 0);
        assert(n.bookmarks.items.len == 0);
        n.store = try .choose(alloc, entry, files);
        n.store.renumber(paragraphs); // A 0.2.0 file, numbered as now before it's read
        const highlight_notes = try n.store.read(alloc, .highlight);
        const highlights_read = try highlights.parse(alloc, paragraphs, highlight_notes);
        try n.highlights.appendSlice(alloc, highlights_read);
        // Copied: the notes' ids are the store's
        const ids = try alloc.alloc([]const u8, highlight_notes.len);
        for (ids, highlight_notes) |*id, note| id.* = try alloc.dupe(u8, note.id);
        n.stored_highlight_ids = ids;
        const bookmark_notes = try n.store.read(alloc, .bookmark);
        const bookmarks_read = try bookmarks.parse(alloc, paragraphs, bookmark_notes);
        try n.bookmarks.appendSlice(alloc, bookmarks_read);
        std.debug.print("{d} bookmarks loaded\n", .{n.bookmarks.items.len});
        std.debug.print("{d} highlights loaded\n", .{n.highlights.items.len});
    }

    /// Rebuilds the marks layout shades after highlights change, into one list reused
    /// rather than a new one each time. Layout points at the list given back.
    pub fn rebuild_marks(n: *BookNotes, alloc: std.mem.Allocator) ![]const book_model.Mark {
        n.marks.clearRetainingCapacity();
        for (n.highlights.items) |h| try n.marks.append(alloc, h.mark);
        assert(n.marks.items.len == n.highlights.items.len);
        return n.marks.items;
    }
};
