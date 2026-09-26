//! Command line. Opened with `:` into command mode. Edited via `Mode`.

const std = @import("std");
const Event = @import("tty.zig").Event;

pub const max_len: u8 = 96;

/// Reasons the command box can show on its right edge. Static strings:
/// the line borrows them, so no ownership moves. An empty `Line.err`
/// means a clean line.
pub const err_unknown: []const u8 = "unknown command";
pub const err_bad_spec: []const u8 = "bad pattern";
pub const err_needs_file: []const u8 = "exec-save needs a file";
pub const err_no_buffer: []const u8 = "no file open";
pub const err_no_path: []const u8 = "no such path";
pub const err_no_tree: []const u8 = "no tree by that name";
pub const err_git: []const u8 = "git failed";
pub const err_busy: []const u8 = "a run is in flight";
pub const err_oom: []const u8 = "out of memory";

pub const Line = struct {
    bytes: [max_len]u8 = undefined,
    len: u8 = 0,
    col: u8 = 0,
    /// Why the submit failed, or "" for a clean line.
    err: []const u8 = "",

    pub fn text(self: *const Line) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Replace the whole line, cursor to the end. History navigation
    /// uses this. Truncates past `max_len`.
    pub fn setText(self: *Line, s: []const u8) void {
        const n: usize = @min(s.len, @as(usize, max_len));
        @memcpy(self.bytes[0..n], s[0..n]);
        self.len = @intCast(n);
        self.col = @intCast(n);
        self.err = "";
    }

    pub fn handle(self: *Line, ev: Event) Outcome {
        switch (ev) {
            .none => return .none,
            .esc, .ctrl_c => return .cancel,
            .ctrl_r => return .none,
            .enter => return .submit,
            .backspace => {
                self.err = "";
                if (self.col == 0) return .none;
                const i = self.col - 1;
                std.mem.copyForwards(u8, self.bytes[i .. self.len - 1], self.bytes[self.col..self.len]);
                self.len -= 1;
                self.col -= 1;
                return .none;
            },
            .left, .s_left => {
                if (self.col > 0) self.col -= 1;
                return .none;
            },
            .right, .s_right => {
                if (self.col < self.len) self.col += 1;
                return .none;
            },
            .up, .down, .s_up, .s_down => return .none,
            .char => |c| {
                if (c < 32 or self.len >= max_len) return .none;
                self.err = "";
                std.mem.copyBackwards(u8, self.bytes[self.col + 1 .. self.len + 1], self.bytes[self.col..self.len]);
                self.bytes[self.col] = c;
                self.len += 1;
                self.col += 1;
                return .none;
            },
        }
    }
};

pub const Outcome = enum { none, cancel, submit };

/// In-memory command history for one session. Up and down in the
/// command box walk older and newer entries. The current draft is
/// stashed inline while navigating and restored past the newest entry.
/// Empty on launch: nothing is read from or written to disk.
pub const history_cap: usize = 128;

pub const History = struct {
    entries: std.ArrayList([]u8) = .empty,
    cursor: ?usize = null,
    draft: [max_len]u8 = undefined,
    draft_len: u8 = 0,

    pub fn deinit(self: *History, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e);
        self.entries.deinit(gpa);
        self.cursor = null;
        self.draft_len = 0;
    }

    /// Leave navigation: forget the cursor and the stashed draft.
    /// Allocation-free, safe on every open and dismiss.
    pub fn resetNav(self: *History) void {
        self.cursor = null;
        self.draft_len = 0;
    }

    /// Record a submitted line. Skips empties and consecutive dupes.
    /// Drops the oldest past the cap.
    pub fn push(self: *History, gpa: std.mem.Allocator, text: []const u8) void {
        self.resetNav();
        if (text.len == 0) return;
        if (self.entries.items.len > 0 and
            std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], text)) return;
        const kept = gpa.dupe(u8, text) catch return;
        self.entries.append(gpa, kept) catch {
            gpa.free(kept);
            return;
        };
        while (self.entries.items.len > history_cap) {
            const old = self.entries.orderedRemove(0);
            gpa.free(old);
        }
    }

    /// One up or down step through history, editing `line` in place.
    /// Allocation-free: the draft stash is a fixed buffer.
    pub fn navigate(self: *History, up: bool, line: *Line) void {
        if (self.entries.items.len == 0) return;
        if (up) {
            if (self.cursor == null) {
                const cur = line.text();
                const n: usize = @min(cur.len, @as(usize, max_len));
                @memcpy(self.draft[0..n], cur[0..n]);
                self.draft_len = @intCast(n);
                self.cursor = self.entries.items.len - 1;
                line.setText(self.entries.items[self.cursor.?]);
            } else if (self.cursor.? > 0) {
                self.cursor.? -= 1;
                line.setText(self.entries.items[self.cursor.?]);
            }
        } else {
            const c = self.cursor orelse return;
            if (c + 1 >= self.entries.items.len) {
                self.cursor = null;
                line.setText(self.draft[0..self.draft_len]);
                self.draft_len = 0;
            } else {
                self.cursor = c + 1;
                line.setText(self.entries.items[self.cursor.?]);
            }
        }
    }
};

