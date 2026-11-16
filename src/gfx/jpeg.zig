//! JPEG pictures, decoded to one gray byte per pixel: baseline and progressive, any
//! chroma sampling, restart markers, and gray, YCbCr, RGB, CMYK and YCCK files.
//!
//! A port of stb_image's decoder (its Huffman tables, integer IDCT and upsampling),
//! so a picture's grays are exactly the ones stb_image gave. One difference makes it
//! faster: the gray of a YCbCr picture is its Y alone, so the colour is read past
//! but never transformed back into pixels. A file cut short or damaged is an error,
//! never a crash.
//!
//! The gray leaves row by row, into a `rows.Sink` that scales it as it comes: a
//! baseline picture's as each row of blocks is read, a progressive one's as each row of
//! blocks is transformed once every scan is read. Only a progressive picture's gray
//! components keep their coefficients whole; the others keep a bit per coefficient,
//! which is all reading the later scans needs. A picture too large for its workspace
//! is decoded at a half, a quarter or an eighth (`shrink`), keeping only that much of
//! each block's coefficients.
const std = @import("std");
const assert = std.debug.assert;
const decoded = @import("decoded.zig");
const Gray = decoded.Gray;
const scaler = @import("rows.zig");
const Workspace = @import("workspace.zig").Workspace;

pub const Error = error{ BadJpeg, OutOfMemory };

/// Huffman codes this long or shorter are looked up in one step.
const fast_bits = 9;
const fast_size = 1 << fast_bits;
const fast_none = 255;
const block_length = 64;
const components_max = 4;
const tables_max = 4;
/// What `marker` holds when no marker is waiting.
const marker_none = 0xff;
/// The most samples a picture may have: stb_image refused more than fit a C int.
const samples_max = std.math.maxInt(i32);

comptime {
    assert(fast_size == 512);
    assert(block_length == 8 * 8);
    assert(dezigzag.len == block_length + 15);
}

/// Where each coefficient in a block's zigzag order lies in the 8 x 8 block, with room
/// for a damaged file to run 15 past the end.
const dezigzag = [_]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
};

/// (1 << n) - 1.
const bit_mask = [17]u32{
    0,   1,    3,    7,    15,   31,    63,    127,   255,
    511, 1023, 2047, 4095, 8191, 16383, 32767, 65535,
};

/// (-1 << n) + 1: what turns n bits into a negative number.
const extend_bias = [16]i32{
    0,    -1,   -3,    -7,    -15,   -31,   -63,    -127,
    -255, -511, -1023, -2047, -4095, -8191, -16383, -32767,
};

const Huffman = struct {
    fast: [fast_size]u8,
    code: [256]u16,
    values: [256]u8,
    size: [257]u8,
    maxcode: [18]u32,
    delta: [17]i32,
};

/// Everything stb_image kept zeroed at the start.
const Tables = struct {
    dc: [tables_max]Huffman,
    ac: [tables_max]Huffman,
    dequant: [tables_max][block_length]u16,
    fast_ac: [tables_max][fast_size]i16,
};

const Component = struct {
    id: u8 = 0,
    h: u8 = 0,
    v: u8 = 0,
    quant: u8 = 0,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    dc_prediction: i32 = 0,
    /// Its pixels, then its pixels padded out to whole MCUs.
    x: u32 = 0,
    y: u32 = 0,
    w2: u32 = 0,
    h2: u32 = 0,
    /// Its samples once transformed, if the gray needs them: `data_rows` rows of
    /// `stride` samples, all of them or a few block rows in turn, row r at r modulo
    /// `data_rows`. At the decoder's `shrink`, a block is `8 / shrink` samples a side.
    data: []u8 = &.{},
    data_rows: u32 = 0,
    stride: u32 = 0,
    /// Rows of samples transformed so far, from the top.
    rows_done: u32 = 0,
    /// Its pixels at the decoder's `shrink`.
    out_x: u32 = 0,
    out_y: u32 = 0,
    /// A progressive picture's coefficients, kept between scans: every one of each
    /// block (`masks` empty), or the top-left square `8 / shrink` a side and a bit per
    /// coefficient saying which aren't zero (`masks`), or only those bits.
    coefficients: []i16 = &.{},
    masks: []u64 = &.{},
    coefficients_width: u32 = 0,
};

/// Which components the gray is made from, and so are transformed back into samples.
const Needed = enum { predicted, all };

const Decoder = struct {
    source: []const u8,
    at: u32 = 0,
    /// Zero bits the bit reader made up past the end of the file, at the bottom of its
    /// buffer. Reading ahead is fine; using one means the picture was cut short.
    made_up_bits: i32 = 0,
    cut_short: bool = false,
    tables: *Tables,
    width: u32 = 0,
    height: u32 = 0,
    channels: u8 = 0,
    h_max: u8 = 1,
    v_max: u8 = 1,
    mcu_x: u32 = 0,
    mcu_y: u32 = 0,
    component: [components_max]Component = @splat(.{}),
    code_buffer: u32 = 0,
    code_bits: i32 = 0,
    marker: u8 = marker_none,
    nomore: bool = false,
    progressive: bool = false,
    spec_start: u8 = 0,
    spec_end: u8 = 0,
    succ_high: u8 = 0,
    succ_low: u8 = 0,
    eob_run: i32 = 0,
    jfif: bool = false,
    /// The Adobe APP14 colour transform: -1 when there's none.
    app14: i32 = -1,
    /// How many components are named R, G and B.
    rgb_names: u8 = 0,
    scan_count: u8 = 0,
    order: [components_max]u8 = @splat(0),
    restart_interval: u32 = 0,
    todo: i32 = 0,
    scans_decoded: u32 = 0,
    needed: Needed,
    /// Components whose samples are kept: only those the gray is made from.
    keep: [components_max]bool = @splat(false),
    work: *Workspace,
    sink: *scaler.Sink,
    /// The picture is decoded at 1 / `shrink` of its size, each block `side` samples.
    shrink: u8,
    side: u8,
    /// Whether a baseline picture's rows go to the sink as its first scan is read,
    /// which holds a few rows instead of the whole picture. Else they go once every
    /// scan is read.
    streaming: bool,
    /// What the rows going out are made from, and how each component is upsampled.
    gray_from: GrayFrom = .{ .count = 1, .kind = .y },
    resamples: [components_max]Resample = undefined,
    /// A row of gray, when it isn't the first component's samples as they are.
    gray_line: []u8 = &.{},
    out_width: u32 = 0,
    out_height: u32 = 0,
    rows_out: u32 = 0,

    fn get8(d: *Decoder) u8 {
        assert(d.at <= d.source.len);
        if (d.at == d.source.len) return 0;
        const byte = d.source[d.at];
        d.at += 1;
        assert(d.at <= d.source.len);
        return byte;
    }

    fn get16(d: *Decoder) u32 {
        const high: u32 = d.get8();
        const low: u32 = d.get8();
        assert(high <= 255);
        assert(low <= 255);
        return high << 8 | low;
    }

    fn at_end(d: *const Decoder) bool {
        assert(d.at <= d.source.len);
        // `decode` turned down files too long for 32-bit offsets
        assert(d.source.len <= std.math.maxInt(u32));
        return d.at == d.source.len;
    }

    fn skip(d: *Decoder, count: i32) void {
        assert(d.at <= d.source.len);
        if (count < 0) {
            d.at = @intCast(d.source.len);
            return;
        }
        const target = @as(u64, d.at) + @as(u32, @intCast(count));
        d.at = @intCast(@min(target, d.source.len));
        assert(d.at <= d.source.len);
    }
};

/// Whether `data` starts like a JPEG: fill bytes, then the start-of-image marker.
pub fn is_jpeg(data: []const u8) bool {
    if (data.len < 2 or data[0] != 0xff) return false;
    for (data[1..]) |byte| {
        if (byte != 0xff) return byte == marker_start;
    }
    return false;
}

/// Decodes a JPEG into gray pixels allocated from `alloc`, which the caller frees.
pub fn decode(alloc: std.mem.Allocator, data: []const u8) Error!Gray {
    var work = Workspace.init(alloc, std.math.maxInt(u32));
    defer work.reset();
    var sink = scaler.Sink{ .target = .{ .divided = 1 }, .out = alloc };
    try decode_rows(&work, data, &sink, 1);
    const pixels = sink.finish();
    assert(pixels.len == @as(u64, sink.size.width) * sink.size.height);
    return .{ .pixels = pixels, .width = sink.size.width, .height = sink.size.height };
}

