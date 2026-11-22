//! Strips a 32-bit ARM program of its symbols and lines, for the Kindle, keeping its
//! code byte for byte: a crash's addresses (src/main.zig `panic`) are then read in the
//! unstripped program it came from. Zig's own `objcopy` can't strip this kind of
//! file, and a compiler asked to leave them out makes slightly different code.
//!
//!   strip <program> <out>
//!
//! A static program runs from what its program headers map; the symbols, lines and
//! the section table come after all of that. So the copy ends where the last mapped
//! byte does, its section table dropped from the header.
const std = @import("std");
const assert = std.debug.assert;

/// The header of a 32-bit ELF file, where the fields read are.
const ident_class = 4;
const ident_data = 5;
const class_32 = 1;
const data_little = 1;
const phoff_at = 28;
const shoff_at = 32;
const phentsize_at = 42;
const phnum_at = 44;
const shentsize_at = 46;
const shnum_at = 48;
const shstrndx_at = 50;
const header_size = 52;
/// A program header: where its bytes are in the file, and how many.
const phdr_size = 32;
const phdr_offset_at = 4;
const phdr_filesz_at = 16;
/// The largest program read: the app is a few megabytes, with its lines some tens.
const program_bytes_max = 256 << 20;

comptime {
    assert(shstrndx_at + 2 == header_size);
    assert(phdr_filesz_at + 4 <= phdr_size);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) {
        std.debug.print("usage: strip <program> <out>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const limit: std.Io.Limit = .limited(program_bytes_max);
    const program = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, limit);
    assert(args.len == 3);
    const stripped = try strip(program);
    assert(stripped.len <= program.len); // Only ever cut
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = args[2],
        .data = stripped,
        .flags = .{ .permissions = .executable_file }, // A program, run as one
    });
}

/// `program` cut to what's mapped, its section table gone from the header. Changes
/// `program` in place, and returns the part of it that's kept.
fn strip(program: []u8) error{NotElf32}![]u8 {
    if (program.len < header_size) return error.NotElf32;
    if (!std.mem.eql(u8, program[0..4], "\x7fELF")) return error.NotElf32;
    if (program[ident_class] != class_32) return error.NotElf32;
    if (program[ident_data] != data_little) return error.NotElf32;
    const phoff = read32(program, phoff_at);
    const phnum = read16(program, phnum_at);
    if (read16(program, phentsize_at) != phdr_size) return error.NotElf32;
    const headers_end = @as(u64, phoff) + @as(u64, phnum) * phdr_size;
    if (headers_end > program.len) return error.NotElf32;
    var end: u64 = @max(header_size, headers_end);
    for (0..phnum) |index| {
        const at = phoff + @as(u32, @intCast(index)) * phdr_size;
        const offset = read32(program, at + phdr_offset_at);
        const size = read32(program, at + phdr_filesz_at);
        end = @max(end, @as(u64, offset) + size);
    }
    if (end > program.len) return error.NotElf32;
    // The section table, and what it names, come after every mapped byte
    const shoff = read32(program, shoff_at);
    if (shoff != 0 and shoff < end) return error.NotElf32;
    write16(program, shentsize_at, 0);
    write16(program, shnum_at, 0);
    write16(program, shstrndx_at, 0);
    std.mem.writeInt(u32, program[shoff_at..][0..4], 0, .little);
    assert(end <= program.len);
    return program[0..@intCast(end)];
}

fn read32(bytes: []const u8, at: u32) u32 {
    assert(at + 4 <= bytes.len);
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn read16(bytes: []const u8, at: u32) u16 {
    assert(at + 2 <= bytes.len);
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn write16(bytes: []u8, at: u32, value: u16) void {
    assert(at + 2 <= bytes.len);
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

test "a program is cut where its last mapped byte ends, its section table dropped" {
    // A header, one program header mapping 100 bytes from 84, then "symbols" and a
    // section table after them
    var program: [400]u8 = @splat(0xaa);
    @memcpy(program[0..4], "\x7fELF");
    program[ident_class] = class_32;
    program[ident_data] = data_little;
    std.mem.writeInt(u32, program[phoff_at..][0..4], header_size, .little);
    write16(&program, phentsize_at, phdr_size);
    write16(&program, phnum_at, 1);
    std.mem.writeInt(u32, program[shoff_at..][0..4], 300, .little);
    write16(&program, shnum_at, 3);
    const phdr = header_size;
    std.mem.writeInt(u32, program[phdr + phdr_offset_at ..][0..4], 84, .little);
    std.mem.writeInt(u32, program[phdr + phdr_filesz_at ..][0..4], 100, .little);
    const code = program[84..184].*;
    const kept = try strip(&program);
    try std.testing.expectEqual(@as(usize, 184), kept.len);
    try std.testing.expectEqualSlices(u8, &code, kept[84..184]); // The code as it was
    try std.testing.expectEqual(@as(u32, 0), read32(kept, shoff_at));
    try std.testing.expectEqual(@as(u16, 0), read16(kept, shnum_at));
}

test "a file that isn't a 32-bit ELF program, or whose sections sit among its code, is refused" {
    var short: [10]u8 = @splat(0);
    try std.testing.expectError(error.NotElf32, strip(&short));
    var not_elf: [header_size]u8 = @splat(0);
    try std.testing.expectError(error.NotElf32, strip(&not_elf));
}
