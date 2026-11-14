//! Prints the structure of a KFX book without its text: entity types with counts, and
//! the field layout of one type. Strings show as their length only.
//! Usage: kfxshape <book.kfx> [type [max entities]]
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const ion = core.ion;
const print = std.debug.print;

/// KFX entity types and the fields this tool reads, by their symbol numbers.
const style_kind = 157;
const resource_kind = 164;
const media_kind = 417;
const style_name_key = 173;
const measure_unit_key = 306;
const measure_amount_key = 307;
const resource_format_key = 161;
const resource_location_key = 165;
const resource_width_key = 422;
const resource_height_key = 423;
/// An entity's header length sits at bytes 6 to 10, after "ENTY" and a version.
const entity_header_size_offset = 6;
const entity_header_size_min = 10;

/// How deep `shape` goes into nested values; deeper ones are cut short. Two spaces
/// of indent a level.
const depth_max = 30;
const indent_pad: [depth_max * 2]u8 = @splat(' ');
/// Items of a list shown before the rest are left out.
const items_shown_max = 4;
/// Distinct style field values counted, and the longest one described.
const tally_size_max = 256;
const description_size_max = 64;
/// Entity types counted, by number.
const kinds_max = 2048;

comptime {
    assert(indent_pad.len == depth_max * 2);
    // A symbol field's description, the shortest kind, fits at its longest.
    assert(description_size_max >= "$18446744073709551615 = $18446744073709551615".len);
    assert(media_kind < kinds_max);
}

/// One container value being walked: a struct's fields or a list's items.
const Frame = struct {
    depth: u32,
    walk: union(enum) {
        fields: ion.Fields,
        items: Items,
    },

    /// A list's items, and how many of them have been shown.
    const Items = struct { iterator: ion.Items, shown: u32 = 0 };
};

/// Prints `value`'s shape: containers with what's in them, indented, and the rest by
/// kind. Walks with an explicit stack, as a book's nesting is outside our control.
fn shape(value: ion.Value, items_max: u32) void {
    assert(items_max > 0);
    var stack: [depth_max]Frame = undefined;
    var stack_count: u32 = 0;
    shape_open(value, 0, &stack, &stack_count);
    while (stack_count > 0) {
        assert(stack_count <= stack.len);
        const frame = &stack[stack_count - 1];
        const indent = indent_pad[0 .. frame.depth * 2];
        switch (frame.walk) {
            .fields => |*fields| {
                if (fields.next()) |field| {
                    print("{s}  ${d}: ", .{ indent, field.key });
                    shape_open(field.value, frame.depth + 1, &stack, &stack_count);
                } else {
                    print("{s}}}\n", .{indent});
                    stack_count -= 1;
                }
            },
            .items => |*items| {
                const item = if (items.shown < items_max) items.iterator.next() else null;
                if (item) |shown| {
                    items.shown += 1;
                    print("{s}  - ", .{indent});
                    shape_open(shown, frame.depth + 1, &stack, &stack_count);
                } else {
                    stack_count -= 1;
                }
            },
        }
    }
}

/// Prints the first line of `value` at `depth`, and opens a frame for a container.
fn shape_open(
    value: ion.Value,
    depth: u32,
    stack: *[depth_max]Frame,
    stack_count: *u32,
) void {
    assert(depth == stack_count.*);
    assert(stack_count.* <= stack.len);
    const container = value.kind == .struct_ or value.kind == .list or value.kind == .sexp;
    if (container and depth == stack.len) {
        print("(nested deeper than {d})\n", .{depth_max});
        return;
    }
    switch (value.kind) {
        .struct_ => {
            print("{{\n", .{});
            stack[depth] = .{ .depth = depth, .walk = .{ .fields = value.fields() } };
            stack_count.* += 1;
        },
        .list, .sexp => {
            var counter = value.items();
            var count: u32 = 0;
            while (counter.next()) |_| count += 1;
            print("[{d} items]\n", .{count});
            const items: Frame.Items = .{ .iterator = value.items() };
            stack[depth] = .{ .depth = depth, .walk = .{ .items = items } };
            stack_count.* += 1;
        },
        .string => print("string({d})\n", .{value.body.len}),
        .symbol => print("${d}\n", .{value.int}),
        .uint => print("{d}\n", .{value.int}),
        else => print("{s}\n", .{@tagName(value.kind)}),
    }
    if (container) assert(stack_count.* == depth + 1) else assert(stack_count.* == depth);
}

/// How often each style field value shows up, in the order first seen.
const Tally = struct {
    descriptions: [tally_size_max][description_size_max]u8 = undefined,
    counts: [tally_size_max]u32 = @splat(0),
    count: u32 = 0,

    fn add(tally: *Tally, description: []const u8) void {
        assert(description.len <= description_size_max);
        assert(tally.count <= tally_size_max);
        const used = tally.descriptions[0..tally.count];
        for (used, tally.counts[0..tally.count]) |*seen, *count| {
            if (std.mem.eql(u8, std.mem.sliceTo(seen, 0), description)) {
                count.* += 1;
                return;
            }
        }
        // Past the table's size, new values go uncounted.
        if (tally.count < tally_size_max) {
            const slot = &tally.descriptions[tally.count];
            @memset(slot, 0);
            @memcpy(slot[0..description.len], description);
            tally.counts[tally.count] = 1;
            tally.count += 1;
            assert(tally.count <= tally_size_max);
        }
    }
};

