//! Looking through the library's index (index.zig) in fixed memory: the books in an
//! order (sorted on the drive when first shown after a change), the ones a filter and a
//! search let through, the page of them on screen, the book to continue, and the totals
//! for the stats. Each look is a pass or two straight through the index's files.
//!
//! An arrangement remembers, every so many books let through, where it is in the
//! order's file: a page is read from the nearest such place, never the whole list.
const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("../model/catalog.zig");
const search = @import("../model/search.zig");
const files = @import("files.zig");
const keys = @import("keys.zig");
const sorter = @import("sorter.zig");
const index = @import("index.zig");
const builder = @import("builder.zig");

/// The most places an arrangement remembers in its order: past them, it keeps every
/// other and remembers half as often, so a page is found from at most `count / 512`
/// books before it.
const checkpoints_max: u32 = 1024;

/// What a filter and a search let through, in an order, and where they are in it.
pub const View = struct {
    order: catalog.Order = .recent,
    count: u32 = 0, // Books let through
    hero: ?u32 = null, // The book to continue, by id
    stride: u32 = 1, // Books let through between remembered places
    checkpoints: [checkpoints_max]u32 = undefined, // Positions in the order's file
    checkpoint_count: u32 = 0,
    bits_generation: u64 = 0, // Which pass of `Work.bits` is this view's

    pub fn invariants(v: *const View) void {
        assert(v.checkpoint_count <= checkpoints_max);
        assert(v.stride >= 1);
        assert(@as(u64, v.checkpoint_count) * v.stride <= @as(u64, v.count) + v.stride);
    }
};

/// What the passes share: the work's bits, and which pass last filled them.
pub const Bits = struct {
    words: []u64,
    generation: u64 = 0,

    fn set(b: *Bits, id: u32) void {
        assert(id / 64 < b.words.len);
        b.words[id / 64] |= @as(u64, 1) << @intCast(id % 64);
        assert(b.get(id));
    }

    fn clear(b: *Bits, id: u32) void {
        assert(id / 64 < b.words.len);
        b.words[id / 64] &= ~(@as(u64, 1) << @intCast(id % 64));
        assert(!b.get(id));
    }

    fn get(b: *const Bits, id: u32) bool {
        assert(b.words.len > 0);
        assert(id / 64 < b.words.len);
        return b.words[id / 64] & (@as(u64, 1) << @intCast(id % 64)) != 0;
    }
};

/// A book's numbers as an entry, its texts empty: for what depends only on them.
fn numbers_of(r: *const index.Record) catalog.Entry {
    r.invariants();
    const e: catalog.Entry = .{
        .path = "",
        .title = "",
        .author = "",
        .percent = r.percent,
        .last = r.last,
        .finished = r.flags & index.Record.finished != 0,
        .seconds_read = r.seconds_read,
        .availability = @fromBackingInt(@intCast(r.availability)),
    };
    assert(e.percent <= 100);
    return e;
}

/// Reads every book in id order, its record and, when `with_text`, its texts too.
const Stream = struct {
    ix: *index.Index,
    records: files.Reader,
    text: ?files.Reader,

    fn open(ix: *index.Index, work: *const builder.Work, with_text: bool) !Stream {
        assert(ix.header.count <= index.books_max);
        const generation = ix.header.generation;
        var records = try index.open_data(ix.dir, "records", generation, work.in_records);
        errdefer records.close();
        const text = if (with_text)
            try index.open_data(ix.dir, "text", generation, work.in_text)
        else
            null;
        assert(records.size >= index.file_head_bytes);
        return .{ .ix = ix, .records = records, .text = text };
    }

    fn close(s: *Stream) void {
        assert(s.records.fd >= 0);
        s.records.close();
        if (s.text) |*t| t.close();
        assert(s.records.fd < 0);
    }

    fn record(s: *Stream, id: u32) !index.Record {
        assert(s.records.fd >= 0);
        assert(id < s.ix.header.count);
        const offset = index.file_head_bytes + @as(u64, id) * @sizeOf(index.Record);
        const bytes = try s.records.read_at(offset, @sizeOf(index.Record));
        const r = std.mem.bytesToValue(index.Record, bytes);
        if (r.percent > 100 or r.text_len > index.blob_bytes_max) return error.Damaged;
        if (r.availability > 2) return error.Damaged;
        return r;
    }

    /// Book `id`'s entry, its texts in `slot`.
    fn entry(s: *Stream, id: u32, r: *const index.Record, slot: *index.Slot) !*catalog.Entry {
        assert(s.text != null); // Opened with its texts
        const text = &s.text.?;
        const blob = try text.read_at(r.text_offset, r.text_len);
        @memcpy(slot.text[0..blob.len], blob);
        slot.entry = try index.entry_of(r, slot.text[0..blob.len]);
        slot.id = id;
        assert(slot.holds());
        return &slot.entry;
    }
};

