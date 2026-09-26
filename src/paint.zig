//! One frame: header, rule, gutter, reverse-video cell.
//! Cursor sits mid-screen until the file runs out at either end.

const std = @import("std");
const ansi = @import("lib").ansi;
const Buffer = @import("buffer.zig").Buffer;
const buffer_mod = @import("buffer.zig");
const Mode = @import("mode.zig").Mode;
const Size = @import("tty.zig").Size;
const command = @import("command.zig");
const highlight = @import("lib").highlight;

const header_rows: u32 = 2;
const mode_inset: u16 = 2; // two-col inset from either edge
const fish_col: u16 = mode_inset + 1; // fish starts here, mirrors the mode label
const fish_open = "><";
const fish_close = ">";

var render_buf: [256 * 1024]u8 = undefined;

/// Window-relative selection span for one row, or null when the
/// overlay is off that row, empty, or fully scrolled out. Merges the
/// old norm + line-span + clip steps: endpoints order top-down, the
/// end cell stays inclusive (span runs one past `ecol`, saturating
/// at length), then the span moves into `[hoff, hoff + width)`.
pub const SelWin = struct { s: usize, e: usize };

pub fn selWindow(
    arow: u64,
    acol: u64,
    brow: u64,
    bcol: u64,
    row: u64,
    line_len: u64,
    hoff: u64,
    width: usize,
) ?SelWin {
    const srow, const scol, const erow, const ecol = if (arow < brow or (arow == brow and acol <= bcol))
        .{ arow, acol, brow, bcol }
    else
        .{ brow, bcol, arow, acol };
    if (row < srow or row > erow) return null;
    const s: u64 = if (row == srow) scol else 0;
    const e: u64 = if (row == erow) @min(ecol + 1, line_len) else line_len;
    const sc = @min(s, line_len);
    if (sc >= e) return null;
    const w: u64 = @intCast(width);
    const lo = @max(sc, hoff);
    const hi = @min(e, hoff + w);
    if (lo >= hi) return null;
    return .{ .s = @intCast(lo - hoff), .e = @intCast(hi - hoff) };
}

fn inSel(sel: ?SelWin, i: usize) bool {
    const s = sel orelse return false;
    return i >= s.s and i < s.e;
}

/// First visible line. Cursor is mid-screen unless that would scroll
/// past the start or end of the file.
/// Absolute line number on the cursor row. Distance from the cursor elsewhere.
pub fn gutterNum(line: u64, cursor: u64) u64 {
    if (line == cursor) return line + 1;
    return if (line > cursor) line - cursor else cursor - line;
}

pub fn scrollFor(cursor: u64, body: u64, total: u64) u64 {
    if (body == 0) return 0;
    const half = body / 2;
    const want = if (cursor > half) cursor - half else 0;
    const max = if (total > body) total - body else 0;
    return @min(want, max);
}

/// First visible column. Same centering rule as `scrollFor`, over the
/// cursor line plus its cursor cell, so the EOL cursor stays on screen.
pub fn colFor(cursor: u64, width: u32, len: u64) u64 {
    if (width == 0) return 0;
    const total = len +| 1;
    const half = width / 2;
    const want = if (cursor > half) cursor - half else 0;
    const max = if (total > width) total - width else 0;
    return @min(want, max);
}

fn digitCount(n: u64) u32 {
    var x: u64 = @max(n, 1);
    var w: u32 = 0;
    while (x > 0) : (x /= 10) w += 1;
    return w;
}

