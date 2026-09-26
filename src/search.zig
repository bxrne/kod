//! Regex search across three scopes. Spec shape after the scope
//! prefix (`/`, `f/`, `b/`, `bl/`) is `pat/repl/flags` with `\/` and
//! `\\` escapes. Flags: `i` case-insensitive, `g` replace-all. One
//! slash (`/pat`) finds only; two (`/pat/repl`, `/pat//i`) replace,
//! where an empty replacement deletes. Anything past a third slash,
//! an empty pattern, or an unknown flag is `error.BadSearch`.
//!
//! Matching is line-based: `^` and `$` are line anchors, patterns
//! never span newlines. Lines past `Buffer.max_search_line` are
//! skipped. Zero-length matches never replace (a global replace of
//! `a*` would loop forever) and find treats them as real hits.
//!
//! This module owns parsing, state, the filename walk, and results
//! rendering. Acting on docs (jumps, edits, renames) lives in
//! `docs.zig`, which alone may mutate the registry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const command = @import("command.zig");
const regex = @import("lib").regex;
const ut = @import("lib").usertrees;

pub const Scope = command.SearchScope;

/// Borrowed parse of one spec: pattern, optional replacement, flags.
pub const Spec = struct {
    pattern: []const u8,
    replacement: ?[]const u8,
    ci: bool = false,
    global: bool = false,
};

/// Length of an escaped `\/` or `\\` at `i`, else 0. Shared by
/// `parseSpec` splitting and `unescape` copying so both agree.
fn escSkip(s: []const u8, i: usize) usize {
    if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '/' or s[i + 1] == '\\')) return 2;
    return 0;
}

pub fn parseSpec(spec: []const u8) !Spec {
    // Split on unescaped slashes, at most three parts.
    var parts: [3][]const u8 = undefined;
    var nparts: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < spec.len) {
        if (escSkip(spec, i) == 2) {
            i += 2;
            continue;
        }
        if (spec[i] == '/') {
            if (nparts >= 3) return error.BadSearch;
            parts[nparts] = spec[start..i];
            nparts += 1;
            start = i + 1;
        }
        i += 1;
    }
    if (nparts >= 3) return error.BadSearch;
    parts[nparts] = spec[start..];
    nparts += 1;

    if (parts[0].len == 0) return error.BadSearch;
    var out = Spec{ .pattern = parts[0], .replacement = null };
    if (nparts >= 2) out.replacement = parts[1];
    if (nparts >= 3) {
        for (parts[2]) |f| {
            if (f == 'i') out.ci = true else if (f == 'g') out.global = true else return error.BadSearch;
        }
    }
    return out;
}

/// Unescape `\/` and `\\` into an owned copy.
pub fn unescape(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (escSkip(s, i) == 2) {
            try out.append(gpa, s[i + 1]);
            i += 2;
            continue;
        }
        if (s[i] == '\\') return error.BadSearch;
        try out.append(gpa, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Last submitted query plus its options. Hits are never stored: `n`
/// re-scans from the cursor, so edits can never stale them.
pub const State = struct {
    scope: Scope = .buffer,
    pattern: []u8 = &.{},
    replacement: []u8 = &.{},
    has_repl: bool = false,
    ci: bool = false,
    global: bool = false,
    /// Doc `n` continues in (buffer scopes). Zero when none.
    last_doc: u32 = 0,
    /// Owned files-scope anchor: last opened match path.
    last_path: []u8 = &.{},

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.pattern.len > 0) gpa.free(self.pattern);
        if (self.replacement.len > 0) gpa.free(self.replacement);
        if (self.last_path.len > 0) gpa.free(self.last_path);
        self.* = .{};
    }

    pub fn empty(self: *const State) bool {
        return self.pattern.len == 0;
    }

    /// Record a submit, compiling first so a bad pattern never
    /// clobbers the previous working query.
    pub fn submit(self: *State, gpa: Allocator, scope: Scope, spec: Spec) !void {
        const pat = try unescape(gpa, spec.pattern);
        errdefer gpa.free(pat);
        var re = regex.compile(gpa, pat, spec.ci) catch |err| {
            return err;
        };
        re.deinit();
        var repl: []u8 = &.{};
        var has_repl = false;
        if (spec.replacement) |r| {
            repl = try unescape(gpa, r);
            has_repl = true;
        }
        errdefer if (has_repl) gpa.free(repl);
        self.deinit(gpa);
        self.scope = scope;
        self.pattern = pat;
        self.replacement = repl;
        self.has_repl = has_repl;
        self.ci = spec.ci;
        self.global = spec.global;
    }

    /// Fresh compiled regex for the stored query. Caller deinits.
    pub fn compile(self: *const State, gpa: Allocator) !regex.Regex {
        return try regex.compile(gpa, self.pattern, self.ci);
    }
};