/// Shrinks a picture can be decoded at: a block gives 8, 4, 2 or 1 samples a side.
pub fn shrink_valid(shrink: u8) bool {
    return shrink == 1 or shrink == 2 or shrink == 4 or shrink == 8;
}

/// Decodes a JPEG into `sink`, which `begin`s once the size is known, at 1 / `shrink`
/// of its size, its memory from `work`. On an error, the sink is as it was given.
pub fn decode_rows(work: *Workspace, data: []const u8, sink: *scaler.Sink, shrink: u8) Error!void {
    assert(shrink_valid(shrink));
    assert(sink.mode == .waiting);
    if (!is_jpeg(data)) return error.BadJpeg;
    if (data.len > std.math.maxInt(u32)) return error.BadJpeg;
    const tables = try work.allocator().create(Tables);
    const tables_made = work.mark();
    var plan = Plan{ .needed = .predicted, .streaming = true };
    // Each retry keeps more or streams less, so there are three plans at most
    for (0..3) |_| {
        decode_with(work, data, tables, sink, .{ .shrink = shrink, .plan = plan }) catch |err| {
            if (sink.mode != .waiting) sink.abandon();
            work.rewind(tables_made);
            switch (err) {
                // A colour marker after the first scan changed which components make
                // the gray: keep them all
                error.BadJpegRetry => {
                    assert(plan.needed == .predicted); // Every component was kept
                    plan.needed = .all;
                },
                // A later scan went back over rows already gone: keep them all
                error.Replan => {
                    assert(plan.streaming);
                    plan.streaming = false;
                },
                error.BadJpeg => return error.BadJpeg,
                error.OutOfMemory => return error.OutOfMemory,
            }
            continue;
        };
        assert(sink.mode != .waiting);
        return;
    }
    unreachable; // The plans ran out: each retry changed one, and both have changed
}

/// What a decoding keeps, and when its rows go.
const Plan = struct { needed: Needed, streaming: bool };

const RetryError = Error || error{ BadJpegRetry, Replan };

fn decode_with(
    work: *Workspace,
    data: []const u8,
    tables: *Tables,
    sink: *scaler.Sink,
    options: struct { shrink: u8, plan: Plan },
) RetryError!void {
    assert(data.len <= std.math.maxInt(u32));
    assert(shrink_valid(options.shrink));
    tables.* = std.mem.zeroes(Tables);
    var d = Decoder{
        .source = data,
        .tables = tables,
        .needed = options.plan.needed,
        .work = work,
        .sink = sink,
        .shrink = options.shrink,
        .side = 8 / options.shrink,
        .streaming = options.plan.streaming,
    };
    try decode_image(&d);
    assert(d.scans_decoded > 0);
    const gray_from = gray_components(&d);
    assert(gray_from.count >= 1);
    for (0..gray_from.count) |index| {
        const component = &d.component[index];
        const kept = if (d.progressive) component.coefficients.len > 0 else component.data.len > 0;
        if (!kept) return error.BadJpegRetry;
    }
    if (d.progressive) return finish_progressive(&d);
    if (!d.streaming) return finish_planes(&d);
    // The rows went with what made the gray at the first scan
    if (gray_from.kind != d.gray_from.kind or gray_from.count != d.gray_from.count) {
        return error.Replan;
    }
    assert(d.rows_out == d.out_height);
}

/// What the gray of a picture is made from, as stb_image decided it.
const GrayFrom = struct {
    /// Components 0 up to this one are upsampled.
    count: u8,
    kind: enum { y, rgb, cmyk, ycck },
};

fn gray_components(d: *const Decoder) GrayFrom {
    assert(d.channels == 1 or d.channels == 3 or d.channels == 4);
    const is_rgb = d.channels == 3 and (d.rgb_names == 3 or (d.app14 == 0 and !d.jfif));
    if (d.channels == 3 and !is_rgb) return .{ .count = 1, .kind = .y };
    if (d.channels == 1) return .{ .count = 1, .kind = .y };
    if (is_rgb) return .{ .count = 3, .kind = .rgb };
    assert(d.channels == 4);
    if (d.app14 == 0) return .{ .count = 4, .kind = .cmyk };
    if (d.app14 == 2) return .{ .count = 4, .kind = .ycck };
    // Only the first component counts: stb_image upsampled all four, then kept it
    return .{ .count = 1, .kind = .y };
}

/// Decides, at the first scan, which components to keep samples of.
fn predict_kept(d: *Decoder) void {
    assert(d.channels >= 1);
    const gray_from = gray_components(d);
    for (0..components_max) |index| {
        d.keep[index] = d.needed == .all or index < gray_from.count;
    }
    // The gray is always made from the first component at least
    assert(d.keep[0]);
}

// Reading the file's markers.

/// The next marker: one the bit reader found, or the next in the file.
fn get_marker(d: *Decoder) u8 {
    assert(d.at <= d.source.len);
    if (d.marker != marker_none) {
        const waiting = d.marker;
        d.marker = marker_none;
        return waiting;
    }
    assert(d.marker == marker_none);
    var byte = d.get8();
    if (byte != 0xff) return marker_none;
    // Fill bytes before a marker: bounded by the file, past whose end `get8` gives 0
    while (byte == 0xff) byte = d.get8();
    return byte;
}

const marker_start = 0xd8;
const marker_end = 0xd9;
const marker_scan = 0xda;
const marker_lines = 0xdc;
const marker_restart_first = 0xd0;
const marker_restart_last = 0xd7;
const marker_frame_progressive = 0xc2;

comptime {
    assert(marker_restart_last - marker_restart_first == 7);
    assert(marker_start > marker_restart_last);
}

fn is_restart(marker: u8) bool {
    return marker >= marker_restart_first and marker <= marker_restart_last;
}

/// Baseline, extended and progressive frames: the Huffman-coded 8-bit ones.
fn is_frame(marker: u8) bool {
    return marker == 0xc0 or marker == 0xc1 or marker == marker_frame_progressive;
}

/// Reads a marker's segment. False for one stb_image couldn't read.
fn process_marker(d: *Decoder, marker: u8) bool {
    assert(d.at <= d.source.len);
    assert(d.channels <= components_max);
    switch (marker) {
        marker_none => return false,
        0xdd => {
            if (d.get16() != 4) return false;
            d.restart_interval = d.get16();
            return true;
        },
        0xdb => return read_quantization(d),
        0xc4 => return read_huffman(d),
        else => {},
    }
    if ((marker >= 0xe0 and marker <= 0xef) or marker == 0xfe) return read_application(d, marker);
    return false;
}

fn read_quantization(d: *Decoder) bool {
    var left: i32 = @as(i32, @intCast(d.get16())) - 2;
    // Each table takes at least 65 bytes of the segment's 64 KB
    while (left > 0) {
        const q = d.get8();
        const precision = q >> 4;
        const table = q & 15;
        if (precision != 0 and precision != 1) return false;
        if (table >= tables_max) return false;
        assert(precision <= 1);
        const target = &d.tables.dequant[table];
        for (0..block_length) |index| {
            const value: u32 = if (precision == 1) d.get16() else d.get8();
            target[dezigzag[index]] = @intCast(value);
        }
        left -= if (precision == 1) 129 else 65;
    }
    assert(left <= 0);
    return left == 0;
}

fn read_huffman(d: *Decoder) bool {
    var left: i32 = @as(i32, @intCast(d.get16())) - 2;
    // Each table takes at least 17 bytes of the segment's 64 KB
    while (left > 0) {
        const q = d.get8();
        const class = q >> 4;
        const table = q & 15;
        if (class > 1 or table >= tables_max) return false;
        var counts: [16]u32 = undefined;
        var total: u32 = 0;
        for (&counts) |*count| {
            count.* = d.get8();
            total += count.*;
        }
        if (total > 256) return false;
        assert(table < tables_max);
        left -= 17;
        const huffman = if (class == 0) &d.tables.dc[table] else &d.tables.ac[table];
        if (!build_huffman(huffman, &counts)) return false;
        for (huffman.values[0..total]) |*value| value.* = d.get8();
        if (class != 0) build_fast_ac(&d.tables.fast_ac[table], huffman);
        left -= @intCast(total);
    }
    assert(left <= 0);
    return left == 0;
}

