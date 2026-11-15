//! PNG pictures, decoded to one gray byte per pixel: every colour type and bit depth,
//! interlaced or not. Transparency is dropped (the page under a picture is white
//! anyway), and colours become gray with stb_image's weights, 16-bit samples rounded as
//! it did, so a picture looks exactly as it did when stb_image decoded it. A file
//! stb_image turned down is turned down here too; a damaged or cut-short one is an
//! error, never a crash.
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;
const decoded = @import("decoded.zig");
const Gray = decoded.Gray;

pub const Error = error{ BadPng, OutOfMemory };

const signature = "\x89PNG\r\n\x1a\n";
/// A chunk: its length and type, its data, then a checksum.
const chunk_header_size = 8;
const chunk_checksum_size = 4;
const header_chunk_size = 13;
/// Limits stb_image had, kept so that the same files open.
const idat_size_max = 1 << 30;
const pixel_bytes_max = 1 << 30;
const palette_entries_max = 256;
/// Adam7: where each of the seven passes starts, and how far apart its pixels are.
const pass_count = 7;
const pass_x_start = [pass_count]u8{ 0, 4, 0, 2, 0, 1, 0 };
const pass_y_start = [pass_count]u8{ 0, 0, 4, 0, 2, 0, 1 };
const pass_x_step = [pass_count]u8{ 8, 8, 4, 4, 2, 2, 1 };
const pass_y_step = [pass_count]u8{ 8, 8, 8, 4, 4, 2, 2 };

comptime {
    assert(signature.len == 8);
    assert(pixel_bytes_max <= decoded.pixels_max);
    assert(palette_entries_max * 3 == 768);
    for (0..pass_count) |pass| assert(pass_x_start[pass] < pass_x_step[pass]);
}

fn chunk_type(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

/// What the chunks before the picture data say.
const Header = struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u8 = 0,
    color: u8 = 0,
    interlaced: bool = false,
    /// Samples a pixel has in the file: a palette's pixels have one, the index.
    channels: u8 = 0,
    paletted: bool = false,
    palette_count: u32 = 0,
    /// Each palette entry's gray, looked up per pixel. Entries past the palette are black.
    palette_gray: [palette_entries_max]u8 = @splat(0),
    /// Apple's own PNG variant (a CgBI chunk first): its data has no zlib header.
    apple: bool = false,
    /// Bytes of compressed picture data, over all its IDAT chunks.
    idat_size: u32 = 0,
    idat_count: u32 = 0,
    seen_header: bool = false,
};

pub fn is_png(data: []const u8) bool {
    return data.len >= signature.len and std.mem.eql(u8, data[0..signature.len], signature);
}

/// Decodes a PNG into gray pixels allocated from `alloc`, which the caller frees.
pub fn decode(alloc: std.mem.Allocator, data: []const u8) Error!Gray {
    if (!is_png(data)) return error.BadPng;
    var header: Header = .{};
    try read_chunks(data, &header);
    assert(header.seen_header);
    assert(header.idat_count > 0);
    const raw_size = try raw_size_of(&header);
    const raw = try alloc.alloc(u8, raw_size);
    defer alloc.free(raw);
    try inflate_idat(alloc, data, &header, raw);
    const pixels = try alloc.alloc(u8, @as(u32, header.width) * header.height);
    errdefer alloc.free(pixels);
    try unfilter_all(alloc, &header, raw, pixels);
    return .{ .pixels = pixels, .width = header.width, .height = header.height };
}

/// Reads every chunk up to IEND, checking them as stb_image did.
fn read_chunks(data: []const u8, header: *Header) Error!void {
    assert(is_png(data));
    var at: u32 = signature.len;
    // Every chunk takes at least its header, so the loop ends.
    while (at + chunk_header_size <= data.len) {
        const length = std.mem.readInt(u32, data[at..][0..4], .big);
        const kind = std.mem.readInt(u32, data[at + 4 ..][0..4], .big);
        const start = at + chunk_header_size;
        if (kind == chunk_type("IEND")) {
            if (!header.seen_header) return error.BadPng;
            if (header.idat_count == 0) return error.BadPng;
            return;
        }
        if (length > data.len - start) return error.BadPng;
        if (data.len - start - length < chunk_checksum_size) return error.BadPng;
        try read_chunk(header, kind, data[start..][0..length]);
        at = start + length + chunk_checksum_size;
        assert(at <= data.len);
    }
    // The file ended before its IEND
    return error.BadPng;
}