/// Writes the order's file afresh, sorting every book by its key.
pub fn sort_order(ix: *index.Index, work: *const builder.Work, order: catalog.Order) !void {
    assert(ix.dir.len > 0);
    assert(ix.header.count <= index.books_max);
    var stream = try Stream.open(ix, work, true);
    defer stream.close();
    var first = sorter.Sorter.init(&work.sort, ix.dir, "sort-first");
    defer first.discard();
    var second = sorter.Sorter.init(&work.sort_second, ix.dir, "sort-second");
    defer second.discard();
    var key_buffer: [sorter.key_bytes_max]u8 = undefined;
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const r = try stream.record(id);
        const e = try stream.entry(id, &r, work.slot);
        var k: keys.Key = .{ .buffer = &key_buffer };
        if (order != .series) {
            keys.of(&k, order, e);
            try first.add(k.bytes(), id);
        } else if (e.series.len == 0) {
            keys.series_none(&k, e);
            try second.add(k.bytes(), id);
        } else {
            keys.series_first(&k, e);
            try first.add(k.bytes(), id);
        }
    }
    var name_buffer: [32]u8 = undefined;
    const name = try index.order_name(&name_buffer, order);
    var out = try OrderOut.create(ix, name, work.out_records);
    errdefer out.abandon();
    if (order == .series) {
        var series: SeriesPass = .{ .second = &second };
        try first.finish(&series, SeriesPass.emit);
        try second.finish(&out, OrderOut.emit);
    } else {
        try first.finish(&out, OrderOut.emit);
    }
    try out.finish(ix, order);
}

/// The first pass by series becomes the second: each series' books, its latest
/// reading (the first of each run, by its key) put ahead of each.
const SeriesPass = struct {
    second: *sorter.Sorter,
    name: [keys.text_bytes_max + 1]u8 = undefined,
    name_len: u32 = 0,
    series_last: u64 = 0,

    fn emit(p: *SeriesPass, first: []const u8, id: u64) !void {
        assert(first.len > 0);
        const name_len = keys.series_name_len(first);
        const name = first[0..name_len];
        const same = name_len == p.name_len and std.mem.eql(u8, name, p.name[0..p.name_len]);
        if (!same) {
            @memcpy(p.name[0..name_len], first[0..name_len]);
            p.name_len = name_len;
            p.series_last = ~std.mem.readInt(u64, first[name_len..][0..8], .big);
        }
        var key_buffer: [sorter.key_bytes_max]u8 = undefined;
        var k: keys.Key = .{ .buffer = &key_buffer };
        keys.series_second(&k, first, p.series_last);
        try p.second.add(k.bytes(), id);
        assert(p.name_len == name_len);
    }
};

