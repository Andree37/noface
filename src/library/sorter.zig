//! Sorting more items than fit in memory, in memory of a fixed size. Items (a key of
//! bytes and a 64-bit value) go into a run buffer; a full buffer is sorted and written
//! to a file of its own, a run. At the end the runs are merged, a few at a time, into
//! the caller's sink. Up to a buffer's worth it's one sort in memory, nothing written.
//!
//! Keys compare as bytes, so a caller orders by anything by how it writes the key (a
//! number big-endian, text lowercased and ended by a 0). Equal keys go by value.
//!
//! This is how the library sorts any number of books in the same memory: the runs and
//! merges are on the user drive, and their count grows with the books, the memory not.
const std = @import("std");
const assert = std.debug.assert;
const files = @import("files.zig");

/// The longest key an item may have.
pub const key_bytes_max: u32 = 1024;
/// Bytes an item takes in the buffer and in a run: its key's length, its key, its value.
const item_overhead_bytes: u32 = 2 + 8;
/// The most runs one sort may write, merges included. A run holds a buffer's worth, so
/// this is far past any library: with 4 MB buffers, a quarter of a terabyte of keys.
const runs_max: u32 = 1 << 16;

comptime {
    assert(key_bytes_max < std.math.maxInt(u16)); // Its length fits the length field
}

/// The memory a sort uses: the caller's, reused sort after sort.
pub const Memory = struct {
    /// The run buffer, and where each item in it starts.
    items: []u8,
    offsets: []u32,
    /// One for each run merged at once: two at least.
    inputs: []const []u8,
    /// For writing runs out.
    output: []u8,
};

