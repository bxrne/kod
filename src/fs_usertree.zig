//! Filesystem user tree. The `lib` primitive owns hierarchy and
//! flattening. This module owns the filesystem meaning: listing a
//! directory into a tree, rendering one entry per line, and applying
//! buffer edits back to disk (oil-style: new line creates, deleted
//! line removes, edited line renames/moves).
//!
//! Line format is the entry name, with a trailing `/` for directories:
//!     src/
//!     main.zig
//! Nested slashes move across directories: `sub/new.zig`.
//! Empty lines and lines that escape the viewed tree (absolute paths,
//! `.` / `..` components) are ignored on save.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ut = @import("lib").usertrees;
const treediff = @import("lib").treediff;
const Buffer = @import("buffer.zig").Buffer;

/// Filesystem-flavoured tree node. Lives transiently while rendering.
/// Long-lived state is the flat snapshot below.
pub const FsNode = ut.PathNode;

/// Directory listing viewed as an editable buffer.
pub const FsBuffer = struct {
    gpa: Allocator,
    io: std.Io,
    buf: Buffer,
    dir: std.Io.Dir,
    /// Owned display path. `buf.path` points here.
    dir_path: []u8,
    snapshot: std.ArrayList(treediff.SnapEntry) = .empty,

    pub fn open(gpa: Allocator, io: std.Io, base: std.Io.Dir, path: []const u8) !FsBuffer {
        const norm = normalizeDirPath(path);
        if (norm.len == 0) return error.BadPath;
        var handle = try base.openDir(io, norm, .{ .iterate = true });
        errdefer handle.close(io);

        var self = FsBuffer{
            .gpa = gpa,
            .io = io,
            .buf = undefined,
            .dir = handle,
            .dir_path = &.{},
        };
        errdefer self.snapshot.deinit(gpa);

        try listInto(gpa, io, handle, &self.snapshot);
        sortSnapshot(self.snapshot.items);
        const text = try renderSnapshot(gpa, norm, self.snapshot.items);
        errdefer gpa.free(text);
        self.dir_path = try gpa.dupe(u8, norm);
        errdefer gpa.free(self.dir_path);
        self.buf = try Buffer.initOwned(gpa, self.dir_path, text);
        self.buf.hl_mode = .filenames;
        return self;
    }

    pub fn close(self: *FsBuffer) void {
        self.buf.close();
        self.dir.close(self.io);
        ut.freeOwnedLines(self.gpa, &self.snapshot);
        self.snapshot.deinit(self.gpa);
        self.gpa.free(self.dir_path);
        self.* = undefined;
    }

    /// Persist buffer edits: new lines create, missing lines remove,
    /// changed lines rename/move. Refreshes from disk afterwards so the
    /// buffer always shows what is really there. Best effort: applies
    /// every op, then returns the first error, if any.
    pub fn save(self: *FsBuffer) !void {
        if (!self.buf.dirty) return;
        const gpa = self.gpa;

        var line_buf: [4096]u8 = undefined;
        const nlines = self.buf.lineCount();
        var i: u64 = 0;
        while (i < nlines) : (i += 1) {
            if (try self.buf.lineLen(i) > @as(u64, line_buf.len)) return error.NameTooLong;
        }

        var owned = std.ArrayList([]u8).empty;
        defer {
            for (owned.items) |s| gpa.free(s);
            owned.deinit(gpa);
        }
        var desired = std.ArrayList(treediff.DesiredEntry).empty;
        defer desired.deinit(gpa);

        i = 0;
        while (i < nlines) : (i += 1) {
            const line = try self.buf.line(i, &line_buf);
            const parsed = treediff.parseDesiredLine(line) orelse continue;
            var dup = false;
            for (desired.items) |prev| {
                if (treediff.sameKey(prev.name, prev.is_dir, parsed.name, parsed.is_dir)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            const kept = try gpa.dupe(u8, parsed.name);
            try owned.append(gpa, kept);
            try desired.append(gpa, .{ .name = kept, .is_dir = parsed.is_dir });
        }

        var plan = try treediff.planOps(gpa, self.snapshot.items, desired.items);
        defer plan.deinit(gpa);

        var first_err: ?anyerror = null;
        self.apply(plan, desired.items, &first_err);
        try self.refresh();
        if (first_err) |e| return e;
    }

    /// Parsed entry under `row`. `line_buf` backs the returned name, so
    /// use it before the next call.
    pub fn entryAtRow(self: *FsBuffer, row: u64, line_buf: []u8) ?treediff.DesiredEntry {
        if (row >= self.buf.lineCount()) return null;
        const len = self.buf.lineLen(row) catch return null;
        if (len > @as(u64, line_buf.len)) return null;
        const line = self.buf.line(row, line_buf) catch return null;
        return treediff.parseDesiredLine(line);
    }

    /// Move the cursor to the row showing `display` (name with `/`
    /// suffix for dirs). No-op when absent.
    pub fn selectRow(self: *FsBuffer, display: []const u8) void {
        var line_buf: [4096]u8 = undefined;
        var r: u64 = 0;
        while (r < self.buf.lineCount()) : (r += 1) {
            const len = self.buf.lineLen(r) catch continue;
            if (len != display.len) continue;
            const line = self.buf.line(r, &line_buf) catch continue;
            if (std.mem.eql(u8, line, display)) {
                self.buf.row = r;
                self.buf.col = 0;
                return;
            }
        }
    }

    fn apply(self: *FsBuffer, plan: treediff.Plan, desired: []const treediff.DesiredEntry, first_err: *?anyerror) void {
        const io = self.io;
        const dir = self.dir;
        const old = self.snapshot.items;

        for (plan.deletes.items) |si| {
            const e = old[si];
            if (e.is_dir) {
                dir.deleteTree(io, e.name) catch |err| record(first_err, err);
            } else {
                dir.deleteFile(io, e.name) catch |err| record(first_err, err);
            }
        }

        for (plan.renames.items) |r| {
            if (std.fs.path.dirname(desired[r.to].name)) |parent| {
                dir.createDirPath(io, parent) catch |err| {
                    record(first_err, err);
                    continue;
                };
            }
        }
        for (desired) |d| {
            if (!d.is_dir) continue;
            var keep = false;
            for (old) |o| {
                if (treediff.sameKey(o.name, o.is_dir, d.name, d.is_dir)) {
                    keep = true;
                    break;
                }
            }
            if (keep) continue;
            dir.createDirPath(io, d.name) catch |err| record(first_err, err);
        }

        for (plan.renames.items) |r| {
            const dest = desired[r.to].name;
            if (dir.statFile(io, dest, .{})) |_| {
                record(first_err, error.PathAlreadyExists);
                continue;
            } else |_| {}
            std.Io.Dir.rename(dir, old[r.from].name, dir, dest, io) catch |err| {
                record(first_err, err);
            };
        }

        for (plan.creates.items) |ni| {
            const d = desired[ni];
            if (d.is_dir) continue;
            if (dir.statFile(io, d.name, .{})) |_| continue else |_| {}
            dir.writeFile(io, .{ .sub_path = d.name, .data = "" }) catch |err| {
                record(first_err, err);
            };
        }
    }

    fn refresh(self: *FsBuffer) !void {
        const gpa = self.gpa;
        var fresh = std.ArrayList(treediff.SnapEntry).empty;
        errdefer {
            ut.freeOwnedLines(gpa, &fresh);
            fresh.deinit(gpa);
        }
        try listInto(gpa, self.io, self.dir, &fresh);
        sortSnapshot(fresh.items);
        const text = try renderSnapshot(gpa, self.dir_path, fresh.items);
        defer gpa.free(text);
        try self.buf.replaceAll(text);
        ut.freeOwnedLines(gpa, &self.snapshot);
        try self.snapshot.appendSlice(gpa, fresh.items);
        fresh.deinit(gpa);
    }
};

fn record(first_err: *?anyerror, err: anyerror) void {
    if (err == error.FileNotFound) return;
    if (first_err.* == null) first_err.* = err;
}

fn normalizeDirPath(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn listInto(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    out: *std.ArrayList(treediff.SnapEntry),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try out.append(gpa, .{ .name = name, .is_dir = entry.kind == .directory });
    }
}

fn sortSnapshot(items: []treediff.SnapEntry) void {
    std.mem.sort(treediff.SnapEntry, items, {}, struct {
        fn less(_: void, a: treediff.SnapEntry, b: treediff.SnapEntry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
}

/// Render snapshot lines through the user-tree primitive: root plus one
/// child per entry, flattened in visible order. Skips the root itself.
fn renderSnapshot(gpa: Allocator, dir_path: []const u8, snap: []const treediff.SnapEntry) ![]u8 {
    const nodes = try gpa.alloc(FsNode, snap.len + 1);
    defer gpa.free(nodes);
    nodes[0] = .{ .tree = ut.UserTree.init(), .name = dir_path, .is_dir = true };
    for (snap, 1..) |e, i| {
        nodes[i] = .{ .tree = ut.UserTree.init(), .name = e.name, .is_dir = e.is_dir };
    }
    for (nodes[1..]) |*n| nodes[0].tree.appendChild(&n.tree);
    nodes[0].tree.expanded = true;

    // Virtual first row: the parent. It is never part of the snapshot
    // and never planned on save. Main handles enter on it.
    return ut.joinVisible(gpa, &nodes[0].tree, FsNode, .{ .header = "../" });
}

test "fs open lists dirs first with slash markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "x" });

    var fb = try FsBuffer.open(gpa, io, tmp.dir, ".");
    defer fb.close();
    try std.testing.expect(fb.buf.hl_mode == .filenames);

    var line_buf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 4), fb.buf.lineCount());
    try std.testing.expectEqualStrings("../", try fb.buf.line(0, &line_buf));
    try std.testing.expectEqualStrings("sub/", try fb.buf.line(1, &line_buf));
    try std.testing.expectEqualStrings("a.zig", try fb.buf.line(2, &line_buf));
    try std.testing.expectEqualStrings("b.zig", try fb.buf.line(3, &line_buf));
}

test "fs save creates, renames, moves, and deletes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "old.zig", .data = "keep me" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.zig", .data = "x" });

    var fb = try FsBuffer.open(gpa, io, tmp.dir, ".");
    defer fb.close();

    // gone.zig | old.zig -> keep/old.zig (move by basename) + new.zig.
    // The leftover pairs as a content-preserving rename, so new.zig
    // inherits gone.zig's bytes instead of being created empty.
    try fb.buf.replaceAll("keep/old.zig\nnew.zig");
    fb.buf.dirty = true;
    try fb.save();

    var got: [16]u8 = undefined;
    try std.testing.expectEqualStrings("keep me", try tmp.dir.readFile(io, "keep/old.zig", &got));
    try std.testing.expectEqualStrings("x", try tmp.dir.readFile(io, "new.zig", &got));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "gone.zig", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "old.zig", .{}));

    var line_buf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 3), fb.buf.lineCount());
    try std.testing.expectEqualStrings("../", try fb.buf.line(0, &line_buf));
    try std.testing.expectEqualStrings("keep/", try fb.buf.line(1, &line_buf));
    try std.testing.expectEqualStrings("new.zig", try fb.buf.line(2, &line_buf));
    try std.testing.expect(!fb.buf.dirty);
}