/// Columns left for the filename inside `><name>`. Fish starts at `fish_col`
/// to mirror the mode inset. Stops before the centered count, before the
/// mode label, and before the diagnostic status that follows the name.
pub fn headerNameLimit(cols: u16, mode_len: u16, count_len: u16, status_len: u16) u16 {
    const chrome: u16 = fish_open.len + fish_close.len;
    if (cols < fish_col + chrome - 1) return 0;
    const mode_col: u16 = if (cols >= mode_len + mode_inset)
        cols - mode_inset - mode_len + 1
    else
        cols + 1;
    var room: u16 = if (mode_col > fish_col + chrome) mode_col - fish_col - chrome else 0;
    if (status_len > 0) room -|= @min(room, status_len + 1);
    if (count_len > 0 and cols >= count_len) {
        const count_col = (cols - count_len) / 2 + 1;
        if (count_col > fish_col + chrome) {
            room = @min(room, count_col - fish_col - chrome);
        } else {
            room = 0;
        }
    }
    return room;
}

pub fn headerCountCol(count_len: u16, cols: u16) u16 {
    if (count_len == 0 or cols < count_len) return 0;
    return (cols - count_len) / 2 + 1;
}

/// Gutter summary after the file name: `2e 1w`, errors pink and
/// warnings yellow, grey when the marks are stale. Empty when the
/// buffer carries no marks.
pub fn diagStatus(buf: *const Buffer, out: []u8) []const u8 {
    const c = buf.diagCounts();
    if (c.err == 0 and c.warn == 0) return "";
    const err_style = if (buf.diagStale()) ansi.fg_grey else ansi.fg_pink;
    const warn_style = if (buf.diagStale()) ansi.fg_grey else ansi.fg_yellow;
    var w: std.Io.Writer = .fixed(out);
    if (c.err > 0) {
        w.print("{s}{d}e{s}", .{ err_style, c.err, ansi.reset }) catch return "";
    }
    if (c.warn > 0) {
        if (c.err > 0) w.writeByte(' ') catch return "";
        w.print("{s}{d}w{s}", .{ warn_style, c.warn, ansi.reset }) catch return "";
    }
    return w.buffered();
}

/// Visible width of `diagStatus` output, escapes excluded.
pub fn diagStatusWidth(c: buffer_mod.DiagCounts) u16 {
    var w: u16 = 0;
    if (c.err > 0) w += @intCast(digitCount(c.err) + 1);
    if (c.warn > 0) {
        if (c.err > 0) w += 1;
        w += @intCast(digitCount(c.warn) + 1);
    }
    return w;
}

/// One frame to the terminal, through the shared render buffer.
pub fn paint(io: std.Io, buf: *Buffer, size: Size, mode: Mode) !void {
    var w: std.Io.Writer = .fixed(&render_buf);
    try paintTo(io, &w, buf, size, mode);
    try std.Io.File.stdout().writeStreamingAll(io, w.buffered());
}

