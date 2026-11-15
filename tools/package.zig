//! Packs noface as one zip holding a single "noface" folder:
//!
//!   noface/                     the app, its launcher and picture helper, the startup
//!                               file and notices, copied to the root of the Kindle's drive
//!   noface/kpm/noface/          the launcher entry, copied into kmc/kpm/packages/
//!
//! Nothing in it shares a name with a folder already on the Kindle, so copying it
//! never asks to replace one (Finder replacing "kmc" would remove KMC).
//!
//! Run by `zig build package -Dversion=1.2.3`, which builds everything first and
//! writes zig-out/noface-1.2.3.zip. build.zig names the files:
//!
//!   package <out.zip> <version> [<mode> <path in the zip> <file>]...
//!
//! where mode is 644 or 755. The zip also gets noface/VERSION, saying the version.
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;

/// The most files a package holds: it has about a dozen.
const files_max = 32;
/// The largest file packed: the app is a few megabytes.
const file_bytes_max = 64 << 20;
const version_path = "noface/VERSION";

comptime {
    assert(files_max * file_bytes_max <= std.math.maxInt(u32)); // No zip64 needed
}

/// What goes in the zip: a path inside it, its contents and its Unix mode.
pub const Item = struct { path: []const u8, data: []const u8, mode: u32 };

/// Where an entry's local header starts, and what the central directory repeats.
const Written = struct {
    path: []const u8,
    offset: u32,
    crc: u32,
    compressed: u32,
    size: u32,
    method: u16,
    mode: u32,
};

const local_signature = 0x04034b50;
const central_signature = 0x02014b50;
const end_signature = 0x06054b50;
const method_store = 0;
const method_deflate = 8;
/// Made by Unix (3), version 3.0: so unzip keeps each file's mode.
const made_by = (3 << 8) | 30;
const needed_version = 20;
const mode_directory = 0o040755;
const mode_file = 0o100000;
const dos_directory_attribute = 0x10;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3 or (args.len - 3) % 3 != 0 or (args.len - 3) / 3 >= files_max) {
        const usage = "usage: package <out.zip> <version> [<mode> <path in zip> <file>]...\n";
        std.debug.print(usage, .{});
        std.process.exit(2);
    }
    assert(args.len >= 3);
    const io = init.io;
    var items: std.ArrayList(Item) = .empty;
    var index: u32 = 3;
    while (index < args.len) : (index += 3) {
        const mode = std.fmt.parseInt(u32, args[index], 8) catch return error.BadMode;
        if (mode != 0o644 and mode != 0o755) return error.BadMode;
        const limit: std.Io.Limit = .limited(file_bytes_max);
        const data = try std.Io.Dir.cwd().readFileAlloc(io, args[index + 2], gpa, limit);
        try items.append(gpa, .{ .path = args[index + 1], .data = data, .mode = mode });
    }
    const version = try std.fmt.allocPrint(gpa, "noface {s}\n", .{args[2]});
    try items.append(gpa, .{ .path = version_path, .data = version, .mode = 0o644 });
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const zip = try build_zip(gpa, items.items, dos_time(@intCast(@max(now, 0))));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = zip });
    var line: [1024]u8 = undefined;
    const said = std.fmt.bufPrint(&line, "{s}\n", .{args[1]}) catch return error.PathTooLong;
    try std.Io.File.stdout().writeStreamingAll(io, said);
    assert(zip.len > 0);
}

/// A time in MS-DOS's form, as zip keeps it: the date in the high half, the time in
/// the low, to two seconds. Zips can't hold times before 1980.
pub fn dos_time(unix_seconds: u64) u32 {
    const seconds = @max(unix_seconds, 315_532_800); // 1 Jan 1980
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    assert(year_day.year >= 1980);
    const date: u32 = (@as(u32, year_day.year - 1980) << 9) |
        (@as(u32, month_day.month.numeric()) << 5) | (@as(u32, month_day.day_index) + 1);
    const time: u32 = (@as(u32, day.getHoursIntoDay()) << 11) |
        (@as(u32, day.getMinutesIntoHour()) << 5) | (day.getSecondsIntoMinute() / 2);
    assert(time <= 0xFFFF);
    return (date << 16) | time;
}