fn read_chunk(header: *Header, kind: u32, body: []const u8) Error!void {
    assert(body.len <= std.math.maxInt(u32));
    if (kind == chunk_type("CgBI")) {
        header.apple = true;
        return;
    }
    if (kind == chunk_type("IHDR")) return read_header(header, body);
    if (!header.seen_header) return error.BadPng;
    if (kind == chunk_type("PLTE")) return read_palette(header, body);
    if (kind == chunk_type("tRNS")) return check_transparency(header, body);
    if (kind == chunk_type("IDAT")) {
        if (header.paletted and header.palette_count == 0) return error.BadPng;
        if (body.len > idat_size_max) return error.BadPng;
        if (header.idat_size + body.len > idat_size_max) return error.BadPng;
        header.idat_size += @intCast(body.len);
        header.idat_count += 1;
        return;
    }
    // Bit 5 of a type's first letter clear: a chunk the picture can't be read without
    if (kind & (1 << 29) == 0) return error.BadPng;
    assert(header.seen_header);
}

fn read_header(header: *Header, body: []const u8) Error!void {
    if (header.seen_header) return error.BadPng;
    if (body.len != header_chunk_size) return error.BadPng;
    header.seen_header = true;
    header.width = std.mem.readInt(u32, body[0..4], .big);
    header.height = std.mem.readInt(u32, body[4..8], .big);
    header.depth = body[8];
    header.color = body[9];
    if (header.width > decoded.side_max or header.height > decoded.side_max) {
        return error.BadPng;
    }
    switch (header.depth) {
        1, 2, 4, 8, 16 => {},
        else => return error.BadPng,
    }
    if (header.color > 6) return error.BadPng;
    if (header.color == 3 and header.depth == 16) return error.BadPng;
    header.paletted = header.color == 3;
    if (!header.paletted and header.color & 1 != 0) return error.BadPng;
    // Compression and filter method 0 are the only ones; interlacing is none or Adam7
    if (body[10] != 0 or body[11] != 0 or body[12] > 1) return error.BadPng;
    header.interlaced = body[12] == 1;
    if (header.width == 0 or header.height == 0) return error.BadPng;
    const color_channels: u8 = if (header.color & 2 != 0) 3 else 1;
    const alpha_channels: u8 = if (header.color & 4 != 0) 1 else 0;
    header.channels = if (header.paletted) 1 else color_channels + alpha_channels;
    // A palette's pixels become four bytes each in stb_image, which it counted
    const counted: u32 = if (header.paletted) 4 else header.channels;
    if (pixel_bytes_max / header.width / counted < header.height) return error.BadPng;
    assert(header.channels >= 1);
    assert(header.channels <= 4);
}

fn read_palette(header: *Header, body: []const u8) Error!void {
    assert(header.seen_header);
    if (body.len > palette_entries_max * 3) return error.BadPng;
    if (body.len % 3 != 0) return error.BadPng;
    const count: u32 = @intCast(body.len / 3);
    header.palette_count = count;
    for (0..count) |entry| {
        const rgb = body[entry * 3 ..][0..3];
        header.palette_gray[entry] = decoded.luma(rgb[0], rgb[1], rgb[2]);
    }
    assert(header.palette_count <= palette_entries_max);
}

/// Transparency means nothing to a gray picture, but a tRNS chunk stb_image found
/// wrong made it turn the picture down, so it does here.
fn check_transparency(header: *const Header, body: []const u8) Error!void {
    assert(header.seen_header);
    assert(header.channels >= 1);
    if (header.idat_count > 0) return error.BadPng;
    if (header.paletted) {
        if (header.palette_count == 0) return error.BadPng;
        if (body.len > header.palette_count) return error.BadPng;
        return;
    }
    // Only gray and colour without an alpha channel may have one
    if (header.channels & 1 == 0) return error.BadPng;
    if (body.len != @as(u32, header.channels) * 2) return error.BadPng;
}

/// Inflates the picture data into `raw`. A copy of the IDAT chunks joined goes as soon
/// as it's inflated, so it's never held beside the pixels.
fn inflate_idat(
    alloc: std.mem.Allocator,
    data: []const u8,
    header: *const Header,
    raw: []u8,
) Error!void {
    assert(header.idat_count > 0);
    assert(raw.len > 0);
    const compressed = try gather_idat(alloc, data, header);
    defer if (header.idat_count > 1) alloc.free(compressed);
    try inflate(compressed, header.apple, raw);
}