pub const Run = union(enum) {
    empty,
    quit,
    unknown,
    /// Open a directory as an editable buffer. Empty path means the
    /// containing directory of the current buffer. Borrows `s`.
    fs: []const u8,
    /// Open the buffer list. Bare only.
    bufs,
    /// Open the git log. Bare only.
    git,
    /// Regex search. Borrows the spec after the scope prefix: `/` the
    /// current buffer, `f/` filenames, `b/` or `bl/` open buffers.
    /// `search.zig` parses `pat/repl/flags` out of it.
    search: SearchSpec,
    /// Stage paths. Empty means all. Borrows `s`.
    gadd: []const u8,
    /// Commit with a message. Borrows `s`.
    gcommit: []const u8,
    gpush,
    gpull,
    /// Switch to a branch. Borrows `s`.
    gswitch: []const u8,
    /// Create and switch to a branch. Borrows `s`.
    gbranch: []const u8,
    /// Open the help listing. Bare only.
    help,
    /// Open the state inspector, or one named section of it when a
    /// name follows. Borrows the name. The plural spelling is gone:
    /// one verb opens every tree.
    trees: ?[]const u8,
    /// Run a shell command into the `*exec*` problem tree. Empty cmd
    /// reruns the last one. Borrows `s`.
    exec: []const u8,
    /// Run and rerun on save for the current file. Borrows `s`.
    exec_save: []const u8,
};

/// Search scope selected by the command prefix.
pub const SearchScope = enum { buffer, files, buffers };

/// Borrowed search spec: everything after `/`, `f/`, `b/`, or `bl/`.
/// Shape is `pat/repl/flags` with `/` escapable as `\/`.
pub const SearchSpec = struct {
    scope: SearchScope,
    spec: []const u8,
};

/// Every `:` command with its args and one-line meaning. `:help`
/// renders this table, so keep it in sync with `interpret`.
pub const HelpEntry = struct {
    name: []const u8,
    args: []const u8,
    desc: []const u8,
};

pub const help_entries: []const HelpEntry = &.{
    .{ .name = "q", .args = "", .desc = "quit, same as quit" },
    .{ .name = "quit", .args = "", .desc = "quit" },
    .{ .name = "fs", .args = "[path]", .desc = "open a directory as an editable buffer" },
    .{ .name = "buf", .args = "", .desc = "list and operate open buffers" },
    .{ .name = "git", .args = "", .desc = "open the current branch log" },
    .{ .name = "gadd", .args = "[paths]", .desc = "stage paths, empty stages all" },
    .{ .name = "gcommit", .args = "<text>", .desc = "commit staged work" },
    .{ .name = "gpush", .args = "", .desc = "push the current branch" },
    .{ .name = "gpull", .args = "", .desc = "pull the current branch" },
    .{ .name = "gswitch", .args = "<branch>", .desc = "switch branch" },
    .{ .name = "gbranch", .args = "<name>", .desc = "create and switch to a branch" },
    .{ .name = "/", .args = "[pat/repl/flags]", .desc = "regex find in buffer, repl optional, flags i g" },
    .{ .name = "f/", .args = "[pat/repl/flags]", .desc = "regex find filenames, repl renames" },
    .{ .name = "b/", .args = "[pat/repl/flags]", .desc = "regex find open buffers, repl edits (bl/ alias)" },
    .{ .name = "help", .args = "", .desc = "show this listing" },
    .{ .name = "tree", .args = "[name]", .desc = "inspect undo, search, exec, buffers, git, commands" },
    .{ .name = "exec", .args = "[cmd]", .desc = "run shell cmd into *exec* tree (bare reruns)" },
    .{ .name = "exec-save", .args = "<cmd>", .desc = "run and rerun on save for this file" },
};

