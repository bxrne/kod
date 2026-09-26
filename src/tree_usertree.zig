//! State inspector trees. `:tree` opens one readonly scratch buffer
//! with foldable sections for the live usertrees worth looking at:
//! undo histories, the last search, open buffers, the git view, and
//! the commands run this session. Enter folds sections and jumps to
//! leaf rows (docs, matches, files), and puts a recorded command back
//! in the command box. Esc re-renders. Inspection only: nothing here
//! edits.
//!
//! The buffer owns row targets and rendered text. The caller in
//! `docs.zig` supplies plain-data snapshots, so this module never
//! imports the registry and cannot cycle back into it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const undotree = @import("lib").undotree;
const ut = @import("lib").usertrees;

pub const max_undo_rows: usize = 200;
pub const max_search_rows: usize = 50;
pub const max_commit_rows: usize = 15;
pub const max_diag_rows: usize = 50;
pub const max_command_rows: usize = 50;

/// Undo history of one open doc, borrowed for one render call.
pub const UndoView = struct {
    id: u32,
    title: []const u8,
    tree: *const undotree.UndoTree,
};

/// Last search query plus its hits, borrowed for one render call.
pub const SearchView = struct {
    query: []const u8,
    hits: []const SearchHit,
};

pub const SearchHit = struct {
    label: []const u8,
    target: TreeTarget,
};

pub const BufView = struct {
    id: u32,
    title: []const u8,
    kind: []const u8,
    row: u64,
    col: u64,
};

pub const CommitView = struct {
    hash: []const u8,
    subject: []const u8,
};

pub const GitView = struct {
    branch: []const u8,
    base: []const u8,
    unstaged: usize,
    staged: usize,
    commits: []const CommitView,
};

/// Last run: what ran, how it ended, and its jumpable rows. The
/// inspector shows the same `path:row:col:` rows the `*exec*` tree
/// holds, so the state of the run is visible without switching docs.
/// A null `exit_code` means the run is still in flight.
pub const ExecView = struct {
    cmd: []const u8,
    exit_code: ?u8,
    hits: []const SearchHit,
};

/// Where Enter lands. File paths are duped into the rows. Git rows
/// carry no payload: Enter opens the git log, where its own Enter
/// takes over for folds and diffs. Command rows carry an index into
/// this buffer's own copy of the session history.
pub const TreeTarget = union(enum) {
    none,
    section: usize,
    undo_doc: u32,
    doc: struct { id: u32, row: u64, col: u64 },
    file: struct { path: []const u8 },
    /// A diagnostics row: a file with a position inside it.
    hit: struct { path: []const u8, row: u64, col: u64 },
    git,
    /// Index into this buffer's own `commands` copy.
    command: usize,
};

pub const Section = enum { undo, search, exec, buffers, git, commands };

/// Section names for `:tree <name>`, in `Section` order. The command
/// parses a name and this table resolves it, so the list lives in one
/// place.
pub const section_names = [_][]const u8{ "undo", "search", "exec", "buffers", "git", "commands" };

/// Section that `:tree <name>` names, or null for an unknown name.
pub fn sectionOf(name: []const u8) ?Section {
    for (section_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @enumFromInt(i);
    }
    return null;
}

/// Title for a single-section buffer, so `:tree exec` is unmistakably
/// the exec section of the inspector and not the `*exec*` run tree.
pub fn sectionTitle(s: Section) []const u8 {
    return switch (s) {
        .undo => "*tree undo*",
        .search => "*tree search*",
        .exec => "*tree exec*",
        .buffers => "*tree buffers*",
        .git => "*tree git*",
        .commands => "*tree commands*",
    };
}

/// Transient render node, like the other usertrees.
pub const TreeNode = ut.TextNode;

