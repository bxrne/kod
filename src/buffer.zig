//! Dual-buffer document: file-backed original + append-only add buffer.
//! Original bytes stay on disk behind a fixed page cache. Pieces are
//! red-black leaves. Original is never mutated in place.

const std = @import("std");
const assert = std.debug.assert;
const rbtree = @import("lib").redblacktree;
const highlight = @import("lib").highlight;
const UndoTreeMod = @import("lib").undotree;
const UndoTree = UndoTreeMod.UndoTree;
const UndoCursor = UndoTreeMod.Cursor;
const pager = @import("pages.zig");

const add_size_max: usize = 64 * 1024 * 1024;

const Source = enum { orig, add };

const Piece = struct {
    node: rbtree.Node = .{},
    src: Source,
    off: u64,
    len: u64,
    nls: u64,
    sub_bytes: u64 = 0,
    sub_nls: u64 = 0,
};

const PieceCtx = struct {
    pub fn augment(node: *rbtree.Node) void {
        const p = pieceFrom(node);
        var bytes = p.len;
        var nls = p.nls;
        if (node.left) |l| {
            const lp = pieceFrom(l);
            bytes += lp.sub_bytes;
            nls += lp.sub_nls;
        }
        if (node.right) |r| {
            const rp = pieceFrom(r);
            bytes += rp.sub_bytes;
            nls += rp.sub_nls;
        }
        p.sub_bytes = bytes;
        p.sub_nls = nls;
    }
};

fn pieceFrom(n: *rbtree.Node) *Piece {
    return @alignCast(@fieldParentPtr("node", n));
}

fn pieceFromConst(n: *const rbtree.Node) *const Piece {
    return @alignCast(@fieldParentPtr("node", n));
}

pub const Jump = union(enum) {
    top,
    bottom,
    line_start,
    line_end,
    /// 1-based line number.
    line: u64,
};

pub const DiagKind = enum { err, warn };

/// One gutter diagnostic. Bytes per hit, not per file byte: the
/// message lives in the `*exec*` tree, only the position stays here.
pub const Diag = struct {
    row: u64,
    col: u64,
    kind: DiagKind,
};

/// How many marks of each kind a buffer carries. The header shows it.
pub const DiagCounts = struct { err: usize, warn: usize };

