//! Intrusive red-black tree.
//!
//! Embed `Node` in your item. Recover the item with `@fieldParentPtr`.
//! The tree does not allocate. The caller owns every node.
//!
//! `Context` must provide:
//!     pub fn augment(node: *Node) void
//!         recompute per-node metadata from children; called on rotate
//!         and up the ancestor chain after insert/remove
//! `Context` may provide:
//!     pub fn order(a: *const Node, b: *const Node) std.math.Order
//!         required for key `insert` / `find`

const std = @import("std");
const assert = std.debug.assert;
const Order = std.math.Order;

pub const Color = enum { red, black };

pub const Node = struct {
    parent: ?*Node = null,
    left: ?*Node = null,
    right: ?*Node = null,
    color: Color = .black,

    pub fn next(self: *Node) ?*Node {
        return self.step(true);
    }

    pub fn prev(self: *Node) ?*Node {
        return self.step(false);
    }

    /// One-directional inorder step. Forward goes right-then-far-left,
    /// backward goes left-then-far-right, else climbs to the parent
    /// that owns the subtree just left.
    fn step(self: *Node, forward: bool) ?*Node {
        if (forward) {
            if (self.right) |r| return extremum(r, true);
        } else {
            if (self.left) |l| return extremum(l, false);
        }
        var n: *Node = self;
        while (n.parent) |p| {
            const came_from = if (forward) p.right else p.left;
            if (n != came_from) return p;
            n = p;
        }
        return null;
    }
};