/// The zip: every item, each folder above them first, then the central directory.
pub fn build_zip(gpa: std.mem.Allocator, items: []const Item, time: u32) ![]u8 {
    assert(items.len > 0);
    assert(items.len <= files_max);
    var out: std.ArrayList(u8) = .empty;
    var written: std.ArrayList(Written) = .empty;
    for (items) |item| {
        // Each folder on the way to it, once, as zip -r lists them
        var slash = std.mem.indexOfScalar(u8, item.path, '/');
        while (slash) |end| : (slash = std.mem.indexOfScalarPos(u8, item.path, end + 1, '/')) {
            const folder = item.path[0 .. end + 1];
            const seen = for (written.items) |w| {
                if (std.mem.eql(u8, w.path, folder)) break true;
            } else false;
            if (seen) continue;
            try written.append(gpa, try add_entry(gpa, &out, folder, "", mode_directory, time));
        }
        const mode = mode_file | item.mode;
        try written.append(gpa, try add_entry(gpa, &out, item.path, item.data, mode, time));
    }
    const directory_start: u32 = @intCast(out.items.len);
    for (written.items) |w| try add_central(gpa, &out, w, time);
    const directory_size: u32 = @intCast(out.items.len - directory_start);
    try append_int(gpa, &out, u32, end_signature);
    try append_int(gpa, &out, u16, 0); // This disk
    try append_int(gpa, &out, u16, 0); // The disk the directory starts on
    try append_int(gpa, &out, u16, @intCast(written.items.len)); // Entries on this disk
    try append_int(gpa, &out, u16, @intCast(written.items.len));
    try append_int(gpa, &out, u32, directory_size);
    try append_int(gpa, &out, u32, directory_start);
    try append_int(gpa, &out, u16, 0); // No comment
    assert(written.items.len > items.len); // The folders too
    return out.items;
}

/// One entry's local header and data, deflated unless it's a folder.
fn add_entry(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    data: []const u8,
    mode: u32,
    time: u32,
) !Written {
    assert(path.len > 0);
    assert(data.len <= file_bytes_max);
    const is_directory = path[path.len - 1] == '/';
    // Deflate writes through a buffer of at least 8 bytes
    var packed_data: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 16);
    if (!is_directory) {
        const window = try gpa.alloc(u8, flate.max_window_len);
        var deflate = try flate.Compress.init(&packed_data.writer, window, .raw, .level_9);
        try deflate.writer.writeAll(data);
        try deflate.finish();
    }
    const entry: Written = .{
        .path = path,
        .offset = @intCast(out.items.len),
        .crc = std.hash.Crc32.hash(data),
        .compressed = @intCast(packed_data.written().len),
        .size = @intCast(data.len),
        .method = if (is_directory) method_store else method_deflate,
        .mode = mode,
    };
    try append_int(gpa, out, u32, local_signature);
    try append_int(gpa, out, u16, needed_version);
    try append_int(gpa, out, u16, 0); // No flags
    try append_int(gpa, out, u16, entry.method);
    try append_int(gpa, out, u32, time);
    try append_int(gpa, out, u32, entry.crc);
    try append_int(gpa, out, u32, entry.compressed);
    try append_int(gpa, out, u32, entry.size);
    try append_int(gpa, out, u16, @intCast(path.len));
    try append_int(gpa, out, u16, 0); // No extra fields, as zip -X leaves them out
    try out.appendSlice(gpa, path);
    try out.appendSlice(gpa, packed_data.written());
    if (is_directory) assert(entry.size == 0);
    return entry;
}

