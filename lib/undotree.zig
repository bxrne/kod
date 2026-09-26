//! Undo usertree. Per-buffer in-memory edit history with branches.
//! Session only: every tree dies with its buffer, nothing is persisted.
//!
//! Each node holds one recorded edit plus the cursor left behind by it.
//! Positions are absolute byte offsets at record time. Undo applies the
//! inverse of the current node and steps to its parent. A new edit from
//! a non-tip node forks a branch; redo follows the newest child.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// One recorded edit. `insert` means `text` appeared at `pos`, `delete`
/// means `text` vanished from `pos`, `replace` means `old` became `new`.
/// Note: `insert` and `delete` share the same `{pos, text}` shape but
/// keep separate payload structs on purpose. A shared switch arm would
/// need a generic capture over two distinct types, which hides the kind
/// at every use site; the two one-line arms below are the explicit form.
pub const Op = union(enum) {
    insert: Insert,
    delete: Delete,
    replace: Replace,

    fn deinit(self: *Op, gpa: Allocator) void {
        switch (self.*) {
            .insert => |*ins| ins.text.deinit(gpa),
            .delete => |*del| del.text.deinit(gpa),
            .replace => |*rep| {
                rep.old.deinit(gpa);
                rep.new.deinit(gpa);
            },
        }
    }
};

pub const Insert = struct {
    pos: u64,
    text: std.ArrayList(u8),
};

pub const Delete = struct {
    pos: u64,
    text: std.ArrayList(u8),
};

pub const Replace = struct {
    pos: u64,
    old: std.ArrayList(u8),
    new: std.ArrayList(u8),
};

/// Cursor snapshot. Each node keeps the cursor from before its edit
/// and after it, so undo lands where the edit started and redo lands
/// where it ended.
pub const Cursor = struct {
    row: u64,
    col: u64,
};

const Node = struct {
    parent: ?u32,
    op: ?Op,
    pre: Cursor,
    post: Cursor,
};

/// Cursor plus op for one undo or redo step. `op` inverts on undo and
/// re-applies on redo. `cursor` is where the cursor stood at the far
/// side of the step; the caller clamps it into the changed content.
pub const Target = struct {
    op: *const Op,
    cursor: Cursor,
};