pub const TreeBuffer = struct {
    gpa: Allocator,
    buf: Buffer,
    /// Owned title. `buf.path` points here.
    title: []u8,
    rows: std.ArrayList(TreeTarget) = .empty,
    folds: [@typeInfo(Section).@"enum".fields.len]bool = .{ false, false, false, false, false, false },
    undo_docs: std.ArrayList(UndoDocFold) = .empty,
    /// Owned copy of the session command history as rendered, newest
    /// first. Enter hands the text back for the command box, so the
    /// buffer never borrows the caller's strings.
    commands: std.ArrayList([]u8) = .empty,
    /// Set when this buffer holds one section alone, as `:tree exec`
    /// opens it. The section then renders open, with no other section
    /// beside it. Null is the full inspector.
    single: ?Section = null,

    pub const UndoDocFold = struct { id: u32, open: bool };

    pub fn open(gpa: Allocator, title: []const u8) !TreeBuffer {
        var self = TreeBuffer{ .gpa = gpa, .buf = undefined, .title = &.{} };
        errdefer self.close();
        self.title = try gpa.dupe(u8, title);
        errdefer gpa.free(self.title);
        const empty: []u8 = try gpa.dupe(u8, "");
        errdefer gpa.free(empty);
        self.buf = try Buffer.initOwned(gpa, self.title, empty);
        self.buf.hl_mode = .trees;
        return self;
    }

    pub fn close(self: *TreeBuffer) void {
        self.buf.close();
        self.clearRows();
        self.rows.deinit(self.gpa);
        self.undo_docs.deinit(self.gpa);
        self.clearCommands();
        self.commands.deinit(self.gpa);
        if (self.title.len > 0) self.gpa.free(self.title);
        self.* = undefined;
    }

    fn clearRows(self: *TreeBuffer) void {
        ut.freeOwnedLines(self.gpa, &self.rows);
    }

    fn clearCommands(self: *TreeBuffer) void {
        for (self.commands.items) |c| self.gpa.free(c);
        self.commands.clearRetainingCapacity();
    }

    /// Recorded command `i`, newest first, or null when out of range.
    pub fn commandAt(self: *const TreeBuffer, i: usize) ?[]const u8 {
        if (i >= self.commands.items.len) return null;
        return self.commands.items[i];
    }

    /// Push one row target. Paths are duped, so a row outlives the
    /// snapshot it came from: the exec tree frees its own paths on the
    /// next run, and a stale trees row must not point into them.
    fn pushRow(self: *TreeBuffer, t: TreeTarget) !void {
        switch (t) {
            .file => |f| {
                const kept = try self.gpa.dupe(u8, f.path);
                errdefer self.gpa.free(kept);
                try self.rows.append(self.gpa, .{ .file = .{ .path = kept } });
            },
            .hit => |h| {
                const kept = try self.gpa.dupe(u8, h.path);
                errdefer self.gpa.free(kept);
                try self.rows.append(self.gpa, .{ .hit = .{ .path = kept, .row = h.row, .col = h.col } });
            },
            else => try self.rows.append(self.gpa, t),
        }
    }

    pub fn targetAtRow(self: *const TreeBuffer, row: u64) ?TreeTarget {
        if (row >= self.rows.items.len) return null;
        return self.rows.items[row];
    }

    fn sectionOpen(self: *TreeBuffer, s: Section) *bool {
        return &self.folds[@intFromEnum(s)];
    }

    /// Flip whatever lives on `row`: sections and undo docs fold,
    /// leaves report their jump target. Returns null for headers.
    /// A buffer that holds one section has nothing to fold, so its
    /// header reports the first leaf instead: `Enter` there opens the
    /// first row of the tree rather than doing nothing.
    pub fn toggle(self: *TreeBuffer, row: u64) ?TreeTarget {
        const t = self.targetAtRow(row) orelse return null;
        switch (t) {
            .section => |s| {
                // A lone section has nothing to fold: its header is
                // row 0, and Enter there opens the first leaf.
                if (self.single != null) return self.firstLeaf(row + 1);
                const sec: Section = @enumFromInt(s);
                const flag = self.sectionOpen(sec);
                flag.* = !flag.*;
                return null;
            },
            .undo_doc => |id| {
                for (self.undo_docs.items) |*d| {
                    if (d.id == id) {
                        d.open = !d.open;
                        break;
                    }
                }
                return null;
            },
            else => return t,
        }
    }

    /// First leaf target at or after `from`, skipping section headers.
    /// Used by a lone section, where the header stands in for the
    /// whole tree.
    fn firstLeaf(self: *TreeBuffer, from: u64) ?TreeTarget {
        var r = from;
        while (r < self.rows.items.len) : (r += 1) {
            switch (self.rows.items[r]) {
                .section, .undo_doc, .none => continue,
                else => return self.rows.items[r],
            }
        }
        return null;
    }

    /// True when this buffer wants `s` on its own, or the whole set.
    fn wants(self: *const TreeBuffer, s: Section) bool {
        const one = self.single orelse return true;
        return one == s;
    }

    /// Fold state for `s`: open when the section renders alone, since
    /// a lone section has nothing to fold into.
    fn isOpen(self: *const TreeBuffer, s: Section) bool {
        if (self.single == s) return true;
        return self.folds[@intFromEnum(s)];
    }

    /// Render every section from borrowed snapshots, or only `single`
    /// when the buffer holds one tree on its own. Undo doc folds
    /// persist by doc id; unknown ids default closed. `history` is
    /// the session command log, oldest first; the section shows it
    /// newest first.
    pub fn render(
        self: *TreeBuffer,
        undo: []const UndoView,
        search: SearchView,
        bufs: []const BufView,
        git: ?GitView,
        run: ?ExecView,
        history: []const []const u8,
    ) !void {
        // Prune folds for closed docs, keep the rest by id.
        var kept = std.ArrayList(UndoDocFold).empty;
        defer kept.deinit(self.gpa);
        for (undo) |u| {
            var is_open = false;
            for (self.undo_docs.items) |d| {
                if (d.id == u.id) {
                    is_open = d.open;
                    break;
                }
            }
            try kept.append(self.gpa, .{ .id = u.id, .open = is_open });
        }
        self.undo_docs.clearRetainingCapacity();
        try self.undo_docs.appendSlice(self.gpa, kept.items);

        self.clearRows();
        var texts = std.ArrayList([]u8).empty;
        defer {
            ut.freeOwnedLines(self.gpa, &texts);
            texts.deinit(self.gpa);
        }
        // Upper bound first: tree nodes hold pointers into this very
        // backing, so it must never reallocate mid-render.
        var bound: usize = 1 + 4 + bufs.len + 1;
        for (undo) |u| bound += 1 + @min(u.tree.nodeCount(), max_undo_rows);
        bound += @min(search.hits.len, max_search_rows);
        if (run) |r| bound += 1 + @min(r.hits.len, max_diag_rows);
        if (git) |g| bound += @min(g.commits.len, max_commit_rows);
        bound += 1 + @min(history.len, max_command_rows);
        var nodes = std.ArrayList(TreeNode).empty;
        defer nodes.deinit(self.gpa);
        try nodes.ensureTotalCapacity(self.gpa, bound);
        try nodes.append(self.gpa, .{ .tree = ut.UserTree.init(), .text = "tree" });

        if (self.wants(.undo)) try self.renderUndo(undo, &texts, &nodes);
        if (self.wants(.search)) try self.renderSearch(search, &texts, &nodes);
        if (self.wants(.exec)) try self.renderExec(run, &texts, &nodes);
        if (self.wants(.buffers)) try self.renderBuffers(bufs, &texts, &nodes);
        if (self.wants(.git)) try self.renderGit(git, &texts, &nodes);
        if (self.wants(.commands)) try self.renderCommands(history, &texts, &nodes);

        nodes.items[0].tree.expanded = true;
        const text = try ut.joinVisible(self.gpa, &nodes.items[0].tree, TreeNode, .{});
        defer self.gpa.free(text);
        try self.buf.replaceAll(text);
        // Headers and leaves push exactly one row each, so rows stay
        // parallel to buffer lines one to one.
        std.debug.assert(self.rows.items.len == self.buf.lineCount());
    }

    /// Single row builder replacing `addHeader` plus `addLeaf`. Headers
    /// pass a `.section` target with their fold state; leaves pass
    /// their jump target with `expanded = false`.
    fn appendRow(
        self: *TreeBuffer,
        parent: usize,
        text: []const u8,
        target: TreeTarget,
        expanded: bool,
        texts: *std.ArrayList([]u8),
        nodes: *std.ArrayList(TreeNode),
    ) !usize {
        const kept = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(kept);
        try texts.append(self.gpa, kept);
        try self.pushRow(target);
        try nodes.append(self.gpa, .{ .tree = ut.UserTree.init(), .text = kept });
        const at = nodes.items.len - 1;
        nodes.items[at].tree.expanded = expanded;
        nodes.items[parent].tree.appendChild(&nodes.items[at].tree);
        return at;
    }

    fn renderUndo(
        self: *TreeBuffer,
        undo: []const UndoView,
        texts: *std.ArrayList([]u8),
        nodes: *std.ArrayList(TreeNode),
    ) !void {
        var total: usize = 0;
        for (undo) |u| total += u.tree.nodeCount();
        const head = try std.fmt.allocPrint(self.gpa, "undo ({d} docs, {d} nodes)", .{ undo.len, total });
        defer self.gpa.free(head);
        const sec = try self.appendRow(0, head, .{ .section = @intFromEnum(Section.undo) }, self.isOpen(.undo), texts, nodes);
        if (!self.isOpen(.undo)) return;
        for (undo) |u| {
            var is_open = false;
            for (self.undo_docs.items) |d| {
                if (d.id == u.id) {
                    is_open = d.open;
                    break;
                }
            }
            const sub = try std.fmt.allocPrint(self.gpa, "  {s} ({d} nodes)", .{ u.title, u.tree.nodeCount() });
            defer self.gpa.free(sub);
            const sub_at = try self.appendRow(sec, sub, .{ .undo_doc = u.id }, is_open, texts, nodes);
            if (!is_open) continue;
            // Nested walk from the root: children render under their
            // parent, so forks across buffers and buffer types show
            // as branches. Flat index order would hide the tree shape.
            var shown: usize = 0;
            try self.renderUndoNode(u, sub_at, 0, 0, &shown, texts, nodes);
        }
    }

    /// One undo node plus its children, depth-first. Indent grows with
    /// depth so branches read as branches. Stops at `max_undo_rows`
    /// rows per doc; the tree itself stays untouched.
    fn renderUndoNode(
        self: *TreeBuffer,
        u: UndoView,
        parent_row: usize,
        idx: usize,
        depth: usize,
        shown: *usize,
        texts: *std.ArrayList([]u8),
        nodes: *std.ArrayList(TreeNode),
    ) !void {
        if (shown.* >= max_undo_rows) return;
        shown.* += 1;
        const desc = try u.tree.describe(self.gpa, idx);
        defer self.gpa.free(desc);
        const pad = try self.gpa.alloc(u8, 4 + depth * 2);
        defer self.gpa.free(pad);
        @memset(pad, ' ');
        const line = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ pad, desc });
        defer self.gpa.free(line);
        const post = u.tree.postOf(idx);
        // Interior nodes stay expanded: collapse lives one level up
        // in the section and per-doc folds, never mid-branch.
        const at = try self.appendRow(parent_row, line, .{ .doc = .{ .id = u.id, .row = post.row, .col = post.col } }, true, texts, nodes);
        const n = u.tree.nodeCount();
        var c: usize = 0;
        while (c < n) : (c += 1) {
            if (u.tree.parentOf(c)) |p| {
                if (p == @as(u32, @intCast(idx))) {
                    try self.renderUndoNode(u, at, c, depth + 1, shown, texts, nodes);
                }
            }
        }
    }

    /// Search hits: one flat section, header plus leaves. The leaves
    /// carry the same targets the search doc uses.
    fn renderSearch(
        self: *TreeBuffer,
        search: SearchView,
        texts: *std.ArrayList([]u8),
        nodes: *std.ArrayList(TreeNode),
    ) !void {
        const head = try std.fmt.allocPrint(self.gpa, "search ({d} hits): {s}", .{ search.hits.len, search.query });
        defer self.gpa.free(head);
        const sec = try self.appendRow(0, head, .{ .section = @intFromEnum(Section.search) }, self.isOpen(.search), texts, nodes);
        if (!self.isOpen(.search)) return;
        const show = @min(search.hits.len, max_search_rows);
        var k: usize = 0;
        while (k < show) : (k += 1) {
            const line = try std.fmt.allocPrint(self.gpa, "  {s}", .{search.hits[k].label});
            defer self.gpa.free(line);
            // pushRow dupes file paths, so borrowed targets are safe.
            _ = try self.appendRow(sec, line, search.hits[k].target, false, texts, nodes);
        }
    }

    /// The last run, the same `path:row:col:` rows the `*exec*` tree
    /// holds, so the diagnostics of a run are visible from the
    /// inspector. Enter on a row jumps to the file.
    fn renderExec(
        self: *TreeBuffer,
        run: ?ExecView,
        texts: *std.ArrayList([]u8),
        nodes: *std.ArrayList(TreeNode),
    ) !void {
        const r = run orelse {
            _ = try self.appendRow(0, "exec (no run yet)", .{ .section = @intFromEnum(Section.exec) }, self.isOpen(.exec), texts, nodes);
            return;
        };
        const head = if (r.exit_code) |code|
            try std.fmt.allocPrint(self.gpa, "exec: {s} (exit {d}, {d} problems)", .{ r.cmd, code, r.hits.len })
        else
            try std.fmt.allocPrint(self.gpa, "exec: {s} (running...)", .{r.cmd});
        defer self.gpa.free(head);
        const sec = try self.appendRow(0, head, .{ .section = @intFromEnum(Section.exec) }, self.isOpen(.exec), texts, nodes);
        if (!self.isOpen(.exec)) return;
        const show = @min(r.hits.len, max_diag_rows);
        var k: usize = 0;
        while (k < show) : (k += 1) {
            const line = try std.fmt.allocPrint(self.gpa, "  {s}", .{r.hits[k].label});
            defer self.gpa.free(line);
            _ = try self.appendRow(sec, line, r.hits[k].target, false, texts, nodes);
        }
    }

    /// Open buffers: header plus one row per doc, with its kind and
    /// cursor. `Enter` switches to the doc.
    fn renderBuffers(
        self: *TreeBuffer,
        bufs: []const BufView,
        texts: *std.ArrayList([]u8),
        nodes: *std.ArrayList(TreeNode),
    ) !void {
        const head = try std.fmt.allocPrint(self.gpa, "buffers ({d})", .{bufs.len});
        defer self.gpa.free(head);
        const sec = try self.appendRow(0, head, .{ .section = @intFromEnum(Section.buffers) }, self.isOpen(.buffers), texts, nodes);
        if (!self.isOpen(.buffers)) return;
        for (bufs) |b| {
            const line = try std.fmt.allocPrint(self.gpa, "  {s} [{s}]", .{ b.title, b.kind });
            defer self.gpa.free(line);
            _ = try self.appendRow(sec, line, .{ .doc = .{ .id = b.id, .row = b.row, .col = b.col } }, false, texts, nodes);
        }
    }

    /// Git: the branch, the counts, and the recent commits. Without a
    /// log the section is one row that opens the log. `Enter` on a
    /// commit row opens the log too, where its own Enter takes over.
    fn renderGit(
        self: *TreeBuffer,
        git: ?GitView,
        texts: *std.ArrayList([]u8),
        nodes: *std.ArrayList(TreeNode),
    ) !void {
        const g = git orelse {
            // Nothing to fold when no log is open: Enter opens it.
            _ = try self.appendRow(0, "git (no log open)", .git, false, texts, nodes);
            return;
        };
        const head = try std.fmt.allocPrint(self.gpa, "git: {s} <- {s} (+{d}/-{d})", .{
            g.branch,
            g.base,
            g.unstaged,
            g.staged,
        });
        defer self.gpa.free(head);
        const sec = try self.appendRow(0, head, .{ .section = @intFromEnum(Section.git) }, self.isOpen(.git), texts, nodes);
        if (!self.isOpen(.git)) return;
        const show = @min(g.commits.len, max_commit_rows);
        var k: usize = 0;
        while (k < show) : (k += 1) {
            const line = try std.fmt.allocPrint(self.gpa, "  {s} {s}", .{ g.commits[k].hash, g.commits[k].subject });
            defer self.gpa.free(line);
            _ = try self.appendRow(sec, line, .git, false, texts, nodes);
        }
    }

    /// The commands run this session, newest first, the same list the
    /// command box walks with up and down. Each row keeps its text in
    /// the buffer, so Enter can put it back in the box.
    fn renderCommands(
        self: *TreeBuffer,
        history: []const []const u8,
        texts: *std.ArrayList([]u8),
        nodes: *std.ArrayList(TreeNode),
    ) !void {
        self.clearCommands();
        const head = try std.fmt.allocPrint(self.gpa, "commands ({d})", .{history.len});
        defer self.gpa.free(head);
        const sec = try self.appendRow(0, head, .{ .section = @intFromEnum(Section.commands) }, self.isOpen(.commands), texts, nodes);
        if (!self.isOpen(.commands)) return;
        const show = @min(history.len, max_command_rows);
        var k: usize = show;
        while (k > 0) {
            k -= 1;
            const kept = try self.gpa.dupe(u8, history[k]);
            try self.commands.append(self.gpa, kept);
            const line = try std.fmt.allocPrint(self.gpa, "  :{s}", .{kept});
            defer self.gpa.free(line);
            _ = try self.appendRow(sec, line, .{ .command = self.commands.items.len - 1 }, false, texts, nodes);
        }
    }
};

