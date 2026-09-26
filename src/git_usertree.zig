//! Git user tree. The `lib` primitive owns hierarchy and
//! flattening. This module owns the git meaning: branch plus base,
//! folded unstaged and staged sections, and a readonly log of the
//! current branch, plus thin wrappers for add, commit, push, pull,
//! switch, and branch.
//!
//! Layout is one branch line, one base line, two status headers, then
//! one line per commit. Enter on a status header folds or unfolds its
//! `git diff --stat` lines. Enter on a commit folds or unfolds one
//! author line plus `git show --stat` lines. Enter on a stat file line
//! does not fold: main opens that file's diff as a scratch buffer.
//! The buffer is readonly. Edits are discarded on refresh.
//! All mutations run through `:gadd` etc, never through typing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ut = @import("lib").usertrees;
const highlight = @import("lib").highlight;
const Buffer = @import("buffer.zig").Buffer;

/// Tree node used transiently while rendering.
pub const GitNode = ut.TextNode;

/// One commit. All fields are owned, hash has no trailing newline.
pub const Commit = struct {
    hash: []u8,
    author: []u8,
    date: []u8,
    subject: []u8,

    pub fn free(self: *Commit, gpa: Allocator) void {
        gpa.free(self.hash);
        gpa.free(self.author);
        gpa.free(self.date);
        gpa.free(self.subject);
        self.* = undefined;
    }
};

/// Borrowed commit fields for building a buffer.
pub const CommitInit = struct {
    hash: []const u8,
    author: []const u8,
    date: []const u8,
    subject: []const u8,
};

const max_stat_lines: usize = 100;
const title_text = "*git*";

fn headerAlloc(gpa: Allocator, c: *const Commit) ![]u8 {
    const short = c.hash[0..@min(c.hash.len, 7)];
    if (c.subject.len == 0) return try gpa.dupe(u8, short);
    return try std.fmt.allocPrint(gpa, "{s} {s}", .{ short, c.subject });
}

fn authorLineAlloc(gpa: Allocator, c: *const Commit) ![]u8 {
    return try std.fmt.allocPrint(gpa, "  {s} | {s}", .{ c.author, c.date });
}

/// Split `git log` output into owned commits. The log must use
/// `%H%x00%an%x00%ad%x00%s%x1e` so NUL separates fields and RS
/// separates records. Corrupt records are skipped.
pub fn parseLogAlloc(gpa: Allocator, raw: []const u8) !std.ArrayList(Commit) {
    var out = std.ArrayList(Commit).empty;
    errdefer {
        for (out.items) |*c| c.free(gpa);
        out.deinit(gpa);
    }
    var recs = std.mem.splitScalar(u8, raw, 0x1e);
    while (recs.next()) |rec| {
        const t = std.mem.trim(u8, rec, "\r\n");
        if (t.len == 0) continue;
        var fields = std.mem.splitScalar(u8, t, 0x00);
        const hash = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const date = fields.next() orelse continue;
        const subject = fields.next() orelse continue;
        if (hash.len == 0) continue;
        try out.append(gpa, .{
            .hash = try gpa.dupe(u8, hash),
            .author = try gpa.dupe(u8, author),
            .date = try gpa.dupe(u8, date),
            .subject = try gpa.dupe(u8, subject),
        });
    }
    return out;
}

/// Split `git show --stat` output into owned lines. Caps the count so
/// one huge commit cannot flood the buffer.
pub fn parseStatAlloc(gpa: Allocator, raw: []const u8) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |l| {
        if (out.items.len >= max_stat_lines) break;
        const t = std.mem.trimEnd(u8, l, "\r");
        if (t.len == 0) continue;
        try out.append(gpa, try gpa.dupe(u8, t));
    }
    return out;
}

fn runChecked(gpa: Allocator, io: std.Io, argv: []const []const u8) !void {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return error.GitFailed;
}

fn runOutput(gpa: Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(res.stderr);
    errdefer gpa.free(res.stdout);
    if (res.term != .exited or res.term.exited != 0) {
        gpa.free(res.stdout);
        return error.GitFailed;
    }
    return res.stdout;
}