pub const UndoTree = struct {
    nodes: std.ArrayList(Node) = .empty,
    current: u32 = 0,

    pub fn deinit(self: *UndoTree, gpa: Allocator) void {
        self.freeNodes(gpa);
        self.nodes.deinit(gpa);
        self.* = .{};
    }

    /// Drop every node and forget the position. View refreshes call this:
    /// rebuilt text is not a continuation of the old edits.
    pub fn clear(self: *UndoTree, gpa: Allocator) void {
        self.freeNodes(gpa);
        self.nodes.clearRetainingCapacity();
        self.current = 0;
    }

    /// Release every recorded op payload without dropping the slot array.
    /// Shared by `deinit` (which then frees the array) and `clear`
    /// (which keeps capacity for the rebuilt history).
    fn freeNodes(self: *UndoTree, gpa: Allocator) void {
        for (self.nodes.items) |*n| {
            if (n.op) |*op| op.deinit(gpa);
        }
    }

    pub fn nodeCount(self: *const UndoTree) usize {
        return self.nodes.items.len;
    }

    /// Index of the current node. Drives the `(current)` marker.
    pub fn currentIndex(self: *const UndoTree) u32 {
        return self.current;
    }

    pub fn parentOf(self: *const UndoTree, i: usize) ?u32 {
        if (i >= self.nodes.items.len) return null;
        return self.nodes.items[i].parent;
    }

    pub fn childCount(self: *const UndoTree, i: usize) u32 {
        if (i >= self.nodes.items.len) return 0;
        var n: u32 = 0;
        for (self.nodes.items) |*nd| {
            if (nd.parent) |p| {
                if (p == i) n += 1;
            }
        }
        return n;
    }

    pub const OpKind = enum { insert, delete, replace };

    /// Null for the root, which holds no edit.
    pub fn opKind(self: *const UndoTree, i: usize) ?OpKind {
        if (i >= self.nodes.items.len) return null;
        const op = self.nodes.items[i].op orelse return null;
        return switch (op) {
            .insert => .insert,
            .delete => .delete,
            .replace => .replace,
        };
    }

    pub fn postOf(self: *const UndoTree, i: usize) Cursor {
        if (i >= self.nodes.items.len) return .{ .row = 0, .col = 0 };
        return self.nodes.items[i].post;
    }

    /// Owned one-line summary for inspection: `#i p=P KIND nB @r,c`
    /// plus a truncated, escaped text preview. Root renders `#0 root`.
    pub fn describe(self: *const UndoTree, gpa: Allocator, i: usize) ![]u8 {
        if (i >= self.nodes.items.len) return error.OutOfBounds;
        const nd = &self.nodes.items[i];
        const op = nd.op orelse return try gpa.dupe(u8, "#0 root");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const kind: []const u8 = switch (op) {
            .insert => "insert",
            .delete => "delete",
            .replace => "replace",
        };
        const bytes: []const u8 = switch (op) {
            .insert => |ins| ins.text.items,
            .delete => |del| del.text.items,
            .replace => |rep| rep.old.items,
        };
        try out.print(gpa, "#{d} p={} {s} {d}B @{d},{d} `", .{
            i,
            if (nd.parent) |p| p else 0,
            kind,
            bytes.len,
            nd.post.row,
            nd.post.col,
        });
        var shown: usize = 0;
        for (bytes) |b| {
            if (shown >= 24) break;
            if (b == '\n') {
                try out.appendSlice(gpa, "\\n");
            } else if (b == '\t') {
                try out.appendSlice(gpa, "\\t");
            } else if (b == '\r') {
                try out.appendSlice(gpa, "\\r");
            } else if (b < 32 or b == 127) {
                try out.append(gpa, '?');
            } else {
                try out.append(gpa, b);
            }
            shown += 1;
        }
        if (bytes.len > shown) try out.append(gpa, '+');
        try out.append(gpa, '`');
        if (i == self.current) try out.appendSlice(gpa, " (current)");
        if (self.childCount(i) > 1) try out.appendSlice(gpa, " (fork)");
        return out.toOwnedSlice(gpa);
    }

    pub fn canUndo(self: *const UndoTree) bool {
        return self.undoTarget() != null;
    }

    pub fn canRedo(self: *const UndoTree) bool {
        return self.redoTarget() != null;
    }

    /// Recorded insert of `text` at `pos`. Adjacent typing at the tip
    /// coalesces into one node so a word undoes at once.
    pub fn pushInsert(
        self: *UndoTree,
        gpa: Allocator,
        pos: u64,
        text: []const u8,
        pre: Cursor,
        post: Cursor,
    ) !void {
        if (text.len == 0) return;
        try self.ensureRoot(gpa);
        if (self.coalesceInsert(pos)) |tip| {
            try tip.op.?.insert.text.appendSlice(gpa, text);
            tip.post = post;
            return;
        }
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, text);
        try self.push(gpa, .{ .insert = .{ .pos = pos, .text = list } }, pre, post);
    }

    /// Recorded insert of `n` copies of `byte` at `pos`. One node for the
    /// whole run, so multi-line `openLine` undoes at once. Materializes
    /// the run into a temp slice and delegates to `pushInsert`, so tip
    /// coalescing lives in exactly one place.
    pub fn pushInsertRun(
        self: *UndoTree,
        gpa: Allocator,
        pos: u64,
        byte: u8,
        n: u64,
        pre: Cursor,
        post: Cursor,
    ) !void {
        if (n == 0) return;
        const count: usize = @intCast(n);
        const buf = try gpa.alloc(u8, count);
        defer gpa.free(buf);
        @memset(buf, byte);
        try self.pushInsert(gpa, pos, buf, pre, post);
    }

    pub fn pushDelete(
        self: *UndoTree,
        gpa: Allocator,
        pos: u64,
        text: []const u8,
        pre: Cursor,
        post: Cursor,
    ) !void {
        if (text.len == 0) return;
        try self.ensureRoot(gpa);
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, text);
        try self.push(gpa, .{ .delete = .{ .pos = pos, .text = list } }, pre, post);
    }

    pub fn pushReplace(
        self: *UndoTree,
        gpa: Allocator,
        pos: u64,
        old: []const u8,
        new: []const u8,
        pre: Cursor,
        post: Cursor,
    ) !void {
        if (old.len == 0 and new.len == 0) return;
        try self.ensureRoot(gpa);
        var kept_old: std.ArrayList(u8) = .empty;
        errdefer kept_old.deinit(gpa);
        var kept_new: std.ArrayList(u8) = .empty;
        errdefer kept_new.deinit(gpa);
        try kept_old.appendSlice(gpa, old);
        try kept_new.appendSlice(gpa, new);
        try self.push(gpa, .{ .replace = .{ .pos = pos, .old = kept_old, .new = kept_new } }, pre, post);
    }

    /// Op to invert for one undo step plus the cursor from before it.
    /// Null at the root. Call `commitUndo` after applying the inverse.
    pub fn undoTarget(self: *const UndoTree) ?Target {
        if (self.nodes.items.len == 0) return null;
        const cur = self.nodes.items[self.current];
        _ = cur.op orelse return null;
        _ = cur.parent orelse return null;
        return .{ .op = &self.nodes.items[self.current].op.?, .cursor = cur.pre };
    }

    pub fn commitUndo(self: *UndoTree) void {
        const cur = self.nodes.items[self.current];
        self.current = cur.parent orelse self.current;
    }

    /// Op to re-apply for one redo step plus the cursor from after it.
    /// Follows the newest child when the tree forked. Null at a tip.
    /// Call `commitRedo` after applying the op.
    pub fn redoTarget(self: *const UndoTree) ?Target {
        const child = self.newestChild(self.current) orelse return null;
        const c = self.nodes.items[child];
        return .{ .op = &self.nodes.items[child].op.?, .cursor = c.post };
    }

    pub fn commitRedo(self: *UndoTree) void {
        const child = self.newestChild(self.current) orelse return;
        self.current = child;
    }

    fn push(self: *UndoTree, gpa: Allocator, op: Op, pre: Cursor, post: Cursor) !void {
        const at: u32 = @intCast(self.nodes.items.len);
        assert(at > 0);
        try self.nodes.append(gpa, .{ .parent = self.current, .op = op, .pre = pre, .post = post });
        self.current = at;
    }

    fn ensureRoot(self: *UndoTree, gpa: Allocator) !void {
        if (self.nodes.items.len == 0) {
            try self.nodes.append(gpa, .{ .parent = null, .op = null, .pre = .{ .row = 0, .col = 0 }, .post = .{ .row = 0, .col = 0 } });
            self.current = 0;
        }
    }

    fn isTip(self: *const UndoTree, idx: u32) bool {
        return self.newestChild(idx) == null;
    }

    /// Tip node when it holds an insert ending exactly at `pos`.
    fn coalesceInsert(self: *UndoTree, pos: u64) ?*Node {
        const tip = &self.nodes.items[self.current];
        if (tip.op) |*op| {
            if (op.* == .insert and self.isTip(self.current) and
                op.insert.pos + @as(u64, op.insert.text.items.len) == pos)
            {
                return tip;
            }
        }
        return null;
    }

    fn newestChild(self: *const UndoTree, idx: u32) ?u32 {
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.nodes.items[i].parent) |p| {
                if (p == idx) return @intCast(i);
            }
        }
        return null;
    }
};