pub const Buffer = struct {
    gpa: std.mem.Allocator,
    io: std.Io = undefined,
    dir: std.Io.Dir = .cwd(),
    file: ?std.Io.File = null,
    file_len: u64 = 0,
    orig: []u8 = &.{},
    add: std.ArrayList(u8) = .empty,
    pages: ?*pager.Pages = null,
    pieces: rbtree.Tree(PieceCtx) = .{},
    path: []const u8,
    /// Highlighting mode, set once at open. Views keep it on refresh.
    hl_mode: highlight.Mode = .auto,
    row: u64 = 0,
    col: u64 = 0,
    dirty: bool = false,
    /// Exec diagnostics, sorted by row. Stale when `edit_gen` moved
    /// past `diag_gen`; paint dims stale marks instead of clearing.
    diags: std.ArrayList(Diag) = .empty,
    diag_gen: u64 = 0,
    edit_gen: u64 = 0,
    /// Armed `:exec-save` command for this buffer. Reruns on save.
    /// Owned, freed on close or re-arm.
    exec_cmd: ?[]u8 = null,
    /// In-memory edit history. Dies with the buffer, never persisted.
    /// View refreshes clear it via `replaceAll`.
    undo_tree: UndoTree = .{},
    /// True while applying an undo or redo step, so the inverse edit
    /// itself is not recorded as a new node.
    applying: bool = false,

    fn bumpEdit(self: *Buffer) void {
        self.edit_gen +%= 1;
    }

    /// Worst kind on `row`, or null. Binary search over sorted diags,
    /// then scan the row run: an error may sit beside a warning.
    pub fn diagAt(self: *const Buffer, row: u64) ?DiagKind {
        var lo: usize = 0;
        var hi: usize = self.diags.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const d = self.diags.items[mid];
            if (d.row < row) {
                lo = mid + 1;
            } else if (d.row > row) {
                hi = mid;
            } else {
                var worst = d.kind;
                var i = mid + 1;
                while (i < self.diags.items.len and self.diags.items[i].row == row) : (i += 1) {
                    if (self.diags.items[i].kind == .err) worst = .err;
                }
                i = mid;
                while (i > 0) {
                    i -= 1;
                    if (self.diags.items[i].row != row) break;
                    if (self.diags.items[i].kind == .err) worst = .err;
                }
                return worst;
            }
        }
        return null;
    }

    pub fn diagStale(self: *const Buffer) bool {
        return self.diags.items.len > 0 and self.edit_gen != self.diag_gen;
    }

    /// Error and warning counts in the gutter marks. The header shows
    /// them, so a buffer with marks never looks clean.
    pub fn diagCounts(self: *const Buffer) DiagCounts {
        var counts = DiagCounts{ .err = 0, .warn = 0 };
        for (self.diags.items) |d| {
            switch (d.kind) {
                .err => counts.err += 1,
                .warn => counts.warn += 1,
            }
        }
        return counts;
    }

    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Buffer {
        return openDir(gpa, io, .cwd(), path);
    }

    pub fn openDir(
        gpa: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !Buffer {
        assert(path.len > 0);
        const file = try dir.openFile(io, path, .{ .mode = .read_only });
        errdefer file.close(io);
        const st = try file.stat(io);
        const file_len: u64 = @intCast(st.size);
        const pages = try gpa.create(pager.Pages);
        errdefer gpa.destroy(pages);
        pages.* = .{};

        var self: Buffer = .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .file = file,
            .file_len = file_len,
            .pages = pages,
            .path = path,
        };
        if (file_len > 0) {
            const nls = try self.scanFileNewlines();
            const p = try self.allocPiece(.orig, 0, file_len, nls);
            self.pieces.insertRoot(&p.node);
        }
        return self;
    }

    /// In-memory original for tests. Does not open a file.
    pub fn initOwned(gpa: std.mem.Allocator, path: []const u8, orig: []u8) !Buffer {
        var self: Buffer = .{
            .gpa = gpa,
            .path = path,
            .orig = orig,
        };
        if (orig.len > 0) {
            const p = try self.allocPiece(.orig, 0, @intCast(orig.len), null);
            self.pieces.insertRoot(&p.node);
        }
        return self;
    }

    pub fn close(self: *Buffer) void {
        // Join the loader ahead of destroying its pages and closing
        // its file. File-backed only; views never spawn one.
        if (self.file != null) {
            if (self.pages) |p| p.stopLoader(self.io);
        }
        self.freePieces();
        self.add.deinit(self.gpa);
        self.undo_tree.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        if (self.exec_cmd) |c| self.gpa.free(c);
        if (self.orig.len > 0) self.gpa.free(self.orig);
        if (self.pages) |p| self.gpa.destroy(p);
        if (self.file) |f| f.close(self.io);
        self.* = undefined;
    }

    /// esc save. Streams leaves to a temp file and renames over the
    /// original. Atomic: readers see old or new, never partial.
    pub fn save(self: *Buffer) !void {
        if (!self.dirty) return;
        var atomic = try self.dir.createFileAtomic(self.io, self.path, .{ .replace = true });
        defer atomic.deinit(self.io);
        var n = self.pieces.first();
        while (n) |node| : (n = node.next()) {
            try self.writePiece(atomic.file, pieceFrom(node));
        }
        try atomic.replace(self.io);
        try self.compactAfterSave();
    }

    /// Replace the whole content with `text`. Only for in-memory buffers
    /// (directory views). Clears undo of pieces, clamps the cursor,
    /// and leaves the buffer clean.
    pub fn replaceAll(self: *Buffer, text: []const u8) !void {
        assert(self.file == null);
        if (text.len > add_size_max) return error.AddTooLarge;
        self.bumpEdit();
        self.undo_tree.clear(self.gpa);
        self.freePieces();
        self.add.clearRetainingCapacity();
        if (self.orig.len > 0) {
            self.gpa.free(self.orig);
            self.orig = &.{};
        }
        if (text.len == 0) {
            self.row = 0;
            self.col = 0;
            self.dirty = false;
            return;
        }
        try self.add.appendSlice(self.gpa, text);
        const p = try self.allocPiece(.add, 0, @intCast(text.len), null);
        self.pieces.insertRoot(&p.node);
        self.row = @min(self.row, self.lineCount() - 1);
        const len = try self.lineLen(self.row);
        if (self.col > len) self.col = len;
        self.dirty = false;
    }

    pub fn lineCount(self: *const Buffer) u64 {
        return self.nlCount() + 1;
    }

    pub fn lineLen(self: *Buffer, i: u64) !u64 {
        var n: u64 = 0;
        try self.forLine(i, &n, null);
        return n;
    }

    /// Copy line `i` into `out`, omitting the trailing newline. Truncates if
    /// the line is longer than `out`.
    pub fn line(self: *Buffer, i: u64, out: []u8) ![]const u8 {
        var n: u64 = 0;
        try self.forLine(i, &n, out);
        return out[0..n];
    }

    /// Reads the line starting at byte `pos` into `out`, skipping the
    /// first `skip` bytes of the line. The newline is omitted. Copies at
    /// most `out.len` bytes but always scans to the newline, returning
    /// the bytes copied and the start of the next line (`byteCount` at
    /// EOF). Sequential paint walks rows with this instead of one tree
    /// lookup per row.
    pub fn readLineAt(self: *Buffer, pos: u64, skip: u64, out: []u8) !struct { len: usize, next: u64 } {
        assert(pos <= self.byteCount());
        if (pos >= self.byteCount()) return .{ .len = 0, .next = self.byteCount() };
        const loc = self.locate(pos);
        var cur = pos;
        var skipped = skip;
        var n: usize = 0;
        var inner = loc.inner;
        var piece = loc.piece;
        while (true) {
            const run = try self.runBytes(piece, inner, piece.len - inner);
            if (std.mem.findScalarPos(u8, run, 0, '\n')) |idx| {
                const at: u64 = @intCast(idx);
                if (skipped < at) {
                    const from: usize = @intCast(skipped);
                    const take = @min(idx - from, out.len - n);
                    @memcpy(out[n..][0..take], run[from..][0..take]);
                    n += take;
                }
                return .{ .len = n, .next = cur + at + 1 };
            }
            if (skipped < @as(u64, run.len)) {
                const from: usize = @intCast(skipped);
                const take = @min(run.len - from, out.len - n);
                @memcpy(out[n..][0..take], run[from..][0..take]);
                n += take;
                skipped = 0;
            } else {
                skipped -= @as(u64, run.len);
            }
            cur += @as(u64, run.len);
            const node = piece.node.next() orelse return .{ .len = n, .next = self.byteCount() };
            piece = pieceFrom(node);
            inner = 0;
        }
    }

    fn forLine(self: *Buffer, i: u64, n: *u64, out: ?[]u8) !void {
        assert(i < self.lineCount());
        n.* = 0;
        const start = try self.lineStart(i);
        if (self.byteCount() == 0 or start >= self.byteCount()) return;
        var loc = self.locate(start);
        while (true) {
            const run = try self.runBytes(loc.piece, loc.inner, loc.piece.len - loc.inner);
            const idx = std.mem.findScalarPos(u8, run, 0, '\n');
            const seglen: u64 = if (idx) |j| @intCast(j) else @intCast(run.len);
            if (out) |o| {
                const room: u64 = @as(u64, o.len) - @min(n.*, @as(u64, o.len));
                const take: usize = @intCast(@min(seglen, room));
                @memcpy(o[@as(usize, @intCast(n.*))..][0..take], run[0..take]);
                n.* += take;
                if (idx != null or n.* >= @as(u64, o.len)) return;
            } else {
                n.* += seglen;
                if (idx != null) return;
            }
            const next = loc.piece.node.next() orelse return;
            loc = .{ .piece = pieceFrom(next), .inner = 0 };
        }
    }

    /// Tells the background loader the reader got this far. Paint calls
    /// it with the end of the visible range each frame, so sequential
    /// scrolling preloads ahead instead of faulting behind.
    pub fn noteReadAhead(self: *Buffer, io: std.Io, off: u64) void {
        const p = self.pages orelse return;
        p.noteReadAhead(io, off);
    }

    pub fn move(self: *Buffer, drow: i32, dcol: i32) !void {
        const n = self.lineCount();
        assert(n > 0);
        assert(self.row < n);

        self.row = addClamp(self.row, drow, n - 1);
        const len = try self.lineLen(self.row);
        self.col = addClamp(self.col, dcol, len);
    }

    /// View motion: rows wrap past the ends instead of clamping, so
    /// listings cycle top to bottom and back. Columns still clamp.
    /// Files keep `move`: edits must never wrap the cursor.
    pub fn moveWrap(self: *Buffer, drow: i32, dcol: i32) !void {
        const n = self.lineCount();
        assert(n > 0);
        assert(self.row < n);

        self.row = wrapRow(self.row, drow, n);
        const len = try self.lineLen(self.row);
        self.col = addClamp(self.col, dcol, len);
    }

    pub fn jump(self: *Buffer, which: Jump) !void {
        const n = self.lineCount();
        assert(n > 0);
        assert(self.row < n);
        switch (which) {
            .top => self.row = 0,
            .bottom => self.row = n - 1,
            .line_start => self.col = 0,
            .line_end => self.col = try self.lineLen(self.row),
            .line => |one| {
                const want: u64 = if (one == 0) 1 else one;
                self.row = @min(want, n) - 1;
            },
        }
        const len = try self.lineLen(self.row);
        if (self.col > len) self.col = len;
    }

    /// `steps > 0` walks to later word starts on this line. `steps < 0` walks
    /// to earlier ones. A word is a run of the same class (word chars, or
    /// punctuation), split by space and tab.
    pub fn skipWord(self: *Buffer, steps: i32) !void {
        if (steps == 0) return;
        const forward = steps > 0;
        var left: u32 = @intCast(if (forward) steps else -steps);
        while (left > 0) : (left -= 1) {
            const before = self.col;
            if (forward) {
                try self.skipWordForward();
            } else {
                try self.skipWordBack();
            }
            if (self.col == before) return;
        }
    }

    /// Delete `count` lines. Positive starts at the cursor and goes down.
    /// Negative includes the cursor and goes up.
    pub fn deleteLines(self: *Buffer, count: i32) !void {
        assert(count != 0);
        const nlines = self.lineCount();
        assert(nlines > 0);
        assert(self.row < nlines);
        if (self.byteCount() == 0) return;

        const mag: u32 = @intCast(if (count < 0) -count else count);
        const start: u64 = if (count > 0)
            self.row
        else if (self.row + 1 > mag)
            self.row + 1 - mag
        else
            0;
        const end: u64 = if (count > 0)
            @min(nlines, self.row + mag)
        else
            self.row + 1;
        assert(start < end);

        var from = try self.lineStart(start);
        const to = if (end >= nlines) self.byteCount() else try self.lineStart(end);
        const ate_prev = end >= nlines and start > 0;
        if (ate_prev) from -= 1;
        const gone = try self.collectRange(from, to);
        defer self.gpa.free(gone);
        const pre = UndoCursor{ .row = self.row, .col = self.col };
        try self.deleteRange(from, to);
        self.dirty = true;
        const after = self.lineCount();
        self.row = if (ate_prev) start - 1 else @min(start, after - 1);
        const len = try self.lineLen(self.row);
        if (self.col > len) self.col = len;
        if (!self.applying) {
            const post = UndoCursor{ .row = self.row, .col = self.col };
            self.undo_tree.pushDelete(self.gpa, from, gone, pre, post) catch {};
        }
    }

    /// Insert `n` blank lines above or below the cursor. Cursor lands on the
    /// first new line.
    pub fn openLine(self: *Buffer, below: bool, n: u32) !void {
        assert(n > 0);
        const len = try self.lineLen(self.row);
        const at = try self.lineStart(self.row) + if (below) len else 0;
        const pre = UndoCursor{ .row = self.row, .col = self.col };
        var i: u32 = 0;
        while (i < n) : (i += 1) try self.insertAt(at, '\n');
        self.dirty = true;
        if (below) self.row += 1;
        self.col = 0;
        if (!self.applying) {
            const post = UndoCursor{ .row = self.row, .col = self.col };
            self.undo_tree.pushInsertRun(self.gpa, at, '\n', n, pre, post) catch {};
        }
    }

    /// Overwrite `n` characters at the cursor with `byte`. Stops at the line end.
    pub fn changeChars(self: *Buffer, n: u32, byte: u8) !void {
        assert(n > 0);
        assert(byte == '\t' or byte >= 32);
        const len = try self.lineLen(self.row);
        if (self.col >= len) return;
        const m = @min(n, len - self.col);
        const start = try self.lineStart(self.row) + self.col;
        const old = try self.collectRange(start, start + m);
        defer self.gpa.free(old);
        const pre = UndoCursor{ .row = self.row, .col = self.col };
        var i: u64 = m;
        while (i > 0) {
            i -= 1;
            try self.deleteAt(start + i);
            try self.insertAt(start + i, byte);
        }
        self.dirty = true;
        if (!self.applying) {
            var new_bytes: std.ArrayList(u8) = .empty;
            defer new_bytes.deinit(self.gpa);
            var k: u64 = 0;
            while (k < m) : (k += 1) try new_bytes.append(self.gpa, byte);
            const post = UndoCursor{ .row = self.row, .col = self.col };
            self.undo_tree.pushReplace(self.gpa, start, old, new_bytes.items, pre, post) catch {};
        }
    }

    /// Lines longer than this are skipped by search, never materialized.
    pub const max_search_line: usize = 1 << 20;

    /// Owned copy of line `i` without the newline. Errors `LineTooLong`
    /// past the cap; search skips those lines instead of OOMing.
    pub fn readFullLine(self: *Buffer, gpa: std.mem.Allocator, i: u64) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const start = try self.lineStart(i);
        if (start >= self.byteCount()) return out.toOwnedSlice(gpa);
        var loc = self.locate(start);
        while (true) {
            const run = try self.runBytes(loc.piece, loc.inner, loc.piece.len - loc.inner);
            if (std.mem.findScalarPos(u8, run, 0, '\n')) |idx| {
                if (out.items.len + idx > max_search_line) return error.LineTooLong;
                try out.appendSlice(gpa, run[0..idx]);
                return out.toOwnedSlice(gpa);
            }
            if (out.items.len + run.len > max_search_line) return error.LineTooLong;
            try out.appendSlice(gpa, run);
            const next = loc.piece.node.next() orelse return out.toOwnedSlice(gpa);
            loc = .{ .piece = pieceFrom(next), .inner = 0 };
        }
    }

    /// Replace byte range `[from, to)` with `new` as one undoable step.
    /// Cursor lands at the end of the replacement. Powers search
    /// replace; normal typing keeps its own ops.
    pub fn replaceRange(self: *Buffer, from: u64, to: u64, new: []const u8) !void {
        assert(from <= to);
        assert(to <= self.byteCount());
        if (from == to and new.len == 0) return;
        const old = try self.collectRange(from, to);
        defer self.gpa.free(old);
        const pre = UndoCursor{ .row = self.row, .col = self.col };
        try self.deleteRange(from, to);
        try self.insertBytes(from, new);
        try self.seekOffset(from + @as(u64, new.len));
        self.dirty = true;
        if (!self.applying) {
            const post = UndoCursor{ .row = self.row, .col = self.col };
            self.undo_tree.pushReplace(self.gpa, from, old, new, pre, post) catch {};
        }
    }

    /// Move the cursor to byte offset `off`, clamped into the content.
    /// Search jumps land here; offsets come from match spans.
    pub fn seekOffset(self: *Buffer, off: u64) !void {
        const o = @min(off, self.byteCount());
        var row: u64 = 0;
        var cur: u64 = 0;
        var n = self.pieces.first();
        while (n) |node| {
            const p = pieceFrom(node);
            if (o < cur + p.len) {
                const inner = o - cur;
                var at: u64 = 0;
                while (at < inner) {
                    const run = try self.runBytes(p, at, inner - at);
                    row += std.mem.countScalar(u8, run, '\n');
                    at += @as(u64, run.len);
                }
                break;
            }
            row += p.nls;
            cur += p.len;
            n = node.next();
        }
        self.row = row;
        const ls = try self.lineStart(self.row);
        self.col = o - ls;
        try self.clampCursor();
    }

    /// Clamped cursor set for search jumps to known rows.
    pub fn goTo(self: *Buffer, row: u64, col: u64) !void {
        self.row = row;
        self.col = col;
        try self.clampCursor();
    }

    pub fn insert(self: *Buffer, byte: u8) !void {
        const len = try self.lineLen(self.row);
        if (self.col > len) self.col = len;
        const pre = UndoCursor{ .row = self.row, .col = self.col };
        const pos = try self.lineStart(self.row) + self.col;
        try self.insertAt(pos, byte);
        self.dirty = true;
        if (byte == '\n') {
            self.row += 1;
            self.col = 0;
        } else {
            self.col += 1;
        }
        if (!self.applying) {
            const post = UndoCursor{ .row = self.row, .col = self.col };
            self.undo_tree.pushInsert(self.gpa, pos, &.{byte}, pre, post) catch {};
        }
    }

    pub fn backspace(self: *Buffer) !void {
        if (self.col == 0 and self.row == 0) return;
        const pos = try self.lineStart(self.row) + self.col;
        assert(pos > 0);
        const gone_at = pos - 1;
        const pre = UndoCursor{ .row = self.row, .col = self.col };
        const loc = self.locate(gone_at);
        const gone_byte = try self.pieceByte(loc.piece, loc.inner);
        if (self.col == 0) {
            const prev_len = try self.lineLen(self.row - 1);
            try self.deleteAt(gone_at);
            self.row -= 1;
            self.col = prev_len;
        } else {
            try self.deleteAt(gone_at);
            self.col -= 1;
        }
        self.dirty = true;
        if (!self.applying) {
            const post = UndoCursor{ .row = self.row, .col = self.col };
            self.undo_tree.pushDelete(self.gpa, gone_at, &.{gone_byte}, pre, post) catch {};
        }
    }

    /// Step one edit back. Returns false at the root. Marks the buffer
    /// dirty; the caller saves like any other normal-mode edit.
    pub fn undo(self: *Buffer) !bool {
        const t = self.undo_tree.undoTarget() orelse return false;
        self.applying = true;
        defer self.applying = false;
        try self.applyOp(t.op, false);
        self.undo_tree.commitUndo();
        self.row = t.cursor.row;
        self.col = t.cursor.col;
        try self.clampCursor();
        self.dirty = true;
        return true;
    }

    /// Re-apply the newest undone edit. Returns false at a tip. Forks
    /// stay: redo follows the most recent branch.
    pub fn redo(self: *Buffer) !bool {
        const t = self.undo_tree.redoTarget() orelse return false;
        self.applying = true;
        defer self.applying = false;
        try self.applyOp(t.op, true);
        self.undo_tree.commitRedo();
        self.row = t.cursor.row;
        self.col = t.cursor.col;
        try self.clampCursor();
        self.dirty = true;
        return true;
    }

    fn applyOp(self: *Buffer, op: *const UndoTreeMod.Op, forward: bool) !void {
        switch (op.*) {
            .insert => |*ins| {
                const span = ins.pos + @as(u64, ins.text.items.len);
                if (forward) try self.insertBytes(ins.pos, ins.text.items) else try self.deleteRange(ins.pos, span);
            },
            .delete => |*del| {
                const span = del.pos + @as(u64, del.text.items.len);
                if (forward) try self.deleteRange(del.pos, span) else try self.insertBytes(del.pos, del.text.items);
            },
            .replace => |*rep| {
                const old_span = rep.pos + @as(u64, rep.old.items.len);
                const new_span = rep.pos + @as(u64, rep.new.items.len);
                if (forward) {
                    try self.deleteRange(rep.pos, old_span);
                    try self.insertBytes(rep.pos, rep.new.items);
                } else {
                    try self.deleteRange(rep.pos, new_span);
                    try self.insertBytes(rep.pos, rep.old.items);
                }
            },
        }
    }

    fn insertBytes(self: *Buffer, pos: u64, bytes: []const u8) !void {
        for (bytes, 0..) |b, i| try self.insertAt(pos + @as(u64, i), b);
    }

    /// Owned copy of `[from, to)`. Used to record the inverse before a
    /// destructive edit.
    fn collectRange(self: *Buffer, from: u64, to: u64) ![]u8 {
        const gpa = self.gpa;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var off = from;
        if (off < to) {
            const first = self.locate(off);
            var piece = first.piece;
            var inner = first.inner;
            while (off < to) {
                const want = @min(piece.len - inner, to - off);
                const run = try self.runBytes(piece, inner, want);
                try out.appendSlice(gpa, run);
                off += @as(u64, run.len);
                inner += @as(u64, run.len);
                if (off < to and inner >= piece.len) {
                    const next = piece.node.next() orelse break;
                    piece = pieceFrom(next);
                    inner = 0;
                }
            }
        }
        return out.toOwnedSlice(gpa);
    }

    fn clampCursor(self: *Buffer) !void {
        const n = self.lineCount();
        if (self.row >= n) self.row = n - 1;
        const len = try self.lineLen(self.row);
        if (self.col > len) self.col = len;
    }

    fn addClamp(pos: u64, delta: i32, max: u64) u64 {
        const base: u64 = @min(pos, max);
        if (delta < 0) {
            const back: u64 = @intCast(-@as(i64, delta));
            return if (base > back) base - back else 0;
        }
        const fwd: u64 = @intCast(delta);
        return base + @min(fwd, max - base);
    }

    /// Euclidean row wrap for view motion. `@mod` stays non-negative,
    /// so up from 0 lands on the last row and down from it on 0.
    fn wrapRow(pos: u64, delta: i32, n: u64) u64 {
        assert(n > 0);
        const m: i64 = @intCast(n);
        const r = @mod(@as(i64, @intCast(pos)) + @as(i64, delta), m);
        return @intCast(r);
    }

    fn skipWordForward(self: *Buffer) !void {
        const len = try self.lineLen(self.row);
        if (self.col >= len) return;
        var i = self.col;
        const kind = try self.colClass(i);
        if (kind != 0) {
            while (i < len and try self.colClass(i) == kind) i += 1;
        }
        while (i < len and try self.colClass(i) == 0) i += 1;
        if (i < len) self.col = i;
    }

    fn skipWordBack(self: *Buffer) !void {
        const len = try self.lineLen(self.row);
        if (self.col == 0) return;
        var i = if (self.col > len) len else self.col;
        i -= 1;
        while (i > 0 and try self.colClass(i) == 0) i -= 1;
        if (try self.colClass(i) == 0) {
            self.col = i;
            return;
        }
        const kind = try self.colClass(i);
        while (i > 0 and try self.colClass(i - 1) == kind) i -= 1;
        self.col = i;
    }

    /// 0 blank, 1 word (`[A-Za-z0-9_]`), 2 punctuation.
    fn colClass(self: *Buffer, col: u64) !u2 {
        const pos = try self.lineStart(self.row) + col;
        const loc = self.locate(pos);
        const b = try self.pieceByte(loc.piece, loc.inner);
        if (b == ' ' or b == '\t') return 0;
        if (std.ascii.isAlphanumeric(b) or b == '_') return 1;
        return 2;
    }

    fn deleteRange(self: *Buffer, from: u64, to: u64) !void {
        assert(from <= to);
        assert(to <= self.byteCount());
        if (from == to) return;
        self.bumpEdit();
        const total = self.byteCount();
        // Split at both edges so the range covers whole pieces.
        if (from > 0) {
            const loc = self.locate(from);
            if (loc.inner != 0 and loc.inner != loc.piece.len) {
                try self.split(loc.piece, loc.inner);
            }
        }
        if (to < total) {
            const loc = self.locate(to);
            if (loc.inner != 0 and loc.inner != loc.piece.len) {
                try self.split(loc.piece, loc.inner);
            }
        }
        // Drop every whole piece in `[from, to)`. O(pieces), not O(bytes).
        var off = from;
        var cur = self.locate(from).piece;
        while (true) {
            const next_n = cur.node.next();
            const span = cur.len;
            const at_add_tail = cur.src == .add and cur.off + cur.len == self.add.items.len;
            self.pieces.remove(&cur.node);
            if (at_add_tail) {
                var k: u64 = 0;
                while (k < span) : (k += 1) _ = self.add.pop();
            }
            self.gpa.destroy(cur);
            off += span;
            if (off >= to) break;
            cur = pieceFrom(next_n.?);
        }
        assert(off == to);
    }

    fn insertAt(self: *Buffer, pos: u64, byte: u8) !void {
        self.bumpEdit();
        if (try self.tryExtend(pos, byte)) return;
        if (self.add.items.len >= add_size_max) return error.AddTooLarge;
        try self.add.append(self.gpa, byte);
        const add_off: u64 = @intCast(self.add.items.len - 1);
        const neu = try self.allocPiece(.add, add_off, 1, null);

        if (self.pieces.root == null) {
            self.pieces.insertRoot(&neu.node);
            return;
        }

        const loc = self.locate(pos);
        if (loc.inner == 0) {
            self.pieces.insertBefore(&loc.piece.node, &neu.node);
        } else if (loc.inner == loc.piece.len) {
            self.pieces.insertAfter(&loc.piece.node, &neu.node);
        } else {
            try self.split(loc.piece, loc.inner);
            self.pieces.insertAfter(&loc.piece.node, &neu.node);
        }
    }

    fn tryExtend(self: *Buffer, pos: u64, byte: u8) !bool {
        if (pos == 0) return false;
        if (self.pieces.root == null) return false;
        if (self.add.items.len >= add_size_max) return false;
        const loc = self.locate(pos - 1);
        if (loc.inner + 1 != loc.piece.len) return false;
        if (loc.piece.src != .add) return false;
        if (loc.piece.off + loc.piece.len != self.add.items.len) return false;
        try self.add.append(self.gpa, byte);
        loc.piece.len += 1;
        if (byte == '\n') loc.piece.nls += 1;
        self.pieces.augmentUp(&loc.piece.node);
        return true;
    }

    fn deleteAt(self: *Buffer, pos: u64) !void {
        self.bumpEdit();
        const total = self.byteCount();
        assert(pos < total);
        const loc = self.locate(pos);
        assert(loc.inner < loc.piece.len);
        const p = loc.piece;
        const at_add_tail = p.src == .add and p.off + p.len == self.add.items.len;

        if (p.len == 1) {
            self.pieces.remove(&p.node);
            if (at_add_tail) _ = self.add.pop();
            self.gpa.destroy(p);
            return;
        }

        if (loc.inner == 0) {
            p.off += 1;
            p.len -= 1;
            p.nls = try self.countNlRange(p.src, p.off, p.len);
            self.pieces.augmentUp(&p.node);
            return;
        }
        if (loc.inner + 1 == p.len) {
            p.len -= 1;
            p.nls = try self.countNlRange(p.src, p.off, p.len);
            if (at_add_tail) _ = self.add.pop();
            self.pieces.augmentUp(&p.node);
            return;
        }

        try self.split(p, loc.inner + 1);
        p.len = loc.inner;
        p.nls = try self.countNlRange(p.src, p.off, p.len);
        self.pieces.augmentUp(&p.node);
    }

    fn split(self: *Buffer, p: *Piece, inner: u64) !void {
        assert(inner > 0);
        assert(inner < p.len);
        const right_off = p.off + inner;
        const right_len = p.len - inner;
        const right = try self.allocPiece(p.src, right_off, right_len, null);
        p.len = inner;
        p.nls = try self.countNlRange(p.src, p.off, p.len);
        self.pieces.insertAfter(&p.node, &right.node);
        self.pieces.augmentUp(&p.node);
    }

    fn allocPiece(self: *Buffer, src: Source, off: u64, len: u64, nls_opt: ?u64) !*Piece {
        const nls = nls_opt orelse try self.countNlRange(src, off, len);
        const p = try self.gpa.create(Piece);
        p.* = .{
            .src = src,
            .off = off,
            .len = len,
            .nls = nls,
            .sub_bytes = len,
            .sub_nls = nls,
        };
        return p;
    }

    fn pieceByte(self: *Buffer, p: *const Piece, inner: u64) !u8 {
        assert(inner < p.len);
        const off = p.off + inner;
        switch (p.src) {
            .add => return self.add.items[off],
            .orig => {
                if (self.file) |f| {
                    const s = try self.pages.?.slice(self.io, f, self.file_len, off);
                    return s[0];
                }
                return self.orig[off];
            },
        }
    }

    /// One contiguous run of piece bytes starting at `inner`, up to
    /// `max` bytes. File pieces end the run at the page edge. Scans
    /// walk runs with vectorized search instead of per-byte calls.
    /// Advance by the returned length.
    fn runBytes(self: *Buffer, piece: *const Piece, inner: u64, max: u64) ![]const u8 {
        assert(inner <= piece.len);
        const take = @min(piece.len - inner, max);
        if (take == 0) return "";
        switch (piece.src) {
            .add => return self.add.items[piece.off + inner ..][0..take],
            .orig => {
                if (self.file) |f| {
                    const s = try self.pages.?.slice(self.io, f, self.file_len, piece.off + inner);
                    return s[0..@min(take, @as(u64, s.len))];
                }
                return self.orig[piece.off + inner ..][0..take];
            },
        }
    }

    fn countNlRange(self: *Buffer, src: Source, off: u64, len: u64) !u64 {
        var n: u64 = 0;
        switch (src) {
            .add => {
                n += countNl(self.add.items[off .. off + len]);
            },
            .orig => {
                if (self.file) |f| {
                    var i: u64 = 0;
                    while (i < len) {
                        const s = try self.pages.?.slice(self.io, f, self.file_len, off + i);
                        const take: u64 = @min(@as(u64, s.len), len - i);
                        n += countNl(s[0..take]);
                        i += take;
                    }
                } else {
                    n += countNl(self.orig[off .. off + len]);
                }
            },
        }
        return n;
    }

    fn scanFileNewlines(self: *Buffer) !u64 {
        const f = self.file.?;
        var n: u64 = 0;
        var off: u64 = 0;
        while (off < self.file_len) {
            const s = try self.pages.?.slice(self.io, f, self.file_len, off);
            n += countNl(s);
            off += @intCast(s.len);
        }
        return n;
    }

    fn writePiece(self: *Buffer, file: std.Io.File, p: *const Piece) !void {
        switch (p.src) {
            .add => try file.writeStreamingAll(self.io, self.add.items[p.off .. p.off + p.len]),
            .orig => {
                if (self.file) |f| {
                    var inner: u64 = 0;
                    while (inner < p.len) {
                        const s = try self.pages.?.slice(self.io, f, self.file_len, p.off + inner);
                        const take: usize = @min(s.len, @as(usize, @intCast(p.len - inner)));
                        try file.writeStreamingAll(self.io, s[0..take]);
                        inner += take;
                    }
                } else {
                    try file.writeStreamingAll(self.io, self.orig[p.off .. p.off + p.len]);
                }
            },
        }
    }

    fn compactAfterSave(self: *Buffer) !void {
        self.freePieces();
        self.add.clearRetainingCapacity();
        // The atomic replace swapped the inode: the loader's handle
        // reads the old file, so join it before invalidating. It
        // respawns lazily on the next fault past the threshold.
        if (self.pages) |p| {
            p.stopLoader(self.io);
            p.invalidate();
        }
        if (self.file) |f| {
            f.close(self.io);
            self.file = null;
        }
        if (self.orig.len > 0) {
            self.gpa.free(self.orig);
            self.orig = &.{};
        }
        const neu = try self.dir.openFile(self.io, self.path, .{ .mode = .read_only });
        self.file = neu;
        const st = try neu.stat(self.io);
        self.file_len = @intCast(st.size);
        if (self.file_len > 0) {
            const nls = try self.scanFileNewlines();
            const p = try self.allocPiece(.orig, 0, self.file_len, nls);
            self.pieces.insertRoot(&p.node);
        }
        self.dirty = false;
    }

    fn freePieces(self: *Buffer) void {
        var n = self.pieces.first();
        while (n) |node| {
            const next = node.next();
            self.gpa.destroy(pieceFrom(node));
            n = next;
        }
        self.pieces = .{};
    }

    pub fn byteCount(self: *const Buffer) u64 {
        const root = self.pieces.root orelse return 0;
        return pieceFromConst(root).sub_bytes;
    }

    /// Byte offset of `(row, col)`, clamping the column to the line.
    /// Selection endpoints land here; rows come from live cursors.
    pub fn offsetOf(self: *Buffer, row: u64, col: u64) !u64 {
        const r = @min(row, self.lineCount() - 1);
        return try self.lineStart(r) + @min(col, try self.lineLen(r));
    }

    /// Selection byte range from the anchor to the cursor, end-exclusive
    /// with the cursor cell included. Never empty: equal endpoints
    /// collapse to `[o, o]`, which the range ops treat as a no-op.
    pub fn selBytes(self: *Buffer, arow: u64, acol: u64) ![2]u64 {
        const a = try self.offsetOf(arow, acol);
        const b = try self.offsetOf(self.row, self.col);
        const from = @min(a, b);
        const to = @min(@max(a, b) + 1, self.byteCount());
        return .{ from, @max(from, to) };
    }

    /// Delete byte range `[from, to)` as one undoable step. Cursor
    /// lands at the start of the gap. Empty ranges are silent no-ops
    /// that stay clean. Powers selection delete.
    pub fn deleteByteRange(self: *Buffer, from: u64, to: u64) !void {
        assert(from <= to);
        assert(to <= self.byteCount());
        if (from == to) return;
        const gone = try self.collectRange(from, to);
        defer self.gpa.free(gone);
        const pre = UndoCursor{ .row = self.row, .col = self.col };
        try self.deleteRange(from, to);
        self.dirty = true;
        try self.seekOffset(from);
        if (!self.applying) {
            const post = UndoCursor{ .row = self.row, .col = self.col };
            self.undo_tree.pushDelete(self.gpa, from, gone, pre, post) catch {};
        }
    }

    /// Overwrite every non-newline byte in `[from, to)` with `byte` as
    /// one undoable step. Line structure survives: newlines are kept.
    /// Cursor lands at the start of the range. Powers selection
    /// replace (`r`); single-char replace stays on `changeChars`.
    pub fn replaceRangeWithChar(self: *Buffer, from: u64, to: u64, byte: u8) !void {
        assert(byte == '\t' or byte >= 32);
        assert(from <= to);
        assert(to <= self.byteCount());
        if (from == to) return;
        const old = try self.collectRange(from, to);
        defer self.gpa.free(old);
        var new_bytes: std.ArrayList(u8) = .empty;
        defer new_bytes.deinit(self.gpa);
        var all_nl = true;
        for (old) |b| {
            if (b == '\n') {
                try new_bytes.append(self.gpa, b);
            } else {
                try new_bytes.append(self.gpa, byte);
                all_nl = false;
            }
        }
        if (all_nl) return;
        const pre = UndoCursor{ .row = self.row, .col = self.col };
        try self.deleteRange(from, to);
        try self.insertBytes(from, new_bytes.items);
        self.dirty = true;
        try self.seekOffset(from);
        if (!self.applying) {
            const post = UndoCursor{ .row = self.row, .col = self.col };
            self.undo_tree.pushReplace(self.gpa, from, old, new_bytes.items, pre, post) catch {};
        }
    }

    fn nlCount(self: *const Buffer) u64 {
        const root = self.pieces.root orelse return 0;
        return pieceFromConst(root).sub_nls;
    }

    /// Byte offset of the start of line `i`. One tree lookup; paint
    /// calls it once per frame, then walks forward sequentially.
    pub fn lineStart(self: *Buffer, i: u64) !u64 {
        if (i == 0) return 0;
        const abs = try self.newlinePos(i - 1);
        return abs + 1;
    }

    fn newlinePos(self: *Buffer, which: u64) !u64 {
        assert(which < self.nlCount());
        var n = self.pieces.root.?;
        var remain = which;
        while (true) {
            const p = pieceFrom(n);
            const left_nls = if (n.left) |l| pieceFrom(l).sub_nls else 0;
            if (remain < left_nls) {
                n = n.left.?;
                continue;
            }
            remain -= left_nls;
            if (remain < p.nls) {
                var need = remain;
                var inner: u64 = 0;
                while (inner < p.len) {
                    const run = try self.runBytes(p, inner, p.len - inner);
                    const c: u64 = std.mem.countScalar(u8, run, '\n');
                    if (need < c) {
                        var pos: usize = 0;
                        var r = need;
                        while (true) {
                            const idx = std.mem.findScalarPos(u8, run, pos, '\n').?;
                            if (r == 0) {
                                const found = inner + @as(u64, idx);
                                return positionOf(n, found);
                            }
                            r -= 1;
                            pos = idx + 1;
                        }
                    }
                    need -= c;
                    inner += @as(u64, run.len);
                }
                unreachable;
            }
            remain -= p.nls;
            n = n.right.?;
        }
    }

    const Loc = struct { piece: *Piece, inner: u64 };

    fn locate(self: *const Buffer, off: u64) Loc {
        const total = self.byteCount();
        assert(off <= total);
        assert(self.pieces.root != null);
        if (off == total) {
            const last = pieceFrom(self.pieces.last().?);
            return .{ .piece = last, .inner = last.len };
        }
        var n = self.pieces.root.?;
        var remain = off;
        while (true) {
            const p = pieceFrom(n);
            const left_bytes = if (n.left) |l| pieceFrom(l).sub_bytes else 0;
            if (remain < left_bytes) {
                n = n.left.?;
                continue;
            }
            remain -= left_bytes;
            if (remain < p.len) return .{ .piece = p, .inner = remain };
            remain -= p.len;
            n = n.right.?;
        }
    }

    fn positionOf(n: *const rbtree.Node, inner: u64) u64 {
        var off = inner;
        if (n.left) |l| off += pieceFromConst(l).sub_bytes;
        var cur: *const rbtree.Node = n;
        while (cur.parent) |p| {
            if (cur == p.right) {
                off += pieceFromConst(p).len;
                if (p.left) |l| off += pieceFromConst(l).sub_bytes;
            }
            cur = p;
        }
        return off;
    }
};