pub fn currentBranchAlloc(gpa: Allocator, io: std.Io) ![]u8 {
    const out = try runOutput(gpa, io, &.{ "git", "branch", "--show-current" });
    defer gpa.free(out);
    const t = std.mem.trim(u8, out, " \t\r\n");
    if (t.len == 0) return try gpa.dupe(u8, "HEAD");
    return try gpa.dupe(u8, t);
}

pub fn logAlloc(gpa: Allocator, io: std.Io) !std.ArrayList(Commit) {
    const out = try runOutput(gpa, io, &.{
        "git", "log", "--format=%H%x00%an%x00%ad%x00%s%x1e", "--date=short",
    });
    defer gpa.free(out);
    return try parseLogAlloc(gpa, out);
}

pub fn showStatAlloc(gpa: Allocator, io: std.Io, hash: []const u8) !std.ArrayList([]u8) {
    const out = try runOutput(gpa, io, &.{
        "git", "show", "--stat", "--format=-- %s", hash,
    });
    defer gpa.free(out);
    return try parseStatAlloc(gpa, out);
}

/// Upstream tracking branch (`origin/main`), or error when none is set.
/// Callers fall back to `(none)`.
pub fn baseBranchAlloc(gpa: Allocator, io: std.Io) ![]u8 {
    const out = try runOutput(gpa, io, &.{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" });
    defer gpa.free(out);
    const t = std.mem.trim(u8, out, " \t\r\n");
    if (t.len == 0) return error.GitFailed;
    return try gpa.dupe(u8, t);
}

/// `git diff --stat` lines for the worktree (`cached` selects staged).
pub fn diffStatAlloc(gpa: Allocator, io: std.Io, cached: bool) !std.ArrayList([]u8) {
    const out = if (cached)
        try runOutput(gpa, io, &.{ "git", "diff", "--stat", "--cached" })
    else
        try runOutput(gpa, io, &.{ "git", "diff", "--stat" });
    defer gpa.free(out);
    return try parseStatAlloc(gpa, out);
}

/// Full diff of `file` at `hash` for the enter-to-diff buffer.
pub fn showCommitFileAlloc(gpa: Allocator, io: std.Io, hash: []const u8, file: []const u8) ![]u8 {
    return try runOutput(gpa, io, &.{ "git", "show", hash, "--", file });
}

/// Worktree diff of `file` for the enter-to-diff buffer.
pub fn diffWorktreeFileAlloc(gpa: Allocator, io: std.Io, cached: bool, file: []const u8) ![]u8 {
    if (cached) return try runOutput(gpa, io, &.{ "git", "diff", "--cached", "--", file });
    return try runOutput(gpa, io, &.{ "git", "diff", "--", file });
}

pub fn add(gpa: Allocator, io: std.Io, paths: []const []const u8) !void {
    if (paths.len == 0) {
        return try runChecked(gpa, io, &.{ "git", "add", "-A" });
    }
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "add", "--" });
    try argv.appendSlice(gpa, paths);
    return try runChecked(gpa, io, argv.items);
}

pub fn commit(gpa: Allocator, io: std.Io, msg: []const u8) !void {
    const t = std.mem.trim(u8, msg, " \t");
    if (t.len == 0) return error.BadArg;
    return try runChecked(gpa, io, &.{ "git", "commit", "-m", t });
}

pub fn push(gpa: Allocator, io: std.Io) !void {
    return try runChecked(gpa, io, &.{ "git", "push" });
}

pub fn pull(gpa: Allocator, io: std.Io) !void {
    return try runChecked(gpa, io, &.{ "git", "pull" });
}

pub fn switchBranch(gpa: Allocator, io: std.Io, name: []const u8) !void {
    return runSwitch(gpa, io, name, false);
}

pub fn createBranch(gpa: Allocator, io: std.Io, name: []const u8) !void {
    return runSwitch(gpa, io, name, true);
}