test "trees buffer renders sections with folds" {
    const gpa = std.testing.allocator;
    const utree = @import("lib").undotree;
    var utr = utree.UndoTree{};
    defer utr.deinit(gpa);
    try utr.pushInsert(gpa, 0, "hi", .{ .row = 0, .col = 0 }, .{ .row = 0, .col = 2 });
    var tb = try TreeBuffer.open(gpa, "*tree");
    defer tb.close();
    try std.testing.expect(tb.buf.hl_mode == .trees);
    const undo = [_]UndoView{.{ .id = 1, .title = "a.txt", .tree = &utr }};
    const hits = [_]SearchHit{};
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &.{});
    var line_buf: [256]u8 = undefined;
    // All sections start folded: 6 headers, undo first.
    try std.testing.expectEqual(@as(u64, 6), tb.buf.lineCount());
    try std.testing.expectEqualStrings("undo (1 docs, 2 nodes)", try tb.buf.line(0, &line_buf));
    try std.testing.expectEqual(tb.rows.items.len, tb.buf.lineCount());
    // Headers fold via toggle (null asks the caller to re-render).
    try std.testing.expect(tb.targetAtRow(0).? == .section);
    try std.testing.expect(tb.toggle(0) == null);
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &.{});
    // Undo section opened, but per-doc folds start closed: header,
    // one doc row, then the 5 other section headers.
    try std.testing.expectEqual(@as(u64, 7), tb.buf.lineCount());
    try std.testing.expectEqualStrings("  a.txt (2 nodes)", try tb.buf.line(1, &line_buf));
    try std.testing.expectEqual(tb.rows.items.len, tb.buf.lineCount());
}