/// One entry's line in the central directory, with its Unix mode.
fn add_central(gpa: std.mem.Allocator, out: *std.ArrayList(u8), w: Written, time: u32) !void {
    assert(w.path.len > 0);
    assert(w.compressed <= out.items.len);
    const is_directory = w.path[w.path.len - 1] == '/';
    const dos_attributes: u32 = if (is_directory) dos_directory_attribute else 0;
    try append_int(gpa, out, u32, central_signature);
    try append_int(gpa, out, u16, made_by);
    try append_int(gpa, out, u16, needed_version);
    try append_int(gpa, out, u16, 0); // No flags
    try append_int(gpa, out, u16, w.method);
    try append_int(gpa, out, u32, time);
    try append_int(gpa, out, u32, w.crc);
    try append_int(gpa, out, u32, w.compressed);
    try append_int(gpa, out, u32, w.size);
    try append_int(gpa, out, u16, @intCast(w.path.len));
    try append_int(gpa, out, u16, 0); // No extra fields
    try append_int(gpa, out, u16, 0); // No comment
    try append_int(gpa, out, u16, 0); // On the first disk
    try append_int(gpa, out, u16, 0); // Internal attributes: binary
    try append_int(gpa, out, u32, (w.mode << 16) | dos_attributes);
    try append_int(gpa, out, u32, w.offset);
    try out.appendSlice(gpa, w.path);
}

fn append_int(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    assert(@typeInfo(T).int.signedness == .unsigned);
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
    assert(out.items.len >= bytes.len);
}

/// `text` `times` over, for the tests.
fn repeated(comptime text: []const u8, comptime times: u32) []const u8 {
    comptime assert(text.len > 0);
    comptime assert(times > 0);
    @setEvalBranchQuota(10 * times);
    comptime var out: []const u8 = "";
    inline for (0..times) |_| out = out ++ text;
    return out;
}

test "the zip lists each folder once, then every file, readable by std's zip reader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const items = [_]Item{
        .{ .path = "noface/noface", .data = repeated("program ", 100), .mode = 0o755 },
        .{ .path = "noface/kpm/noface/launch.sh", .data = "#!/bin/sh\n", .mode = 0o755 },
        .{ .path = "noface/VERSION", .data = "noface 1.0.0\n", .mode = 0o644 },
    };
    const zip = try build_zip(gpa, &items, dos_time(1_794_700_800));
    // The end record: six entries (three folders, three files)
    const end = zip[zip.len - 22 ..];
    try std.testing.expectEqual(@as(u32, end_signature), std.mem.readInt(u32, end[0..4], .little));
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, end[10..12], .little));
    // The first entry is the top folder, stored, then the app, deflated and smaller
    try std.testing.expectEqualStrings("noface/", zip[30..37]);
    const second = zip[37..];
    const method = std.mem.readInt(u16, second[8..10], .little);
    try std.testing.expectEqual(@as(u16, method_deflate), method);
    const compressed = std.mem.readInt(u32, second[18..22], .little);
    try std.testing.expect(compressed < 800);
    try std.testing.expectEqualStrings("noface/noface", second[30..43]);
    var input: std.Io.Reader = .fixed(second[43..][0..compressed]);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&input, .raw, &window);
    var data: [800]u8 = undefined;
    try inflate.reader.readSliceAll(&data);
    try std.testing.expectEqualStrings(repeated("program ", 100), &data);
}

test "zip times count from 1980, to two seconds" {
    // 15 Nov 2026, 00:00:00
    const time = dos_time(1_794_700_800);
    try std.testing.expectEqual(@as(u32, 46), time >> 25);
    try std.testing.expectEqual(@as(u32, 11), (time >> 21) & 0xF);
    try std.testing.expectEqual(@as(u32, 15), (time >> 16) & 0x1F);
    try std.testing.expectEqual(@as(u32, 0), time & 0xFFFF);
    try std.testing.expectEqual(dos_time(0), dos_time(315_532_800));
}