fn runSwitch(gpa: Allocator, io: std.Io, name: []const u8, create: bool) !void {
    const t = std.mem.trim(u8, name, " \t");
    if (t.len == 0) return error.BadArg;
    if (create) return runChecked(gpa, io, &.{ "git", "switch", "-c", t });
    return runChecked(gpa, io, &.{ "git", "switch", t });
}

/// Readonly branch, status, and log view.
pub const GitBuffer = struct {
    gpa: Allocator,
    buf: Buffer,
    /// Owned title. `buf.path` points here.
    title: []u8,
    branch: []u8,
    /// Owned upstream name, or `(none)`.
    base: []u8,
    /// Owned `git diff --stat` lines, folded under their headers.
    unstaged: std.ArrayList([]u8) = .empty,
    unstaged_open: bool = false,
    staged: std.ArrayList([]u8) = .empty,
    staged_open: bool = false,
    commits: std.ArrayList(Commit) = .empty,
    expanded: std.ArrayList(bool) = .empty,
    /// Owned detail lines per commit. Line zero is always the
    /// author line. Stat lines follow once loaded.
    details: std.ArrayList(std.ArrayList([]u8)) = .empty,
    stat_loaded: std.ArrayList(bool) = .empty,

    pub fn openWith(
        gpa: Allocator,
        title: []const u8,
        branch: []const u8,
        base: []const u8,
        inits: []const CommitInit,
    ) !GitBuffer {
        var self = GitBuffer{
            .gpa = gpa,
            .buf = undefined,
            .title = &.{},
            .branch = &.{},
            .base = &.{},
        };
        errdefer self.close();
        self.title = try gpa.dupe(u8, title);
        errdefer gpa.free(self.title);
        self.branch = try gpa.dupe(u8, branch);
        errdefer gpa.free(self.branch);
        self.base = try gpa.dupe(u8, base);
        errdefer gpa.free(self.base);
        for (inits) |in| {
            try self.appendCommitBorrowed(in);
        }
        const text = try self.renderLocked();
        errdefer gpa.free(text);
        self.buf = try Buffer.initOwned(gpa, self.title, text);
        self.buf.hl_mode = .gitlog;
        return self;
    }

    pub fn openLive(gpa: Allocator, io: std.Io) !GitBuffer {
        const branch = try currentBranchAlloc(gpa, io);
        defer gpa.free(branch);
        const base = baseBranchAlloc(gpa, io) catch try gpa.dupe(u8, "(none)");
        defer gpa.free(base);
        var list = try logAlloc(gpa, io);
        defer {
            for (list.items) |*c| c.free(gpa);
            list.deinit(gpa);
        }
        var inits = std.ArrayList(CommitInit).empty;
        defer inits.deinit(gpa);
        for (list.items) |*c| {
            try inits.append(gpa, .{
                .hash = c.hash,
                .author = c.author,
                .date = c.date,
                .subject = c.subject,
            });
        }
        var gb = try GitBuffer.openWith(gpa, title_text, branch, base, inits.items);
        errdefer gb.close();
        var un = try diffStatAlloc(gpa, io, false);
        defer un.deinit(gpa);
        try gb.adoptSectionLines(.unstaged, &un);
        var st = try diffStatAlloc(gpa, io, true);
        defer st.deinit(gpa);
        try gb.adoptSectionLines(.staged, &st);
        const text = try gb.renderLocked();
        defer gpa.free(text);
        try gb.buf.replaceAll(text);
        return gb;
    }

    pub fn close(self: *GitBuffer) void {
        self.buf.close();
        for (self.commits.items) |*c| c.free(self.gpa);
        self.commits.deinit(self.gpa);
        self.expanded.deinit(self.gpa);
        self.stat_loaded.deinit(self.gpa);
        for (self.details.items) |*d| {
            for (d.items) |s| self.gpa.free(s);
            d.deinit(self.gpa);
        }
        self.details.deinit(self.gpa);
        ut.freeOwnedLines(self.gpa, &self.unstaged);
        self.unstaged.deinit(self.gpa);
        ut.freeOwnedLines(self.gpa, &self.staged);
        self.staged.deinit(self.gpa);
        if (self.title.len > 0) self.gpa.free(self.title);
        if (self.branch.len > 0) self.gpa.free(self.branch);
        if (self.base.len > 0) self.gpa.free(self.base);
        self.* = undefined;
    }

    /// Reload base, status, branch, and log from git. Drops expansions.
    pub fn refreshLive(self: *GitBuffer, io: std.Io) !void {
        const branch = try currentBranchAlloc(self.gpa, io);
        defer self.gpa.free(branch);
        const base = baseBranchAlloc(self.gpa, io) catch try self.gpa.dupe(u8, "(none)");
        defer self.gpa.free(base);
        var list = try logAlloc(self.gpa, io);
        defer {
            for (list.items) |*c| c.free(self.gpa);
            list.deinit(self.gpa);
        }
        var un = try diffStatAlloc(self.gpa, io, false);
        defer un.deinit(self.gpa);
        var st = try diffStatAlloc(self.gpa, io, true);
        defer st.deinit(self.gpa);
        for (self.commits.items) |*c| c.free(self.gpa);
        self.commits.clearRetainingCapacity();
        self.expanded.clearRetainingCapacity();
        self.stat_loaded.clearRetainingCapacity();
        for (self.details.items) |*d| {
            for (d.items) |s| self.gpa.free(s);
            d.deinit(self.gpa);
        }
        self.details.clearRetainingCapacity();
        try self.adoptSectionLines(.unstaged, &un);
        try self.adoptSectionLines(.staged, &st);
        self.unstaged_open = false;
        self.staged_open = false;
        self.gpa.free(self.branch);
        self.branch = try self.gpa.dupe(u8, branch);
        self.gpa.free(self.base);
        self.base = try self.gpa.dupe(u8, base);
        for (list.items) |*c| {
            try self.appendCommitBorrowed(.{
                .hash = c.hash,
                .author = c.author,
                .date = c.date,
                .subject = c.subject,
            });
        }
        const text = try self.renderLocked();
        defer self.gpa.free(text);
        try self.buf.replaceAll(text);
    }

    pub const Section = enum { unstaged, staged };

    const SectionView = struct { lines: *std.ArrayList([]u8), open: *bool };
    const SectionViewConst = struct { lines: *const std.ArrayList([]u8), open: *const bool };

    fn section(self: *GitBuffer, which: Section) SectionView {
        return if (which == .unstaged)
            .{ .lines = &self.unstaged, .open = &self.unstaged_open }
        else
            .{ .lines = &self.staged, .open = &self.staged_open };
    }

    fn sectionConst(self: *const GitBuffer, which: Section) SectionViewConst {
        return if (which == .unstaged)
            .{ .lines = &self.unstaged, .open = &self.unstaged_open }
        else
            .{ .lines = &self.staged, .open = &self.staged_open };
    }

    /// Append one borrowed commit plus its author detail line. Shared by
    /// `openWith` and `refreshLive` so the adopt loop lives in one place.
    fn appendCommitBorrowed(self: *GitBuffer, init: CommitInit) !void {
        const gpa = self.gpa;
        try self.commits.append(gpa, .{
            .hash = try gpa.dupe(u8, init.hash),
            .author = try gpa.dupe(u8, init.author),
            .date = try gpa.dupe(u8, init.date),
            .subject = try gpa.dupe(u8, init.subject),
        });
        errdefer {
            var c = self.commits.pop().?;
            c.free(gpa);
        }
        try self.expanded.append(gpa, false);
        errdefer _ = self.expanded.pop();
        try self.stat_loaded.append(gpa, false);
        errdefer _ = self.stat_loaded.pop();
        var d = std.ArrayList([]u8).empty;
        errdefer d.deinit(gpa);
        const aline = try authorLineAlloc(gpa, &self.commits.items[self.commits.items.len - 1]);
        try d.append(gpa, aline);
        try self.details.append(gpa, d);
    }

    /// Take ownership of every line in `owned`, leaving it empty.
    /// Replaces any previous section content.
    pub fn adoptSectionLines(self: *GitBuffer, which: Section, owned: *std.ArrayList([]u8)) !void {
        const dst = self.section(which).lines;
        ut.freeOwnedLines(self.gpa, dst);
        try dst.appendSlice(self.gpa, owned.items);
        owned.clearRetainingCapacity();
    }

    /// One visible row. Status and commit detail rows carry their
    /// parent so enter knows what to fold or open.
    pub const Row = union(enum) {
        branch,
        base,
        status_head: Section,
        status_line: struct { section: Section, idx: usize },
        commit: usize,
        commit_detail: struct { idx: usize, sub: usize },
    };

    /// Map a visible row. Row zero is the branch line, row one the base.
    pub fn locate(self: *const GitBuffer, row: u64) ?Row {
        var cur: u64 = 0;
        if (row == cur) return .branch;
        cur += 1;
        if (row == cur) return .base;
        cur += 1;
        for ([_]Section{ .unstaged, .staged }) |sec| {
            if (row == cur) return .{ .status_head = sec };
            cur += 1;
            const view = self.sectionConst(sec);
            if (view.open.*) {
                const n: u64 = @intCast(view.lines.items.len);
                if (row < cur + n) return .{ .status_line = .{ .section = sec, .idx = @intCast(row - cur) } };
                cur += n;
            }
        }
        for (self.commits.items, 0..) |_, i| {
            if (row == cur) return .{ .commit = i };
            cur += 1;
            if (self.expanded.items[i]) {
                const n: u64 = @intCast(self.details.items[i].items.len);
                if (row < cur + n) return .{ .commit_detail = .{ .idx = i, .sub = @intCast(row - cur) } };
                cur += n;
            }
        }
        return null;
    }

    /// Where enter on a file line should go. Borrowed hash and file:
    /// the caller dupes before running git. Null for headers, the
    /// branch and base lines, and non-file detail rows.
    pub const DiffKind = enum { unstaged, staged, commit };

    pub const DiffTarget = struct {
        kind: DiffKind,
        hash: []const u8,
        file: []const u8,
    };

    pub fn diffTargetAtRow(self: *GitBuffer, row: u64, line_buf: []u8) ?DiffTarget {
        const found = self.locate(row) orelse return null;
        switch (found) {
            .status_line => |s| {
                const line = self.buf.line(row, line_buf) catch return null;
                const file = highlight.statFileName(line) orelse return null;
                return .{
                    .kind = if (s.section == .unstaged) .unstaged else .staged,
                    .hash = "",
                    .file = file,
                };
            },
            .commit_detail => |d| {
                const line = self.buf.line(row, line_buf) catch return null;
                const file = highlight.statFileName(line) orelse return null;
                return .{
                    .kind = .commit,
                    .hash = self.commits.items[d.idx].hash,
                    .file = file,
                };
            },
            else => return null,
        }
    }

    /// Flip a header at `row`: status sections and commits fold or
    /// unfold, detail rows collapse their parent. Branch, base, and
    /// file lines are no-ops; main opens diffs for the latter.
    pub fn toggleLocal(self: *GitBuffer, row: u64) !void {
        const found = self.locate(row) orelse return;
        switch (found) {
            .branch, .base => return,
            .status_head => |sec| self.section(sec).open.* = !self.section(sec).open.*,
            .status_line => return,
            .commit => |i| self.expanded.items[i] = !self.expanded.items[i],
            .commit_detail => |d| self.expanded.items[d.idx] = false,
        }
        const text = try self.renderLocked();
        defer self.gpa.free(text);
        try self.buf.replaceAll(text);
    }

    /// Toggle with lazy `git show --stat` load on first commit expand.
    /// Status sections load eagerly at open and refresh.
    pub fn toggleLive(self: *GitBuffer, io: std.Io, row: u64) !void {
        const found = self.locate(row) orelse return;
        if (found == .commit) {
            const i = found.commit;
            if (!self.expanded.items[i] and !self.stat_loaded.items[i]) {
                const hash = try self.gpa.dupe(u8, self.commits.items[i].hash);
                defer self.gpa.free(hash);
                if (showStatAlloc(self.gpa, io, hash)) |s| {
                    // Ownership transfers line by line: the loader list
                    // only ever holds not-yet-adopted lines, so a close
                    // mid-toggle cannot leak either side.
                    var owned: std.ArrayList([]u8) = s;
                    defer owned.deinit(self.gpa);
                    var k: usize = 0;
                    errdefer ut.freeOwnedLines(self.gpa, owned.items[k..]);
                    while (k < owned.items.len) : (k += 1) {
                        try self.details.items[i].append(self.gpa, owned.items[k]);
                    }
                    owned.clearRetainingCapacity();
                    self.stat_loaded.items[i] = true;
                } else |_| {}
            }
        }
        try self.toggleLocal(row);
    }

    /// Replace stat lines for tests and seeding.
    pub fn setStatLines(self: *GitBuffer, idx: usize, lines: []const []const u8) !void {
        var d = &self.details.items[idx];
        while (d.items.len > 1) {
            const s = d.pop().?;
            self.gpa.free(s);
        }
        for (lines) |l| {
            try d.append(self.gpa, try self.gpa.dupe(u8, l));
        }
        self.stat_loaded.items[idx] = true;
    }

    /// Replace status lines for tests and seeding.
    pub fn setSectionLines(self: *GitBuffer, which: Section, lines: []const []const u8) !void {
        const dst = self.section(which).lines;
        ut.freeOwnedLines(self.gpa, dst);
        for (lines) |l| {
            try dst.append(self.gpa, try self.gpa.dupe(u8, l));
        }
    }

    fn renderLocked(self: *GitBuffer) ![]u8 {
        const gpa = self.gpa;
        var detail_total: usize = 0;
        if (self.unstaged_open) detail_total += self.unstaged.items.len;
        if (self.staged_open) detail_total += self.staged.items.len;
        for (self.commits.items, 0..) |_, i| {
            if (self.expanded.items[i]) detail_total += self.details.items[i].items.len;
        }
        const branch_line = try std.fmt.allocPrint(gpa, "branch {s}", .{self.branch});
        defer gpa.free(branch_line);
        const base_line = try std.fmt.allocPrint(gpa, "base {s}", .{self.base});
        defer gpa.free(base_line);
        const unstaged_head = try std.fmt.allocPrint(gpa, "unstaged ({d})", .{self.unstaged.items.len});
        defer gpa.free(unstaged_head);
        const staged_head = try std.fmt.allocPrint(gpa, "staged ({d})", .{self.staged.items.len});
        defer gpa.free(staged_head);

        var headers = std.ArrayList([]u8).empty;
        defer {
            ut.freeOwnedLines(gpa, &headers);
            headers.deinit(gpa);
        }
        if (self.commits.items.len == 0) {
            try headers.append(gpa, try gpa.dupe(u8, "(empty)"));
        } else {
            for (self.commits.items) |*c| {
                try headers.append(gpa, try headerAlloc(gpa, c));
            }
        }

        // branch, base, two status headers, commit headers, details.
        const total = 4 + headers.items.len + detail_total;
        const nodes = try gpa.alloc(GitNode, total);
        defer gpa.free(nodes);
        nodes[0] = .{ .tree = ut.UserTree.init(), .text = branch_line };
        var ni: usize = 1;
        const fixed = [_]struct { text: []const u8, open: bool, lines: []const []u8 }{
            .{ .text = base_line, .open = false, .lines = &.{} },
            .{ .text = unstaged_head, .open = self.unstaged_open, .lines = self.unstaged.items },
            .{ .text = staged_head, .open = self.staged_open, .lines = self.staged.items },
        };
        for (fixed) |f| {
            nodes[ni] = .{ .tree = ut.UserTree.init(), .text = f.text };
            nodes[0].tree.appendChild(&nodes[ni].tree);
            const head = ni;
            nodes[head].tree.expanded = f.open;
            ni += 1;
            if (f.open) {
                for (f.lines) |line| {
                    nodes[ni] = .{ .tree = ut.UserTree.init(), .text = line };
                    nodes[head].tree.appendChild(&nodes[ni].tree);
                    ni += 1;
                }
            }
        }
        for (headers.items, 0..) |h, i| {
            nodes[ni] = .{ .tree = ut.UserTree.init(), .text = h };
            nodes[0].tree.appendChild(&nodes[ni].tree);
            const commit_node = ni;
            if (i < self.expanded.items.len) {
                nodes[commit_node].tree.expanded = self.expanded.items[i];
            } else {
                nodes[commit_node].tree.expanded = false;
            }
            ni += 1;
            if (i < self.commits.items.len and self.expanded.items[i]) {
                for (self.details.items[i].items) |line| {
                    nodes[ni] = .{ .tree = ut.UserTree.init(), .text = line };
                    nodes[commit_node].tree.appendChild(&nodes[ni].tree);
                    ni += 1;
                }
            }
        }
        nodes[0].tree.expanded = true;

        return ut.joinVisible(gpa, &nodes[0].tree, GitNode, .{ .skip_root = false });
    }
};