fn countNl(bytes: []const u8) u32 {
    return @intCast(@min(std.mem.countScalar(u8, bytes, '\n'), std.math.maxInt(u32)));
}

fn collect(b: *Buffer, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n = b.pieces.first();
    while (n) |node| : (n = node.next()) {
        const p = pieceFrom(node);
        var i: u64 = 0;
        while (i < p.len) : (i += 1) {
            try out.append(gpa, try b.pieceByte(p, i));
        }
    }
    return out.toOwnedSlice(gpa);
}

test "orig file lines omit the newline" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\nc");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try std.testing.expectEqual(@as(u64, 2), b.lineCount());
    var tmp: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ab", try b.line(0, &tmp));
    try std.testing.expectEqualStrings("c", try b.line(1, &tmp));
}

test "readLineAt walks rows with skip and next" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\ncde\n");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    var tmp: [8]u8 = undefined;
    const r0 = try b.readLineAt(0, 0, &tmp);
    try std.testing.expectEqualStrings("ab", tmp[0..r0.len]);
    try std.testing.expectEqual(@as(u64, 3), r0.next);

    // Skip renders the horizontal window without a second lookup.
    const r0w = try b.readLineAt(0, 1, &tmp);
    try std.testing.expectEqualStrings("b", tmp[0..r0w.len]);
    try std.testing.expectEqual(@as(u64, 3), r0w.next);

    const r1 = try b.readLineAt(r0.next, 0, &tmp);
    try std.testing.expectEqualStrings("cde", tmp[0..r1.len]);
    try std.testing.expectEqual(@as(u64, 7), r1.next);

    // Last line without newline ends at the byte count.
    const r2 = try b.readLineAt(r1.next, 0, &tmp);
    try std.testing.expectEqual(@as(usize, 0), r2.len);
    try std.testing.expectEqual(@as(u64, 7), r2.next);
}