/// Build one frame into `w`. `paint` wraps this with the terminal
/// write, and the tests use it directly so a frame never reaches the
/// real stdout.
pub fn paintTo(io: std.Io, w: *std.Io.Writer, buf: *Buffer, size: Size, mode: Mode) !void {
    // No wrap: a full-width row must not wrap, or the rule lands a line low.
    try ansi.frameStart(w);

    const cols = size.cols;
    const name = std.fs.path.basename(buf.path);
    const mode_s = mode.label();
    var count_buf: [24]u8 = undefined;
    const count_s = mode.countLabel(&count_buf);
    const count_len: u16 = @intCast(count_s.len);
    const mode_len: u16 = @intCast(mode_s.len);
    // Diagnostic summary sits after the name: a file with marks says so
    // even when the marked row is far from the camera.
    const counts = buf.diagCounts();
    const status_w = diagStatusWidth(counts);
    var status_buf: [48]u8 = undefined;
    const status_s = diagStatus(buf, &status_buf);
    const name_limit = headerNameLimit(cols, mode_len, count_len, status_w);
    const shown = name[0..@min(name.len, name_limit)];

    try ansi.clearLine(w);
    if (cols >= fish_col + fish_open.len + fish_close.len - 1) {
        try ansi.at(w, 1, fish_col);
        try ansi.boldText(w, fish_open);
        try ansi.dimText(w, shown);
        try ansi.boldText(w, fish_close);
    }
    if (status_s.len > 0) {
        const shown_len: u16 = @intCast(shown.len);
        const status_col: u16 = fish_col + @as(u16, fish_open.len) + shown_len + @as(u16, fish_close.len);
        if (status_col + status_w <= cols) {
            try ansi.at(w, 1, status_col);
            try w.writeAll(status_s);
        }
    }
    if (cols >= mode_len + mode_inset) {
        const mode_col = cols - mode_inset - mode_len + 1;
        try ansi.at(w, 1, mode_col);
        try w.writeAll(mode_s);
    }
    const count_col = headerCountCol(count_len, cols);
    if (count_col > fish_col + fish_open.len + shown.len + fish_close.len - 1) {
        try ansi.at(w, 1, count_col);
        try ansi.dimText(w, count_s);
    }

    try ansi.at(w, 2, 1);
    try ansi.clearLine(w);
    try ansi.rule(w, cols);

    const body: u32 = if (size.rows > header_rows) size.rows - header_rows else 0;
    const gutter = digitCount(buf.lineCount()) + 2;
    const text_cols: usize = if (cols > gutter) cols - gutter else 0;
    const top = scrollFor(buf.row, body, buf.lineCount());
    // Horizontal center camera: same rule as vertical, over the cursor
    // line plus its cursor cell. Other lines render through the window.
    const cur_len = try buf.lineLen(buf.row);
    const hoff = colFor(buf.col, @intCast(text_cols), cur_len);
    const spec = switch (buf.hl_mode) {
        .auto => highlight.detect(buf.path),
        .filenames, .gitlog, .trees, .search, .exec, .listing => null,
    };
    // State resync: the lexer carries open strings and blocks, so walk
    // a bounded margin above the viewport and keep only the state.
    const resync_margin: u64 = 128;
    const start_row = if (spec == null) top else if (top < resync_margin) 0 else top - resync_margin;
    var pos: u64 = if (start_row == 0) 0 else try buf.lineStart(start_row);
    var line_tmp: [4096]u8 = undefined;
    var spans: [highlight.max_spans]highlight.Span = undefined;
    var st: highlight.State = .{};
    if (spec) |sp| {
        var rr = start_row;
        while (rr < top) : (rr += 1) {
            const got = try buf.readLineAt(pos, 0, &line_tmp);
            pos = got.next;
            _ = highlight.lexLine(sp, line_tmp[0..got.len], &st, &spans);
        }
    }

    var r: u32 = 0;
    while (r < body) : (r += 1) {
        try ansi.at(w, r + header_rows + 1, 1);
        try ansi.clearLine(w);
        const abs = top + r;
        if (abs >= buf.lineCount()) continue;

        const on = abs == buf.row;
        // Diagnostics color the gutter number: error pink, warning
        // yellow. Stale marks (edited since the run) dim. No icon, so
        // the layout never shifts.
        const dk = buf.diagAt(abs);
        const stale = dk != null and buf.diagStale();
        const num_s: []const u8 = if (dk) |k| switch (k) {
            .err => highlight.monokai.keyword,
            .warn => highlight.monokai.string,
        } else if (!on) ansi.dim else "";
        // Current row keeps its absolute number. Every other row shows how
        // far it is from the cursor, so a count prefix matches the gutter.
        try w.print("{s}{s}{s}{d: >[5]}{s}  ", .{
            if (on) ansi.bold else "",
            if (stale) ansi.dim else "",
            num_s,
            gutterNum(abs, buf.row),
            ansi.reset,
            gutter - 2,
        });
        if (text_cols == 0) continue;

        // One tree lookup for the first row, then a sequential walk.
        // No per-row scan from the piece start.
        const got = try buf.readLineAt(pos, 0, &line_tmp);
        pos = got.next;
        const src = line_tmp[0..got.len];
        // Selection span for this row in window coords, if the
        // overlay is active and touches the drawn bytes.
        const selw: ?SelWin = if (mode.sel) |sl|
            selWindow(sl.arow, sl.acol, buf.row, buf.col, abs, got.len, hoff, text_cols)
        else
            null;
        const faded = buf.hl_mode == .filenames and highlight.isFadedName(src);
        if (faded) {
            const win = windowOf(src, hoff, text_cols);
            const cur = if (on) buf.col - hoff else null;
            try writeFadedLine(w, win, cur, text_cols, selw);
        } else if (spec) |sp| {
            const nspans = highlight.lexLine(sp, src, &st, &spans);
            const cur = if (on) buf.col else null;
            try writeHiLine(w, highlight.monokai, src, spans[0..nspans], hoff, cur, selw, text_cols);
        } else if (buf.hl_mode == .filenames) {
            // Each row names a file: highlight it by its own
            // extension. Rows stand alone, so state stays fresh.
            const cur = if (on) buf.col else null;
            if (highlight.detectName(src)) |ls| {
                var rst: highlight.State = .{};
                const nspans = highlight.lexLine(ls, src, &rst, &spans);
                try writeHiLine(w, highlight.monokai, src, spans[0..nspans], hoff, cur, selw, text_cols);
            } else {
                const win = windowOf(src, hoff, text_cols);
                if (on) {
                    try writeCursorLine(w, win, buf.col - hoff, text_cols, selw);
                } else {
                    try writeSelLine(w, win, text_cols, selw);
                }
            }
        } else if (buf.hl_mode == .gitlog) {
            const nspans = highlight.lexGitLine(src, &spans);
            const cur = if (on) buf.col else null;
            try writeHiLine(w, highlight.monokai, src, spans[0..nspans], hoff, cur, selw, text_cols);
        } else if (buf.hl_mode == .trees) {
            const nspans = highlight.lexTreeLine(src, &spans);
            const cur = if (on) buf.col else null;
            try writeHiLine(w, highlight.monokai, src, spans[0..nspans], hoff, cur, selw, text_cols);
        } else if (buf.hl_mode == .listing) {
            // Welcome and help text: command rows, keys, version.
            const nspans = highlight.lexListingLine(src, &spans);
            const cur = if (on) buf.col else null;
            try writeHiLine(w, highlight.monokai, src, spans[0..nspans], hoff, cur, selw, text_cols);
        } else if (buf.hl_mode == .search or buf.hl_mode == .exec) {
            // Hit rows lex their preview by the hit path's language;
            // plain log rows fall through to whole-line plain.
            const nspans = highlight.lexHitLine(src, &spans);
            const cur = if (on) buf.col else null;
            try writeHiLine(w, highlight.monokai, src, spans[0..nspans], hoff, cur, selw, text_cols);
        } else if (on) {
            const win = windowOf(src, hoff, text_cols);
            try writeCursorLine(w, win, buf.col - hoff, text_cols, selw);
        } else {
            try writeSelLine(w, windowOf(src, hoff, text_cols), text_cols, selw);
        }
    }
    // End of the visible range: the loader works ahead of it.
    buf.noteReadAhead(io, pos);

    if (mode.cmdLine()) |line| try writeCommandOverlay(w, size, line);
}

