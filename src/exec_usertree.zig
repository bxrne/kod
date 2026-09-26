//! Exec diagnostics tree. `:exec <cmd>` runs a shell command in a
//! background thread and parses `path:row:col: message` rows into a
//! surfable tree. Enter jumps, `n`/`p` walk hits. Kod never links a
//! parser: the tool reads the saved file from disk while kod holds
//! only the resulting spans, so the paging promise holds at any scale.
//!
//! Runs are synchronous syscalls in one worker thread. The worker owns
//! all of its memory (page allocator) until the main loop joins it,
//! so the main GPA is never touched from two threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const search = @import("search.zig");

pub const exec_title = "*exec*";

pub const HitKind = enum { err, warn };

/// One parsed diagnostics row. Slices borrow the output line.
pub const ParsedHit = struct {
    path: []const u8,
    row: u64,
    col: u64,
    kind: HitKind,
    msg: []const u8,
};

fn inferKind(msg: []const u8) HitKind {
    if (std.ascii.indexOfIgnoreCase(msg, "warning") != null) return .warn;
    return .err;
}

fn parseU64(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// `path:row:col: msg` or `path:row: msg`. Rows and cols are 1-based
/// on the wire, 0-based here. Null when the line carries no position.
pub fn parseExecLine(line: []const u8) ?ParsedHit {
    const first = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const path = std.mem.trim(u8, line[0..first], " \t");
    if (path.len == 0) return null;
    const rest = line[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const row = parseU64(std.mem.trim(u8, rest[0..second], " \t")) orelse return null;
    if (row == 0) return null;
    const after = rest[second + 1 ..];
    const third = std.mem.indexOfScalar(u8, after, ':');
    const col: u64, const msg: []const u8 = if (third) |t| blk: {
        const maybe_col = std.mem.trim(u8, after[0..t], " \t");
        if (maybe_col.len > 0) {
            if (parseU64(maybe_col)) |c| {
                if (c == 0) return null;
                break :blk .{ c - 1, std.mem.trim(u8, after[t + 1 ..], " \t") };
            }
        }
        break :blk .{ 0, std.mem.trim(u8, after, " \t") };
    } else .{ 0, std.mem.trim(u8, after, " \t") };
    return .{
        .path = path,
        .row = row - 1,
        .col = col,
        .kind = inferKind(msg),
        .msg = msg,
    };
}

/// One rendered exec row: where Enter lands. File rows own their
/// path until the next refresh or close.
pub const Target = union(enum) {
    none,
    file: struct { path: []u8, row: u64, col: u64 },
};

pub const ExecNode = struct {
    text: []const u8,
};

pub const ExecBuffer = struct {
    gpa: Allocator,
    buf: Buffer,
    /// Owned title. `buf.path` points here.
    title: []u8,
    targets: std.ArrayList(Target) = .empty,
    /// Command shown in the header. Owned, for the running display.
    cmd_text: []u8 = &.{},
    running: bool = false,
    exit_code: ?u8 = null,

    pub fn open(gpa: Allocator, title: []const u8) !ExecBuffer {
        var self = ExecBuffer{ .gpa = gpa, .buf = undefined, .title = &.{} };
        errdefer self.close();
        self.title = try gpa.dupe(u8, title);
        errdefer gpa.free(self.title);
        const empty: []u8 = try gpa.dupe(u8, "");
        errdefer gpa.free(empty);
        self.buf = try Buffer.initOwned(gpa, self.title, empty);
        self.buf.hl_mode = .exec;
        return self;
    }

    pub fn close(self: *ExecBuffer) void {
        self.buf.close();
        self.clearTargets();
        self.targets.deinit(self.gpa);
        if (self.cmd_text.len > 0) self.gpa.free(self.cmd_text);
        if (self.title.len > 0) self.gpa.free(self.title);
        self.* = undefined;
    }

    fn clearTargets(self: *ExecBuffer) void {
        for (self.targets.items) |t| {
            if (t == .file) self.gpa.free(t.file.path);
        }
        self.targets.clearRetainingCapacity();
    }

    pub fn targetAtRow(self: *const ExecBuffer, row: u64) ?Target {
        if (row >= self.targets.items.len) return null;
        return self.targets.items[row];
    }

    fn setCmdText(self: *ExecBuffer, cmd: []const u8) !void {
        // Dupe before freeing: on OOM the old text stays valid instead
        // of dangling into a later double free in `close`.
        const kept = try self.gpa.dupe(u8, cmd);
        if (self.cmd_text.len > 0) self.gpa.free(self.cmd_text);
        self.cmd_text = kept;
    }

    /// Header-only running state. Previous results clear: the header
    /// says what is running, and completion repaints.
    pub fn refreshRunning(self: *ExecBuffer, cmd: []const u8) !void {
        try self.setCmdText(cmd);
        self.running = true;
        self.exit_code = null;
        const head = try std.fmt.allocPrint(self.gpa, "$ {s} (running...)", .{cmd});
        defer self.gpa.free(head);
        var fresh = std.ArrayList(Target).empty;
        errdefer fresh.deinit(self.gpa);
        try fresh.append(self.gpa, .none);
        // Commit only after every fallible step: rows and text never
        // diverge on OOM.
        self.clearTargets();
        self.targets.deinit(self.gpa);
        self.targets = fresh;
        try self.buf.replaceAll(head);
    }

    /// Full results: header plus one row per output line. Parsed rows
    /// carry jump targets, the rest are plain log context. Targets
    /// commit atomically with the text: on OOM the old rows stay.
    pub fn refresh(
        self: *ExecBuffer,
        cmd: []const u8,
        exit_code: u8,
        lines: []const []const u8,
        hits: []const ?ParsedHit,
    ) !void {
        assert(lines.len == hits.len);
        var fresh = std.ArrayList(Target).empty;
        errdefer {
            for (fresh.items) |t| {
                if (t == .file) self.gpa.free(t.file.path);
            }
            fresh.deinit(self.gpa);
        }
        var problems: usize = 0;
        for (hits) |h| if (h != null) {
            problems += 1;
        };
        const head = try std.fmt.allocPrint(
            self.gpa,
            "$ {s} ({d} problems, exit {d})",
            .{ cmd, problems, exit_code },
        );
        defer self.gpa.free(head);
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, head);
        try fresh.append(self.gpa, .none);
        for (lines, hits) |line, h| {
            try out.append(self.gpa, '\n');
            try out.appendSlice(self.gpa, line);
            if (h) |hit| {
                const kept = try self.gpa.dupe(u8, hit.path);
                errdefer self.gpa.free(kept);
                try fresh.append(self.gpa, .{
                    .file = .{ .path = kept, .row = hit.row, .col = hit.col },
                });
            } else {
                try fresh.append(self.gpa, .none);
            }
        }
        const text = try out.toOwnedSlice(self.gpa);
        defer self.gpa.free(text);
        try self.setCmdText(cmd);
        self.running = false;
        self.exit_code = exit_code;
        self.clearTargets();
        self.targets.deinit(self.gpa);
        self.targets = fresh;
        try self.buf.replaceAll(text);
    }

    /// First jumpable row at or after `row`, wrapping once. Null when
    /// the run reported no hit at all. Enter works from any row: a
    /// plain log row opens the next diagnostic instead of nothing, so
    /// no row of the run is a dead end.
    pub fn hitAtOrAfter(self: *const ExecBuffer, row: u64) ?u64 {
        const n = self.targets.items.len;
        if (n == 0) return null;
        var k: usize = @intCast(row);
        var steps: usize = 0;
        while (steps < n) : (steps += 1) {
            if (self.targets.items[k] == .file) return k;
            k = (k + 1) % n;
        }
        return null;
    }

    /// Next or previous jumpable row from the cursor, wrapping once.
    /// Null when the tree holds no hits.
    pub fn step(self: *ExecBuffer, fwd: bool) ?u64 {
        const n = self.targets.items.len;
        if (n == 0) return null;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const at = if (fwd)
                (self.buf.row + 1 + k) % n
            else
                (self.buf.row + n - k) % n;
            if (self.targets.items[at] == .file) return at;
        }
        return null;
    }
};

