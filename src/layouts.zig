//! The app laid out for another Kindle's screen, built by `zig build layouts` and never
//! run: building it is the check. Every layout asserts as it's built that it fits its
//! screen, and every place a test taps is a tap on its control (screens/places.zig),
//! so this compiles only if the whole interface fits the Kindle it's built for.
const app = @import("main.zig");
const places = @import("screens/places.zig");

pub const std_options = app.std_options;
pub const panic = app.panic;
pub const main = app.main;

comptime {
    // Every named place, worked out for this screen, and each checked as it is
    _ = places.all;
}