test "parse log splits NUL fields and RS records" {
    const gpa = std.testing.allocator;
    const raw = "abc1234\x00Ada\x002026-01-02\x00first subj\x1e" ++
        "def5678\x00Bo\x002026-01-03\x00second\x1e";
    var list = try parseLogAlloc(gpa, raw);
    defer {
        for (list.items) |*c| c.free(gpa);
        list.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("abc1234", list.items[0].hash);
    try std.testing.expectEqualStrings("Ada", list.items[0].author);
    try std.testing.expectEqualStrings("first subj", list.items[0].subject);
}

test "git view renders branch base status and short hashes" {
    const gpa = std.testing.allocator;
    const inits = [_]CommitInit{
        .{ .hash = "abc1234567", .author = "Ada", .date = "2026-01-02", .subject = "first" },
        .{ .hash = "def5678", .author = "Bo", .date = "2026-01-03", .subject = "second" },
    };
    var gb = try GitBuffer.openWith(gpa, title_text, "main", "origin/main", &inits);
    defer gb.close();
    try std.testing.expectEqual(@as(u64, 6), gb.buf.lineCount());
    var tmp: [128]u8 = undefined;
    try std.testing.expectEqualStrings("branch main", try gb.buf.line(0, &tmp));
    try std.testing.expectEqualStrings("base origin/main", try gb.buf.line(1, &tmp));
    try std.testing.expectEqualStrings("unstaged (0)", try gb.buf.line(2, &tmp));
    try std.testing.expectEqualStrings("staged (0)", try gb.buf.line(3, &tmp));
    try std.testing.expectEqualStrings("abc1234 first", try gb.buf.line(4, &tmp));
    try std.testing.expectEqualStrings("def5678 second", try gb.buf.line(5, &tmp));
}

test "git toggle expands author plus stat lines" {
    const gpa = std.testing.allocator;
    const inits = [_]CommitInit{
        .{ .hash = "abc1234", .author = "Ada", .date = "2026-01-02", .subject = "first" },
    };
    var gb = try GitBuffer.openWith(gpa, title_text, "main", "(none)", &inits);
    defer gb.close();
    try std.testing.expect(gb.buf.hl_mode == .gitlog);
    try gb.setStatLines(0, &.{" file.zig | 3 ++-"});
    try gb.toggleLocal(4);
    var tmp: [128]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 7), gb.buf.lineCount());
    try std.testing.expectEqualStrings("  Ada | 2026-01-02", try gb.buf.line(5, &tmp));
    try std.testing.expectEqualStrings(" file.zig | 3 ++-", try gb.buf.line(6, &tmp));
    try gb.toggleLocal(6);
    try std.testing.expectEqual(@as(u64, 5), gb.buf.lineCount());
}