test "undo renders forks as nested branches" {
    const gpa = std.testing.allocator;
    const utree = @import("lib").undotree;
    var utr = utree.UndoTree{};
    defer utr.deinit(gpa);
    const pre = utree.Cursor{ .row = 0, .col = 0 };
    try utr.pushInsert(gpa, 0, "ab", pre, .{ .row = 0, .col = 2 });
    _ = utr.undoTarget();
    utr.commitUndo();
    try utr.pushInsert(gpa, 0, "c", pre, .{ .row = 0, .col = 1 });
    // Root plus two children: a fork, not a line.
    try std.testing.expectEqual(@as(usize, 3), utr.nodeCount());
    var tb = try TreeBuffer.open(gpa, "*tree");
    defer tb.close();
    const undo = [_]UndoView{.{ .id = 1, .title = "a.txt", .tree = &utr }};
    const hits = [_]SearchHit{};
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &.{});
    // Sections and docs start folded: open both, then re-render.
    try std.testing.expect(tb.toggle(0) == null);
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &.{});
    try std.testing.expect(tb.toggle(1) == null);
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &.{});
    var line_buf: [256]u8 = undefined;
    // Header, doc, root, two depth-1 branches, then 5 headers.
    try std.testing.expectEqual(@as(u64, 10), tb.buf.lineCount());
    try std.testing.expect(std.mem.startsWith(
        u8,
        try tb.buf.line(2, &line_buf),
        "    #0 root",
    ));
    try std.testing.expect(std.mem.startsWith(
        u8,
        try tb.buf.line(3, &line_buf),
        "      #",
    ));
    try std.testing.expect(std.mem.startsWith(
        u8,
        try tb.buf.line(4, &line_buf),
        "      #",
    ));
    try std.testing.expectEqual(tb.rows.items.len, tb.buf.lineCount());
    // Branch leaves jump back into the doc.
    try std.testing.expect(tb.targetAtRow(3).? == .doc);
}