/// One rendered results row: where Enter lands.
pub const RowTarget = union(enum) {
    open: struct { id: u32, row: u64, col: u64 },
    file: struct { path: []const u8 },
};

/// Editable-tree node for results rendering. Transient, like the
/// other usertrees: rows own their text elsewhere.
pub const ResultNode = struct {
    tree: ut.UserTree,
    text: []const u8,

    pub fn fromTree(t: *ut.UserTree) *ResultNode {
        return t.cast(ResultNode, "tree");
    }
};

/// Results listing over a `*search*` buffer. Rows parallel the
/// targets the caller keeps; Enter maps a row back through `target`.
pub const SearchBuffer = struct {
    gpa: Allocator,
    buf: Buffer,
    /// Owned title. `buf.path` points here.
    title: []u8,
    targets: std.ArrayList(RowTarget) = .empty,

    pub fn open(gpa: Allocator, title: []const u8) !SearchBuffer {
        var self = SearchBuffer{ .gpa = gpa, .buf = undefined, .title = &.{} };
        errdefer self.close();
        self.title = try gpa.dupe(u8, title);
        errdefer gpa.free(self.title);
        const empty: []u8 = try gpa.dupe(u8, "");
        errdefer gpa.free(empty);
        self.buf = try Buffer.initOwned(gpa, self.title, empty);
        self.buf.hl_mode = .search;
        return self;
    }

    pub fn close(self: *SearchBuffer) void {
        self.buf.close();
        self.clearTargets();
        self.targets.deinit(self.gpa);
        if (self.title.len > 0) self.gpa.free(self.title);
        self.* = undefined;
    }

    fn clearTargets(self: *SearchBuffer) void {
        for (self.targets.items) |t| {
            if (t == .file) self.gpa.free(t.file.path);
        }
        self.targets.clearRetainingCapacity();
    }

    pub fn targetAtRow(self: *const SearchBuffer, row: u64) ?RowTarget {
        if (row >= self.targets.items.len) return null;
        return self.targets.items[row];
    }
    /// Replace rows and text. File targets are duped; the buffer owns
    /// them until the next refresh or close.
    pub fn refresh(self: *SearchBuffer, targets: []const RowTarget, lines: []const []const u8) !void {
        self.clearTargets();
        for (targets) |t| {
            if (t == .file) {
                const kept = try self.gpa.dupe(u8, t.file.path);
                try self.targets.append(self.gpa, .{ .file = .{ .path = kept } });
            } else {
                try self.targets.append(self.gpa, t);
            }
        }
        const nodes = try self.gpa.alloc(ResultNode, lines.len + 1);
        defer self.gpa.free(nodes);
        nodes[0] = .{ .tree = ut.UserTree.init(), .text = "search" };
        for (lines, 1..) |l, k| nodes[k] = .{ .tree = ut.UserTree.init(), .text = l };
        for (nodes[1..]) |*n| nodes[0].tree.appendChild(&n.tree);
        nodes[0].tree.expanded = true;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.gpa);
        var first = true;
        var it = ut.VisibleIterator.init(&nodes[0].tree);
        while (it.next()) |item| {
            if (item.depth == 0) continue;
            if (!first) try out.append(self.gpa, '\n');
            first = false;
            try out.appendSlice(self.gpa, ResultNode.fromTree(item.node).text);
        }
        const text = try out.toOwnedSlice(self.gpa);
        defer self.gpa.free(text);
        try self.buf.replaceAll(text);
    }
};

/// One non-empty match inside a line. Columns and lengths are bytes.
pub const LineHit = struct { col: usize, len: usize };

/// Every non-empty match of `re` on `line`. Zero-length matches are
/// skipped everywhere: a global replace of `a*` would loop forever,
/// and find would stick on them.
pub fn lineHits(re: *regex.Regex, line: []const u8, out: *std.ArrayList(LineHit), gpa: Allocator) !void {
    var from: usize = 0;
    while (from <= line.len) {
        const h = re.find(line, from) orelse return;
        if (h.e > h.s) try out.append(gpa, .{ .col = h.s, .len = h.e - h.s });
        from = if (h.e > from) h.e else from + 1;
        if (from > line.len) return;
    }
}

