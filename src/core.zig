//! Shared by the app and the tools in tools/, which can't reach into src/ directly.

// Amazon: the Kindle's formats, services and hardware.
pub const annotation_db = @import("kindle/annotation_db.zig");
pub const catalog_db = @import("kindle/catalog.zig");
pub const hwtcon = @import("kindle/hwtcon.zig");
pub const ion = @import("kindle/ion.zig");
pub const jpegxr = @import("kindle/jpegxr.zig");
pub const kfx = @import("kindle/kfx.zig");
pub const lipc = @import("kindle/lipc.zig");
pub const safe = @import("kindle/safe.zig");
pub const fonts_db = @import("kindle/fonts.zig");
pub const store = @import("kindle/store.zig");

// Linux.
pub const clock = @import("sys/clock.zig");
pub const file = @import("sys/file.zig");
pub const os = @import("sys/os.zig");
pub const process = @import("sys/process.zig");

// Ours.
pub const book = @import("model/book.zig");
pub const note_rules = @import("model/notes.zig");
pub const catalog = @import("model/catalog.zig");
pub const settings = @import("model/settings.zig");
pub const quick = @import("model/quick.zig");
pub const text = @import("layout/text.zig");
pub const cover = @import("gfx/image.zig");
pub const font = @import("gfx/font.zig");
pub const page = @import("gfx/page.zig");
pub const card = @import("ui/card.zig");
pub const aa = @import("ui/aa.zig");
pub const fonts = @import("ui/fonts.zig");
pub const goto = @import("ui/goto.zig");
pub const keyboard = @import("ui/keyboard.zig");
pub const library = @import("ui/library.zig");
pub const menu = @import("ui/menu.zig");
pub const notes = @import("ui/notes.zig");
pub const search_sheet = @import("ui/search_sheet.zig");
pub const book_actions = @import("ui/book_actions.zig");
pub const toolbar = @import("ui/toolbar.zig");