pub const Sorter = struct {
    memory: *const Memory,
    dir: []const u8, // Where runs are written: never /tmp, which is RAM
    name: []const u8, // Each run's file is "<name>-<number>.run"
    used: u32 = 0, // Bytes of `memory.items` holding items
    count: u32 = 0, // Items in the buffer
    runs_first: u32 = 0, // The runs not yet merged are numbered [first, end)
    runs_end: u32 = 0,
    items_total: u64 = 0,

    pub fn init(memory: *const Memory, dir: []const u8, name: []const u8) Sorter {
        assert(memory.inputs.len >= 2); // Merging takes two runs at least
        // A run's reader holds its longest item
        for (memory.inputs) |input| assert(input.len >= key_bytes_max + item_overhead_bytes);
        assert(memory.items.len >= key_bytes_max + item_overhead_bytes);
        assert(memory.offsets.len > 0);
        return .{ .memory = memory, .dir = dir, .name = name };
    }

    /// Adds an item. An error only when a full buffer couldn't be written out as a run.
    pub fn add(s: *Sorter, key: []const u8, value: u64) !void {
        assert(key.len <= key_bytes_max);
        assert(s.used <= s.memory.items.len);
        const size: u32 = @intCast(item_overhead_bytes + key.len);
        const full = s.used + size > s.memory.items.len or s.count == s.memory.offsets.len;
        if (full) try s.spill();
        const at = s.used;
        std.mem.writeInt(u16, s.memory.items[at..][0..2], @intCast(key.len), .little);
        @memcpy(s.memory.items[at + 2 ..][0..key.len], key);
        std.mem.writeInt(u64, s.memory.items[at + 2 + key.len ..][0..8], value, .little);
        s.memory.offsets[s.count] = at;
        s.count += 1;
        s.used += size;
        s.items_total += 1;
        assert(s.used <= s.memory.items.len);
    }

    /// Sorts the buffer and writes it out as the next run.
    fn spill(s: *Sorter) !void {
        assert(s.count > 0);
        if (s.runs_end == runs_max) return error.TooManyRuns;
        s.sort_buffer();
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const path = try s.run_path(&path_buffer, s.runs_end);
        var w = try files.Writer.create(path, s.memory.output);
        for (s.memory.offsets[0..s.count]) |at| w.write(item_bytes(s.memory.items, at));
        _ = w.finish() catch |err| {
            files.remove(path);
            return err;
        };
        s.runs_end += 1;
        s.used = 0;
        s.count = 0;
        assert(s.runs_end <= runs_max);
    }

    fn sort_buffer(s: *Sorter) void {
        const offsets = s.memory.offsets[0..s.count];
        std.mem.sort(u32, offsets, s.memory.items, offset_less);
        assert(std.sort.isSorted(u32, offsets, s.memory.items, offset_less));
        assert(offsets.len == s.count);
    }

    /// Every item, in order, to `emit(context, key, value)`; then the runs are gone. An
    /// error from `emit` stops it; any other is a run that couldn't be read or written.
    pub fn finish(
        s: *Sorter,
        context: anytype,
        comptime emit: fn (@TypeOf(context), []const u8, u64) anyerror!void,
    ) !void {
        defer s.discard();
        if (s.runs_end == 0) {
            // All in memory: no run was written
            s.sort_buffer();
            for (s.memory.offsets[0..s.count]) |at| {
                const item = item_bytes(s.memory.items, at);
                try emit(context, item_key(item), item_value(item));
            }
            return;
        }
        if (s.count > 0) try s.spill();
        // Merge the oldest runs into a new one until few enough are left to merge at once.
        // Each merge leaves one run fewer, so this ends.
        const fan_in: u32 = @intCast(s.memory.inputs.len);
        for (0..runs_max) |_| {
            if (s.runs_end - s.runs_first <= fan_in) break;
            try s.merge_to_run(fan_in);
        } else return error.TooManyRuns;
        assert(s.runs_end - s.runs_first <= fan_in);
        try s.merge(s.runs_end - s.runs_first, context, emit);
    }

    /// Merges the oldest `count` runs into a new run.
    fn merge_to_run(s: *Sorter, count: u32) !void {
        assert(count >= 2);
        if (s.runs_end == runs_max) return error.TooManyRuns;
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const path = try s.run_path(&path_buffer, s.runs_end);
        var w = try files.Writer.create(path, s.memory.output);
        s.merge(count, &w, write_item) catch |err| {
            w.abandon();
            files.remove(path);
            return err;
        };
        _ = w.finish() catch |err| {
            files.remove(path);
            return err;
        };
        s.runs_end += 1;
        assert(s.runs_end <= runs_max);
    }

    fn write_item(w: *files.Writer, key: []const u8, value: u64) !void {
        assert(key.len <= key_bytes_max);
        var head: [2]u8 = undefined;
        std.mem.writeInt(u16, &head, @intCast(key.len), .little);
        w.write(&head);
        w.write(key);
        w.write_int(u64, value);
        assert(w.size >= item_overhead_bytes + key.len);
    }

    /// Merges the oldest `count` runs into `emit`, and removes them.
    fn merge(
        s: *Sorter,
        count: u32,
        context: anytype,
        comptime emit: fn (@TypeOf(context), []const u8, u64) anyerror!void,
    ) !void {
        assert(count >= 1);
        assert(count <= s.memory.inputs.len);
        var heads: [64]Head = undefined;
        assert(count <= heads.len);
        var opened: u32 = 0;
        defer for (heads[0..opened]) |*head| head.reader.close();
        for (heads[0..count], 0..) |*head, i| {
            var path_buffer: [files.path_bytes_max]u8 = undefined;
            const path = try s.run_path(&path_buffer, s.runs_first + @as(u32, @intCast(i)));
            head.* = .{ .reader = try files.Reader.open(path, s.memory.inputs[i]) };
            opened += 1;
            try head.next();
        }
        // Each step emits one item of the runs, so this many steps emit them all
        for (0..s.items_total + 1) |_| {
            const least = least_head(heads[0..count]) orelse break;
            try emit(context, heads[least].key, heads[least].value);
            try heads[least].next();
        } else unreachable; // Never more items than were added
        for (0..count) |i| {
            var path_buffer: [files.path_bytes_max]u8 = undefined;
            files.remove(try s.run_path(&path_buffer, s.runs_first + @as(u32, @intCast(i))));
        }
        s.runs_first += count;
        assert(s.runs_first <= s.runs_end);
    }

    /// Removes every run left: after `finish`, or instead of it after an error.
    pub fn discard(s: *Sorter) void {
        assert(s.runs_first <= s.runs_end);
        for (s.runs_first..s.runs_end) |run| {
            var path_buffer: [files.path_bytes_max]u8 = undefined;
            const path = s.run_path(&path_buffer, @intCast(run)) catch continue;
            files.remove(path);
        }
        s.runs_first = s.runs_end;
        s.used = 0;
        s.count = 0;
        assert(s.runs_first == s.runs_end);
    }

    fn run_path(s: *const Sorter, buffer: []u8, run: u32) ![:0]u8 {
        assert(run < runs_max);
        assert(s.name.len > 0);
        const format = "{s}/{s}-{d}.run";
        const path = try std.fmt.bufPrintSentinel(buffer, format, .{ s.dir, s.name, run }, 0);
        assert(std.mem.endsWith(u8, path, ".run"));
        return path;
    }
};

