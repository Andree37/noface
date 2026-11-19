//! What noface keeps per language for reading: its hyphenation, made the first time a
//! book in that language opens, and its dictionary, a file in the data folder mapped
//! the first time a word is looked up. Both are kept for good once made.
const std = @import("std");
const assert = std.debug.assert;
const hyphen = @import("layout/hyphen.zig");
const dictionary = @import("model/dictionary.zig");
const file = @import("sys/file.zig");

/// How many languages noface hyphenates and has dictionaries for.
pub const count = @typeInfo(hyphen.Lang).@"enum".field_names.len;

/// Room for a dictionary's path: the data folder, a slash and its file's name.
const path_bytes_max = 320;

comptime {
    // Every language has a dictionary file, named in `dictionary_file`
    assert(count == 2);
}

/// The file a language's dictionary is kept in, in the data folder.
pub fn dictionary_file(lang: hyphen.Lang) []const u8 {
    return switch (lang) {
        .english => "dict-en",
        .portuguese => "dict-pt",
    };
}

pub const Languages = struct {
    /// The data folder, where the dictionaries are.
    dir: []const u8,
    hyphenators: [count]?hyphen.Hyphenator = @splat(null),
    dictionaries: [count]?dictionary.Dictionary = @splat(null),

    /// Lets go of every hyphenation made and every dictionary mapped.
    pub fn release(l: *Languages) void {
        assert(l.dir.len > 0); // Set as the App is assembled
        for (std.enums.values(hyphen.Lang)) |lang| l.forget_dictionary(lang);
        for (&l.hyphenators) |*slot| {
            if (slot.*) |*made| made.deinit();
            slot.* = null;
        }
        assert(!l.looked_up());
    }

    /// Hyphenation for a book's language, made in `alloc` the first time, or null to
    /// break only at spaces and dashes.
    pub fn hyphenator(
        l: *Languages,
        alloc: std.mem.Allocator,
        lang: ?hyphen.Lang,
    ) ?*const hyphen.Hyphenator {
        const which = lang orelse return null;
        const slot = &l.hyphenators[@backingInt(which)];
        if (slot.* == null) {
            slot.* = hyphen.Hyphenator.init(alloc, which) catch |err| {
                std.debug.print("hyphenation not loaded: {s}\n", .{@errorName(err)});
                return null;
            };
        }
        // Made with its patterns: a word's breaks keep letters on each side
        assert(slot.*.?.left > 0);
        assert(slot.*.?.right > 0);
        return &slot.*.?;
    }

    /// The dictionary for a book's language. Null when the language isn't known or its
    /// file isn't there.
    pub fn dictionary_for(l: *Languages, lang: ?hyphen.Lang) ?dictionary.Dictionary {
        const which = lang orelse return null;
        const slot = &l.dictionaries[@backingInt(which)];
        if (slot.* == null) {
            var buf: [path_bytes_max]u8 = undefined;
            const name = dictionary_file(which);
            const fields = .{ l.dir, name };
            const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", fields, 0) catch return null;
            const data = file.map(path) catch return null;
            assert(data.len > 0); // An empty file is an error from file.map
            slot.* = dictionary.Dictionary.open(data) orelse {
                file.unmap(data);
                std.debug.print("dictionary {s} unreadable\n", .{name});
                return null;
            };
            assert(slot.*.?.data.ptr == data.ptr);
        }
        assert(slot.* != null);
        return slot.*;
    }

    /// Forgets a language's dictionary, so the next lookup maps the file again: after
    /// one has just been downloaded.
    pub fn forget_dictionary(l: *Languages, lang: hyphen.Lang) void {
        assert(l.dir.len > 0); // Where it was mapped from, set as the App is assembled
        const slot = &l.dictionaries[@backingInt(lang)];
        if (slot.*) |d| {
            assert(d.data.len > 0); // An empty file is an error from file.map
            file.unmap(d.data);
        }
        slot.* = null;
    }

    /// Whether any dictionary is mapped: a word was looked up.
    pub fn looked_up(l: *const Languages) bool {
        for (l.dictionaries) |d| {
            if (d != null) return true;
        }
        return false;
    }
};