test "git status sections fold and count their lines" {
    const gpa = std.testing.allocator;
    const inits = [_]CommitInit{
        .{ .hash = "abc1234", .author = "Ada", .date = "2026-01-02", .subject = "first" },
    };
    var gb = try GitBuffer.openWith(gpa, title_text, "main", "(none)", &inits);
    defer gb.close();
    try gb.setSectionLines(.unstaged, &.{" a.zig | 2 ++"});
    try gb.setSectionLines(.staged, &.{ " b.zig | 1 +", " c.zig | 1 -" });
    // Headers count before expanding; counts refresh on render.
    try gb.toggleLocal(2);
    var tmp: [128]u8 = undefined;
    try std.testing.expectEqualStrings("unstaged (1)", try gb.buf.line(2, &tmp));
    try std.testing.expectEqualStrings(" a.zig | 2 ++", try gb.buf.line(3, &tmp));
    try std.testing.expectEqualStrings("staged (2)", try gb.buf.line(4, &tmp));
    try gb.toggleLocal(4);
    try std.testing.expectEqualStrings(" b.zig | 1 +", try gb.buf.line(5, &tmp));
    try std.testing.expectEqualStrings(" c.zig | 1 -", try gb.buf.line(6, &tmp));
    try std.testing.expectEqualStrings("abc1234 first", try gb.buf.line(7, &tmp));
    // Collapsing the section header hides its lines again.
    try gb.toggleLocal(2);
    try std.testing.expectEqualStrings("staged (2)", try gb.buf.line(3, &tmp));
}