/// An order's file being written: its ids, after the head.
const OrderOut = struct {
    writer: files.Writer,
    count: u32 = 0,
    path_new: [files.path_bytes_max]u8 = undefined,
    path_new_len: u32 = 0,
    name: []const u8,

    fn create(ix: *index.Index, name: []const u8, buffer: []u8) !OrderOut {
        assert(name.len > 0);
        var out: OrderOut = .{ .writer = undefined, .name = name };
        const format = "{s}/{s}.new";
        const path = try std.fmt.bufPrintSentinel(&out.path_new, format, .{ ix.dir, name }, 0);
        out.path_new_len = @intCast(path.len);
        out.writer = try files.Writer.create(path, buffer);
        const head: index.FileHead = .{ .generation = ix.header.generation };
        out.writer.write(std.mem.asBytes(&head));
        assert(out.writer.size == index.file_head_bytes);
        return out;
    }

    fn emit(out: *OrderOut, _: []const u8, id: u64) !void {
        assert(id < index.books_max);
        out.writer.write_int(u32, @intCast(id));
        out.count += 1;
        assert(out.count <= index.books_max);
    }

    fn abandon(out: *OrderOut) void {
        assert(out.path_new_len > 0);
        if (out.writer.fd >= 0) out.writer.abandon();
        files.remove(out.path_new[0..out.path_new_len :0]);
        assert(out.writer.fd < 0);
    }

    /// Puts the file in place and marks the order sorted.
    fn finish(out: *OrderOut, ix: *index.Index, order: catalog.Order) !void {
        assert(out.writer.fd >= 0);
        if (out.count != ix.header.count) return error.Damaged; // Every book once
        _ = try out.writer.finish();
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const path = try files.path_in(&path_buffer, ix.dir, out.name);
        try files.replace(out.path_new[0..out.path_new_len :0], path);
        ix.header.stale &= ~index.order_bit(order);
        try ix.write_header();
        assert(!ix.header.is_stale(order));
    }
};

/// Books let through, from the `first`th to before the `end`th.
pub const Range = struct { first: u32, end: u32 };

/// What a filter and a search let through, and the book to continue.
pub const Look = struct {
    filter: catalog.Filter,
    words: []const u8, // Empty: no search
};

/// Arranges `v` for `order` and `look`: sorts the order if it's stale, finds the hero,
/// marks the books let through, and remembers where they are in the order.
pub fn arrange(
    ix: *index.Index,
    work: *const builder.Work,
    bits: *Bits,
    v: *View,
    order: catalog.Order,
    look: Look,
) !void {
    assert(ix.header.count <= index.books_max);
    if (ix.header.is_stale(order)) try sort_order(ix, work, order);
    v.* = .{ .order = order };
    try mark(ix, work, bits, look, &v.hero);
    // While searching, every match is listed, the hero too
    if (look.words.len == 0) {
        if (v.hero) |h| {
            if (bits.get(h)) bits.clear(h);
        }
    }
    v.bits_generation = bits.generation;
    count_through(ix, work, bits, v) catch {
        // Its file gone or damaged: sorted again, from the records
        try sort_order(ix, work, order);
        v.count = 0;
        v.checkpoint_count = 0;
        v.stride = 1;
        try count_through(ix, work, bits, v);
    };
    v.invariants();
}

/// Sets a bit for each book `look` lets through, and finds the hero: the latest book
/// in progress on this Kindle, or else the latest opened.
fn mark(ix: *index.Index, work: *const builder.Work, bits: *Bits, look: Look, hero: *?u32) !void {
    assert(bits.words.len > 0);
    assert(ix.header.count <= bits.words.len * 64);
    var stream = try Stream.open(ix, work, look.words.len > 0);
    defer stream.close();
    @memset(bits.words[0 .. (ix.header.count + 63) / 64], 0);
    bits.generation += 1;
    var going: ?u32 = null;
    var going_last: u64 = 0;
    var latest: ?u32 = null;
    var latest_last: u64 = 0;
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const r = try stream.record(id);
        const e = numbers_of(&r);
        if (e.is_local()) {
            if (e.in_progress() and (going == null or e.last > going_last)) {
                going = id;
                going_last = e.last;
            }
            if (latest == null or e.last > latest_last) {
                latest = id;
                latest_last = e.last;
            }
        }
        const through = switch (look.filter) {
            .all => true,
            .read => e.is_read(),
            .unread => !e.is_read(),
        };
        if (!through) continue;
        if (look.words.len > 0) {
            const full = try stream.entry(id, &r, work.slot);
            if (!catalog.matches_query(full.*, look.words)) continue;
        }
        bits.set(id);
    }
    hero.* = going orelse latest;
}