test "fs save through real editing ops" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "x" });

    var fb = try FsBuffer.open(gpa, io, tmp.dir, ".");
    defer fb.close();

    // Cursor on `a.zig`, below the virtual `../` row. Open a line below
    // and type a new name, the way oil editing works from the keyboard.
    fb.buf.row = 1;
    try fb.buf.openLine(true, 1);
    for ("b.zig") |c| try fb.buf.insert(c);
    try std.testing.expect(fb.buf.dirty);
    try fb.save();

    var got: [16]u8 = undefined;
    try std.testing.expectEqualStrings("x", try tmp.dir.readFile(io, "a.zig", &got));
    try std.testing.expectEqualStrings("", try tmp.dir.readFile(io, "b.zig", &got));
}

test "fs save ignores blank lines and escapes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "x" });

    var fb = try FsBuffer.open(gpa, io, tmp.dir, ".");
    defer fb.close();

    try fb.buf.replaceAll("a.zig\n\n../evil\n/abs");
    fb.buf.dirty = true;
    try fb.save();

    var got: [16]u8 = undefined;
    try std.testing.expectEqualStrings("x", try tmp.dir.readFile(io, "a.zig", &got));
    var line_buf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 2), fb.buf.lineCount());
    try std.testing.expectEqualStrings("../", try fb.buf.line(0, &line_buf));
    try std.testing.expectEqualStrings("a.zig", try fb.buf.line(1, &line_buf));
}

test "fs save restores a deleted parent row" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "x" });

    var fb = try FsBuffer.open(gpa, io, tmp.dir, ".");
    defer fb.close();

    // Deleting the virtual row is a no-op: it carries no snapshot entry
    // and comes back on refresh.
    try fb.buf.deleteLines(1);
    fb.buf.dirty = true;
    try fb.save();

    var line_buf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 2), fb.buf.lineCount());
    try std.testing.expectEqualStrings("../", try fb.buf.line(0, &line_buf));
    try std.testing.expectEqualStrings("a.zig", try fb.buf.line(1, &line_buf));
}