test "git rows open the log" {
    const gpa = std.testing.allocator;
    var tb = try TreeBuffer.open(gpa, "*tree");
    defer tb.close();
    const undo = [_]UndoView{};
    const hits = [_]SearchHit{};
    // No log open: one row, and it opens the log.
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &.{});
    try std.testing.expectEqual(@as(u64, 6), tb.buf.lineCount());
    try std.testing.expect(tb.targetAtRow(4).? == .git);
    // Log open with commits: unfold the git section, commit rows open it.
    const commits = [_]CommitView{.{ .hash = "abc1234", .subject = "first" }};
    const git = GitView{
        .branch = "main",
        .base = "origin/main",
        .unstaged = 1,
        .staged = 0,
        .commits = &commits,
    };
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, git, null, &.{});
    try std.testing.expect(tb.toggle(4) == null);
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, git, null, &.{});
    try std.testing.expectEqual(@as(u64, 7), tb.buf.lineCount());
    try std.testing.expect(tb.targetAtRow(5).? == .git);
    try std.testing.expectEqual(tb.rows.items.len, tb.buf.lineCount());
}

test "lone tree header opens its first leaf" {
    const gpa = std.testing.allocator;
    var tb = try TreeBuffer.open(gpa, "*trees exec*");
    defer tb.close();
    tb.single = .exec;
    const undo = [_]UndoView{};
    const hits = [_]SearchHit{};
    const run = [_]SearchHit{.{
        .label = "a.txt:2:3: boom",
        .target = .{ .hit = .{ .path = "a.txt", .row = 1, .col = 2 } },
    }};
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, .{
        .cmd = "printf x",
        .exit_code = 1,
        .hits = &run,
    }, &.{});
    // Row 0 is the header of the only section, and Enter on it opens
    // the first leaf: there is nothing to fold.
    try std.testing.expect(tb.targetAtRow(0).? == .section);
    const t = tb.toggle(0).?;
    try std.testing.expect(t == .hit);
    try std.testing.expectEqualStrings("a.txt", t.hit.path);
    try std.testing.expectEqual(@as(u64, 1), t.hit.row);
}