/// Counts the books marked, in the order's file, remembering where every `stride`th is.
fn count_through(ix: *index.Index, work: *const builder.Work, bits: *const Bits, v: *View) !void {
    assert(v.count == 0); // Counted afresh
    var name_buffer: [32]u8 = undefined;
    const name = try index.order_name(&name_buffer, v.order);
    var order = try index.open_data(ix.dir, name, ix.header.generation, work.in_order);
    defer order.close();
    if (order.size != index.file_head_bytes + @as(u64, ix.header.count) * 4) return error.Damaged;
    for (0..ix.header.count) |i| {
        const position: u32 = @intCast(i);
        const id = try id_at(&order, position);
        if (id >= ix.header.count) return error.Damaged;
        if (!bits.get(id)) continue;
        if (v.count % v.stride == 0) {
            if (v.checkpoint_count == checkpoints_max) {
                // Full: keep every other, and remember half as often
                for (0..checkpoints_max / 2) |k| v.checkpoints[k] = v.checkpoints[2 * k];
                v.checkpoint_count = checkpoints_max / 2;
                v.stride *= 2;
            }
            if (v.count % v.stride == 0) {
                v.checkpoints[v.checkpoint_count] = position;
                v.checkpoint_count += 1;
            }
        }
        v.count += 1;
    }
    v.invariants();
}

fn id_at(order: *files.Reader, position: u32) !u32 {
    assert(position < index.books_max);
    const offset = index.file_head_bytes + @as(u64, position) * 4;
    const bytes = try order.read_at(offset, 4);
    const id = std.mem.readInt(u32, bytes[0..4], .little);
    assert(offset + 4 <= order.size);
    return id;
}

/// The books let through from the `first`th to before the `end`th, read into `slots`:
/// how many.
pub fn page(
    ix: *index.Index,
    work: *const builder.Work,
    bits: *Bits,
    v: *View,
    look: Look,
    range: Range,
    slots: []index.Slot,
) !u32 {
    assert(range.first <= range.end);
    assert(range.end - range.first <= slots.len);
    // Another look filled the bits since: this view's again
    if (v.bits_generation != bits.generation) try arrange(ix, work, bits, v, v.order, look);
    if (range.first >= v.count) return 0;
    const end = @min(range.end, v.count);
    const checkpoint = @min(range.first / v.stride, v.checkpoint_count - 1);
    var name_buffer: [32]u8 = undefined;
    const name = try index.order_name(&name_buffer, v.order);
    var order = try index.open_data(ix.dir, name, ix.header.generation, work.in_order);
    defer order.close();
    var through: u32 = checkpoint * v.stride;
    var filled: u32 = 0;
    for (v.checkpoints[checkpoint]..ix.header.count) |p| {
        if (through == end) break;
        const id = try id_at(&order, @intCast(p));
        if (id >= ix.header.count) return error.Damaged;
        if (!bits.get(id)) continue;
        if (through >= range.first) {
            try ix.read(id, &slots[filled]);
            filled += 1;
        }
        through += 1;
    }
    assert(filled <= end - range.first);
    return filled;
}

/// The first `slots.len` books, in order `order`, whose title, author or series has
/// `words`, read into `slots`: how many there are of them, up to one more than fit.
pub fn first_matches(
    ix: *index.Index,
    work: *const builder.Work,
    bits: *Bits,
    order: catalog.Order,
    words: []const u8,
    slots: []index.Slot,
) !u32 {
    assert(words.len > 0);
    assert(slots.len > 0);
    if (ix.header.is_stale(order)) try sort_order(ix, work, order);
    var hero: ?u32 = null;
    try mark(ix, work, bits, .{ .filter = .all, .words = words }, &hero);
    var name_buffer: [32]u8 = undefined;
    const name = try index.order_name(&name_buffer, order);
    var file = try index.open_data(ix.dir, name, ix.header.generation, work.in_order);
    defer file.close();
    var found: u32 = 0;
    for (0..ix.header.count) |p| {
        const id = try id_at(&file, @intCast(p));
        if (id >= ix.header.count) return error.Damaged;
        if (!bits.get(id)) continue;
        if (found == slots.len) return found + 1; // More than fit
        try ix.read(id, &slots[found]);
        found += 1;
    }
    assert(found <= slots.len);
    return found;
}