/// Worker-owned run result. All slices use the page allocator: the
/// main GPA is never touched from the worker thread.
pub const RunResult = struct {
    cmd: []u8,
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    target_id: u32,
    switch_to: bool,
};

pub fn freeResult(r: *RunResult) void {
    const pa = std.heap.page_allocator;
    pa.free(r.cmd);
    pa.free(r.stdout);
    pa.free(r.stderr);
    r.* = undefined;
}

pub const Runner = struct {
    thread: std.Thread,
    done: std.atomic.Value(bool),
    result: ?RunResult = null,
};

const WorkerArgs = struct {
    runner: *Runner,
    io: std.Io,
    cmd: []u8,
    target_id: u32,
    switch_to: bool,
};

fn workerMain(args: WorkerArgs) void {
    const pa = std.heap.page_allocator;
    var result = RunResult{
        .cmd = args.cmd,
        .stdout = &.{},
        .stderr = &.{},
        .exit_code = 127,
        .target_id = args.target_id,
        .switch_to = args.switch_to,
    };
    if (std.process.run(pa, args.io, .{ .argv = &.{ "sh", "-c", args.cmd } })) |res| {
        // Ownership of all three buffers passes to the main thread with
        // `result`: `freeResult` frees them after the rows are parsed.
        // Freeing stderr here unmapped the page the main thread was
        // about to scan, which crashed `:exec` on any tool that
        // reported on stderr.
        result.stdout = res.stdout;
        result.stderr = res.stderr;
        result.exit_code = switch (res.term) {
            .exited => |c| c,
            else => 1,
        };
    } else |_| {
        result.stderr = pa.dupe(u8, "exec: failed to spawn shell") catch &.{};
    }
    args.runner.result = result;
    args.runner.done.store(true, .release);
}

