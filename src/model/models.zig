//! The Kindles noface knows, by name: one declaration, read by the app (device.zig)
//! and by build.zig, which lays the interface out for each. It imports nothing but std,
//! so the build can read it.

/// The Kindles noface knows the screens of.
pub const Model = enum { paperwhite_12, basic_11, scribe, basic_10 };