/// One listing row for `e`, owned by `gpa`: `:name args  desc`, with
/// the args left out when empty. `:help` and the trees command section
/// share it, so the two can never differ.
pub fn helpLine(gpa: std.mem.Allocator, e: HelpEntry) ![]u8 {
    if (e.args.len == 0) return std.fmt.allocPrint(gpa, "  :{s}  {s}", .{ e.name, e.desc });
    return std.fmt.allocPrint(gpa, "  :{s} {s}  {s}", .{ e.name, e.args, e.desc });
}

/// Borrowed args after `prefix`: bare `prefix` gives empty, `prefix`
/// plus a space or tab gives the trimmed rest. Null otherwise.
fn argOf(t: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, t, prefix)) return "";
    if (t.len > prefix.len and std.mem.startsWith(u8, t, prefix) and
        (t[prefix.len] == ' ' or t[prefix.len] == '\t'))
    {
        return std.mem.trim(u8, t[prefix.len..], " \t");
    }
    return null;
}

pub fn interpret(s: []const u8) Run {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return .empty;
    // Search scopes sort before everything: no other command starts
    // with `/`, `f/`, `b/`, or `bl/`.
    if (t[0] == '/') return .{ .search = .{ .scope = .buffer, .spec = t[1..] } };
    if (std.mem.startsWith(u8, t, "f/")) return .{ .search = .{ .scope = .files, .spec = t[2..] } };
    if (std.mem.startsWith(u8, t, "bl/")) return .{ .search = .{ .scope = .buffers, .spec = t[3..] } };
    if (std.mem.startsWith(u8, t, "b/")) return .{ .search = .{ .scope = .buffers, .spec = t[2..] } };
    if (std.mem.eql(u8, t, "q") or std.mem.eql(u8, t, "quit")) return .quit;
    if (std.mem.eql(u8, t, "buf")) return .bufs;
    if (std.mem.eql(u8, t, "git")) return .git;
    if (std.mem.eql(u8, t, "help")) return .help;
    if (argOf(t, "tree")) |name| return .{ .trees = if (name.len == 0) null else name };
    if (argOf(t, "exec-save")) |c| {
        if (c.len == 0) return .unknown;
        return .{ .exec_save = c };
    }
    // Dashless alias: the error box cannot tell a typo apart, and
    // this is the one users type first.
    if (argOf(t, "execsave")) |c| {
        if (c.len == 0) return .unknown;
        return .{ .exec_save = c };
    }
    if (argOf(t, "exec")) |c| return .{ .exec = c };
    if (std.mem.eql(u8, t, "gpush")) return .gpush;
    if (std.mem.eql(u8, t, "gpull")) return .gpull;
    if (argOf(t, "gadd")) |p| return .{ .gadd = p };
    if (argOf(t, "gcommit")) |msg| {
        if (msg.len == 0) return .unknown;
        return .{ .gcommit = msg };
    }
    if (argOf(t, "gswitch")) |name| {
        if (name.len == 0) return .unknown;
        return .{ .gswitch = name };
    }
    if (argOf(t, "gbranch")) |name| {
        if (name.len == 0) return .unknown;
        return .{ .gbranch = name };
    }
    if (argOf(t, "fs")) |p| return .{ .fs = p };
    return .unknown;
}

test "interpret quit spellings" {
    try std.testing.expectEqual(Run.quit, interpret("quit"));
    try std.testing.expectEqual(Run.quit, interpret("  q  "));
    try std.testing.expectEqual(Run.empty, interpret(""));
    try std.testing.expectEqual(Run.unknown, interpret("foo"));
    try std.testing.expectEqual(Run.unknown, interpret("fsoo"));
}