fn writeCommandOverlay(w: *std.Io.Writer, size: Size, line: *const command.Line) !void {
    if (size.cols < 16 or size.rows < 7) return;

    const box_w: u16 = @min(size.cols -| 6, 44);
    const box_h: u16 = 3;
    const left: u16 = (size.cols - box_w) / 2 + 1;
    const top: u16 = (size.rows - box_h) / 2 + 1;
    const inner: u16 = box_w - 2;

    try ansi.at(w, top, left);
    try w.writeAll(ansi.top_left);
    try writeTitleRule(w, inner);
    try w.writeAll(ansi.top_right);

    try ansi.at(w, top + 1, left);
    try w.writeAll(ansi.vert);
    try ansi.spaces(w, inner);
    try w.writeAll(ansi.vert);

    const prompt = ": ";
    const text = line.text();
    const text_room: usize = if (inner > prompt.len) inner - prompt.len else 0;
    const shown = text[0..@min(text.len, text_room)];
    try ansi.at(w, top + 1, left + 1);
    try ansi.dimText(w, prompt);
    try writeCursorLine(w, shown, line.col, text_room, null);

    // Why the submit failed, right aligned. Every reason in `command`
    // fits the box; a very narrow window drops it.
    const reason = line.err;
    if (reason.len > 0 and inner > @as(u16, @intCast(reason.len)) + 2) {
        const msg_col: u16 = left + 1 + inner - @as(u16, @intCast(reason.len));
        try ansi.at(w, top + 1, msg_col);
        try ansi.dimText(w, reason);
    }

    try ansi.at(w, top + 2, left);
    try w.writeAll(ansi.bot_left);
    try ansi.repeat(w, ansi.horiz, inner);
    try w.writeAll(ansi.bot_right);
}