/// An APPn or comment segment: only JFIF and Adobe's colour transform matter.
fn read_application(d: *Decoder, marker: u8) bool {
    assert(marker >= 0xe0);
    var left: i32 = @intCast(d.get16());
    if (left < 2) return false;
    left -= 2;
    if (marker == 0xe0 and left >= 5) {
        var ok = true;
        for ("JFIF\x00") |expected| {
            if (d.get8() != expected) ok = false;
        }
        left -= 5;
        if (ok) d.jfif = true;
    } else if (marker == 0xee and left >= 12) {
        var ok = true;
        for ("Adobe\x00") |expected| {
            if (d.get8() != expected) ok = false;
        }
        left -= 6;
        if (ok) {
            _ = d.get8(); // Version
            _ = d.get16(); // Flags
            _ = d.get16();
            d.app14 = d.get8();
            left -= 6;
        }
    }
    assert(left >= 0);
    d.skip(left);
    return true;
}

fn read_scan_header(d: *Decoder) bool {
    assert(d.channels >= 1);
    const length = d.get16();
    const count = d.get8();
    if (count < 1 or count > components_max or count > d.channels) return false;
    if (length != 6 + 2 * @as(u32, count)) return false;
    d.scan_count = count;
    for (0..count) |index| {
        const id = d.get8();
        const q = d.get8();
        const which = for (0..d.channels) |candidate| {
            if (d.component[candidate].id == id) break candidate;
        } else return false;
        if (q >> 4 >= tables_max or q & 15 >= tables_max) return false;
        d.component[which].dc_table = q >> 4;
        d.component[which].ac_table = q & 15;
        d.order[index] = @intCast(which);
    }
    d.spec_start = d.get8();
    d.spec_end = d.get8();
    const approximation = d.get8();
    d.succ_high = approximation >> 4;
    d.succ_low = approximation & 15;
    if (d.progressive) {
        if (d.spec_start > 63 or d.spec_end > 63 or d.spec_start > d.spec_end) return false;
        if (d.succ_high > 13 or d.succ_low > 13) return false;
    } else {
        if (d.spec_start != 0 or d.succ_high != 0 or d.succ_low != 0) return false;
        d.spec_end = 63;
    }
    assert(d.scan_count >= 1);
    return true;
}

fn read_frame_header(d: *Decoder) Error!void {
    const length = d.get16();
    if (length < 11) return error.BadJpeg;
    if (d.get8() != 8) return error.BadJpeg; // 8-bit samples only
    d.height = d.get16();
    d.width = d.get16();
    if (d.height == 0 or d.width == 0) return error.BadJpeg;
    const channels = d.get8();
    if (channels != 1 and channels != 3 and channels != 4) return error.BadJpeg;
    d.channels = channels;
    if (length != 8 + 3 * @as(u32, channels)) return error.BadJpeg;
    d.rgb_names = 0;
    for (d.component[0..channels], 0..) |*component, index| {
        component.id = d.get8();
        if (channels == 3 and component.id == "RGB"[index]) d.rgb_names += 1;
        const sampling = d.get8();
        component.h = sampling >> 4;
        component.v = sampling & 15;
        if (component.h == 0 or component.h > 4) return error.BadJpeg;
        if (component.v == 0 or component.v > 4) return error.BadJpeg;
        component.quant = d.get8();
        if (component.quant >= tables_max) return error.BadJpeg;
    }
    if (@as(u64, d.width) * d.height * channels > samples_max) return error.BadJpeg;
    for (d.component[0..channels]) |component| {
        d.h_max = @max(d.h_max, component.h);
        d.v_max = @max(d.v_max, component.v);
    }
    assert(d.h_max <= 4);
    assert(d.v_max <= 4);
    // Upsampling only goes by whole factors
    for (d.component[0..channels]) |component| {
        if (d.h_max % component.h != 0 or d.v_max % component.v != 0) return error.BadJpeg;
    }
    try size_components(d);
    assert(d.mcu_x > 0);
}

/// Works out each component's size, at the picture's own and at the decoder's shrink.
fn size_components(d: *Decoder) Error!void {
    assert(d.h_max >= 1);
    assert(d.v_max >= 1);
    const mcu_width = @as(u32, d.h_max) * 8;
    const mcu_height = @as(u32, d.v_max) * 8;
    d.mcu_x = (d.width + mcu_width - 1) / mcu_width;
    d.mcu_y = (d.height + mcu_height - 1) / mcu_height;
    d.out_width = shrunk(d.width, d.shrink);
    d.out_height = shrunk(d.height, d.shrink);
    for (d.component[0..d.channels]) |*component| {
        component.x = (d.width * component.h + d.h_max - 1) / d.h_max;
        component.y = (d.height * component.v + d.v_max - 1) / d.v_max;
        component.w2 = d.mcu_x * component.h * 8;
        component.h2 = d.mcu_y * component.v * 8;
        component.out_x = shrunk(component.x, d.shrink);
        component.out_y = shrunk(component.y, d.shrink);
        component.stride = component.w2 / d.shrink;
        component.coefficients_width = component.w2 / 8;
        if (d.progressive) {
            const count = @as(u64, component.w2) * component.h2;
            if (count > samples_max) return error.BadJpeg;
        }
    }
}

/// A length at 1 / `shrink`, rounded up.
fn shrunk(length: u32, shrink: u8) u32 {
    assert(shrink_valid(shrink));
    assert(length > 0);
    return @intCast(scaler.divide_up(length, shrink));
}

/// At the first scan: decides which components to keep and makes room for them, and
/// for the gray the sink is given.
fn begin_scans(d: *Decoder) Error!void {
    assert(d.scans_decoded == 0);
    assert(d.scan_count >= 1);
    predict_kept(d);
    const work = d.work.allocator();
    if (d.progressive) {
        d.streaming = false;
        try allocate_coefficients(d);
    } else {
        // Every component kept comes in this scan, or the rows wait for the last
        for (0..d.channels) |index| {
            if (d.keep[index] and !in_scan(d, @intCast(index))) d.streaming = false;
        }
        try allocate_kept(d);
    }
    try d.sink.begin(work, .{ .width = d.out_width, .height = d.out_height }, .rows);
    if (d.streaming) try begin_rows(d);
}

fn in_scan(d: *const Decoder, index: u8) bool {
    assert(index < d.channels);
    assert(d.scan_count <= components_max);
    for (d.order[0..d.scan_count]) |n| {
        if (n == index) return true;
    }
    return false;
}

/// Makes room for the samples of each component kept: a few rows of blocks when they
/// go to the sink as they come, else all of them.
fn allocate_kept(d: *Decoder) Error!void {
    assert(d.channels >= 1);
    assert(!d.progressive);
    for (d.component[0..d.channels], 0..) |*component, index| {
        if (!d.keep[index]) continue;
        const count = @as(u64, component.w2) * component.h2;
        if (count > samples_max) return error.BadJpeg;
        const rows = if (d.streaming) band_rows(d, component) * 2 else component.h2 / d.shrink;
        try allocate_samples(d, component, rows);
    }
    assert(d.component[0].data.len > 0);
}

/// Rows of samples a row of MCUs gives a component.
fn band_rows(d: *const Decoder, component: *const Component) u32 {
    assert(component.v >= 1);
    assert(d.side >= 1);
    return @as(u32, component.v) * d.side;
}

fn allocate_samples(d: *Decoder, component: *Component, rows: u32) Error!void {
    assert(rows % d.side == 0); // Whole blocks, which never wrap
    assert(component.stride > 0);
    component.data_rows = rows;
    component.data = try d.work.allocator().alloc(u8, @intCast(@as(u64, component.stride) * rows));
    @memset(component.data, 0);
    component.rows_done = 0;
}

/// Makes room for a progressive picture's coefficients: whole for the components the
/// gray is made of, a corner of each block's when shrunk, only which aren't zero for
/// the others.
fn allocate_coefficients(d: *Decoder) Error!void {
    assert(d.progressive);
    assert(d.channels >= 1);
    const work = d.work.allocator();
    for (d.component[0..d.channels], 0..) |*component, index| {
        const blocks = @as(u64, component.coefficients_width) * (component.h2 / 8);
        assert(blocks * block_length <= samples_max); // `size_components` checked
        if (d.keep[index]) {
            const per_block = @as(u64, d.side) * d.side;
            component.coefficients = try work.alloc(i16, @intCast(blocks * per_block));
            @memset(component.coefficients, 0);
        }
        if (!d.keep[index] or d.shrink > 1) {
            component.masks = try work.alloc(u64, @intCast(blocks));
            @memset(component.masks, 0);
        }
    }
    assert(d.component[0].coefficients.len > 0);
}

