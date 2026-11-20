//! The test books, built in: read by the scenarios, and written by the device tests'
//! runner into the test folders it makes on the Kindle (tools/e2e.zig `all`), so both
//! play on the same books.
/// Three chapters of plain text, many pages long.
pub const scenario = @embedFile("scenario.epub");
/// A footnote's mark and a picture on its first page, then long paragraphs after.
pub const notes = @embedFile("notes.epub");