fn writeTitleRule(w: *std.Io.Writer, inner: u16) !void {
    const title = " command ";
    if (title.len + 2 > inner) {
        try ansi.repeat(w, ansi.horiz, inner);
        return;
    }
    const rest = inner - @as(u16, @intCast(title.len));
    const lead = rest / 2;
    const trail = rest - lead;
    try ansi.repeat(w, ansi.horiz, lead);
    try ansi.dimText(w, title);
    try ansi.repeat(w, ansi.horiz, trail);
}

/// Visible slice of a line through the horizontal window.
fn windowOf(src: []const u8, hoff: u64, width: usize) []const u8 {
    const s: usize = @intCast(@min(hoff, @as(u64, src.len)));
    const e: usize = @intCast(@min(hoff + @as(u64, width), @as(u64, src.len)));
    return src[s..e];
}

/// Dim line for faded rows (directories, dotfiles). Mirrors
/// `writeCursorLine` with dim text around a plain cursor cell.
fn writeFadedLine(w: *std.Io.Writer, src: []const u8, col: ?u64, width: usize, sel: ?SelWin) !void {
    const shown = @min(src.len, width);
    const cur = col orelse {
        if (sel == null) {
            try ansi.dimText(w, src[0..shown]);
            return;
        }
        var i: usize = 0;
        while (i < shown) : (i += 1) {
            if (inSel(sel, i)) {
                try ansi.reverseByte(w, src[i]);
            } else {
                try ansi.dimText(w, src[i..][0..1]);
            }
        }
        return;
    };
    const c: usize = @min(@as(usize, @intCast(cur)), src.len);
    if (sel == null) {
        if (c >= width) {
            try ansi.dimText(w, src[0..shown]);
            return;
        }
        if (c > 0) try ansi.dimText(w, src[0..@min(c, shown)]);
        try ansi.reverseByte(w, if (c < src.len) src[c] else ' ');
        if (c + 1 < shown) try ansi.dimText(w, src[c + 1 .. shown]);
        return;
    }
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        if (inSel(sel, i) or (i == c and c < width)) {
            try ansi.reverseByte(w, src[i]);
        } else {
            try ansi.dimText(w, src[i..][0..1]);
        }
    }
    if (c == src.len and c < width) try ansi.reverseByte(w, ' ');
}

fn writeCursorLine(w: *std.Io.Writer, src: []const u8, col: u64, width: usize, sel: ?SelWin) !void {
    const shown = @min(src.len, width);
    const c: usize = @min(@as(usize, @intCast(col)), src.len);
    if (sel == null) {
        if (c >= width) {
            try w.writeAll(src[0..shown]);
            return;
        }
        if (c > 0) try w.writeAll(src[0..@min(c, shown)]);
        try ansi.reverseByte(w, if (c < src.len) src[c] else ' ');
        if (c + 1 < shown) try w.writeAll(src[c + 1 .. shown]);
        return;
    }
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        if (inSel(sel, i) or (i == c and c < width)) {
            try ansi.reverseByte(w, src[i]);
        } else {
            try w.writeByte(src[i]);
        }
    }
    if (c == src.len and c < width) try ansi.reverseByte(w, ' ');
}

