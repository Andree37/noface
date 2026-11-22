//! What a crash leaves in the log: why, which build, and where, as the addresses of
//! the calls that led to it, so the build with its symbols kept turns them into lines
//! (docs/DEVELOPING.md, "Reading a crash"). A panic (a failed check) and a signal (a
//! bad read, a bus error, an illegal instruction) report alike.
//!
//! The app on the Kindle carries no symbols, and Zig's own stack walk brings a reader
//! of them along, two hundred kilobytes, only to find none: the walk is here. On 32-bit
//! ARM, built with frame pointers (build.zig `noface_for`), each call keeps its
//! caller's frame pointer and its return address side by side, with r11 pointing at
//! the pair; following them gives every caller in turn.
//!
//! Everything is written as it's found, with the plain `write` call: a damaged stack
//! that ends the walk with a fault of its own leaves what came before it in the log,
//! and a crash inside the report says so and stops, rather than reporting itself again.
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const linux = @import("calls.zig");

/// The most callers a crash lists: the innermost, where the cause is.
const frames_max = 24;
/// The most stack one call takes, as a guard: a step further up is a damaged frame.
const frame_bytes_max = 1 << 20;
/// Where the log is: standard error, which the launcher sends to noface.log.
const log_fd = 2;

/// How far a report has got: a crash while reporting stops it (noface runs one thread).
var stage: enum { quiet, reporting } = .quiet;
/// The frame `main` runs in: no frame of noface's own is further up the stack.
var stack_top: usize = std.math.maxInt(usize); // usize: an address

/// Notes the top of noface's own stack, from `main`, so a walk stops there.
pub fn mark_stack_top(frame: usize) void { // usize: an address
    assert(frame != 0);
    assert(frame % @alignOf(usize) == 0); // usize: an address's size
    stack_top = frame;
}

/// Reports a panic, `first` being where it was called from when Zig says, and ends
/// noface.
// Assertions: a crash's own report, where one failing would only crash again
pub fn on_panic(msg: []const u8, first: ?usize) noreturn { // usize: an address
    if (again()) std.process.abort();
    say("panic: ");
    say(msg);
    say("\n");
    start_trace();
    // The call that failed, then those that led to it, from the caller of the one
    // Zig named on: the frames before it are the panic's own machinery
    if (first) |site| hex(call_site(site));
    const start = current_frame();
    var walk = Walk.from(start, start); // Every frame left is further up than this one
    if (first) |site| walk.skip_through(site);
    walk.say_rest();
    std.process.abort();
}

/// Reports a signal (a bad read, a bus error, an illegal instruction) with the
/// registers it came with, and ends noface.
// Assertions: a crash's own report, where one failing would only crash again
pub fn on_signal(addr: ?usize, name: []const u8, registers: anytype) noreturn { // usize: an address
    if (again()) std.process.abort();
    say(name);
    if (addr) |a| {
        say(" at address"); // The address comes with its own space
        hex(a);
    }
    say("\n");
    start_trace();
    if (registers) |r| {
        // The instruction that faulted, exactly, then the calls that led to it
        hex(r.getPc());
        // No frame is below the stack pointer: one there is damaged, not to be read
        const sp: usize = if (builtin.cpu.arch == .arm) r.r[13] else 0; // usize: an address
        var walk = Walk.from(r.getFp(), sp);
        walk.say_rest();
    }
    std.process.abort();
}

/// Whether a report is already under way: a crash inside it says so, once.
// Assertions: a crash's own report, where one failing would only crash again
fn again() bool {
    if (stage == .quiet) {
        stage = .reporting;
        return false;
    }
    say("\ncrashed again while reporting the crash: what's above is all of it\n");
    return true;
}

/// Starts the line of addresses, with the build they're in.
// Assertions: a crash's own report, where one failing would only crash again
fn start_trace() void {
    say("crash in build ");
    var id_buffer: [build_id_bytes_max]u8 = undefined;
    const id = build_id(&id_buffer);
    if (id.len == 0) say("(unknown)");
    for (id) |byte| {
        var two: [2]u8 = undefined;
        say(std.fmt.bufPrint(&two, "{x:0>2}", .{byte}) catch return); // Two fit two
    }
    say(" at:");
}

/// The address of the call that returns to `return_address`: the instruction before
/// it, as a call can be a function's last, and its return the next function's first.
fn call_site(return_address: usize) usize { // usize: an address
    assert(return_address > 0);
    return return_address - 1;
}