fn read_header(d: *Decoder) Error!void {
    if (get_marker(d) != marker_start) return error.BadJpeg;
    var marker = get_marker(d);
    // Each marker read takes at least a byte of the file
    for (0..d.source.len + 1) |_| {
        if (is_frame(marker)) break;
        if (!process_marker(d, marker)) return error.BadJpeg;
        marker = get_marker(d);
        // Some files pad between segments
        while (marker == marker_none) {
            if (d.at_end()) return error.BadJpeg;
            marker = get_marker(d);
        }
    } else return error.BadJpeg;
    assert(is_frame(marker));
    d.progressive = marker == marker_frame_progressive;
    try read_frame_header(d);
    assert(d.channels >= 1);
}

/// Skips junk after a scan, up to what looks like a marker.
fn skip_junk_at_end(d: *Decoder) u8 {
    assert(d.at <= d.source.len);
    while (!d.at_end()) {
        var byte = d.get8();
        while (byte == 0xff) {
            if (d.at_end()) return marker_none;
            byte = d.get8();
            if (byte != 0x00 and byte != 0xff) return byte;
        }
    }
    assert(d.at_end());
    return marker_none;
}

/// Reads the whole file: its header, then scan after scan, into samples.
fn decode_image(d: *Decoder) RetryError!void {
    assert(d.scans_decoded == 0);
    try read_header(d);
    assert(d.width > 0);
    var marker = get_marker(d);
    // Each pass takes at least a byte of the file, or ends the loop
    for (0..d.source.len + 1) |_| {
        if (marker == marker_end) break;
        if (marker == marker_scan) {
            if (!read_scan_header(d)) return error.BadJpeg;
            if (d.scans_decoded == 0) {
                try begin_scans(d);
            } else if (d.streaming) {
                // A later scan going back over rows already handed on
                for (0..d.channels) |index| {
                    if (d.keep[index] and in_scan(d, @intCast(index))) return error.Replan;
                }
            }
            try decode_scan(d);
            d.scans_decoded += 1;
            if (d.marker == marker_none) d.marker = skip_junk_at_end(d);
            marker = get_marker(d);
            if (is_restart(marker)) marker = get_marker(d);
        } else if (marker == marker_lines) {
            const length = d.get16();
            const lines = d.get16();
            if (length != 4 or lines != d.height) return error.BadJpeg;
            marker = get_marker(d);
        } else {
            // At a marker it couldn't read, or the end of the file, stb_image kept
            // what it had. A progressive picture may be missing its finest scans then.
            if (!process_marker(d, marker)) {
                if (d.progressive) return error.BadJpeg;
                break;
            }
            marker = get_marker(d);
        }
    } else return error.BadJpeg;
    if (d.scans_decoded == 0) return error.BadJpeg;
    if (d.cut_short) return error.BadJpeg;
}

// The bit reader.

fn reset(d: *Decoder) void {
    assert(d.channels <= components_max);
    check_made_up(d);
    d.made_up_bits = 0;
    d.code_bits = 0;
    d.code_buffer = 0;
    d.nomore = false;
    for (&d.component) |*component| component.dc_prediction = 0;
    d.marker = marker_none;
    d.todo = if (d.restart_interval > 0) @intCast(d.restart_interval) else std.math.maxInt(i32);
    d.eob_run = 0;
    assert(d.todo > 0);
}

/// Notes whether any made-up bit was used: those sit below every real one, so some
/// were once fewer bits are left than were made up.
fn check_made_up(d: *Decoder) void {
    assert(d.made_up_bits >= 0);
    assert(d.made_up_bits <= 32);
    if (d.made_up_bits > d.code_bits) d.cut_short = true;
}

/// Fills the bit buffer to at least 25 bits, stopping at a marker.
fn grow_buffer(d: *Decoder) void {
    assert(d.code_bits <= 24);
    assert(d.code_bits >= 0);
    check_made_up(d);
    // Each turn adds 8 bits, so this runs at most four times
    while (d.code_bits <= 24) {
        var byte: u32 = 0;
        if (!d.nomore) {
            // Past the end of the file: zeros, as stb_image read, noted as made up
            if (d.at_end()) d.made_up_bits = @min(d.made_up_bits, d.code_bits) + 8;
            byte = d.get8();
        }
        if (byte == 0xff) {
            var next = d.get8();
            // Fill bytes: bounded by the file, past whose end `get8` gives 0
            while (next == 0xff) next = d.get8();
            if (next != 0) {
                d.marker = next;
                d.nomore = true;
                return;
            }
        }
        d.code_buffer |= byte << @intCast(24 - d.code_bits);
        d.code_bits += 8;
    }
}

/// Decodes one Huffman symbol: an error for a code the table doesn't have.
fn huffman_decode(d: *Decoder, h: *const Huffman) Error!u8 {
    if (d.code_bits < 16) grow_buffer(d);
    const fast_index = (d.code_buffer >> (32 - fast_bits)) & (fast_size - 1);
    const symbol = h.fast[fast_index];
    if (symbol < fast_none) {
        const size = h.size[symbol];
        assert(size <= fast_bits);
        if (size > d.code_bits) return error.BadJpeg;
        d.code_buffer = std.math.shl(u32, d.code_buffer, size);
        d.code_bits -= size;
        return h.values[symbol];
    }
    // Longer codes: compare against each length's largest code, preshifted to 16 bits
    const top = d.code_buffer >> 16;
    var length: u5 = fast_bits + 1;
    while (length < 17 and top >= h.maxcode[length]) length += 1;
    assert(length <= 17);
    if (length == 17) return error.BadJpeg;
    if (length > d.code_bits) return error.BadJpeg;
    const index = @as(i32, @intCast((d.code_buffer >> @intCast(32 - @as(u32, length))) &
        bit_mask[length])) + h.delta[length];
    if (index < 0 or index >= 256) return error.BadJpeg;
    d.code_bits -= length;
    d.code_buffer = std.math.shl(u32, d.code_buffer, length);
    return h.values[@intCast(index)];
}

/// Reads `n` bits as a signed value, the JPEG way. Zero if the data ran out.
fn extend_receive(d: *Decoder, n: u8) i32 {
    assert(n >= 1);
    assert(n <= 15);
    if (d.code_bits < n) grow_buffer(d);
    if (d.code_bits < n) return 0;
    const negative = d.code_buffer >> 31 == 0;
    const rotated = std.math.rotl(u32, d.code_buffer, n);
    d.code_buffer = rotated & ~bit_mask[n];
    const magnitude: i32 = @intCast(rotated & bit_mask[n]);
    d.code_bits -= n;
    return if (negative) magnitude + extend_bias[n] else magnitude;
}

fn get_bits(d: *Decoder, n: u8) u32 {
    assert(n >= 1);
    assert(n <= 16);
    if (d.code_bits < n) grow_buffer(d);
    if (d.code_bits < n) return 0;
    const rotated = std.math.rotl(u32, d.code_buffer, n);
    d.code_buffer = rotated & ~bit_mask[n];
    d.code_bits -= n;
    return rotated & bit_mask[n];
}

fn get_bit(d: *Decoder) bool {
    assert(d.code_bits <= 32);
    if (d.code_bits < 1) grow_buffer(d);
    if (d.code_bits < 1) return false;
    const bit = d.code_buffer & 0x80000000 != 0;
    d.code_buffer <<= 1;
    d.code_bits -= 1;
    assert(d.code_bits >= 0);
    return bit;
}

fn build_huffman(h: *Huffman, counts: *const [16]u32) bool {
    var k: u32 = 0;
    for (counts, 0..) |count, index| {
        for (0..count) |_| {
            h.size[k] = @intCast(index + 1);
            k += 1;
            if (k >= 257) return false;
        }
    }
    h.size[k] = 0;
    var code: u32 = 0;
    k = 0;
    for (1..17) |length| {
        h.delta[length] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
        if (h.size[k] == length) {
            // Bounded by the 256 symbols counted above
            while (h.size[k] == length) {
                h.code[k] = @truncate(code);
                k += 1;
                code += 1;
            }
            if (code - 1 >= @as(u32, 1) << @intCast(length)) return false;
        }
        h.maxcode[length] = code << @intCast(16 - length);
        code <<= 1;
    }
    h.maxcode[17] = 0xffffffff;
    // Every symbol counted has its code: the walk reached the end of the sizes
    assert(h.size[k] == 0);
    assert(k <= 256);
    build_fast(h, k);
    return true;
}