pub fn Tree(comptime Context: type) type {
    return struct {
        root: ?*Node = null,
        len: u32 = 0,

        const Self = @This();

        pub fn first(self: *const Self) ?*Node {
            return if (self.root) |r| extremum(r, true) else null;
        }

        pub fn last(self: *const Self) ?*Node {
            return if (self.root) |r| extremum(r, false) else null;
        }

        /// Return the node whose key compares equal to `key`, if any.
        pub fn find(self: *const Self, key: *const Node) ?*Node {
            comptime assert(@hasDecl(Context, "order"));
            var n = self.root;
            while (n) |cur| {
                switch (Context.order(key, cur)) {
                    .lt => n = cur.left,
                    .gt => n = cur.right,
                    .eq => return cur,
                }
            }
            return null;
        }

        /// Insert `node` by key. Keys must be unique.
        pub fn insert(self: *Self, node: *Node) void {
            comptime assert(@hasDecl(Context, "order"));
            assert(detached(node));

            var parent: ?*Node = null;
            var slot: *?*Node = &self.root;
            while (slot.*) |cur| {
                parent = cur;
                switch (Context.order(node, cur)) {
                    .lt => slot = &cur.left,
                    .gt => slot = &cur.right,
                    .eq => unreachable,
                }
            }

            node.parent = parent;
            node.color = .red;
            slot.* = node;
            self.len += 1;
            self.insertFix(node);
            self.root.?.color = .black;
            self.augmentUp(node);
        }

        /// Insert `node` as the sole root. Tree must be empty.
        pub fn insertRoot(self: *Self, node: *Node) void {
            assert(self.root == null);
            assert(self.len == 0);
            assert(detached(node));
            node.color = .black;
            self.root = node;
            self.len = 1;
            augmentNode(node);
        }

        /// Insert `node` as the inorder successor of `prev`.
        pub fn insertAfter(self: *Self, prev: *Node, node: *Node) void {
            if (prev.right == null) {
                self.attach(prev, node, false);
            } else {
                self.attach(extremum(prev.right.?, true), node, true);
            }
        }

        /// Insert `node` as the inorder predecessor of `next`.
        pub fn insertBefore(self: *Self, next: *Node, node: *Node) void {
            if (next.left == null) {
                self.attach(next, node, true);
            } else {
                self.attach(extremum(next.left.?, false), node, false);
            }
        }

        /// Attach `node` as the left (`left_side`) or right child of
        /// `parent`, then repair. Merges the old attachLeft/attachRight
        /// pair: the bodies were identical apart from the side.
        fn attach(self: *Self, parent: *Node, node: *Node, left_side: bool) void {
            if (left_side) {
                assert(parent.left == null);
            } else {
                assert(parent.right == null);
            }
            assert(detached(node));
            node.parent = parent;
            node.color = .red;
            if (left_side) {
                parent.left = node;
            } else {
                parent.right = node;
            }
            self.len += 1;
            self.insertFix(node);
            self.root.?.color = .black;
            self.augmentUp(node);
        }

        pub fn augmentUp(self: *const Self, node: *Node) void {
            _ = self;
            var cur: ?*Node = node;
            while (cur) |c| {
                augmentNode(c);
                cur = c.parent;
            }
        }

        /// Remove `node`. It must be in this tree.
        pub fn remove(self: *Self, node: *Node) void {
            assert(self.len > 0);
            assert(self.root != null);

            var y = node;
            var y_color = y.color;
            var x: ?*Node = undefined;
            var x_parent: ?*Node = undefined;

            if (node.left == null) {
                x = node.right;
                x_parent = node.parent;
                self.transplant(node, node.right);
            } else if (node.right == null) {
                x = node.left;
                x_parent = node.parent;
                self.transplant(node, node.left);
            } else {
                y = extremum(node.right.?, true);
                y_color = y.color;
                x = y.right;
                if (y.parent == node) {
                    x_parent = y;
                } else {
                    x_parent = y.parent;
                    self.transplant(y, y.right);
                    y.right = node.right;
                    y.right.?.parent = y;
                }
                self.transplant(node, y);
                y.left = node.left;
                y.left.?.parent = y;
                y.color = node.color;
            }

            node.* = .{};
            self.len -= 1;
            if (y_color == .black) self.deleteFix(x, x_parent);
            if (self.root) |r| {
                r.color = .black;
                if (x) |n| {
                    self.augmentUp(n);
                } else if (x_parent) |p| {
                    self.augmentUp(p);
                } else {
                    augmentNode(r);
                }
            }
        }

        fn insertFix(self: *Self, node: *Node) void {
            var z = node;
            while (z.parent) |p| {
                if (p.color == .black) break;
                const gp = p.parent orelse break;
                if (p == gp.left) {
                    const uncle = gp.right;
                    if (red(uncle)) {
                        p.color = .black;
                        uncle.?.color = .black;
                        gp.color = .red;
                        z = gp;
                        continue;
                    }
                    if (z == p.right) {
                        z = p;
                        self.rotate(z, true);
                    }
                    const p2 = z.parent.?;
                    p2.color = .black;
                    const gp2 = p2.parent.?;
                    gp2.color = .red;
                    self.rotate(gp2, false);
                } else {
                    const uncle = gp.left;
                    if (red(uncle)) {
                        p.color = .black;
                        uncle.?.color = .black;
                        gp.color = .red;
                        z = gp;
                        continue;
                    }
                    if (z == p.left) {
                        z = p;
                        self.rotate(z, false);
                    }
                    const p2 = z.parent.?;
                    p2.color = .black;
                    const gp2 = p2.parent.?;
                    gp2.color = .red;
                    self.rotate(gp2, true);
                }
            }
        }

        fn deleteFix(self: *Self, x_init: ?*Node, parent_init: ?*Node) void {
            var x = x_init;
            var parent = parent_init;
            while (x != self.root and !red(x)) {
                const p = parent orelse break;
                if (x == p.left) {
                    var w = p.right;
                    if (red(w)) {
                        w.?.color = .black;
                        p.color = .red;
                        self.rotate(p, true);
                        w = p.right;
                    }
                    if (w == null) {
                        x = p;
                        parent = p.parent;
                        continue;
                    }
                    const sib = w.?;
                    if (!red(sib.left) and !red(sib.right)) {
                        sib.color = .red;
                        x = p;
                        parent = p.parent;
                    } else {
                        if (!red(sib.right)) {
                            if (sib.left) |l| l.color = .black;
                            sib.color = .red;
                            self.rotate(sib, false);
                            w = p.right;
                        }
                        const sib2 = w.?;
                        sib2.color = p.color;
                        p.color = .black;
                        if (sib2.right) |r| r.color = .black;
                        self.rotate(p, true);
                        x = self.root;
                        parent = null;
                    }
                } else {
                    var w = p.left;
                    if (red(w)) {
                        w.?.color = .black;
                        p.color = .red;
                        self.rotate(p, false);
                        w = p.left;
                    }
                    if (w == null) {
                        x = p;
                        parent = p.parent;
                        continue;
                    }
                    const sib = w.?;
                    if (!red(sib.left) and !red(sib.right)) {
                        sib.color = .red;
                        x = p;
                        parent = p.parent;
                    } else {
                        if (!red(sib.left)) {
                            if (sib.right) |r| r.color = .black;
                            sib.color = .red;
                            self.rotate(sib, true);
                            w = p.left;
                        }
                        const sib2 = w.?;
                        sib2.color = p.color;
                        p.color = .black;
                        if (sib2.left) |l| l.color = .black;
                        self.rotate(p, false);
                        x = self.root;
                        parent = null;
                    }
                }
            }
            if (x) |n| n.color = .black;
        }

        fn transplant(self: *Self, old: *Node, new: ?*Node) void {
            if (old.parent) |p| {
                if (old == p.left) {
                    p.left = new;
                } else {
                    p.right = new;
                }
            } else {
                self.root = new;
            }
            if (new) |n| n.parent = old.parent;
        }

        /// Single rotation merging the old rotateLeft/rotateRight pair.
        /// `go_left` picks the direction: true lifts the right child,
        /// false lifts the left child (mirror image).
        fn rotate(self: *Self, x: *Node, go_left: bool) void {
            const y = if (go_left) x.right.? else x.left.?;
            if (go_left) {
                x.right = y.left;
                if (y.left) |l| l.parent = x;
            } else {
                x.left = y.right;
                if (y.right) |r| r.parent = x;
            }
            y.parent = x.parent;
            if (x.parent) |p| {
                if (x == p.left) {
                    p.left = y;
                } else {
                    p.right = y;
                }
            } else {
                self.root = y;
            }
            if (go_left) {
                y.left = x;
            } else {
                y.right = x;
            }
            x.parent = y;
            augmentNode(x);
            augmentNode(y);
        }

        fn augmentNode(n: *Node) void {
            Context.augment(n);
        }
    };
}