test "interpret fs with and without a path" {
    switch (interpret("fs")) {
        .fs => |p| try std.testing.expectEqualStrings("", p),
        else => return error.Unexpected,
    }
    switch (interpret("fs src")) {
        .fs => |p| try std.testing.expectEqualStrings("src", p),
        else => return error.Unexpected,
    }
    switch (interpret("  fs   src/sub  ")) {
        .fs => |p| try std.testing.expectEqualStrings("src/sub", p),
        else => return error.Unexpected,
    }
}

test "interpret buf is bare only" {
    try std.testing.expect(interpret("buf") == .bufs);
    try std.testing.expectEqual(Run.unknown, interpret("buf foo"));
    try std.testing.expectEqual(Run.unknown, interpret("bufs"));
}

test "interpret git and g verbs" {
    try std.testing.expect(interpret("git") == .git);
    try std.testing.expect(interpret("gpush") == .gpush);
    try std.testing.expect(interpret("gpull") == .gpull);
    switch (interpret("gadd")) {
        .gadd => |p| try std.testing.expectEqualStrings("", p),
        else => return error.Unexpected,
    }
    switch (interpret("gadd src/main.zig")) {
        .gadd => |p| try std.testing.expectEqualStrings("src/main.zig", p),
        else => return error.Unexpected,
    }
    switch (interpret("gcommit fix it")) {
        .gcommit => |m| try std.testing.expectEqualStrings("fix it", m),
        else => return error.Unexpected,
    }
    try std.testing.expectEqual(Run.unknown, interpret("gcommit"));
    try std.testing.expectEqual(Run.unknown, interpret("gcommit   "));
    switch (interpret("gswitch main")) {
        .gswitch => |b| try std.testing.expectEqualStrings("main", b),
        else => return error.Unexpected,
    }
    switch (interpret("gbranch feat")) {
        .gbranch => |b| try std.testing.expectEqualStrings("feat", b),
        else => return error.Unexpected,
    }
    try std.testing.expectEqual(Run.unknown, interpret("gswitch"));
    try std.testing.expectEqual(Run.unknown, interpret("gbranch"));
}

test "interpret tree takes an optional tree name" {
    try std.testing.expect(interpret("tree") == .trees);
    try std.testing.expect(interpret("tree").trees == null);
    switch (interpret("tree exec")) {
        .trees => |name| try std.testing.expectEqualStrings("exec", name.?),
        else => return error.Unexpected,
    }
    // The plural spelling is gone: one verb opens every tree.
    try std.testing.expectEqual(Run.unknown, interpret("trees"));
    try std.testing.expectEqual(Run.unknown, interpret("trees exec"));
    // The section name is checked by the tree, not here.
    try std.testing.expectEqual(Run.unknown, interpret("treehouse"));
}

test "interpret exec runs once or armed on save" {
    switch (interpret("exec")) {
        .exec => |c| try std.testing.expectEqualStrings("", c),
        else => return error.Unexpected,
    }
    switch (interpret("exec zig build")) {
        .exec => |c| try std.testing.expectEqualStrings("zig build", c),
        else => return error.Unexpected,
    }
    switch (interpret("exec-save zig build")) {
        .exec_save => |c| try std.testing.expectEqualStrings("zig build", c),
        else => return error.Unexpected,
    }
    switch (interpret("execsave zig build")) {
        .exec_save => |c| try std.testing.expectEqualStrings("zig build", c),
        else => return error.Unexpected,
    }
    try std.testing.expectEqual(Run.unknown, interpret("exec-save"));
    try std.testing.expectEqual(Run.unknown, interpret("exec-save   "));
    // exec-save is not exec with a dash arg.
    try std.testing.expect(interpret("exec-save zig build") != .unknown);
}

test "interpret help is bare only" {
    try std.testing.expect(interpret("help") == .help);
    try std.testing.expectEqual(Run.unknown, interpret("help foo"));
}