fn build_fast(h: *Huffman, symbols: u32) void {
    assert(symbols <= 256);
    @memset(&h.fast, fast_none);
    for (0..symbols) |index| {
        const size = h.size[index];
        if (size > fast_bits) continue;
        assert(size >= 1);
        const first = @as(u32, h.code[index]) << @intCast(fast_bits - size);
        const count = @as(u32, 1) << @intCast(fast_bits - size);
        @memset(h.fast[first..][0..count], @intCast(index));
    }
}

/// A table that decodes a short AC code and its value in one step: the value times
/// 256, the zero run times 16, and the bits taken.
fn build_fast_ac(fast_ac: *[fast_size]i16, h: *const Huffman) void {
    assert(h.maxcode[17] == 0xffffffff);
    for (fast_ac, 0..) |*entry, index| {
        entry.* = 0;
        const symbol = h.fast[index];
        if (symbol == fast_none) continue;
        const rs = h.values[symbol];
        const run: i32 = (rs >> 4) & 15;
        const magnitude_bits: u32 = rs & 15;
        const length: u32 = h.size[symbol];
        if (magnitude_bits == 0 or length + magnitude_bits > fast_bits) continue;
        const shifted = (@as(u32, @intCast(index)) << @intCast(length)) & (fast_size - 1);
        var k: i32 = @intCast(shifted >> @intCast(fast_bits - magnitude_bits));
        const m = @as(i32, 1) << @intCast(magnitude_bits - 1);
        if (k < m) k += extend_bias[magnitude_bits];
        assert(length >= 1);
        if (k >= -128 and k <= 127) {
            entry.* = @intCast(k * 256 + run * 16 + @as(i32, @intCast(length + magnitude_bits)));
        }
    }
}

// Scans.

fn decode_scan(d: *Decoder) Error!void {
    assert(d.scan_count >= 1);
    reset(d);
    if (d.scan_count == 1) {
        try decode_scan_single(d);
    } else {
        try decode_scan_interleaved(d);
    }
    check_made_up(d);
    assert(d.todo >= 0);
}

/// After each MCU: at the end of a restart interval, expects a restart marker. Only
/// the last MCU of a scan may go without one (stb_image stopped the scan there, and
/// left the rest of the picture blank).
fn next_restart(d: *Decoder, last: bool) Error!void {
    assert(d.todo > 0);
    d.todo -= 1;
    if (d.todo > 0) return;
    if (d.code_bits < 24) grow_buffer(d);
    if (!is_restart(d.marker)) {
        if (last) return;
        return error.BadJpeg;
    }
    reset(d);
    assert(d.marker == marker_none);
}

/// One component on its own, block by block in raster order.
fn decode_scan_single(d: *Decoder) Error!void {
    const n = d.order[0];
    const component = &d.component[n];
    const blocks_x = (component.x + 7) >> 3;
    const blocks_y = (component.y + 7) >> 3;
    assert(blocks_x <= component.w2 / 8);
    assert(blocks_y <= component.h2 / 8);
    for (0..blocks_y) |block_y| {
        for (0..blocks_x) |block_x| {
            try decode_block_at(d, n, @intCast(block_x), @intCast(block_y), true);
            try next_restart(d, block_y + 1 == blocks_y and block_x + 1 == blocks_x);
        }
        if (d.streaming and component.data.len > 0) {
            component.rows_done = @as(u32, @intCast(block_y + 1)) * d.side;
            emit_rows(d);
        }
    }
}

/// Several components, an MCU at a time.
fn decode_scan_interleaved(d: *Decoder) Error!void {
    assert(d.scan_count > 1);
    assert(d.mcu_x > 0);
    for (0..d.mcu_y) |mcu_y| {
        for (0..d.mcu_x) |mcu_x| {
            for (d.order[0..d.scan_count]) |n| {
                const component = &d.component[n];
                for (0..component.v) |y| {
                    for (0..component.h) |x| {
                        const block_x: u32 = @intCast(mcu_x * component.h + x);
                        const block_y: u32 = @intCast(mcu_y * component.v + y);
                        try decode_block_at(d, n, block_x, block_y, false);
                    }
                }
            }
            try next_restart(d, mcu_y + 1 == d.mcu_y and mcu_x + 1 == d.mcu_x);
        }
        if (d.streaming) stream_band(d, @intCast(mcu_y));
    }
}

/// After a row of MCUs of the first scan: the rows it finished go to the sink.
fn stream_band(d: *Decoder, mcu_y: u32) void {
    assert(d.streaming);
    assert(mcu_y < d.mcu_y);
    for (d.order[0..d.scan_count]) |n| {
        const component = &d.component[n];
        if (component.data.len > 0) component.rows_done = (mcu_y + 1) * band_rows(d, component);
    }
    emit_rows(d);
}

fn decode_block_at(d: *Decoder, n: u8, block_x: u32, block_y: u32, single: bool) Error!void {
    const component = &d.component[n];
    assert(block_x < component.w2 / 8);
    assert(block_y < component.h2 / 8);
    if (!d.progressive) {
        var block: [block_length]i16 = undefined;
        const dequant = &d.tables.dequant[component.quant];
        try decode_block(d, &block, n, dequant);
        if (component.data.len > 0) put_block(d, component, block_x, block_y, &block);
        return;
    }
    const index = block_x + block_y * component.coefficients_width;
    if (component.masks.len == 0) {
        const whole = component.coefficients[index * block_length ..][0..block_length];
        return decode_block_progressive(d, Whole, .{ .values = whole }, n, single);
    }
    const per_block = @as(u32, d.side) * d.side;
    const kept = if (component.coefficients.len > 0)
        component.coefficients[index * per_block ..][0..per_block]
    else
        component.coefficients[0..0];
    const sparse = Sparse{ .mask = &component.masks[index], .values = kept, .side = d.side };
    return decode_block_progressive(d, Sparse, sparse, n, single);
}

fn decode_block_progressive(
    d: *Decoder,
    comptime Block: type,
    block: Block,
    n: u8,
    single: bool,
) Error!void {
    assert(d.progressive);
    assert(n < d.channels);
    // AC coefficients come one component a scan: several at once are DC
    if (d.spec_start == 0 or !single) return decode_block_dc(d, Block, block, n);
    const table = d.component[n].ac_table;
    return decode_block_ac(d, Block, block, &d.tables.ac[table], &d.tables.fast_ac[table]);
}

/// A progressive block whose every coefficient is kept.
const Whole = struct {
    values: *[block_length]i16,

    inline fn clear(b: Whole) void {
        @memset(b.values, 0);
    }

    inline fn set(b: Whole, at: u8, value: i16) void {
        b.values[at] = value;
    }

    inline fn nonzero(b: Whole, at: u8) bool {
        return b.values[at] != 0;
    }

    inline fn slot(b: Whole, at: u8) ?*i16 {
        return &b.values[at];
    }
};

/// A progressive block of which only the top-left `side` square of coefficients is
/// kept (none when `side` is 0 or `values` empty), with a bit for every coefficient
/// saying whether it's zero. A refinement scan reads bits for a coefficient only when
/// it isn't zero, and a refinement never makes one zero, so the bits read the scans
/// exactly as the whole block would.
const Sparse = struct {
    mask: *u64,
    values: []i16,
    side: u8,

    fn kept(b: Sparse, at: u8) ?u32 {
        assert(at < block_length);
        assert(b.values.len == 0 or b.values.len == @as(u32, b.side) * b.side);
        if (b.values.len == 0) return null;
        const row = at / 8;
        const column = at % 8;
        if (row >= b.side or column >= b.side) return null;
        return @as(u32, row) * b.side + column;
    }

    fn clear(b: Sparse) void {
        b.mask.* = 0;
        @memset(b.values, 0);
    }

    fn set(b: Sparse, at: u8, value: i16) void {
        const bit = @as(u64, 1) << @intCast(at);
        if (value != 0) b.mask.* |= bit else b.mask.* &= ~bit;
        if (b.kept(at)) |index| b.values[index] = value;
    }

    fn nonzero(b: Sparse, at: u8) bool {
        assert(at < block_length);
        return b.mask.* & (@as(u64, 1) << @intCast(at)) != 0;
    }

    fn slot(b: Sparse, at: u8) ?*i16 {
        const index = b.kept(at) orelse return null;
        return &b.values[index];
    }
};