/// Plain windowed line with an optional reversed selection span.
fn writeSelLine(w: *std.Io.Writer, src: []const u8, width: usize, sel: ?SelWin) !void {
    const shown = @min(src.len, width);
    if (sel == null) {
        try w.writeAll(src[0..shown]);
        return;
    }
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        if (inSel(sel, i)) {
            try ansi.reverseByte(w, src[i]);
        } else {
            try w.writeByte(src[i]);
        }
    }
}

/// Highlighted line through the horizontal window. Spans arrive in
/// line coords; each is clipped to `[hoff, hoff + width)`. The cursor
/// cell splits its span and stacks reverse over the color, and so does
/// every cell of the optional selection span. Past the copied bytes
/// the cursor falls back to a plain cell.
fn writeHiLine(
    w: *std.Io.Writer,
    th: highlight.Theme,
    src: []const u8,
    spans: []const highlight.Span,
    hoff: u64,
    cur: ?u64,
    sel: ?SelWin,
    width: usize,
) !void {
    const wend = hoff + @as(u64, width);
    const has_sel = sel != null;
    const sa: u64 = if (sel) |s| hoff + @as(u64, s.s) else wend;
    const se: u64 = if (sel) |s| hoff + @as(u64, s.e) else wend;
    for (spans) |sp| {
        const s: u64 = @max(@as(u64, sp.start), hoff);
        const e: u64 = @min(@as(u64, sp.end), wend);
        if (s >= e) continue;
        const code = highlight.colorOf(th, sp.kind);
        var a = s;
        const b1 = @min(e, if (has_sel) sa else e);
        if (a < b1) {
            const si: usize = @intCast(a);
            const ei: usize = @intCast(b1);
            if (cur) |c| {
                if (c < a or c >= b1) {
                    try ansi.styled(w, code, src[si..ei]);
                } else {
                    const ci: usize = @intCast(c);
                    try ansi.styled(w, code, src[si..ci]);
                    try ansi.reverseByteStyled(w, code, src[ci]);
                    try ansi.styled(w, code, src[ci + 1 .. ei]);
                }
            } else {
                try ansi.styled(w, code, src[si..ei]);
            }
            a = b1;
        }
        const b2 = @min(e, if (has_sel) se else e);
        if (a < b2) {
            var i: usize = @intCast(a);
            const ei: usize = @intCast(b2);
            while (i < ei) : (i += 1) try ansi.reverseByteStyled(w, code, src[i]);
            a = b2;
        }
        if (a < e) {
            const si: usize = @intCast(a);
            const ei: usize = @intCast(e);
            if (cur) |c| {
                if (c < a or c >= e) {
                    try ansi.styled(w, code, src[si..ei]);
                } else {
                    const ci: usize = @intCast(c);
                    try ansi.styled(w, code, src[si..ci]);
                    try ansi.reverseByteStyled(w, code, src[ci]);
                    try ansi.styled(w, code, src[ci + 1 .. ei]);
                }
            } else {
                try ansi.styled(w, code, src[si..ei]);
            }
        }
    }
    if (cur) |c| {
        if (c >= @as(u64, src.len) and c >= hoff and c - hoff < @as(u64, width)) {
            try ansi.reverseByte(w, ' ');
        }
    }
}