test "git locate maps every row kind" {
    const gpa = std.testing.allocator;
    const inits = [_]CommitInit{
        .{ .hash = "abc1234", .author = "Ada", .date = "2026-01-02", .subject = "first" },
    };
    var gb = try GitBuffer.openWith(gpa, title_text, "main", "(none)", &inits);
    defer gb.close();
    try std.testing.expect(gb.locate(0).? == .branch);
    try std.testing.expect(gb.locate(1).? == .base);
    try std.testing.expect(gb.locate(2).?.status_head == .unstaged);
    try std.testing.expect(gb.locate(3).?.status_head == .staged);
    try std.testing.expectEqual(@as(usize, 0), gb.locate(4).?.commit);
    try std.testing.expect(gb.locate(5) == null);
}

test "git enter targets resolve file lines only" {
    const gpa = std.testing.allocator;
    const inits = [_]CommitInit{
        .{ .hash = "abc1234", .author = "Ada", .date = "2026-01-02", .subject = "first" },
    };
    var gb = try GitBuffer.openWith(gpa, title_text, "main", "(none)", &inits);
    defer gb.close();
    try gb.setSectionLines(.unstaged, &.{" a.zig | 2 ++"});
    try gb.setStatLines(0, &.{" file.zig | 3 ++-"});
    try gb.toggleLocal(2);
    try gb.toggleLocal(5);
    var line_buf: [4096]u8 = undefined;
    const un = gb.diffTargetAtRow(3, &line_buf).?;
    try std.testing.expect(un.kind == .unstaged);
    try std.testing.expectEqualStrings("a.zig", un.file);
    const cm = gb.diffTargetAtRow(7, &line_buf).?;
    try std.testing.expect(cm.kind == .commit);
    try std.testing.expectEqualStrings("abc1234", cm.hash);
    try std.testing.expectEqualStrings("file.zig", cm.file);
    // Headers, author lines, and summaries open nothing.
    try std.testing.expect(gb.diffTargetAtRow(0, &line_buf) == null);
    try std.testing.expect(gb.diffTargetAtRow(2, &line_buf) == null);
    try std.testing.expect(gb.diffTargetAtRow(6, &line_buf) == null);
}

test "git adopted stat lines free exactly once" {
    const gpa = std.testing.allocator;
    const inits = [_]CommitInit{
        .{ .hash = "abc1234", .author = "Ada", .date = "2026-01-02", .subject = "first" },
    };
    var gb = try GitBuffer.openWith(gpa, title_text, "main", "(none)", &inits);
    defer gb.close();
    var owned = try parseStatAlloc(gpa, " a.zig | 2 ++\n b.zig | 1 +-\n");
    defer owned.deinit(gpa);
    try gb.adoptSectionLines(.unstaged, &owned);
    try std.testing.expectEqual(@as(usize, 0), owned.items.len);
    try std.testing.expectEqual(@as(usize, 2), gb.unstaged.items.len);
}