fn detached(n: *const Node) bool {
    return n.parent == null and n.left == null and n.right == null;
}

/// Far endpoint in one direction: leftmost when `go_left`, rightmost
/// otherwise. Merges the old leftmost/rightmost pair; every caller
/// passes its direction explicitly.
fn extremum(n: *Node, go_left: bool) *Node {
    var cur = n;
    while (true) {
        const nxt: ?*Node = if (go_left) cur.left else cur.right;
        const c = nxt orelse return cur;
        cur = c;
    }
}

fn red(n: ?*Node) bool {
    return if (n) |x| x.color == .red else false;
}

const TestItem = struct {
    key: u32,
    node: Node = .{},
};

const TestCtx = struct {
    pub fn order(a: *const Node, b: *const Node) Order {
        const ia: *const TestItem = @fieldParentPtr("node", a);
        const ib: *const TestItem = @fieldParentPtr("node", b);
        return std.math.order(ia.key, ib.key);
    }
    pub fn augment(_: *Node) void {}
};

fn inorderKeys(tree: *Tree(TestCtx), out: []u32) []u32 {
    var i: usize = 0;
    var n = tree.first();
    while (n) |cur| : (n = cur.next()) {
        const item: *TestItem = @fieldParentPtr("node", cur);
        out[i] = item.key;
        i += 1;
    }
    return out[0..i];
}

fn assertBlackHeight(n: ?*Node) u32 {
    if (n == null) return 1;
    const node = n.?;
    if (node.left) |l| assert(l.parent == node);
    if (node.right) |r| assert(r.parent == node);
    if (node.color == .red) {
        assert(!red(node.left));
        assert(!red(node.right));
    }
    const lh = assertBlackHeight(node.left);
    const rh = assertBlackHeight(node.right);
    assert(lh == rh);
    return lh + @intFromBool(node.color == .black);
}

fn assertTree(tree: *Tree(TestCtx)) void {
    if (tree.root) |r| {
        assert(r.parent == null);
        assert(r.color == .black);
        _ = assertBlackHeight(r);
    } else {
        assert(tree.len == 0);
    }
}

test "insert finds and walks in order" {
    var items = [_]TestItem{
        .{ .key = 10 },
        .{ .key = 5 },
        .{ .key = 20 },
        .{ .key = 1 },
        .{ .key = 7 },
    };
    var tree: Tree(TestCtx) = .{};
    for (&items) |*it| tree.insert(&it.node);

    try std.testing.expectEqual(@as(u32, 5), tree.len);
    try std.testing.expect(tree.find(&items[3].node) == &items[3].node);

    var buf: [5]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 1, 5, 7, 10, 20 }, inorderKeys(&tree, &buf));
    assertTree(&tree);
}

test "remove keeps order and color invariants" {
    var items: [8]TestItem = undefined;
    var tree: Tree(TestCtx) = .{};
    for (&items, 0..) |*it, i| {
        it.* = .{ .key = @intCast(i + 1) };
        tree.insert(&it.node);
    }
    assertTree(&tree);

    tree.remove(&items[0].node); // 1
    tree.remove(&items[7].node); // 8
    tree.remove(&items[3].node); // 4
    assertTree(&tree);

    var buf: [5]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 5, 6, 7 }, inorderKeys(&tree, &buf));
    try std.testing.expectEqual(@as(u32, 5), tree.len);
    try std.testing.expect(tree.find(&items[0].node) == null);
}

test "insertAfter walks in insertion order" {
    var items = [_]TestItem{
        .{ .key = 1 },
        .{ .key = 2 },
        .{ .key = 3 },
    };
    var tree: Tree(TestCtx) = .{};
    tree.insertRoot(&items[0].node);
    tree.insertAfter(&items[0].node, &items[1].node);
    tree.insertAfter(&items[1].node, &items[2].node);
    var buf: [3]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, inorderKeys(&tree, &buf));
    try std.testing.expectEqual(@as(u32, 3), tree.len);
    assertTree(&tree);
}

test "remove every node" {
    var items: [16]TestItem = undefined;
    var tree: Tree(TestCtx) = .{};
    for (&items, 0..) |*it, i| {
        it.* = .{ .key = @intCast((i * 7) % 16) };
        tree.insert(&it.node);
    }
    assertTree(&tree);

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        tree.remove(&items[i].node);
        assertTree(&tree);
    }
    try std.testing.expectEqual(@as(u32, 0), tree.len);
    try std.testing.expect(tree.first() == null);
}
