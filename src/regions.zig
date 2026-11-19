//! The memory an App reads in, reserved once (setup.zig) and kept for good: the
//! library's list and covers, what each EPUB is read for while the library is found,
//! the open book, its pages after a settings change, and one action's scratch.
const memory = @import("base/memory.zig");
const covers = @import("ui/covers.zig");
const library_view = @import("library/view.zig");

pub const Regions = struct {
    library: memory.Region,
    covers: covers.Pool, // In the library's region, for good
    covers_bytes: u64, // What the pool and the shared buffers take of the library's budget
    library_shared: library_view.Shared, // In the library's region, for good
    library_budget: memory.Budget, // Shared by a library list and the one reloaded after it
    library_scratch: memory.Region,
    book: memory.Region,
    pages: memory.Region,
    pages_budget: memory.Budget, // Emptied before each layout after a settings change
    scratch: memory.Region,
};
