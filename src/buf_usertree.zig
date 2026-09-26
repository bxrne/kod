//! Buffer-list user tree. The `lib` primitive owns hierarchy and
//! flattening. This module owns the buffer-list meaning: rendering open
//! docs one per line and mapping rows back to doc ids. Main owns the
//! registry and applies edits (switch, close, rename, open).
//!
//! Line format mirrors the fs view: the doc path, with a trailing `/`
//! for directory docs. The buf view itself is never listed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ut = @import("lib").usertrees;
const treediff = @import("lib").treediff;
const Buffer = @import("buffer.zig").Buffer;

pub const BufNode = ut.PathNode;

/// One listed doc. `name` is borrowed, with no trailing slash.
pub const Entry = struct {
    id: u32,
    name: []const u8,
    is_dir: bool,
};

/// Editable listing of open docs.
pub const BufBuffer = struct {
    gpa: Allocator,
    buf: Buffer,
    /// Owned title. `buf.path` points here.
    title: []u8,
    snapshot: std.ArrayList(treediff.SnapEntry) = .empty,
    ids: std.ArrayList(u32) = .empty,

    pub fn open(gpa: Allocator, title: []const u8, entries: []const Entry) !BufBuffer {
        var self = BufBuffer{
            .gpa = gpa,
            .buf = undefined,
            .title = &.{},
        };
        errdefer self.close();
        self.title = try gpa.dupe(u8, title);
        errdefer gpa.free(self.title);
        try self.rebuild(entries);
        const text = try renderEntries(gpa, entries);
        errdefer gpa.free(text);
        self.buf = try Buffer.initOwned(gpa, self.title, text);
        self.buf.hl_mode = .filenames;
        return self;
    }

    pub fn close(self: *BufBuffer) void {
        self.buf.close();
        ut.freeOwnedLines(self.gpa, &self.snapshot);
        self.snapshot.deinit(self.gpa);
        self.ids.deinit(self.gpa);
        if (self.title.len > 0) self.gpa.free(self.title);
        self.* = undefined;
    }

    /// Rebuild the listing from the current registry. Drops removed docs,
    /// appends new ones, keeps cursor when it still fits.
    pub fn refresh(self: *BufBuffer, entries: []const Entry) !void {
        ut.freeOwnedLines(self.gpa, &self.snapshot);
        self.ids.clearRetainingCapacity();
        try self.rebuild(entries);
        const text = try renderEntries(self.gpa, entries);
        defer self.gpa.free(text);
        try self.buf.replaceAll(text);
    }

    /// Doc id on `row`, or null past the listing (e.g. the phantom line
    /// after a trailing newline, or freshly typed unsaved lines).
    pub fn idAtRow(self: *const BufBuffer, row: u64) ?u32 {
        if (row >= self.ids.items.len) return null;
        return self.ids.items[row];
    }

    fn rebuild(self: *BufBuffer, entries: []const Entry) !void {
        for (entries) |e| {
            const kept = try self.gpa.dupe(u8, e.name);
            errdefer self.gpa.free(kept);
            try self.snapshot.append(self.gpa, .{ .name = kept, .is_dir = e.is_dir });
            try self.ids.append(self.gpa, e.id);
        }
    }
};

fn renderEntries(gpa: Allocator, entries: []const Entry) ![]u8 {
    const nodes = try gpa.alloc(BufNode, entries.len + 1);
    defer gpa.free(nodes);
    nodes[0] = .{ .tree = ut.UserTree.init(), .name = "buffers", .is_dir = true };
    for (entries, 1..) |e, i| {
        nodes[i] = .{ .tree = ut.UserTree.init(), .name = e.name, .is_dir = e.is_dir };
    }
    for (nodes[1..]) |*n| nodes[0].tree.appendChild(&n.tree);
    nodes[0].tree.expanded = true;

    return ut.joinVisible(gpa, &nodes[0].tree, BufNode, .{});
}

test "buf listing renders in registry order with slash markers" {
    const gpa = std.testing.allocator;
    const entries = [_]Entry{
        .{ .id = 1, .name = "main.zig", .is_dir = false },
        .{ .id = 2, .name = "src", .is_dir = true },
    };
    var bb = try BufBuffer.open(gpa, "*buffers*", &entries);
    defer bb.close();
    try std.testing.expect(bb.buf.hl_mode == .filenames);

    var line_buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 2), bb.buf.lineCount());
    try std.testing.expectEqualStrings("main.zig", try bb.buf.line(0, &line_buf));
    try std.testing.expectEqualStrings("src/", try bb.buf.line(1, &line_buf));
    try std.testing.expectEqual(@as(?u32, 1), bb.idAtRow(0));
    try std.testing.expectEqual(@as(?u32, 2), bb.idAtRow(1));
    try std.testing.expectEqual(@as(?u32, null), bb.idAtRow(2));
}

test "buf refresh drops closed docs and keeps the cursor" {
    const gpa = std.testing.allocator;
    const before = [_]Entry{
        .{ .id = 1, .name = "a", .is_dir = false },
        .{ .id = 2, .name = "b", .is_dir = false },
    };
    var bb = try BufBuffer.open(gpa, "*buffers*", &before);
    defer bb.close();

    bb.buf.row = 1;
    const after = [_]Entry{.{ .id = 2, .name = "b", .is_dir = false }};
    try bb.refresh(&after);

    var line_buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 1), bb.buf.lineCount());
    try std.testing.expectEqualStrings("b", try bb.buf.line(0, &line_buf));
    try std.testing.expectEqual(@as(?u32, 2), bb.idAtRow(0));
}