/// A style field and its value as one line, "$key = value", or null if it won't fit.
fn describe_field(field: *const ion.Field, line: *[description_size_max]u8) ?[]const u8 {
    assert(field.key != style_name_key);
    const value = field.value;
    switch (value.kind) {
        .symbol => {
            return std.fmt.bufPrint(line, "${d} = ${d}", .{ field.key, value.int }) catch null;
        },
        .struct_ => {
            const amount_value = value.get(measure_amount_key) orelse
                return std.fmt.bufPrint(line, "${d} = struct", .{field.key}) catch null;
            const amount = amount_value.number() orelse 0;
            const unit = if (value.get(measure_unit_key)) |u| u.symbol() orelse 0 else 0;
            const format = "${d} = {d:.3} ${d}";
            return std.fmt.bufPrint(line, format, .{ field.key, amount, unit }) catch null;
        },
        .string => return std.fmt.bufPrint(line, "${d} = string", .{field.key}) catch null,
        else => {
            const kind = @tagName(value.kind);
            return std.fmt.bufPrint(line, "${d} = {s}", .{ field.key, kind }) catch null;
        },
    }
}

/// For every style field, how often each value shows up. Numbers are printed with
/// their unit symbol, so "1.5 $505" is 1.5 of unit $505.
fn style_summary(data: []const u8) !void {
    var tally: Tally = .{};
    var entities = try core.kfx.entities(data);
    while (entities.next()) |entity| {
        if (entity.kind != style_kind) continue;
        const value = core.kfx.entity_value(entity.raw) orelse continue;
        var fields = value.fields();
        while (fields.next()) |field| {
            if (field.key == style_name_key) continue; // The style's own name
            var line: [description_size_max]u8 = undefined;
            const description = describe_field(&field, &line) orelse continue;
            tally.add(description);
        }
    }
    assert(tally.count <= tally_size_max);
    const used = tally.descriptions[0..tally.count];
    for (used, tally.counts[0..tally.count]) |*seen, count| {
        print("{d:>4}  {s}\n", .{ count, std.mem.sliceTo(seen, 0) });
    }
}

/// The bytes after a media entity's header, or null when its header doesn't fit.
fn media_body(raw: []const u8) ?[]const u8 {
    if (raw.len < entity_header_size_min) return null;
    const header_size = std.mem.readInt(u32, raw[entity_header_size_offset..][0..4], .little);
    if (header_size > raw.len) return null;
    const body = raw[header_size..];
    assert(body.len <= raw.len);
    assert(body.len + header_size == raw.len);
    return body;
}

/// Writes one raw media entity's bytes to stdout, for testing decoders.
fn dump_media(data: []const u8, id: u32) !void {
    var entities = try core.kfx.entities(data);
    while (entities.next()) |entity| {
        if (entity.kind != media_kind or entity.id != id) continue;
        const body = media_body(entity.raw) orelse continue;
        _ = std.os.linux.write(1, body.ptr, body.len);
    }
}

/// Raw media: id, size, header length and first bytes; resources: id, format, size,
/// location length.
fn list_media(data: []const u8) !void {
    var entities = try core.kfx.entities(data);
    while (entities.next()) |entity| {
        if (entity.kind == media_kind) {
            const raw = entity.raw;
            var header_size: u32 = 0;
            if (raw.len >= entity_header_size_min) {
                const header_size_bytes = raw[entity_header_size_offset..][0..4];
                header_size = std.mem.readInt(u32, header_size_bytes, .little);
            }
            const body = if (header_size < raw.len) raw[header_size..] else "";
            const start = body[0..@min(8, body.len)];
            print("media ${d}: {d} bytes, header {d}, starts {x}\n", .{
                entity.id,
                entity.raw.len,
                header_size,
                start,
            });
        }
        if (entity.kind == resource_kind) {
            const value = core.kfx.entity_value(entity.raw) orelse continue;
            const format = if (value.get(resource_format_key)) |f| f.symbol() orelse 0 else 0;
            const location = if (value.get(resource_location_key)) |l| l.text() orelse "" else "";
            const width = if (value.get(resource_width_key)) |x| x.int else 0;
            const height = if (value.get(resource_height_key)) |x| x.int else 0;
            print("resource ${d}: format ${d}, {d}x{d}, location {d} chars\n", .{
                entity.id,
                format,
                width,
                height,
                location.len,
            });
        }
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len < 2) return error.Usage;
    const data = try core.file.map(argv[1]);
    const mode = if (argv.len > 2) std.mem.sliceTo(argv[2], 0) else "";
    if (argv.len > 2 and std.mem.eql(u8, mode, "styles")) return style_summary(data);
    if (argv.len > 3 and std.mem.eql(u8, mode, "dump")) {
        return dump_media(data, try std.fmt.parseInt(u32, std.mem.sliceTo(argv[3], 0), 10));
    }
    if (argv.len > 2 and std.mem.eql(u8, mode, "media")) return list_media(data);

    var counts: [kinds_max]u32 = @splat(0);
    var entities = try core.kfx.entities(data);
    const want: ?u32 = if (argv.len > 2) try std.fmt.parseInt(u32, mode, 10) else null;
    var shown_max: u32 = 2;
    if (argv.len > 3) shown_max = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[3], 0), 10);
    var shown: u32 = 0;
    while (entities.next()) |entity| {
        if (entity.kind < counts.len) counts[entity.kind] += 1;
        if (want != null and entity.kind == want.? and shown < shown_max) {
            shown += 1;
            print("entity ${d} type ${d}: ", .{ entity.id, entity.kind });
            if (core.kfx.entity_value(entity.raw)) |value| {
                shape(value, items_shown_max);
            } else {
                print("(not ion, {d} bytes)\n", .{entity.raw.len});
            }
        }
    }
    assert(shown <= shown_max);
    if (want == null) {
        assert(shown == 0);
        for (counts, 0..) |count, kind| {
            if (count > 0) print("type ${d}: {d}\n", .{ kind, count });
        }
    }
}
