//! Where a crash came from, as the addresses of the calls that led to it, read off the
//! stack without symbols: the app on the Kindle carries none, and Zig's own stack
//! walk brings a reader of them along (two hundred kilobytes) only to find nothing.
//! On 32-bit ARM, built with frame pointers (build.zig `noface_built`), each call
//! keeps its caller's frame pointer and its return address side by side, with r11
//! pointing at the pair; following them back gives every caller in turn. The same
//! build with its symbols kept turns the addresses into lines (docs/DEVELOPING.md).
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

/// The calls that led here, innermost first, into `out`: as many as fit, and none on
/// a computer that isn't 32-bit ARM. A frame that doesn't look like one (not aligned,
/// not further up the stack than the one before) ends the walk, as a crash may have
/// left the stack damaged.
// usize: addresses, as the processor has them
pub fn walk(out: []usize) []usize {
    assert(out.len > 0);
    if (builtin.cpu.arch != .arm) return out[0..0];
    // usize: an address
    var frame: usize = asm volatile ("mov %[fp], r11"
        : [fp] "=r" (-> usize), // usize: an address
    );
    var count: u32 = 0;
    while (count < out.len) {
        if (frame == 0 or frame % @alignOf(usize) != 0) break; // usize: an address's size
        // The caller's frame, then where it returns to
        const pair: *const [2]usize = @ptrFromInt(frame); // usize: two addresses
        const return_address = pair[1];
        if (return_address == 0) break;
        out[count] = return_address;
        count += 1;
        const caller = pair[0];
        if (caller <= frame) break; // The stack grows down: a caller's frame is above
        frame = caller;
    }
    assert(count <= out.len);
    return out[0..count];
}