/// A run being merged: its reader, and the item it's at.
const Head = struct {
    reader: files.Reader,
    at: u64 = 0, // Where its next item starts
    key: []const u8 = "",
    value: u64 = 0,
    done: bool = false,

    /// Reads the run's next item, or marks it done at its end. Its key points into the
    /// reader's buffer, which only this run's reads change.
    fn next(h: *Head) !void {
        assert(!h.done);
        if (h.at == h.reader.size) {
            h.done = true;
            return;
        }
        const head = try h.reader.read_at(h.at, 2);
        const key_len = std.mem.readInt(u16, head[0..2], .little);
        if (key_len > key_bytes_max) return error.DamagedRun;
        const item = try h.reader.read_at(h.at, item_overhead_bytes + key_len);
        h.key = item_key(item);
        h.value = item_value(item);
        h.at += item.len;
        assert(h.at <= h.reader.size);
    }
};

/// The run whose item comes first, or null when every run is done.
fn least_head(heads: []const Head) ?u32 {
    assert(heads.len > 0);
    var least: ?u32 = null;
    for (heads, 0..) |head, i| {
        if (head.done) continue;
        if (least) |l| {
            if (!item_less(head.key, head.value, heads[l].key, heads[l].value)) continue;
        }
        least = @intCast(i);
    }
    if (least) |l| assert(!heads[l].done);
    return least;
}

/// The item at `at` in the buffer, as written: length, key, value.
fn item_bytes(items: []const u8, at: u32) []const u8 {
    const key_len = std.mem.readInt(u16, items[at..][0..2], .little);
    assert(key_len <= key_bytes_max);
    const end = at + item_overhead_bytes + key_len;
    assert(end <= items.len);
    return items[at..end];
}

fn item_key(item: []const u8) []const u8 {
    assert(item.len >= item_overhead_bytes);
    const key = item[2 .. item.len - 8];
    assert(key.len == std.mem.readInt(u16, item[0..2], .little));
    return key;
}

fn item_value(item: []const u8) u64 {
    assert(item.len >= item_overhead_bytes);
    assert(item.len - item_overhead_bytes <= key_bytes_max);
    return std.mem.readInt(u64, item[item.len - 8 ..][0..8], .little);
}

fn item_less(key_a: []const u8, value_a: u64, key_b: []const u8, value_b: u64) bool {
    assert(key_a.len <= key_bytes_max);
    assert(key_b.len <= key_bytes_max);
    return switch (std.mem.order(u8, key_a, key_b)) {
        .lt => true,
        .gt => false,
        .eq => value_a < value_b,
    };
}

fn offset_less(items: []const u8, a: u32, b: u32) bool {
    const item_a = item_bytes(items, a);
    const item_b = item_bytes(items, b);
    return item_less(item_key(item_a), item_value(item_a), item_key(item_b), item_value(item_b));
}

/// Collects what a sort emits, for the tests.
const TestSink = struct {
    keys: std.ArrayList(u64) = .empty,
    values: std.ArrayList(u64) = .empty,

    fn emit(sink: *TestSink, key: []const u8, value: u64) !void {
        try sink.keys.append(std.testing.allocator, std.mem.readInt(u64, key[0..8], .big));
        try sink.values.append(std.testing.allocator, value);
    }
};

fn test_sort(items_bytes: u32, inputs_count: u32, count: u32) !void {
    const alloc = std.testing.allocator;
    var buffers: [4][key_bytes_max + item_overhead_bytes]u8 = undefined;
    var inputs: [4][]u8 = undefined;
    for (&inputs, &buffers) |*input, *buffer| input.* = buffer;
    const items = try alloc.alloc(u8, items_bytes);
    defer alloc.free(items);
    var offsets: [64]u32 = undefined;
    var output: [100]u8 = undefined;
    const memory: Memory = .{
        .items = items,
        .offsets = &offsets,
        .inputs = inputs[0..inputs_count],
        .output = &output,
    };
    var s = Sorter.init(&memory, "/tmp", "noface-sort-test");
    var prng = std.Random.DefaultPrng.init(count);
    for (0..count) |i| {
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, prng.random().uintLessThan(u64, 50), .big);
        try s.add(&key, i);
    }
    var sink: TestSink = .{};
    defer sink.keys.deinit(alloc);
    defer sink.values.deinit(alloc);
    try s.finish(&sink, TestSink.emit);
    try std.testing.expectEqual(count, sink.keys.items.len);
    for (1..@max(count, 1)) |i| {
        const a = sink.keys.items[i - 1];
        const b = sink.keys.items[i];
        const values = sink.values.items;
        try std.testing.expect(a < b or (a == b and values[i - 1] < values[i]));
    }
}

test "a sort in memory, and one in many runs merged a few at a time, give the same order" {
    try test_sort(key_bytes_max + 64, 2, 0);
    try test_sort(1 << 16, 2, 60); // In memory
    // Runs of 60 items (18 bytes each), merged two or three at a time, in many passes
    try test_sort(key_bytes_max + 64, 2, 200);
    try test_sort(key_bytes_max + 64, 3, 1000);
    try test_sort(1 << 12, 4, 3000); // Runs of 64, as the offsets fill first
}