test "paint builds a whole frame, marks, and the command overlay" {
    // The test binary only reaches the frame path through this test, so
    // it must stay analyzable here: a type error in it would otherwise
    // reach the app and nothing else. Frames go to a local buffer, never
    // to the real stdout, which would block the test runner.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const text = "one\ntwo\nthree\n";
    var b = try Buffer.initOwned(gpa, "a.txt", try gpa.dupe(u8, text));
    defer b.close();
    try b.diags.append(gpa, .{ .row = 1, .col = 1, .kind = .err });
    try b.diags.append(gpa, .{ .row = 2, .col = 0, .kind = .warn });
    const size: Size = .{ .rows = 10, .cols = 40 };
    var out: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try paintTo(io, &w, &b, size, .{});
    try std.testing.expect(w.buffered().len > 0);
    // Every view mode takes the same path, so run them all once.
    for ([_]highlight.Mode{ .auto, .filenames, .gitlog, .trees, .search, .exec, .listing }) |m| {
        b.hl_mode = m;
        w = .fixed(&out);
        try paintTo(io, &w, &b, size, .{});
    }
    b.hl_mode = .auto;
    // The command overlay with a filled box and a reason.
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("exec-save zig build") |ch| _ = mode.handle(.{ .char = ch });
    w = .fixed(&out);
    try paintTo(io, &w, &b, size, mode);
    mode.flagCommandError("exec-save needs a file");
    w = .fixed(&out);
    try paintTo(io, &w, &b, size, mode);
    // A tiny terminal must not push the header past the edge.
    w = .fixed(&out);
    try paintTo(io, &w, &b, .{ .rows = 3, .cols = 8 }, mode);
    w = .fixed(&out);
    try paintTo(io, &w, &b, .{ .rows = 0, .cols = 0 }, .{});
}

test "header puts the count in the centre and keeps the name on the left" {
    try std.testing.expectEqual(@as(u16, 40), headerCountCol(2, 80));
    try std.testing.expectEqual(@as(u16, 67), headerNameLimit(80, 6, 0, 0));
    try std.testing.expectEqual(@as(u16, 34), headerNameLimit(80, 6, 2, 0));
    // The diagnostic status takes its columns from the name.
    try std.testing.expectEqual(@as(u16, 61), headerNameLimit(80, 6, 0, 5));
    try std.testing.expectEqual(@as(u16, 0), headerNameLimit(6, 6, 0, 4));
}

test "diagStatus counts errors and warnings and dims when stale" {
    const gpa = std.testing.allocator;
    const text: []const u8 = "one\ntwo\nthree\n";
    var b = try Buffer.initOwned(gpa, "a.txt", try gpa.dupe(u8, text));
    defer b.close();
    var out: [48]u8 = undefined;
    try std.testing.expectEqualStrings("", diagStatus(&b, &out));
    // Two errors on row 0 and one warning on row 2.
    try b.diags.append(gpa, .{ .row = 0, .col = 1, .kind = .err });
    try b.diags.append(gpa, .{ .row = 0, .col = 3, .kind = .err });
    try b.diags.append(gpa, .{ .row = 2, .col = 0, .kind = .warn });
    const fresh = diagStatus(&b, &out);
    try std.testing.expectEqualStrings(
        ansi.fg_pink ++ "2e" ++ ansi.reset ++ " " ++ ansi.fg_yellow ++ "1w" ++ ansi.reset,
        fresh,
    );
    try std.testing.expectEqual(@as(u16, 5), diagStatusWidth(b.diagCounts()));
    // An edit makes the marks stale, and the summary goes grey.
    try b.insert('x');
    const stale = diagStatus(&b, &out);
    try std.testing.expectEqualStrings(
        ansi.fg_grey ++ "2e" ++ ansi.reset ++ " " ++ ansi.fg_grey ++ "1w" ++ ansi.reset,
        stale,
    );
}

test "gutterNum is absolute on the cursor and relative elsewhere" {
    try std.testing.expectEqual(@as(u64, 8), gutterNum(7, 7));
    try std.testing.expectEqual(@as(u64, 4), gutterNum(11, 7));
    try std.testing.expectEqual(@as(u64, 4), gutterNum(3, 7));
}