test "readLineAt truncates copy but still finds next" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "abcdef\ng\n");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    var tmp: [3]u8 = undefined;
    const r = try b.readLineAt(0, 0, &tmp);
    try std.testing.expectEqualStrings("abc", tmp[0..r.len]);
    try std.testing.expectEqual(@as(u64, 7), r.next);
}

test "insert types into the add buffer and splits orig" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ac");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.col = 1;
    try b.insert('b');
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("abc", got);
    try std.testing.expectEqual(@as(u64, 2), b.col);
}

test "enter splits a line" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.col = 1;
    try b.insert('\n');
    try std.testing.expectEqual(@as(u64, 2), b.lineCount());
    try std.testing.expectEqual(@as(u64, 1), b.row);
    try std.testing.expectEqual(@as(u64, 0), b.col);
    var tmp: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a", try b.line(0, &tmp));
    try std.testing.expectEqualStrings("b", try b.line(1, &tmp));
}

test "backspace joins lines" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "a\nb");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.row = 1;
    b.col = 0;
    try b.backspace();
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ab", got);
    try std.testing.expectEqual(@as(u64, 0), b.row);
    try std.testing.expectEqual(@as(u64, 1), b.col);
}

test "move repeats a signed row delta and clamps" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "a\nb\nc\nd");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.move(3, 0);
    try std.testing.expectEqual(@as(u64, 3), b.row);
    try b.move(-4, 0);
    try std.testing.expectEqual(@as(u64, 0), b.row);
}