/// The DC difference, added to the component's running prediction.
fn decode_dc(d: *Decoder, n: u8) Error!i32 {
    const component = &d.component[n];
    const t = try huffman_decode(d, &d.tables.dc[component.dc_table]);
    if (t > 15) return error.BadJpeg;
    const difference = if (t > 0) extend_receive(d, @intCast(t)) else 0;
    const dc = std.math.add(i32, component.dc_prediction, difference) catch return error.BadJpeg;
    component.dc_prediction = dc;
    return dc;
}

fn decode_block(
    d: *Decoder,
    block: *[block_length]i16,
    n: u8,
    dequant: *const [block_length]u16,
) Error!void {
    assert(n < d.channels);
    assert(!d.progressive);
    const component = &d.component[n];
    if (d.code_bits < 16) grow_buffer(d);
    @memset(block, 0);
    const dc = try decode_dc(d, n);
    if (!fits_short(dc, dequant[0])) return error.BadJpeg;
    block[0] = @intCast(dc * dequant[0]);
    const fast_ac = &d.tables.fast_ac[component.ac_table];
    const ac = &d.tables.ac[component.ac_table];
    var k: u32 = 1;
    // Each turn moves at least one coefficient on
    while (k < block_length) {
        if (d.code_bits < 16) grow_buffer(d);
        const fast = fast_ac[(d.code_buffer >> (32 - fast_bits)) & (fast_size - 1)];
        if (fast != 0) {
            k += @intCast((fast >> 4) & 15);
            const size: u5 = @intCast(fast & 15);
            if (size > d.code_bits) return error.BadJpeg;
            d.code_buffer = std.math.shl(u32, d.code_buffer, size);
            d.code_bits -= size;
            const zig = dezigzag[k];
            k += 1;
            block[zig] = @truncate(@as(i32, fast >> 8) *% dequant[zig]);
            continue;
        }
        const rs = try huffman_decode(d, ac);
        const s: u8 = @intCast(rs & 15);
        const r: u32 = @intCast(rs >> 4);
        if (s == 0) {
            if (rs != 0xf0) break; // End of block
            k += 16;
        } else {
            k += r;
            const zig = dezigzag[k];
            k += 1;
            block[zig] = @truncate(extend_receive(d, s) *% @as(i32, dequant[zig]));
        }
    }
    assert(k <= dezigzag.len);
}

/// Whether `a * b` fits a 16-bit coefficient.
fn fits_short(a: i32, b: i32) bool {
    assert(b >= 0);
    assert(b <= std.math.maxInt(u16));
    const product = @as(i64, a) * b;
    return product >= std.math.minInt(i16) and product <= std.math.maxInt(i16);
}

fn decode_block_dc(d: *Decoder, comptime Block: type, block: Block, n: u8) Error!void {
    assert(n < d.channels);
    assert(d.progressive);
    if (d.spec_end != 0) return error.BadJpeg;
    if (d.code_bits < 16) grow_buffer(d);
    if (d.succ_high == 0) {
        // The first DC scan
        block.clear();
        const dc = try decode_dc(d, n);
        const scale = @as(i32, 1) << @intCast(d.succ_low);
        if (!fits_short(dc, scale)) return error.BadJpeg;
        block.set(0, @intCast(dc * scale));
    } else {
        // A refinement: one more bit
        if (get_bit(d)) {
            if (block.slot(0)) |dc| dc.* +%= @as(i16, 1) << @intCast(d.succ_low);
        }
    }
    assert(d.succ_low <= 13);
}

fn decode_block_ac(
    d: *Decoder,
    comptime Block: type,
    block: Block,
    ac: *const Huffman,
    fast_ac: *const [fast_size]i16,
) Error!void {
    if (d.spec_start == 0) return error.BadJpeg;
    assert(d.spec_end <= 63);
    if (d.succ_high == 0) return decode_block_ac_first(d, Block, block, ac, fast_ac);
    const bit = @as(i16, 1) << @intCast(d.succ_low);
    if (d.eob_run > 0) {
        d.eob_run -= 1;
        for (d.spec_start..@as(u32, d.spec_end) + 1) |k| refine(d, Block, block, dezigzag[k], bit);
        return;
    }
    return decode_block_ac_refine(d, Block, block, ac, bit);
}

/// The first scan of a band of AC coefficients.
fn decode_block_ac_first(
    d: *Decoder,
    comptime Block: type,
    block: Block,
    ac: *const Huffman,
    fast_ac: *const [fast_size]i16,
) Error!void {
    assert(d.succ_high == 0);
    assert(d.spec_start >= 1);
    if (d.eob_run > 0) {
        d.eob_run -= 1;
        return;
    }
    const shift: u4 = @intCast(d.succ_low);
    var k: u32 = d.spec_start;
    // Each turn moves at least one coefficient on
    while (k <= d.spec_end) {
        if (d.code_bits < 16) grow_buffer(d);
        const fast = fast_ac[(d.code_buffer >> (32 - fast_bits)) & (fast_size - 1)];
        if (fast != 0) {
            k += @intCast((fast >> 4) & 15);
            const size: u5 = @intCast(fast & 15);
            if (size > d.code_bits) return error.BadJpeg;
            d.code_buffer = std.math.shl(u32, d.code_buffer, size);
            d.code_bits -= size;
            block.set(dezigzag[k], @truncate(@as(i32, fast >> 8) *% (@as(i32, 1) << shift)));
            k += 1;
            continue;
        }
        const rs = try huffman_decode(d, ac);
        const s: u8 = @intCast(rs & 15);
        const r: u8 = @intCast(rs >> 4);
        if (s == 0) {
            if (r < 15) {
                d.eob_run = @as(i32, 1) << @intCast(r);
                if (r > 0) d.eob_run += @intCast(get_bits(d, r));
                d.eob_run -= 1;
                break;
            }
            k += 16;
        } else {
            k += r;
            block.set(dezigzag[k], @truncate(extend_receive(d, s) *% (@as(i32, 1) << shift)));
            k += 1;
        }
    }
    assert(d.eob_run >= 0);
}

/// One correction bit for a coefficient already known not to be zero.
fn refine(d: *Decoder, comptime Block: type, block: Block, at: u8, bit: i16) void {
    assert(bit > 0);
    assert(bit <= 1 << 13);
    if (!block.nonzero(at)) return;
    if (!get_bit(d)) return;
    // A coefficient not kept: the bit is read past, and it stays not zero
    const coefficient = block.slot(at) orelse return;
    if (coefficient.* & bit != 0) return;
    if (coefficient.* > 0) {
        coefficient.* +%= bit;
    } else {
        coefficient.* -%= bit;
    }
}

fn decode_block_ac_refine(
    d: *Decoder,
    comptime Block: type,
    block: Block,
    ac: *const Huffman,
    bit: i16,
) Error!void {
    assert(d.eob_run == 0);
    assert(bit > 0);
    var k: u32 = d.spec_start;
    // Each turn moves at least one coefficient on, or ends the band
    while (k <= d.spec_end) {
        const rs = try huffman_decode(d, ac);
        const s = rs & 15;
        var r: i32 = rs >> 4;
        var value: i16 = 0;
        if (s == 0) {
            if (r < 15) {
                d.eob_run = (@as(i32, 1) << @intCast(r)) - 1;
                if (r > 0) d.eob_run += @intCast(get_bits(d, @intCast(r)));
                r = 64; // Ends the block
            }
        } else {
            if (s != 1) return error.BadJpeg;
            value = if (get_bit(d)) bit else -bit;
        }
        // Moves past `r` coefficients still zero, refining those that aren't
        while (k <= d.spec_end) {
            const at = dezigzag[k];
            k += 1;
            if (block.nonzero(at)) {
                refine(d, Block, block, at, bit);
            } else {
                if (r == 0) {
                    block.set(at, value);
                    break;
                }
                r -= 1;
            }
        }
    }
    assert(k >= d.spec_start);
}

/// Transforms a progressive picture's gray components, a row of MCUs at a time, and
/// hands their rows to the sink.
fn finish_progressive(d: *Decoder) Error!void {
    assert(d.progressive);
    assert(d.rows_out == 0);
    for (d.component[0..gray_components(d).count]) |*component| {
        try allocate_samples(d, component, band_rows(d, component) * 2);
    }
    try begin_rows(d);
    for (0..d.mcu_y) |mcu_y| {
        for (d.component[0..d.gray_from.count]) |*component| {
            transform_band(d, component, @intCast(mcu_y));
        }
        emit_rows(d);
    }
    assert(d.rows_out == d.out_height);
}

