//! ANSI escapes and box-drawing chars for terminal painting.
//!
//! One place for every `\x1B[...` sequence and rule glyph, plus small
//! `*std.Io.Writer` helpers so `paint` does not repeat literals.

const std = @import("std");

const Writer = std.Io.Writer;

// Styles.
pub const reset = "\x1B[0m";
pub const bold = "\x1B[1m";
pub const dim = "\x1B[2m";
pub const reverse = "\x1B[7m";

// Fixed 256-color foregrounds for the one built-in theme. Theme is
// the terminal's problem; this table is the only exception.
pub const fg_pink = "\x1B[38;5;197m";
pub const fg_yellow = "\x1B[38;5;227m";
pub const fg_grey = "\x1B[38;5;242m";
pub const fg_purple = "\x1B[38;5;141m";
pub const fg_green = "\x1B[38;5;118m";
pub const fg_cyan = "\x1B[38;5;81m";

// Cursor and wrapping.
pub const hide_cursor = "\x1B[?25l";
pub const show_cursor = "\x1B[?25h";
pub const no_wrap = "\x1B[?7l";
pub const wrap = "\x1B[?7h";

// Cursor placement and erasing.
pub const home = "\x1B[H";
pub const clear_line = "\x1B[2K";
pub const frame_start = hide_cursor ++ no_wrap ++ home;

// Alternate screen enter/exit, as used by `main`.
pub const alt_enter = "\x1B[?1049h" ++ home ++ hide_cursor;
pub const alt_exit = show_cursor ++ wrap ++ "\x1B[r\x1B[?1049l";

// Box-drawing and rule glyphs.
pub const horiz = "─";
pub const vert = "│";
pub const top_left = "┌";
pub const top_right = "┐";
pub const bot_left = "└";
pub const bot_right = "┘";

/// Move to 1-based `(row, col)`.
pub fn at(w: *Writer, row: u32, col: u32) !void {
    try w.print("\x1B[{d};{d}H", .{ row, col });
}

/// Erase the current line.
pub fn clearLine(w: *Writer) !void {
    try w.writeAll(clear_line);
}

/// Hide cursor, disable wrap, go home. Starts every frame.
pub fn frameStart(w: *Writer) !void {
    try w.writeAll(frame_start);
}

/// Write `style ++ s ++ reset`. Writes nothing when `s` is empty so
/// empty names do not emit stray SGR sequences.
pub fn styled(w: *Writer, style: []const u8, s: []const u8) !void {
    if (s.len == 0) return;
    try w.writeAll(style);
    try w.writeAll(s);
    try w.writeAll(reset);
}

pub fn boldText(w: *Writer, s: []const u8) !void {
    try styled(w, bold, s);
}

pub fn dimText(w: *Writer, s: []const u8) !void {
    try styled(w, dim, s);
}

/// Reverse-video for one byte, e.g. the cursor cell.
pub fn reverseByte(w: *Writer, b: u8) !void {
    try w.writeAll(reverse);
    try w.writeByte(b);
    try w.writeAll(reset);
}

/// Reverse-video for one byte over a foreground color, e.g. the
/// cursor cell on highlighted text. Attributes stack.
pub fn reverseByteStyled(w: *Writer, style: []const u8, b: u8) !void {
    try w.writeAll(style);
    try w.writeAll(reverse);
    try w.writeByte(b);
    try w.writeAll(reset);
}

/// Write `s` exactly `n` times. For rules, fills, and borders.
pub fn repeat(w: *Writer, s: []const u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll(s);
}

/// Full-width horizontal rule of `cols` cells.
pub fn rule(w: *Writer, cols: usize) !void {
    try repeat(w, horiz, cols);
}

/// `n` blank cells, e.g. clearing the command overlay row.
pub fn spaces(w: *Writer, n: usize) !void {
    try repeat(w, " ", n);
}

test "styled skips empty text so no stray SGR is emitted" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try styled(&w, bold, "");
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
    try boldText(&w, "><");
    try std.testing.expectEqualStrings(bold ++ "><" ++ reset, w.buffered());
}

test "at moves to 1-based row,col" {
    var buf: [32]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try at(&w, 1, 3);
    try std.testing.expectEqualStrings("\x1B[1;3H", w.buffered());
}

test "repeat writes s n times" {
    var buf: [32]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try repeat(&w, horiz, 3);
    try std.testing.expectEqualStrings(horiz ++ horiz ++ horiz, w.buffered());
}

test "reverseByteStyled stacks color under reverse" {
    var buf: [32]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try reverseByteStyled(&w, fg_pink, 'x');
    try std.testing.expectEqualStrings(fg_pink ++ reverse ++ "x" ++ reset, w.buffered());
}