/// What the stats screen counts of the library, in one pass over the records.
pub const Totals = struct {
    books: u32 = 0,
    finished: u32 = 0,
    in_progress: u32 = 0,
    finished_this_year: u32 = 0,
    seconds_this_year: u64 = 0,
};

/// The library's totals; "this year" is from `year_start`, a day as the journal counts
/// them, by `day_of`.
pub fn totals(
    ix: *index.Index,
    work: *const builder.Work,
    year_start: i32,
    utc_offset: i64,
    comptime day_of: fn (u64, i64) i32,
) !Totals {
    var stream = try Stream.open(ix, work, false);
    defer stream.close();
    var t: Totals = .{};
    for (0..ix.header.count) |i| {
        const r = try stream.record(@intCast(i));
        const e = numbers_of(&r);
        t.books += 1;
        if (e.is_read()) t.finished += 1;
        if (e.in_progress()) t.in_progress += 1;
        if (e.last == 0 or day_of(e.last, utc_offset) < year_start) continue;
        if (e.is_read()) t.finished_this_year += 1;
        t.seconds_this_year += e.seconds_read;
    }
    assert(t.books == ix.header.count);
    assert(t.finished + t.in_progress <= t.books);
    return t;
}

/// The next book of `e`'s series not yet read, by its place in the series, read into
/// `slot`; false when there's none.
pub fn next_in_series(
    ix: *index.Index,
    work: *const builder.Work,
    e: *const catalog.Entry,
    slot: *index.Slot,
) !bool {
    assert(ix.header.count <= index.books_max);
    if (e.series.len == 0) return false;
    const hash = index.series_hash(e.series);
    const place = catalog.series_place(e.*);
    var stream = try Stream.open(ix, work, true);
    defer stream.close();
    var best: ?u32 = null;
    var best_place: f32 = 0;
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const r = try stream.record(id);
        if (r.series_hash != hash) continue;
        const o = try stream.entry(id, &r, work.slot);
        if (!catalog.same_series(o.series, e.series)) continue;
        const o_place = catalog.series_place(o.*);
        if (o_place <= place or o.is_read()) continue;
        if (best == null or o_place < best_place) {
            best = id;
            best_place = o_place;
        }
    }
    const found = best orelse return false;
    try ix.read(found, slot);
    assert(!slot.entry.is_read());
    return true;
}

/// Calls `each(context, entry)` for every book, in id order.
pub fn each_book(
    ix: *index.Index,
    work: *const builder.Work,
    context: anytype,
    comptime each: fn (@TypeOf(context), *const catalog.Entry) void,
) !void {
    assert(ix.header.count <= index.books_max);
    var stream = try Stream.open(ix, work, true);
    defer stream.close();
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const r = try stream.record(id);
        each(context, try stream.entry(id, &r, work.slot));
    }
    assert(stream.records.size >= index.file_head_bytes);
}

/// Calls `each(context, entry)` for every book downloading, read into `slot`.
pub fn each_downloading(
    ix: *index.Index,
    work: *const builder.Work,
    slot: *index.Slot,
    context: anytype,
    comptime each: fn (@TypeOf(context), *const catalog.Entry) bool,
) !bool {
    assert(ix.header.downloading <= ix.header.count);
    assert(slot != work.slot);
    if (ix.header.downloading == 0) return false;
    var stream = try Stream.open(ix, work, true);
    defer stream.close();
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const r = try stream.record(id);
        if (r.availability != @backingInt(catalog.Availability.downloading)) continue;
        if (each(context, try stream.entry(id, &r, slot))) return true;
    }
    return false;
}