/// Dequantizes and transforms one row of MCUs of a component's coefficients.
fn transform_band(d: *Decoder, component: *Component, mcu_y: u32) void {
    assert(d.progressive);
    assert(component.coefficients.len > 0);
    const dequant = &d.tables.dequant[component.quant];
    const blocks_x = (component.x + 7) >> 3;
    const blocks_y = (component.y + 7) >> 3;
    const first = mcu_y * component.v;
    for (first..@min(first + component.v, blocks_y)) |block_y| {
        for (0..blocks_x) |block_x| {
            const index = block_x + block_y * component.coefficients_width;
            var block: [block_length]i16 = @splat(0);
            if (component.masks.len == 0) {
                block = component.coefficients[index * block_length ..][0..block_length].*;
            } else {
                const per_block = @as(u32, d.side) * d.side;
                const kept = component.coefficients[index * per_block ..][0..per_block];
                for (0..d.side) |row| {
                    @memcpy(block[row * 8 ..][0..d.side], kept[row * d.side ..][0..d.side]);
                }
            }
            for (&block, dequant) |*coefficient, factor| coefficient.* *%= @bitCast(factor);
            put_block(d, component, @intCast(block_x), @intCast(block_y), &block);
        }
    }
    component.rows_done = (mcu_y + 1) * band_rows(d, component);
}

/// Each component's samples once every scan of a picture whose rows waited is read.
fn finish_planes(d: *Decoder) Error!void {
    assert(!d.progressive);
    assert(!d.streaming);
    try begin_rows(d);
    for (d.component[0..d.gray_from.count]) |*component| component.rows_done = component.data_rows;
    emit_rows(d);
    assert(d.rows_out == d.out_height);
}

// The inverse DCT: stb_image's integer one, from the IJG's jidctint.

/// A factor in 12-bit fixed point, rounded as stb_image did (toward zero, after adding
/// a half, so negative ones come out a step smaller than the IJG's).
fn fixed(comptime x: f32) i32 {
    comptime assert(x > -4);
    comptime assert(x < 4);
    return @intFromFloat(@as(f64, x * 4096) + 0.5);
}

comptime {
    assert(fixed(0.5411961) == 2217);
    assert(fixed(-1.847759065) == -7567);
    assert(fixed(0.765366865) == 3135);
    assert(fixed(1.175875602) == 4816);
    assert(fixed(0.298631336) == 1223);
    assert(fixed(2.053119869) == 8410);
    assert(fixed(3.072711026) == 12586);
    assert(fixed(1.501321110) == 6149);
    assert(fixed(-0.899976223) == -3685);
    assert(fixed(-2.562915447) == -10497);
    assert(fixed(-1.961570560) == -8034);
    assert(fixed(-0.390180644) == -1597);
}

const Idct = struct { t0: i32, t1: i32, t2: i32, t3: i32, x0: i32, x1: i32, x2: i32, x3: i32 };

/// One 8-point inverse DCT, in stb_image's order of operations and its wrapping.
inline fn idct_1d(s: [8]i32) Idct {
    var p2 = s[2];
    var p3 = s[6];
    var p1 = (p2 +% p3) *% fixed(0.5411961);
    var t2 = p1 +% p3 *% fixed(-1.847759065);
    var t3 = p1 +% p2 *% fixed(0.765366865);
    p2 = s[0];
    p3 = s[4];
    var t0 = (p2 +% p3) *% 4096;
    var t1 = (p2 -% p3) *% 4096;
    const x0 = t0 +% t3;
    const x3 = t0 -% t3;
    const x1 = t1 +% t2;
    const x2 = t1 -% t2;
    t0 = s[7];
    t1 = s[5];
    t2 = s[3];
    t3 = s[1];
    p3 = t0 +% t2;
    var p4 = t1 +% t3;
    p1 = t0 +% t3;
    p2 = t1 +% t2;
    const p5 = (p3 +% p4) *% fixed(1.175875602);
    t0 = t0 *% fixed(0.298631336);
    t1 = t1 *% fixed(2.053119869);
    t2 = t2 *% fixed(3.072711026);
    t3 = t3 *% fixed(1.501321110);
    p1 = p5 +% p1 *% fixed(-0.899976223);
    p2 = p5 +% p2 *% fixed(-2.562915447);
    p3 = p3 *% fixed(-1.961570560);
    p4 = p4 *% fixed(-0.390180644);
    t3 +%= p1 +% p4;
    t2 +%= p2 +% p3;
    t1 +%= p2 +% p4;
    t0 +%= p1 +% p3;
    return .{ .t0 = t0, .t1 = t1, .t2 = t2, .t3 = t3, .x0 = x0, .x1 = x1, .x2 = x2, .x3 = x3 };
}

fn clamp(x: i32) u8 {
    const clamped = std.math.clamp(x, 0, 255);
    assert(clamped >= 0);
    assert(clamped <= 255);
    return @intCast(clamped);
}

/// Transforms a block of coefficients into 8 x 8 samples, rows `stride` apart.
fn idct_block(target: []u8, stride: u32, block: *const [block_length]i16) void {
    assert(stride >= 8);
    assert(target.len >= 7 * stride + 8);
    var values: [block_length]i32 = undefined;
    for (0..8) |column| idct_column(block, &values, @intCast(column));
    for (0..8) |row| {
        const v = values[row * 8 ..][0..8];
        var r = idct_1d(v.*);
        // Undoes the scaling (1 << 17 in all, rounded) and moves -128..127 to 0..255
        const bias: i32 = 65536 + (128 << 17);
        r.x0 +%= bias;
        r.x1 +%= bias;
        r.x2 +%= bias;
        r.x3 +%= bias;
        const out = target[row * stride ..][0..8];
        out[0] = clamp((r.x0 +% r.t3) >> 17);
        out[7] = clamp((r.x0 -% r.t3) >> 17);
        out[1] = clamp((r.x1 +% r.t2) >> 17);
        out[6] = clamp((r.x1 -% r.t2) >> 17);
        out[2] = clamp((r.x2 +% r.t1) >> 17);
        out[5] = clamp((r.x2 -% r.t1) >> 17);
        out[3] = clamp((r.x3 +% r.t0) >> 17);
        out[4] = clamp((r.x3 -% r.t0) >> 17);
    }
}

fn idct_column(block: *const [block_length]i16, values: *[block_length]i32, column: u8) void {
    assert(column < 8);
    const d = block[column..];
    var s: [8]i32 = undefined;
    for (&s, 0..) |*value, row| value.* = d[row * 8];
    var all_zero = true;
    for (s[1..]) |value| {
        if (value != 0) all_zero = false;
    }
    if (all_zero) {
        // Only the DC term: the whole column is that
        for (0..8) |row| values[row * 8 + column] = s[0] *% 4;
        return;
    }
    var r = idct_1d(s);
    // Back down from 1 << 12, keeping two bits more than needed
    r.x0 +%= 512;
    r.x1 +%= 512;
    r.x2 +%= 512;
    r.x3 +%= 512;
    values[0 + column] = (r.x0 +% r.t3) >> 10;
    values[56 + column] = (r.x0 -% r.t3) >> 10;
    values[8 + column] = (r.x1 +% r.t2) >> 10;
    values[48 + column] = (r.x1 -% r.t2) >> 10;
    values[16 + column] = (r.x2 +% r.t1) >> 10;
    values[40 + column] = (r.x2 -% r.t1) >> 10;
    values[24 + column] = (r.x3 +% r.t0) >> 10;
    values[32 + column] = (r.x3 -% r.t0) >> 10;
    assert(values[column] == values[column]);
}

// Upsampling and the gray.

const ResampleKind = enum { copy, vertical, horizontal, both, generic };

/// Upsampling one component: the rows of its samples the next output row mixes,
/// `line0` above `line1`.
const Resample = struct {
    kind: ResampleKind,
    line0: u32 = 0,
    line1: u32 = 0,
    hs: u8,
    vs: u8,
    w_lores: u32,
    ystep: u8,
    ypos: u32 = 0,
    line_buffer: []u8,
};