test "help table covers every command" {
    for (help_entries) |e| {
        try std.testing.expect(e.name.len > 0);
        try std.testing.expect(e.desc.len > 0);
    }
    try std.testing.expect(interpret("help") == .help);
    try std.testing.expect(interpret("fs") != .unknown);
    try std.testing.expect(interpret("buf") != .unknown);
    try std.testing.expect(interpret("git") != .unknown);
    try std.testing.expect(interpret("exec") != .unknown);
    try std.testing.expect(interpret("exec-save zig build") != .unknown);
    try std.testing.expect(interpret("gpush") != .unknown);
    try std.testing.expect(interpret("gpull") != .unknown);
}

test "line inserts and backspaces at the cursor" {
    var line: Line = .{};
    try std.testing.expectEqual(Outcome.none, line.handle(.{ .char = 'q' }));
    try std.testing.expectEqual(Outcome.none, line.handle(.{ .char = 'u' }));
    try std.testing.expectEqualStrings("qu", line.text());
    try std.testing.expectEqual(Outcome.none, line.handle(.left));
    try std.testing.expectEqual(Outcome.none, line.handle(.{ .char = 'i' }));
    try std.testing.expectEqualStrings("qiu", line.text());
    try std.testing.expectEqual(Outcome.submit, line.handle(.enter));
    try std.testing.expectEqual(Outcome.cancel, line.handle(.esc));
}

test "history walks up and down, restoring the draft" {
    const gpa = std.testing.allocator;
    var h = History{};
    defer h.deinit(gpa);
    var line: Line = .{};

    h.navigate(true, &line);
    try std.testing.expectEqualStrings("", line.text());

    h.push(gpa, "fs src");
    h.push(gpa, "buf");
    h.push(gpa, "buf");
    try std.testing.expectEqual(@as(usize, 2), h.entries.items.len);

    line.setText("gi");
    h.navigate(true, &line);
    try std.testing.expectEqualStrings("buf", line.text());
    h.navigate(true, &line);
    try std.testing.expectEqualStrings("fs src", line.text());
    h.navigate(true, &line);
    try std.testing.expectEqualStrings("fs src", line.text());
    h.navigate(false, &line);
    try std.testing.expectEqualStrings("buf", line.text());
    h.navigate(false, &line);
    try std.testing.expectEqualStrings("gi", line.text());
    h.navigate(false, &line);
    try std.testing.expectEqualStrings("gi", line.text());
}

test "history push resets navigation and caps old entries" {
    const gpa = std.testing.allocator;
    var h = History{};
    defer h.deinit(gpa);
    var line: Line = .{};

    h.push(gpa, "");
    try std.testing.expectEqual(@as(usize, 0), h.entries.items.len);

    var i: usize = 0;
    while (i < history_cap + 10) : (i += 1) {
        var tmp: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "c{d}", .{i});
        h.push(gpa, s);
    }
    try std.testing.expectEqual(history_cap, h.entries.items.len);
    try std.testing.expectEqualStrings("c10", h.entries.items[0]);

    h.push(gpa, "fs");
    line.setText("x");
    h.navigate(true, &line);
    try std.testing.expectEqualStrings("fs", line.text());
    h.push(gpa, "git");
    try std.testing.expect(h.cursor == null);
}

test "interpret search scopes split the prefix" {
    switch (interpret("/foo/bar/i")) {
        .search => |s| {
            try std.testing.expect(s.scope == .buffer);
            try std.testing.expectEqualStrings("foo/bar/i", s.spec);
        },
        else => return error.Unexpected,
    }
    switch (interpret("f/.*\\.zig")) {
        .search => |s| {
            try std.testing.expect(s.scope == .files);
            try std.testing.expectEqualStrings(".*\\.zig", s.spec);
        },
        else => return error.Unexpected,
    }
    switch (interpret("b/todo")) {
        .search => |s| try std.testing.expect(s.scope == .buffers),
        else => return error.Unexpected,
    }
    switch (interpret("bl/todo/x/g")) {
        .search => |s| {
            try std.testing.expect(s.scope == .buffers);
            try std.testing.expectEqualStrings("todo/x/g", s.spec);
        },
        else => return error.Unexpected,
    }
    // Bare words that merely start with those letters stay unknown.
    try std.testing.expectEqual(Run.unknown, interpret("foo"));
    try std.testing.expectEqual(Run.unknown, interpret("bl"));
    try std.testing.expectEqual(Run.unknown, interpret("buf foo"));
}