/// A walk up the stack, frame by frame, from a frame pointer.
const Walk = struct {
    frame: usize, // usize: an address
    /// The lowest a frame can be: the stack pointer, or the walk's own start.
    low: usize, // usize: an address
    steps: u32 = 0,

    fn from(frame: usize, low: usize) Walk { // usize: addresses
        const walk: Walk = .{ .frame = frame, .low = low };
        assert(walk.steps == 0);
        return walk;
    }

    /// The next caller's return address, or null where the frames end or stop looking
    /// like frames: not aligned, not further up than the one before, too far up, or
    /// above `main`.
    fn next(w: *Walk) ?usize { // usize: an address
        assert(w.steps <= frames_max);
        if (w.steps == frames_max) return null;
        const at = w.frame;
        if (at == 0 or at % @alignOf(usize) != 0) return null; // usize: an address's size
        if (at < w.low or at > stack_top) return null; // Outside the stack: damaged
        // The caller's frame, then where it returns to
        const pair: *const [2]usize = @ptrFromInt(at); // usize: two addresses
        const caller = pair[0];
        const return_address = pair[1];
        if (return_address == 0) return null;
        w.steps += 1;
        // A caller's frame is further up the stack, and not by more than a call takes
        if (caller <= at or caller - at > frame_bytes_max) {
            w.frame = 0; // This one counts; there's none after it
        } else {
            w.frame = caller;
        }
        assert(w.steps <= frames_max);
        return return_address;
    }

    /// Steps past the frames up to the one returning to `site`; where none does, back to
    /// the start, so the walk still says everything.
    fn skip_through(w: *Walk, site: usize) void { // usize: an address
        assert(site != 0);
        assert(w.steps == 0); // From the walk's start, so it can go back there
        const start = w.*;
        while (w.next()) |return_address| {
            if (return_address == site) return;
        }
        w.* = start;
    }

    /// Writes each call site left, as it's found.
    fn say_rest(w: *Walk) void {
        while (w.next()) |return_address| hex(call_site(return_address));
        say("\n");
    }
};

/// The frame pointer of the caller's frame, on 32-bit ARM; 0 (no frames) elsewhere.
inline fn current_frame() usize { // usize: an address
    if (builtin.cpu.arch != .arm) return 0;
    return asm volatile ("mov %[fp], r11"
        : [fp] "=r" (-> usize), // usize: an address
    );
}

/// Writes " 0x..." for an address.
fn hex(address: usize) void { // usize: an address
    var buffer: [24]u8 = undefined; // " 0x" and sixteen digits at most
    say(std.fmt.bufPrint(&buffer, " 0x{x}", .{address}) catch return);
}

/// How many times a short write to the log is tried again with what's left.
const say_tries = 4;

/// Writes `text` to the log as it is, retrying the rest of a short write a few times.
// Assertions: a crash's own report, where one failing would only crash again
fn say(text: []const u8) void {
    var left = text;
    for (0..say_tries) |_| {
        if (left.len == 0) return;
        const written = linux.write(log_fd, left.ptr, left.len);
        if (written == 0 or written > left.len) return; // Failed: nothing more to do
        left = left[written..];
    }
}

/// The longest build ID read, for a caller to hold one: a SHA-1's 20 bytes, with room
/// to spare.
pub const build_id_bytes_max = 32;
/// An ELF note's header: its name's length, its description's, and its type.
const note_header_size = 12;
const note_type_build_id = 3; // NT_GNU_BUILD_ID
const program_type_note = 4; // PT_NOTE
const program_type_headers = 6; // PT_PHDR: the program headers themselves

/// This program's build ID, from its program headers as the kernel mapped them, into
/// `out`: empty when it has none or this isn't Linux. `noface selftest` checks there's
/// one, as a crash can't be read without it.
pub fn build_id(out: []u8) []const u8 {
    assert(out.len > 0);
    if (builtin.os.tag != .linux) return out[0..0];
    // usize: the program's width
    const Phdr = if (@sizeOf(usize) == 4) std.elf.Elf32.Phdr else std.elf.Elf64.Phdr;
    // Through the C library when it's linked in, as it starts the program and keeps the
    // kernel's word: Zig's own getauxval knows only what Zig's own start was told
    const headers_at = auxiliary(std.elf.AT.PHDR);
    const count = auxiliary(std.elf.AT.PHNUM);
    if (headers_at == 0) return out[0..0];
    assert(headers_at % @alignOf(Phdr) == 0); // Where the kernel says they are
    const headers: [*]const Phdr = @ptrFromInt(headers_at);
    // Where the program was loaded past where it was linked: none for the Kindle's,
    // mapped where it was linked, the size of the move for one loaded anywhere
    var moved: usize = 0; // usize: an address's distance
    for (headers[0..count]) |h| {
        if (@backingInt(h.type) == program_type_headers) moved = headers_at -% h.vaddr;
    }
    for (headers[0..count]) |h| {
        if (@backingInt(h.type) != program_type_note) continue;
        const notes: [*]const u8 = @ptrFromInt(h.vaddr +% moved);
        if (build_id_in(notes[0..h.filesz], out)) |id| return id;
    }
    return out[0..0];
}