test "moveWrap cycles past the ends" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "a\nb\nc\nd");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    // Up from the top lands on the bottom, down from it on top.
    try b.moveWrap(-1, 0);
    try std.testing.expectEqual(@as(u64, 3), b.row);
    try b.moveWrap(1, 0);
    try std.testing.expectEqual(@as(u64, 0), b.row);
    // Counts wrap modulo the line count; columns still clamp.
    try b.moveWrap(-5, 0);
    try std.testing.expectEqual(@as(u64, 3), b.row);
    b.col = 99;
    try b.moveWrap(1, 0);
    try std.testing.expectEqual(@as(u64, 0), b.row);
    try std.testing.expectEqual(@as(u64, 1), b.col);
}

test "deleteLines removes downward and upward" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "a\nb\nc\nd\n");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.row = 1;
    try b.deleteLines(2);
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a\nd\n", got);
    try std.testing.expectEqual(@as(u64, 1), b.row);

    try b.deleteLines(-1);
    const got2 = try collect(&b, gpa);
    defer gpa.free(got2);
    try std.testing.expectEqualStrings("a\n", got2);
    try std.testing.expectEqual(@as(u64, 1), b.row);
}

test "openLine inserts blanks and lands on the first" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\ncd");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.openLine(true, 1);
    var tmp: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", try b.line(1, &tmp));
    try std.testing.expectEqual(@as(u64, 1), b.row);
    try std.testing.expectEqual(@as(u64, 0), b.col);

    b.row = 0;
    try b.openLine(false, 1);
    try std.testing.expectEqualStrings("", try b.line(0, &tmp));
    try std.testing.expectEqual(@as(u64, 0), b.row);
}

