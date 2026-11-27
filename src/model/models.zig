//! The Kindles noface knows, by name: one declaration, read by the app (device.zig)
//! and by build.zig, which lays the interface out for each. It imports nothing but std,
//! so the build can read it.

/// The Kindles noface knows the screens of.
pub const Model = enum { paperwhite_12, basic_11, scribe, basic_10 };

/// The kinds of device noface runs on, each with its own software around noface: what a
/// book is called there, where its reading place and notes are kept, how they sync.
/// src/platform.zig picks the code for the family the build is for.
pub const Family = enum { kindle };

/// The family a model belongs to.
pub fn family(m: Model) Family {
    return switch (m) {
        .paperwhite_12, .basic_11, .scribe, .basic_10 => .kindle,
    };
}