test "commands section lists the session history newest first" {
    const gpa = std.testing.allocator;
    var tb = try TreeBuffer.open(gpa, "*tree");
    defer tb.close();
    const undo = [_]UndoView{};
    const hits = [_]SearchHit{};
    // Oldest first, as the command box stores it.
    const history = [_][]const u8{ "fs src", "exec-save zig build" };
    // Folded by default: the last row is the section header.
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &history);
    const head: u64 = 5;
    try std.testing.expectEqualStrings("commands (2)", try tb.buf.line(head, &line_scratch));
    try std.testing.expect(tb.targetAtRow(head).? == .section);
    // Unfolding gives one row per entry, newest first, and each row
    // hands its own text back for the command box.
    try std.testing.expect(tb.toggle(head) == null);
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &history);
    try std.testing.expectEqual(head + 1 + history.len, tb.buf.lineCount());
    try std.testing.expectEqualStrings("  :exec-save zig build", try tb.buf.line(head + 1, &line_scratch));
    try std.testing.expectEqualStrings("  :fs src", try tb.buf.line(head + 2, &line_scratch));
    const t = tb.targetAtRow(head + 1).?;
    try std.testing.expect(t == .command);
    try std.testing.expectEqualStrings("exec-save zig build", tb.commandAt(t.command).?);
    try std.testing.expect(tb.commandAt(history.len) == null);
    // A re-render replaces the copy instead of appending to it.
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &history);
    try std.testing.expectEqual(@as(usize, 2), tb.commands.items.len);
    try std.testing.expectEqual(tb.rows.items.len, tb.buf.lineCount());
}

test "empty history still shows the section header" {
    const gpa = std.testing.allocator;
    var tb = try TreeBuffer.open(gpa, "*tree");
    defer tb.close();
    const undo = [_]UndoView{};
    const hits = [_]SearchHit{};
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &.{});
    try std.testing.expectEqual(@as(u64, 6), tb.buf.lineCount());
    try std.testing.expectEqualStrings("exec (no run yet)", try tb.buf.line(2, &line_scratch));
    try std.testing.expectEqualStrings("commands (0)", try tb.buf.line(5, &line_scratch));
    try std.testing.expect(tb.toggle(5) == null);
    try tb.render(&undo, .{ .query = "q", .hits = &hits }, &.{}, null, null, &.{});
    try std.testing.expectEqual(@as(u64, 6), tb.buf.lineCount());
    try std.testing.expectEqual(@as(usize, 0), tb.commands.items.len);
}

var line_scratch: [256]u8 = undefined;