test "skipWord stays on the line" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "one two, three");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.skipWord(1);
    try std.testing.expectEqual(@as(u64, 4), b.col);
    try b.skipWord(1);
    try std.testing.expectEqual(@as(u64, 7), b.col);
    try b.skipWord(1);
    try std.testing.expectEqual(@as(u64, 9), b.col);
    try b.skipWord(-1);
    try std.testing.expectEqual(@as(u64, 7), b.col);
    try b.skipWord(5);
    try std.testing.expectEqual(@as(u64, 9), b.col);
}

test "changeChars overwrites and stops at the line end" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "abcd");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.col = 1;
    try b.changeChars(2, 'Z');
    var tmp: [8]u8 = undefined;
    try std.testing.expectEqualStrings("aZZd", try b.line(0, &tmp));
    try b.changeChars(8, 'q');
    try std.testing.expectEqualStrings("aqqq", try b.line(0, &tmp));
}

test "jump reaches the file edges and a 1-based line" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\ncde\n");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.col = 1;
    try b.jump(.line_end);
    try std.testing.expectEqual(@as(u64, 2), b.col);
    try b.jump(.line_start);
    try std.testing.expectEqual(@as(u64, 0), b.col);
    try b.jump(.{ .line = 2 });
    try std.testing.expectEqual(@as(u64, 1), b.row);
    try b.jump(.top);
    try std.testing.expectEqual(@as(u64, 0), b.row);
    try b.jump(.bottom);
    try std.testing.expectEqual(@as(u64, 2), b.row);
}