/// The compressed picture data, in one piece: the one IDAT chunk itself, or a copy of
/// them all joined (owned by the caller when there is more than one).
fn gather_idat(alloc: std.mem.Allocator, data: []const u8, header: *const Header) Error![]const u8 {
    assert(header.idat_count > 0);
    assert(header.idat_size <= idat_size_max);
    const joined = if (header.idat_count > 1) try alloc.alloc(u8, header.idat_size) else null;
    var filled: u32 = 0;
    var at: u32 = signature.len;
    // Checked by `read_chunks`: each chunk lies inside the file, up to IEND
    while (at + chunk_header_size <= data.len) {
        const length = std.mem.readInt(u32, data[at..][0..4], .big);
        const kind = std.mem.readInt(u32, data[at + 4 ..][0..4], .big);
        if (kind == chunk_type("IEND")) break;
        const body = data[at + chunk_header_size ..][0..length];
        if (kind == chunk_type("IDAT")) {
            if (joined) |target| {
                @memcpy(target[filled..][0..length], body);
            } else {
                return body;
            }
            filled += length;
        }
        at += chunk_header_size + length + chunk_checksum_size;
    }
    assert(filled == header.idat_size);
    return joined.?;
}

/// Bytes a row of `width` pixels takes in the file, without its filter byte.
fn row_size(header: *const Header, width: u32) u32 {
    assert(width <= header.width);
    assert(header.depth <= 16);
    const bits = @as(u64, header.channels) * width * header.depth;
    return @intCast((bits + 7) >> 3);
}

/// The size of the picture data once inflated: each pass's rows, with their filter bytes.
fn raw_size_of(header: *const Header) Error!u32 {
    assert(header.width > 0);
    assert(header.height > 0);
    var total: u64 = 0;
    for (0..pass_count) |pass| {
        const size = pass_size(header, @intCast(pass));
        // A pass with no pixels has no rows at all, not even filter bytes
        if (size.width > 0) total += @as(u64, row_size(header, size.width) + 1) * size.height;
        if (!header.interlaced) break;
    }
    if (total > std.math.maxInt(u32)) return error.BadPng;
    return @intCast(total);
}

/// The size of one pass of an interlaced picture, or of the whole picture if it isn't.
fn pass_size(header: *const Header, pass: u8) decoded_size {
    assert(pass < pass_count);
    if (!header.interlaced) return .{ .width = header.width, .height = header.height };
    const x_start = pass_x_start[pass];
    const y_start = pass_y_start[pass];
    const width = if (header.width > x_start)
        (header.width - x_start + pass_x_step[pass] - 1) / pass_x_step[pass]
    else
        0;
    const height = if (header.height > y_start)
        (header.height - y_start + pass_y_step[pass] - 1) / pass_y_step[pass]
    else
        0;
    assert(width <= header.width);
    return .{ .width = width, .height = height };
}

const decoded_size = struct { width: u32, height: u32 };

/// Inflates exactly `raw.len` bytes. Like stb_image, it doesn't check the checksum at
/// the end, nor mind data past what the picture needs.
fn inflate(compressed: []const u8, apple: bool, raw: []u8) Error!void {
    assert(raw.len > 0);
    var stream = compressed;
    if (!apple) {
        // The zlib header: deflate, no preset dictionary, and its own check
        if (stream.len < 2) return error.BadPng;
        const method = stream[0];
        const flags = stream[1];
        if ((@as(u32, method) * 256 + flags) % 31 != 0) return error.BadPng;
        if (flags & 32 != 0) return error.BadPng;
        if (method & 15 != 8) return error.BadPng;
        stream = stream[2..];
    }
    var input: std.Io.Reader = .fixed(stream);
    var decompress: flate.Decompress = .init(&input, .raw, &.{});
    var output: std.Io.Writer = .fixed(raw);
    decompress.reader.streamExact(&output, raw.len) catch return error.BadPng;
    assert(output.end == raw.len);
}