test "adjacent typing coalesces and undoes at once" {
    const gpa = std.testing.allocator;
    var t = UndoTree{};
    defer t.deinit(gpa);
    try std.testing.expect(!t.canUndo());
    try std.testing.expect(!t.canRedo());

    const pre = Cursor{ .row = 0, .col = 0 };
    try t.pushInsert(gpa, 0, "a", pre, .{ .row = 0, .col = 1 });
    try t.pushInsert(gpa, 1, "b", .{ .row = 0, .col = 1 }, .{ .row = 0, .col = 2 });
    try std.testing.expectEqual(@as(usize, 2), t.nodeCount());
    try std.testing.expect(t.canUndo());
    try std.testing.expect(!t.canRedo());

    const t0 = t.undoTarget().?;
    try std.testing.expectEqualStrings("ab", t0.op.insert.text.items);
    try std.testing.expectEqual(pre, t0.cursor);
    t.commitUndo();
    try std.testing.expect(t.canRedo());

    const r0x = t.redoTarget().?;
    try std.testing.expectEqualStrings("ab", r0x.op.insert.text.items);
    try std.testing.expectEqual(@as(u64, 2), r0x.cursor.col);
    t.commitRedo();
    try std.testing.expect(!t.canRedo());
}

test "apart inserts stay separate nodes" {
    const gpa = std.testing.allocator;
    var t = UndoTree{};
    defer t.deinit(gpa);

    const pre = Cursor{ .row = 0, .col = 0 };
    try t.pushInsert(gpa, 0, "ab", pre, .{ .row = 0, .col = 2 });
    try t.pushInsert(gpa, 9, "z", pre, .{ .row = 0, .col = 3 });
    try std.testing.expectEqual(@as(usize, 3), t.nodeCount());

    const t0 = t.undoTarget().?;
    try std.testing.expectEqualStrings("z", t0.op.insert.text.items);
    t.commitUndo();
    const t1 = t.undoTarget().?;
    try std.testing.expectEqualStrings("ab", t1.op.insert.text.items);
}