test "move clamps the column to the new line" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "hi\nbye");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.col = 99;
    try b.move(1, 0);
    try std.testing.expectEqual(@as(u64, 1), b.row);
    try std.testing.expectEqual(@as(u64, 3), b.col);
}

test "empty orig: typing builds the add buffer" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.insert('h');
    try b.insert('i');
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hi", got);
    try std.testing.expectEqual(@as(u32, 1), b.pieces.len);
}

test "open pages the file and save round-trips edits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "ab\nc" });
    var b = try Buffer.openDir(gpa, io, tmp.dir, "f");
    defer b.close();

    try std.testing.expectEqual(@as(usize, 0), b.orig.len);
    try std.testing.expect(b.file != null);
    try std.testing.expectEqual(@as(u64, 2), b.lineCount());

    b.col = 2;
    try b.insert('X');
    try b.save();

    var buf: [16]u8 = undefined;
    const got = try tmp.dir.readFile(io, "f", &buf);
    try std.testing.expectEqualStrings("abX\nc", got);
    try std.testing.expect(!b.dirty);
    try std.testing.expectEqual(@as(u32, 1), b.pieces.len);
}

test "deleteLines drops whole pieces across orig and add" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "1\n2\n3\n4\n5\n");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    // Fragment the tree with mid-line typing first.
    b.row = 1;
    b.col = 1;
    try b.insert('x');
    b.row = 3;
    b.col = 1;
    try b.insert('y');

    b.row = 1;
    b.col = 0;
    try b.deleteLines(3);
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("1\n5\n", got);
    try std.testing.expectEqual(@as(u64, 1), b.row);
}

test "deleteLines of the whole doc empties pieces and add tail" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "hello");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.col = 5;
    for (" BIG") |c| try b.insert(c);
    try b.deleteLines(1);
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("", got);
    try std.testing.expectEqual(@as(usize, 0), b.add.items.len);
    try std.testing.expectEqual(@as(u64, 1), b.lineCount());
}

test "save round-trips tail growth" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "ab" });
    var b = try Buffer.openDir(gpa, io, tmp.dir, "f");
    defer b.close();

    b.col = 2;
    try b.insert('c');
    try b.insert('d');
    try b.save();

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", try tmp.dir.readFile(io, "f", &buf));
    try std.testing.expect(!b.dirty);
    try std.testing.expectEqual(@as(u32, 1), b.pieces.len);
    var line: [16]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", try b.line(0, &line));
}

test "save round-trips overwrites" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "abcd" });
    var b = try Buffer.openDir(gpa, io, tmp.dir, "f");
    defer b.close();

    b.col = 1;
    try b.changeChars(2, 'Z');
    try b.save();

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("aZZd", try tmp.dir.readFile(io, "f", &buf));
    try std.testing.expect(!b.dirty);
    var line: [16]u8 = undefined;
    try std.testing.expectEqualStrings("aZZd", try b.line(0, &line));
}

test "save round-trips mixed edits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "abcd" });
    var b = try Buffer.openDir(gpa, io, tmp.dir, "f");
    defer b.close();

    b.col = 1;
    try b.insert('X');
    b.col = 5;
    try b.insert('Y');
    try b.save();

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("aXbcdY", try tmp.dir.readFile(io, "f", &buf));
    try std.testing.expect(!b.dirty);
    try std.testing.expectEqual(@as(u32, 1), b.pieces.len);
}

test "loader spawns past the cache threshold and joins at close" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const big = try gpa.alloc(u8, 5 * 1024 * 1024);
    defer gpa.free(big);
    for (big, 0..) |*c, i| c.* = if (i % 2 == 0) 'x' else '\n';
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = big });
    var b = try Buffer.openDir(gpa, io, tmp.dir, "f");
    try std.testing.expect(b.pages.?.loader != null);
    var line: [8]u8 = undefined;
    try std.testing.expectEqualStrings("x", try b.line(100, &line));
    b.close();
}