/// Undoes each row's filter and turns it gray, pass by pass.
fn unfilter_all(
    alloc: std.mem.Allocator,
    header: *const Header,
    raw: []const u8,
    pixels: []u8,
) Error!void {
    assert(pixels.len == @as(u64, header.width) * header.height);
    const widest = row_size(header, header.width);
    // Two rows to filter in turn, and the samples of one row unpacked to bytes
    const rows = try alloc.alloc(u8, widest * 2);
    defer alloc.free(rows);
    const samples = try alloc.alloc(u8, @as(u32, header.width) * header.channels);
    defer alloc.free(samples);
    const gray_row = try alloc.alloc(u8, header.width);
    defer alloc.free(gray_row);
    const work: Work = .{ .rows = rows, .samples = samples, .gray_row = gray_row };
    var at: u32 = 0;
    for (0..pass_count) |pass_index| {
        const pass: u8 = @intCast(pass_index);
        const size = pass_size(header, pass);
        if (size.width > 0 and size.height > 0) {
            const used = (row_size(header, size.width) + 1) * size.height;
            try unfilter_pass(header, pass, raw[at..][0..used], pixels, &work);
            at += used;
        }
        if (!header.interlaced) break;
    }
    assert(at == raw.len);
}

/// Buffers `unfilter_pass` reuses for every row.
const Work = struct { rows: []u8, samples: []u8, gray_row: []u8 };

fn unfilter_pass(
    header: *const Header,
    pass: u8,
    raw: []const u8,
    pixels: []u8,
    work: *const Work,
) Error!void {
    const size = pass_size(header, pass);
    const size_in_row = row_size(header, size.width);
    assert(raw.len == (size_in_row + 1) * size.height);
    assert(work.rows.len >= size_in_row * 2);
    // Low bit depths filter byte by byte, others pixel by pixel
    const bytes_per_sample: u32 = if (header.depth == 16) 2 else 1;
    const filter_bytes = if (header.depth < 8) 1 else header.channels * bytes_per_sample;
    for (0..size.height) |row| {
        const half = (row & 1) * size_in_row;
        const current = work.rows[half..][0..size_in_row];
        const prior = work.rows[size_in_row - half ..][0..size_in_row];
        const line = raw[row * (size_in_row + 1) ..][0 .. size_in_row + 1];
        var filter = line[0];
        if (filter > 4) return error.BadPng;
        // The first row has no row above: stb_image's equivalents that don't look at it
        if (row == 0) filter = first_row_filter[filter];
        unfilter_row(filter, line[1..], current, prior, filter_bytes);
        const gray = if (header.interlaced) work.gray_row[0..size.width] else pixels[row *
            header.width ..][0..header.width];
        row_to_gray(header, current, work.samples, gray);
        if (header.interlaced) scatter(header, pass, @intCast(row), gray, pixels);
    }
}

const filter_none = 0;
const filter_sub = 1;
const filter_up = 2;
const filter_average = 3;
const filter_paeth = 4;
/// Average on the first row, where the row above counts as zeros.
const filter_average_first = 5;
const first_row_filter = [5]u8{
    filter_none,
    filter_sub,
    filter_none,
    filter_average_first,
    filter_sub, // Paeth with nothing above is sub
};

/// Undoes one row's filter. A hot loop: plain arguments, one switch per row.
fn unfilter_row(filter: u8, raw: []const u8, current: []u8, prior: []const u8, step: u32) void {
    assert(raw.len == current.len);
    assert(prior.len == current.len);
    assert(step >= 1);
    const n = current.len;
    const first = @min(step, n);
    switch (filter) {
        filter_none => @memcpy(current, raw),
        filter_sub => {
            @memcpy(current[0..first], raw[0..first]);
            for (first..n) |k| current[k] = raw[k] +% current[k - step];
        },
        filter_up => for (0..n) |k| {
            current[k] = raw[k] +% prior[k];
        },
        filter_average => {
            for (0..first) |k| current[k] = raw[k] +% (prior[k] >> 1);
            for (first..n) |k| {
                const sum = @as(u32, prior[k]) + current[k - step];
                current[k] = raw[k] +% @as(u8, @intCast(sum >> 1));
            }
        },
        filter_paeth => {
            for (0..first) |k| current[k] = raw[k] +% prior[k];
            for (first..n) |k| {
                current[k] = raw[k] +% paeth(current[k - step], prior[k], prior[k - step]);
            }
        },
        filter_average_first => {
            @memcpy(current[0..first], raw[0..first]);
            for (first..n) |k| current[k] = raw[k] +% (current[k - step] >> 1);
        },
        else => unreachable, // Mapped above from the five filters, checked
    }
}

/// The Paeth predictor, as stb_image wrote it (the same as the PNG standard's).
fn paeth(left: u8, above: u8, above_left: u8) u8 {
    const a: i32 = left;
    const b: i32 = above;
    const c: i32 = above_left;
    const threshold = c * 3 - (a + b);
    const low = @min(a, b);
    const high = @max(a, b);
    const t0 = if (high <= threshold) low else c;
    const t1 = if (threshold <= low) high else t0;
    assert(t1 >= 0);
    assert(t1 <= 255);
    return @intCast(t1);
}