/// The kernel's auxiliary value `kind` for this program.
fn auxiliary(kind: u32) usize { // usize: an address, or a count, as the kernel gives it
    if (builtin.link_libc) return std.c.getauxval(kind);
    return std.os.linux.getauxval(kind);
}

/// The build ID among the ELF notes in `notes`, into `out`, or null when there's none.
fn build_id_in(notes: []const u8, out: []u8) ?[]const u8 {
    assert(out.len > 0);
    var at: usize = 0; // usize: a place in memory as it's mapped
    // Bounded by the notes' bytes: each note takes its header at least
    while (at + note_header_size <= notes.len) {
        const name_size = std.mem.readInt(u32, notes[at..][0..4], .little);
        const desc_size = std.mem.readInt(u32, notes[at + 4 ..][0..4], .little);
        const kind = std.mem.readInt(u32, notes[at + 8 ..][0..4], .little);
        const name_at = at + note_header_size;
        const desc_at = name_at + std.mem.alignForward(usize, name_size, 4); // usize: size
        const end = desc_at + std.mem.alignForward(usize, desc_size, 4); // usize: size
        if (end > notes.len) return null;
        const is_gnu = name_size == 4 and std.mem.eql(u8, notes[name_at..][0..4], "GNU\x00");
        if (kind == note_type_build_id and is_gnu and desc_size <= out.len) {
            @memcpy(out[0..desc_size], notes[desc_at..][0..desc_size]);
            return out[0..desc_size];
        }
        at = end;
    }
    assert(at <= notes.len);
    return null;
}

test "a walk follows frames up the stack, and stops at one that doesn't look like a frame" {
    // A pretend stack: three frames, each its caller's frame and a return address, the
    // last pointing down, as a damaged one could
    var stack: [6]usize = undefined; // usize: addresses
    const base = @intFromPtr(&stack);
    const word = @sizeOf(usize); // usize: an address's size
    stack[0] = base + 2 * word;
    stack[1] = 0x1001;
    stack[2] = base + 4 * word;
    stack[3] = 0x2002;
    stack[4] = base; // Down the stack: damaged
    stack[5] = 0x3003;
    var walk = Walk.from(base, base);
    try std.testing.expectEqual(@as(?usize, 0x1001), walk.next());
    try std.testing.expectEqual(@as(?usize, 0x2002), walk.next());
    try std.testing.expectEqual(@as(?usize, 0x3003), walk.next()); // Its own return still counts
    try std.testing.expectEqual(@as(?usize, null), walk.next());
    // Skipping to a call site lands after it; one that isn't there leaves the walk whole
    var skipping = Walk.from(base, base);
    skipping.skip_through(0x1001);
    try std.testing.expectEqual(@as(?usize, 0x2002), skipping.next());
    var missing = Walk.from(base, base);
    missing.skip_through(0x9999);
    try std.testing.expectEqual(@as(?usize, 0x1001), missing.next());
    // An unaligned frame pointer, or none, ends a walk at once
    var unaligned = Walk.from(base + 1, base);
    try std.testing.expectEqual(@as(?usize, null), unaligned.next());
    var none = Walk.from(0, 0);
    try std.testing.expectEqual(@as(?usize, null), none.next());
    // A frame below the lowest a frame can be (a wild pointer) is never read
    var below = Walk.from(base, base + 2 * word);
    try std.testing.expectEqual(@as(?usize, null), below.next());
}

test "a call site is the instruction before the return" {
    try std.testing.expectEqual(@as(usize, 0x21a0af), call_site(0x21a0b0));
}

test "the build ID is found among a program's notes" {
    // Another note first, then the GNU build ID: each header, name and description
    // padded to four bytes
    const notes = [_]u8{
        4, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 'Z', 'i', 'g', 0, 0xaa, 0xbb, 0,    0, // Another
        4, 0, 0, 0, 4, 0, 0, 0, 3, 0, 0, 0, 'G', 'N', 'U', 0, 0xde, 0xad, 0xbe, 0xef,
    };
    var out: [build_id_bytes_max]u8 = undefined;
    const id = build_id_in(&notes, &out).?;
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, id);
    try std.testing.expect(build_id_in(notes[0..20], &out) == null); // No build ID
    try std.testing.expect(build_id_in(notes[0..30], &out) == null); // Cut short
}