test "undo types back out a word then redoes it" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    for ("hi") |c| try b.insert(c);
    try std.testing.expectEqual(@as(usize, 2), b.undo_tree.nodeCount());

    try std.testing.expect(try b.undo());
    const gone = try collect(&b, gpa);
    defer gpa.free(gone);
    try std.testing.expectEqualStrings("", gone);

    try std.testing.expect(try b.redo());
    const back = try collect(&b, gpa);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("hi", back);
    try std.testing.expect(!try b.redo());
}

test "undo restores deleted lines and changeChars" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "a\nb\nc\n");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.row = 1;
    try b.deleteLines(1);
    const cut = try collect(&b, gpa);
    defer gpa.free(cut);
    try std.testing.expectEqualStrings("a\nc\n", cut);

    try std.testing.expect(try b.undo());
    const restored = try collect(&b, gpa);
    defer gpa.free(restored);
    try std.testing.expectEqualStrings("a\nb\nc\n", restored);

    b.row = 0;
    b.col = 0;
    try b.changeChars(1, 'Z');
    var tmp: [8]u8 = undefined;
    try std.testing.expectEqualStrings("Z", try b.line(0, &tmp));
    try std.testing.expect(try b.undo());
    try std.testing.expectEqualStrings("a", try b.line(0, &tmp));
}

test "undo of openLine removes the blank and redo forks newest" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.openLine(true, 1);
    try std.testing.expectEqual(@as(u64, 2), b.lineCount());
    try std.testing.expect(try b.undo());
    try std.testing.expectEqual(@as(u64, 1), b.lineCount());

    // New edit after undo forks: redo now replays the fork.
    b.col = 2;
    try b.insert('!');
    try std.testing.expect(!try b.redo());
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ab!", got);
    try std.testing.expect(try b.undo());
    const back = try collect(&b, gpa);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("ab", back);
}

test "undo and redo move the cursor with the edit" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\ncd");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    b.row = 1;
    b.col = 2;
    try b.insert('X');
    try std.testing.expectEqual(@as(u64, 3), b.col);
    try std.testing.expect(try b.undo());
    try std.testing.expectEqual(@as(u64, 1), b.row);
    try std.testing.expectEqual(@as(u64, 2), b.col);
}

test "readFullLine copies whole lines" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\ncde\n");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    const l0 = try b.readFullLine(gpa, 0);
    defer gpa.free(l0);
    try std.testing.expectEqualStrings("ab", l0);
    const l1 = try b.readFullLine(gpa, 1);
    defer gpa.free(l1);
    try std.testing.expectEqualStrings("cde", l1);
    const l2 = try b.readFullLine(gpa, 2);
    defer gpa.free(l2);
    try std.testing.expectEqualStrings("", l2);
}

test "replaceRange swaps bytes as one undo step" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "hello world");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.replaceRange(6, 11, "zig");
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello zig", got);
    try std.testing.expect(b.dirty);
    try std.testing.expect(try b.undo());
    const back = try collect(&b, gpa);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("hello world", back);
    try std.testing.expect(try b.redo());
    const fwd = try collect(&b, gpa);
    defer gpa.free(fwd);
    try std.testing.expectEqualStrings("hello zig", fwd);
}

test "seekOffset and goTo land the cursor" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\ncde\nf");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.seekOffset(4);
    try std.testing.expectEqual(@as(u64, 1), b.row);
    try std.testing.expectEqual(@as(u64, 1), b.col);
    try b.seekOffset(9999);
    try std.testing.expectEqual(@as(u64, 2), b.row);
    try std.testing.expectEqual(@as(u64, 1), b.col);
    try b.goTo(0, 99);
    try std.testing.expectEqual(@as(u64, 2), b.col);
    try b.goTo(99, 0);
    try std.testing.expectEqual(@as(u64, 2), b.row);
}

test "offsetOf clamps columns to the line" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\ncde\nf");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try std.testing.expectEqual(@as(u64, 1), try b.offsetOf(0, 1));
    try std.testing.expectEqual(@as(u64, 2), try b.offsetOf(0, 99));
    try std.testing.expectEqual(@as(u64, 4), try b.offsetOf(1, 1));
    // Round-trips with seekOffset.
    try b.seekOffset(try b.offsetOf(1, 2));
    try std.testing.expectEqual(@as(u64, 1), b.row);
    try std.testing.expectEqual(@as(u64, 2), b.col);
}

test "deleteByteRange drops a span as one undo step" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "hello\nworld\n");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.deleteByteRange(2, 8);
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("herld\n", got);
    try std.testing.expect(b.dirty);
    try std.testing.expectEqual(@as(u64, 0), b.row);
    try std.testing.expectEqual(@as(u64, 2), b.col);
    try std.testing.expect(try b.undo());
    const back = try collect(&b, gpa);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("hello\nworld\n", back);
    try std.testing.expect(try b.redo());
    const fwd = try collect(&b, gpa);
    defer gpa.free(fwd);
    try std.testing.expectEqualStrings("herld\n", fwd);
}

test "deleteByteRange of nothing stays clean" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.deleteByteRange(1, 1);
    try std.testing.expect(!b.dirty);
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ab", got);
}

test "replaceRangeWithChar keeps newlines and undoes" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "abc\nde");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.replaceRangeWithChar(0, 6, 'X');
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("XXX\nXX", got);
    try std.testing.expectEqual(@as(u64, 0), b.row);
    try std.testing.expectEqual(@as(u64, 0), b.col);
    try std.testing.expect(try b.undo());
    const back = try collect(&b, gpa);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("abc\nde", back);
}

test "replaceRangeWithChar over only newlines is a no-op" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "a\nb");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    try b.replaceRangeWithChar(1, 2, 'X');
    try std.testing.expect(!b.dirty);
    const got = try collect(&b, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a\nb", got);
}

test "selBytes covers anchor cell through cursor cell" {
    const gpa = std.testing.allocator;
    const orig = try gpa.dupe(u8, "ab\ncde\nf");
    var b = try Buffer.initOwned(gpa, "t", orig);
    defer b.close();

    // Forward: anchor (0,0), cursor on (1,1) covers "ab\ncd".
    b.row = 1;
    b.col = 1;
    const fwd = try b.selBytes(0, 0);
    try std.testing.expectEqual(@as(u64, 0), fwd[0]);
    try std.testing.expectEqual(@as(u64, 5), fwd[1]);
    // Backward: same range from the other end.
    b.row = 0;
    b.col = 0;
    const rev = try b.selBytes(1, 1);
    try std.testing.expectEqual(@as(u64, 0), rev[0]);
    try std.testing.expectEqual(@as(u64, 5), rev[1]);
    // Single cell selects one byte; empty collapses.
    b.row = 0;
    b.col = 2;
    const one = try b.selBytes(0, 2);
    try std.testing.expectEqual(@as(u64, 2), one[0]);
    try std.testing.expectEqual(@as(u64, 3), one[1]);
    // Anchor on the cursor still covers that cell: selections are
    // never empty except at EOF, where there is no cell to cover.
    b.row = 0;
    b.col = 0;
    const cell = try b.selBytes(0, 0);
    try std.testing.expectEqual(@as(u64, 0), cell[0]);
    try std.testing.expectEqual(@as(u64, 1), cell[1]);
    try b.seekOffset(try b.offsetOf(2, 1));
    const eof = try b.selBytes(2, 1);
    try std.testing.expectEqual(eof[0], eof[1]);
}