/// Turns one unfiltered row into gray pixels.
fn row_to_gray(header: *const Header, row: []const u8, samples: []u8, gray: []u8) void {
    assert(gray.len <= header.width);
    assert(samples.len >= gray.len * header.channels);
    const count: u32 = @intCast(gray.len);
    const channels = header.channels;
    if (header.depth == 16) {
        gray_from_16(row, channels, gray);
        return;
    }
    var bytes = row;
    if (header.depth < 8) {
        // Gray is scaled up to the full range; palette indexes and colour aren't
        const scale: u8 = if (header.color == 0) depth_scale[header.depth] else 1;
        const used = samples[0 .. count * channels];
        unpack(row, header.depth, scale, used);
        bytes = used;
    }
    if (header.paletted) {
        gray_from_palette(bytes[0..count], &header.palette_gray, gray);
    } else if (channels <= 2) {
        gray_from_first(bytes, channels, gray);
    } else {
        gray_from_colour(bytes, channels, gray);
    }
}

/// What a gray sample of 1, 2 or 4 bits is multiplied by to reach 0..255.
const depth_scale = [9]u8{ 0, 0xff, 0x55, 0, 0x11, 0, 0, 0, 0x01 };

/// Spreads samples of 1, 2 or 4 bits into a byte each.
fn unpack(packed_row: []const u8, depth: u8, scale: u8, samples: []u8) void {
    assert(depth == 1 or depth == 2 or depth == 4);
    assert(packed_row.len * 8 >= samples.len * depth);
    const per_byte: u32 = 8 / depth;
    const shift: u3 = @intCast(8 - depth);
    for (samples, 0..) |*sample, index| {
        const byte = packed_row[index / per_byte];
        const position: u3 = @intCast(index % per_byte);
        const bits = (byte << (position * @as(u3, @intCast(depth)))) >> shift;
        sample.* = scale *% bits;
    }
}

fn gray_from_palette(indexes: []const u8, palette_gray: *const [256]u8, gray: []u8) void {
    assert(indexes.len == gray.len);
    assert(palette_gray.len == palette_entries_max);
    for (gray, indexes) |*pixel, index| pixel.* = palette_gray[index];
}

/// Gray, or gray and alpha: the first sample of each pixel.
fn gray_from_first(bytes: []const u8, channels: u8, gray: []u8) void {
    assert(channels == 1 or channels == 2);
    assert(bytes.len >= gray.len * channels);
    if (channels == 1) {
        @memcpy(gray, bytes[0..gray.len]);
        return;
    }
    for (gray, 0..) |*pixel, index| pixel.* = bytes[index * 2];
}

/// Colour, with or without alpha.
fn gray_from_colour(bytes: []const u8, channels: u8, gray: []u8) void {
    assert(channels == 3 or channels == 4);
    assert(bytes.len >= gray.len * channels);
    for (gray, 0..) |*pixel, index| {
        const rgb = bytes[index * channels ..][0..3];
        pixel.* = decoded.luma(rgb[0], rgb[1], rgb[2]);
    }
}

/// 16-bit samples: gray in 16 bits, then its high byte, as stb_image rounded.
fn gray_from_16(bytes: []const u8, channels: u8, gray: []u8) void {
    assert(channels >= 1);
    assert(bytes.len >= gray.len * channels * 2);
    const stride = @as(u32, channels) * 2;
    for (gray, 0..) |*pixel, index| {
        const sample = bytes[index * stride ..];
        if (channels <= 2) {
            pixel.* = sample[0];
        } else {
            const red = std.mem.readInt(u16, sample[0..2], .big);
            const green = std.mem.readInt(u16, sample[2..4], .big);
            const blue = std.mem.readInt(u16, sample[4..6], .big);
            pixel.* = @intCast(decoded.luma16(red, green, blue) >> 8);
        }
    }
}

/// Puts one row of an interlaced pass where its pixels belong.
fn scatter(header: *const Header, pass: u8, row: u32, gray: []const u8, pixels: []u8) void {
    assert(pass < pass_count);
    assert(gray.len <= header.width);
    const y = row * pass_y_step[pass] + pass_y_start[pass];
    assert(y < header.height);
    const line = pixels[y * header.width ..][0..header.width];
    const step = pass_x_step[pass];
    for (gray, 0..) |pixel, column| line[column * step + pass_x_start[pass]] = pixel;
}