test "scrollFor centers until the file runs out" {
    try std.testing.expectEqual(@as(u64, 5), scrollFor(10, 10, 100));
    try std.testing.expectEqual(@as(u64, 0), scrollFor(2, 10, 100));
    try std.testing.expectEqual(@as(u64, 90), scrollFor(99, 10, 100));
}

test "colFor centers the cursor and keeps EOL on screen" {
    try std.testing.expectEqual(@as(u64, 0), colFor(2, 10, 100));
    try std.testing.expectEqual(@as(u64, 5), colFor(10, 10, 100));
    // Cursor on the EOL cell of a 100-char line in width 10 shows cols 91-100.
    try std.testing.expectEqual(@as(u64, 91), colFor(100, 10, 100));
    try std.testing.expectEqual(@as(u64, 0), colFor(3, 10, 5));
    try std.testing.expectEqual(@as(u64, 0), colFor(0, 0, 100));
}

test "selWindow orders, spans, and clips into the window" {
    // Forward and reverse anchors order top-down.
    try std.testing.expectEqual(@as(usize, 2), selWindow(1, 2, 3, 4, 1, 10, 0, 80).?.s);
    try std.testing.expectEqual(@as(usize, 2), selWindow(3, 4, 1, 2, 1, 10, 0, 80).?.s);
    // Middle rows run the whole line; ends clamp, end cell inclusive.
    try std.testing.expectEqual(@as(usize, 2), selWindow(1, 2, 2, 1, 1, 10, 0, 80).?.s);
    try std.testing.expectEqual(@as(usize, 10), selWindow(1, 2, 2, 1, 1, 10, 0, 80).?.e);
    try std.testing.expectEqual(@as(usize, 0), selWindow(1, 2, 2, 1, 2, 10, 0, 80).?.s);
    try std.testing.expectEqual(@as(usize, 2), selWindow(1, 2, 2, 1, 2, 10, 0, 80).?.e);
    try std.testing.expect(selWindow(1, 2, 2, 1, 0, 10, 0, 80) == null);
    try std.testing.expect(selWindow(1, 2, 2, 1, 3, 10, 0, 80) == null);
    // Single cell selects one cell; past-the-end clamps to empty.
    try std.testing.expectEqual(@as(usize, 3), selWindow(0, 3, 0, 3, 0, 10, 0, 80).?.s);
    try std.testing.expectEqual(@as(usize, 4), selWindow(0, 3, 0, 3, 0, 10, 0, 80).?.e);
    try std.testing.expect(selWindow(0, 10, 0, 10, 0, 3, 0, 80) == null);
    // Window clipping: scrolled and fully off-window.
    try std.testing.expectEqual(@as(usize, 0), selWindow(0, 2, 0, 7, 0, 10, 5, 80).?.s);
    try std.testing.expectEqual(@as(usize, 3), selWindow(0, 2, 0, 7, 0, 10, 5, 80).?.e);
    try std.testing.expect(selWindow(0, 2, 0, 3, 0, 10, 10, 80) == null);
    try std.testing.expect(selWindow(0, 20, 0, 29, 0, 30, 0, 10) == null);
}

test "writeHiLine draws scrolled bytes, not window-relative ones" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const src = "hello world";
    const spans = [_]highlight.Span{.{ .start = 0, .end = src.len, .kind = .function }};
    try writeHiLine(&w, highlight.monokai, src, &spans, 6, null, null, 80);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") == null);
}

test "writeHiLine reverses the selection span" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const src = "abcdef";
    const spans = [_]highlight.Span{.{ .start = 0, .end = src.len, .kind = .plain }};
    try writeHiLine(&w, highlight.monokai, src, &spans, 0, null, .{ .s = 1, .e = 3 }, 80);
    const out = w.buffered();
    // b and c reversed, the rest plain.
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.reverse ++ "b" ++ ansi.reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.reverse ++ "c" ++ ansi.reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.reverse ++ "a" ++ ansi.reset) == null);
}