/// Readies the rows: each component the gray is made from upsampled, and a row of gray
/// unless it's the first component's samples as they are.
fn begin_rows(d: *Decoder) Error!void {
    assert(d.rows_out == 0);
    assert(d.sink.mode != .waiting);
    d.gray_from = gray_components(d);
    for (d.resamples[0..d.gray_from.count], 0..) |*r, index| {
        r.* = try resample_for(d, @intCast(index));
    }
    const copied = d.resamples[0].kind == .copy;
    if (d.gray_from.kind != .y or !copied) {
        d.gray_line = try d.work.allocator().alloc(u8, d.out_width);
    }
    assert(d.gray_from.count <= d.channels);
}

/// Hands the sink every row of gray whose samples are all transformed.
fn emit_rows(d: *Decoder) void {
    assert(d.rows_out <= d.out_height);
    const count = d.gray_from.count;
    assert(count >= 1);
    // Each turn hands on a row
    while (d.rows_out < d.out_height) {
        for (d.resamples[0..count], d.component[0..count]) |r, component| {
            if (r.line1 >= component.rows_done) return;
        }
        var rows: [components_max][]const u8 = undefined;
        for (d.resamples[0..count], d.component[0..count], 0..) |*r, *component, index| {
            rows[index] = resample_row(r, component);
        }
        if (d.gray_line.len == 0) {
            d.sink.put_row(rows[0][0..d.out_width]);
        } else {
            gray_row(d.gray_from, rows[0..count], d.gray_line);
            d.sink.put_row(d.gray_line);
        }
        d.rows_out += 1;
    }
}

fn resample_for(d: *Decoder, index: u8) Error!Resample {
    const component = &d.component[index];
    assert(component.data.len > 0);
    const hs = d.h_max / component.h;
    const vs = d.v_max / component.v;
    assert(hs >= 1);
    return .{
        .kind = resample_kind(hs, vs),
        .hs = hs,
        .vs = vs,
        .w_lores = (d.out_width + hs - 1) / hs,
        .ystep = vs >> 1,
        // Room for upsampling past the edge by up to four
        .line_buffer = try d.work.allocator().alloc(u8, d.out_width + 3),
    };
}

fn resample_kind(hs: u8, vs: u8) ResampleKind {
    assert(hs >= 1);
    assert(vs >= 1);
    if (hs == 1 and vs == 1) return .copy;
    if (hs == 1 and vs == 2) return .vertical;
    if (hs == 2 and vs == 1) return .horizontal;
    if (hs == 2 and vs == 2) return .both;
    return .generic;
}

/// Row `row` of a component's samples, wherever it's kept.
fn sample_row(component: *const Component, row: u32) []const u8 {
    assert(row < component.rows_done);
    assert(component.data_rows > 0);
    return component.data[(row % component.data_rows) * component.stride ..][0..component.stride];
}

/// The next output row of one component, upsampled.
fn resample_row(r: *Resample, component: *const Component) []const u8 {
    assert(r.vs >= 1);
    const bottom = r.ystep >= (r.vs >> 1);
    const near = sample_row(component, if (bottom) r.line1 else r.line0);
    const far = sample_row(component, if (bottom) r.line0 else r.line1);
    const row: []const u8 = switch (r.kind) {
        .copy => near,
        .vertical => resample_vertical(r.line_buffer, near, far, r.w_lores),
        .horizontal => resample_horizontal(r.line_buffer, near, r.w_lores),
        .both => resample_both(r.line_buffer, near, far, r.w_lores),
        .generic => resample_generic(r.line_buffer, near, r.w_lores, r.hs),
    };
    r.ystep += 1;
    if (r.ystep >= r.vs) {
        r.ystep = 0;
        r.line0 = r.line1;
        r.ypos += 1;
        if (r.ypos < component.out_y) r.line1 += 1;
    }
    assert(r.line1 < component.out_y);
    return row;
}

/// Transforms a block's coefficients into its samples, `side` a side.
fn put_block(
    d: *const Decoder,
    component: *Component,
    block_x: u32,
    block_y: u32,
    block: *const [block_length]i16,
) void {
    assert(component.data.len > 0);
    assert(component.data_rows % d.side == 0); // A block's rows never wrap
    const row = (block_y * d.side) % component.data_rows;
    const target = component.data[row * component.stride + block_x * d.side ..];
    if (d.shrink == 1) return idct_block(target, component.stride, block);
    var samples: [block_length]u8 = undefined;
    idct_block(&samples, 8, block);
    shrink_block(target, component.stride, &samples, d.shrink);
}

/// Averages a block's 8 x 8 samples down to `8 / shrink` a side, rounded.
fn shrink_block(target: []u8, stride: u32, samples: *const [block_length]u8, shrink: u8) void {
    assert(shrink > 1);
    assert(shrink_valid(shrink));
    const side = 8 / shrink;
    const area = @as(u32, shrink) * shrink;
    for (0..side) |row| {
        for (0..side) |column| {
            var sum: u32 = 0;
            for (0..shrink) |y| {
                const line = samples[(row * shrink + y) * 8 + column * shrink ..][0..shrink];
                for (line) |sample| sum += sample;
            }
            target[row * stride + column] = @intCast((sum + area / 2) / area);
        }
    }
}

fn div4(x: u32) u8 {
    return @intCast(x >> 2);
}

fn resample_vertical(out: []u8, near: []const u8, far: []const u8, w: u32) []const u8 {
    assert(near.len >= w);
    assert(far.len >= w);
    for (out[0..w], near[0..w], far[0..w]) |*o, n, f| o.* = div4(3 * @as(u32, n) + f + 2);
    return out;
}

fn resample_horizontal(out: []u8, input: []const u8, w: u32) []const u8 {
    assert(input.len >= w);
    assert(out.len >= w * 2);
    if (w == 1) {
        out[0] = input[0];
        out[1] = input[0];
        return out;
    }
    out[0] = input[0];
    out[1] = div4(@as(u32, input[0]) * 3 + input[1] + 2);
    for (1..w - 1) |i| {
        const n = 3 * @as(u32, input[i]) + 2;
        out[i * 2] = div4(n + input[i - 1]);
        out[i * 2 + 1] = div4(n + input[i + 1]);
    }
    const last = w - 1;
    out[last * 2] = div4(@as(u32, input[w - 2]) * 3 + input[w - 1] + 2);
    out[last * 2 + 1] = input[w - 1];
    return out;
}

fn resample_both(out: []u8, near: []const u8, far: []const u8, w: u32) []const u8 {
    assert(near.len >= w);
    assert(out.len >= w * 2);
    if (w == 1) {
        out[0] = div4(3 * @as(u32, near[0]) + far[0] + 2);
        out[1] = out[0];
        return out;
    }
    var t1 = 3 * @as(u32, near[0]) + far[0];
    out[0] = div4(t1 + 2);
    for (1..w) |i| {
        const t0 = t1;
        t1 = 3 * @as(u32, near[i]) + far[i];
        out[i * 2 - 1] = @intCast((3 * t0 + t1 + 8) >> 4);
        out[i * 2] = @intCast((3 * t1 + t0 + 8) >> 4);
    }
    out[w * 2 - 1] = div4(t1 + 2);
    return out;
}

fn resample_generic(out: []u8, near: []const u8, w: u32, hs: u8) []const u8 {
    assert(near.len >= w);
    assert(out.len >= w * hs);
    for (0..w) |i| @memset(out[i * hs ..][0..hs], near[i]);
    return out;
}

/// Ink times ink, rounded: how stb_image combined CMYK.
fn blinn(x: u8, y: u8) u8 {
    const t = @as(u32, x) * y + 128;
    const result = (t + (t >> 8)) >> 8;
    assert(result <= 255);
    return @intCast(result);
}

fn gray_row(gray_from: GrayFrom, rows: []const []const u8, out: []u8) void {
    assert(rows.len == gray_from.count);
    assert(rows[0].len >= out.len);
    switch (gray_from.kind) {
        .y => @memcpy(out, rows[0][0..out.len]),
        .rgb => for (out, 0..) |*pixel, i| {
            pixel.* = decoded.luma(rows[0][i], rows[1][i], rows[2][i]);
        },
        .cmyk => for (out, 0..) |*pixel, i| {
            const k = rows[3][i];
            const red = blinn(rows[0][i], k);
            pixel.* = decoded.luma(red, blinn(rows[1][i], k), blinn(rows[2][i], k));
        },
        .ycck => for (out, 0..) |*pixel, i| {
            pixel.* = blinn(255 - rows[0][i], rows[3][i]);
        },
    }
}