/// Start a background run. The caller keeps `cmd` (borrowed); the
/// worker dupes it. False when a run is already active or the thread
/// fails to spawn.
pub fn spawn(runner: *Runner, io: std.Io, cmd: []const u8, target_id: u32, switch_to: bool) bool {
    const pa = std.heap.page_allocator;
    const owned = pa.dupe(u8, cmd) catch return false;
    errdefer pa.free(owned);
    runner.* = .{
        .thread = undefined,
        .done = std.atomic.Value(bool).init(false),
        .result = null,
    };
    runner.thread = std.Thread.spawn(.{}, workerMain, .{WorkerArgs{
        .runner = runner,
        .io = io,
        .cmd = owned,
        .target_id = target_id,
        .switch_to = switch_to,
    }}) catch {
        pa.free(owned);
        return false;
    };
    return true;
}

const assert = std.debug.assert;

test "parseExecLine splits file row col and message" {
    const h = parseExecLine("src/main.zig:12:4: use of undeclared identifier").?;
    try std.testing.expectEqualStrings("src/main.zig", h.path);
    try std.testing.expectEqual(@as(u64, 11), h.row);
    try std.testing.expectEqual(@as(u64, 3), h.col);
    try std.testing.expect(h.kind == .err);
    try std.testing.expectEqualStrings("use of undeclared identifier", h.msg);

    const w = parseExecLine("a.zig:3: warning: unused variable").?;
    try std.testing.expectEqual(@as(u64, 2), w.row);
    try std.testing.expectEqual(@as(u64, 0), w.col);
    try std.testing.expect(w.kind == .warn);

    // Message with colons but no numeric col stays a row-only hit.
    const m = parseExecLine("a.zig:3: note: something: detailed").?;
    try std.testing.expectEqual(@as(u64, 2), m.row);
    try std.testing.expectEqual(@as(u64, 0), m.col);

    try std.testing.expect(parseExecLine("just a log line") == null);
    try std.testing.expect(parseExecLine(":12:4: missing path") == null);
    try std.testing.expect(parseExecLine("a.zig:0:1: zero row") == null);
    try std.testing.expect(parseExecLine("a.zig:1:0: zero col") == null);
}

test "exec buffer refresh parallels rows and targets" {
    const gpa = std.testing.allocator;
    var eb = try ExecBuffer.open(gpa, "*exec*");
    defer eb.close();
    const lines = [_][]const u8{
        "src/main.zig:2:1: boom",
        "plain log line",
    };
    const hits = [_]?ParsedHit{
        parseExecLine(lines[0]),
        parseExecLine(lines[1]),
    };
    try eb.refresh("zig build", 1, &lines, &hits);
    try std.testing.expect(eb.targets.items.len == eb.buf.lineCount());
    try std.testing.expect(eb.targetAtRow(0).? == .none);
    try std.testing.expect(eb.targetAtRow(1).? == .file);
    try std.testing.expect(eb.targetAtRow(2).? == .none);
    try std.testing.expect(eb.step(true).? == 1);
    try std.testing.expect(eb.buf.hl_mode == .exec);
}

test "exec enter on a plain row finds the next hit" {
    // Log rows sit between the hits, so Enter must never be a dead
    // end: a plain row finds the next diagnostic below it, wrapping.
    const gpa = std.testing.allocator;
    var eb = try ExecBuffer.open(gpa, "*exec*");
    defer eb.close();
    const lines = [_][]const u8{
        "install",
        "+- install kod",
        "src/main.zig:2:1: boom",
        "  ^",
        "plain",
        "src/other.zig:7:3: bang",
    };
    const hits = [_]?ParsedHit{
        null,
        null,
        parseExecLine(lines[2]),
        null,
        null,
        parseExecLine(lines[5]),
    };
    // Line 0 is the run header, so lines[2] and lines[5] sit at rows 3
    // and 6.
    try eb.refresh("zig build", 1, &lines, &hits);
    try std.testing.expectEqual(@as(?u64, 3), eb.hitAtOrAfter(1));
    try std.testing.expectEqual(@as(?u64, 6), eb.hitAtOrAfter(4));
    try std.testing.expectEqual(@as(?u64, 6), eb.hitAtOrAfter(5));
    // A hit row finds itself, so a second Enter stays put.
    try std.testing.expectEqual(@as(?u64, 3), eb.hitAtOrAfter(3));
    try std.testing.expectEqual(@as(?u64, 6), eb.hitAtOrAfter(6));
    // The header row finds the first hit below it.
    try std.testing.expectEqual(@as(?u64, 3), eb.hitAtOrAfter(0));
    // A clean run has no hit anywhere, so Enter does nothing.
    const clean = [_][]const u8{"all good"};
    const no_hits = [_]?ParsedHit{null};
    try eb.refresh("true", 0, &clean, &no_hits);
    try std.testing.expect(eb.hitAtOrAfter(0) == null);
}