/// Recursive filename walk from `root`, relative paths owned by the
/// caller. Skips dotfiles, dot-directories, and `zig-out`. Stops past
/// `file_cap` files or `scan_cap` visited entries. Sorted at the end
/// so stepping order is stable. Iteration errors end the walk with
/// partial results instead of failing it.
///
/// `root` must be an already-opened, iterable directory handle. Never
/// pass a bare `Dir.cwd()`: on some platforms iteration seeks the
/// handle, and the cwd handle is not seekable (panics with BADF).
/// Open `"."` first (see `walkCwd`), the way `FsBuffer.open` opens
/// its target.
pub fn walkFiles(
    gpa: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out: *std.ArrayList([]u8),
    file_cap: usize,
    scan_cap: usize,
) !void {
    var scanned: usize = 0;
    try walkInto(gpa, io, root, "", out, file_cap, &scanned, scan_cap);
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

/// Walk the process working directory. Opens `"."` for iteration and
/// closes it after, so callers never touch a bare cwd handle.
pub fn walkCwd(
    gpa: Allocator,
    io: std.Io,
    out: *std.ArrayList([]u8),
    file_cap: usize,
    scan_cap: usize,
) !void {
    var cwd = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer cwd.close(io);
    try walkFiles(gpa, io, cwd, out, file_cap, scan_cap);
}

fn walkInto(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList([]u8),
    file_cap: usize,
    scanned: *usize,
    scan_cap: usize,
) !void {
    if (out.items.len >= file_cap or scanned.* >= scan_cap) return;
    var it = dir.iterate();
    while (true) {
        const entry = (it.next(io) catch break) orelse break;
        if (scanned.* >= scan_cap or out.items.len >= file_cap) return;
        scanned.* += 1;
        const name = entry.name;
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (name[0] == '.') continue;
        // `owned` below is freed on every path, or transferred
        // into `out`. No errdefer spans the transfer.
        const owned: []u8 = if (prefix.len == 0)
            try gpa.dupe(u8, name)
        else
            try std.fs.path.join(gpa, &.{ prefix, name });
        if (entry.kind != .directory) {
            out.append(gpa, owned) catch {
                gpa.free(owned);
                return error.OutOfMemory;
            };
            continue;
        }
        if (std.mem.eql(u8, name, "zig-out")) {
            gpa.free(owned);
            continue;
        }
        var sub = dir.openDir(io, name, .{ .iterate = true }) catch {
            gpa.free(owned);
            continue;
        };
        defer sub.close(io);
        walkInto(gpa, io, sub, owned, out, file_cap, scanned, scan_cap) catch {};
        gpa.free(owned);
    }
}

test "spec splits pattern replacement flags" {
    var s = try parseSpec("foo/bar/i");
    try std.testing.expectEqualStrings("foo", s.pattern);
    try std.testing.expectEqualStrings("bar", s.replacement.?);
    try std.testing.expect(s.ci and !s.global);
    s = try parseSpec("foo");
    try std.testing.expectEqualStrings("foo", s.pattern);
    try std.testing.expect(s.replacement == null);
    s = try parseSpec("a\\/b/c/g");
    try std.testing.expectEqualStrings("a\\/b", s.pattern);
    try std.testing.expectEqualStrings("c", s.replacement.?);
    try std.testing.expect(s.global);
    try std.testing.expectError(error.BadSearch, parseSpec(""));
    try std.testing.expectError(error.BadSearch, parseSpec("a/b/c/d"));
    try std.testing.expectError(error.BadSearch, parseSpec("a/b/x"));
    try std.testing.expectError(error.BadSearch, parseSpec("/b"));
}

test "unescape handles slashes" {
    const gpa = std.testing.allocator;
    const a = try unescape(gpa, "a\\/b\\\\c");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("a/b\\c", a);
    try std.testing.expectError(error.BadSearch, unescape(gpa, "a\\xb"));
}

test "results buffer highlights hits by path language" {
    const gpa = std.testing.allocator;
    var sb = try SearchBuffer.open(gpa, "*search*");
    defer sb.close();
    try std.testing.expect(sb.buf.hl_mode == .search);
}

test "state submit compiles before storing" {
    const gpa = std.testing.allocator;
    var st = State{};
    defer st.deinit(gpa);
    try st.submit(gpa, .buffer, .{ .pattern = "foo", .replacement = "bar", .ci = true });
    try std.testing.expectEqualStrings("foo", st.pattern);
    try std.testing.expect(st.has_repl and st.ci);
    try std.testing.expectError(error.BadPattern, st.submit(gpa, .buffer, .{ .pattern = "(foo", .replacement = null }));
    // Failed submit keeps the previous query.
    try std.testing.expectEqualStrings("foo", st.pattern);
}

test "walkFiles skips dotfiles and sorts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "x" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/c.zig", .data = "x" });
    var out = std.ArrayList([]u8).empty;
    defer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    try walkFiles(gpa, io, tmp.dir, &out, 1000, 100000);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("a.zig", out.items[0]);
    try std.testing.expectEqualStrings("b.zig", out.items[1]);
}

test "walkCwd walks the real repo root without crashing" {
    // Regression: iterating a bare Dir.cwd() panics with BADF on
    // Darwin because iteration seeks the handle. walkCwd opens "."
    // first. Runs from the repo root under `zig build test`.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out = std.ArrayList([]u8).empty;
    defer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    try walkCwd(gpa, io, &out, 50000, 200000);
    var found = false;
    for (out.items) |p| {
        if (std.mem.eql(u8, p, "build.zig")) found = true;
    }
    try std.testing.expect(found);
}