test "a new edit after undo forks, redo follows the newest child" {
    const gpa = std.testing.allocator;
    var t = UndoTree{};
    defer t.deinit(gpa);

    const pre = Cursor{ .row = 0, .col = 0 };
    try t.pushInsert(gpa, 0, "ab", pre, .{ .row = 0, .col = 2 });
    _ = t.undoTarget();
    t.commitUndo();
    try t.pushInsert(gpa, 0, "c", pre, .{ .row = 0, .col = 1 });

    const r0x = t.redoTarget();
    try std.testing.expect(r0x == null);
    _ = t.undoTarget();
    t.commitUndo();
    const r1x = t.redoTarget().?;
    try std.testing.expectEqualStrings("c", r1x.op.insert.text.items);
}

test "delete and replace round-trip their bytes" {
    const gpa = std.testing.allocator;
    var t = UndoTree{};
    defer t.deinit(gpa);

    const pre = Cursor{ .row = 1, .col = 0 };
    try t.pushDelete(gpa, 3, "gone", pre, .{ .row = 1, .col = 0 });
    const t0 = t.undoTarget().?;
    try std.testing.expectEqual(@as(u64, 3), t0.op.delete.pos);
    try std.testing.expectEqualStrings("gone", t0.op.delete.text.items);
    try std.testing.expectEqual(pre, t0.cursor);
    t.commitUndo();

    try t.pushReplace(gpa, 0, "ab", "ZZ", pre, .{ .row = 0, .col = 2 });
    const t1 = t.undoTarget().?;
    try std.testing.expectEqualStrings("ab", t1.op.replace.old.items);
    try std.testing.expectEqualStrings("ZZ", t1.op.replace.new.items);
}

test "clear drops history" {
    const gpa = std.testing.allocator;
    var t = UndoTree{};
    defer t.deinit(gpa);
    try t.pushInsert(gpa, 0, "a", .{ .row = 0, .col = 0 }, .{ .row = 0, .col = 1 });
    t.clear(gpa);
    try std.testing.expect(!t.canUndo());
    try std.testing.expectEqual(@as(usize, 0), t.nodeCount());
}
