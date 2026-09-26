const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Generic tree primitive: hierarchy plus visible flattening. It owns
/// no domain meaning. Each usertree module (`fs_usertree`, `buf_usertree`,
/// `git_usertree`) wraps `UserTree` in its own node type. Undo history
/// lives in `undotree` and does not use this primitive.
pub const UserTree = struct {
    parent: ?*UserTree = null,
    first_child: ?*UserTree = null,
    last_child: ?*UserTree = null,
    next_sibling: ?*UserTree = null,
    prev_sibling: ?*UserTree = null,

    expanded: bool = false,
    selectable: bool = true,

    pub fn init() UserTree {
        return .{};
    }

    /// Appends a child tree node to this node.
    pub fn appendChild(self: *UserTree, child: *UserTree) void {
        assert(child.parent == null);
        assert(child.next_sibling == null);
        assert(child.prev_sibling == null);

        child.parent = self;
        if (self.last_child) |last| {
            last.next_sibling = child;
            child.prev_sibling = last;
            self.last_child = child;
        } else {
            self.first_child = child;
            self.last_child = child;
        }
    }

    /// Unlinks this node from its parent and siblings.
    pub fn detach(self: *UserTree) void {
        if (self.parent) |p| {
            if (p.first_child == self) p.first_child = self.next_sibling;
            if (p.last_child == self) p.last_child = self.prev_sibling;
        }

        if (self.prev_sibling) |prev| prev.next_sibling = self.next_sibling;
        if (self.next_sibling) |next| next.prev_sibling = self.prev_sibling;

        self.parent = null;
        self.next_sibling = null;
        self.prev_sibling = null;
    }

    /// Toggles expansion state if the node has children.
    pub fn toggleExpanded(self: *UserTree) void {
        if (self.first_child != null) {
            self.expanded = !self.expanded;
        }
    }

    /// Casts this core tree node back to the outer parent container struct.
    /// Kept as the single generic `@fieldParentPtr` wrapper: every usertree
    /// module (`fs`, `buf`, `git`, search results) recovers its own node
    /// type through this one call instead of repeating the builtin.
    pub fn cast(self: *UserTree, comptime T: type, comptime field_name: []const u8) *T {
        return @fieldParentPtr(field_name, self);
    }
};

/// A visible item yielded during flattening for window/buffer rendering.
pub const VisibleItem = struct {
    node: *UserTree,
    depth: usize,
};

/// Iterator that flattens visible (expanded) nodes in depth-first order.
pub const VisibleIterator = struct {
    current: ?*UserTree,

    pub fn init(root: *UserTree) VisibleIterator {
        return .{ .current = root };
    }

    pub fn next(self: *VisibleIterator) ?VisibleItem {
        const curr = self.current orelse return null;
        // Depth was a single-use helper: walk parents inline so the
        // flattening logic reads in one place (root = 0).
        var depth: usize = 0;
        var up = curr.parent;
        while (up) |p| : (up = p.parent) {
            depth += 1;
        }

        // Determine the next visible node in depth-first traversal order
        if (curr.expanded and curr.first_child != null) {
            self.current = curr.first_child;
        } else if (curr.next_sibling) |sibling| {
            self.current = sibling;
        } else {
            // Traverse up parents until we find an unvisited next sibling
            var parent = curr.parent;
            var next_node: ?*UserTree = null;
            while (parent) |p| : (parent = p.parent) {
                if (p.next_sibling) |sibling| {
                    next_node = sibling;
                    break;
                }
            }
            self.current = next_node;
        }

        return VisibleItem{
            .node = curr,
            .depth = depth,
        };
    }
};

/// Shared node wrappers. `FsNode`/`BufNode` were byte-identical path
/// nodes and `GitNode`/`TreeNode` were byte-identical text nodes, so
/// they now alias these two types instead of repeating the struct.
pub const PathNode = struct {
    tree: UserTree,
    name: []const u8,
    is_dir: bool,

    pub fn fromTree(t: *UserTree) *PathNode {
        return t.cast(PathNode, "tree");
    }
};

pub const TextNode = struct {
    tree: UserTree,
    text: []const u8,

    pub fn fromTree(t: *UserTree) *TextNode {
        return t.cast(TextNode, "tree");
    }
};

/// Join visible rows into newline-separated text. `Node` is `PathNode`
/// (or an alias) or `TextNode` (or an alias). The caller builds the
/// nodes, links children, and sets `root.expanded = true` first.
pub fn joinVisible(
    gpa: Allocator,
    root: *UserTree,
    comptime Node: type,
    opts: struct {
        skip_root: bool = true,
        header: ?[]const u8 = null,
    },
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    var first = true;
    if (opts.header) |h| {
        try out.appendSlice(gpa, h);
        first = false;
    }
    var it = VisibleIterator.init(root);
    while (it.next()) |item| {
        if (opts.skip_root and item.depth == 0) continue;
        if (!first) try out.append(gpa, '\n');
        first = false;
        if (comptime @hasField(Node, "text")) {
            try out.appendSlice(gpa, Node.fromTree(item.node).text);
        } else {
            const n = Node.fromTree(item.node);
            try out.appendSlice(gpa, n.name);
            if (n.is_dir) try out.append(gpa, '/');
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Free owned strings in a list or slice, then clear the list when
/// given one. Handles `[]u8` lines, `SnapEntry`-like structs with a
/// `.name` field, and `TreeTarget`-like unions with a `.file.path` or
/// `.hit.path` variant. Replaces the scattered `freeSnapshot` /
/// `freeSnapNames` / `freeLines` / `clearRows` helpers.
pub fn freeOwnedLines(gpa: Allocator, list_or_slice: anytype) void {
    const T = @TypeOf(list_or_slice);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice) {
                for (list_or_slice) |e| freeOwnedOne(gpa, e);
                return;
            }
            for (list_or_slice.items) |e| freeOwnedOne(gpa, e);
            list_or_slice.clearRetainingCapacity();
        },
        else => @compileError("freeOwnedLines expects a slice or *ArrayList"),
    }
}

fn freeOwnedOne(gpa: Allocator, e: anytype) void {
    const E = @TypeOf(e);
    if (E == []u8) {
        gpa.free(e);
        return;
    }
    switch (@typeInfo(E)) {
        .@"struct" => {
            if (comptime @hasField(E, "name")) {
                gpa.free(e.name);
            }
        },
        .@"union" => {
            if (comptime hasUnionField(E, "file")) {
                if (e == .file) gpa.free(e.file.path);
            }
            if (comptime hasUnionField(E, "hit")) {
                if (e == .hit) gpa.free(e.hit.path);
            }
        },
        else => {},
    }
}

fn hasUnionField(comptime U: type, comptime name: []const u8) bool {
    for (@typeInfo(U).@"union".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

const TestNode = struct {
    tree: UserTree,
    name: []const u8,

    fn init(name: []const u8) TestNode {
        return .{ .tree = UserTree.init(), .name = name };
    }

    fn fromTree(tree_ptr: *UserTree) *TestNode {
        return tree_ptr.cast(TestNode, "tree");
    }
};

test "usertree traversal and visible flattening" {
    var root_file = TestNode.init("src");
    var child_a = TestNode.init("main.zig");
    var child_b = TestNode.init("usertrees.zig");

    root_file.tree.appendChild(&child_a.tree);
    root_file.tree.appendChild(&child_b.tree);

    // Unexpanded root -> only root is yielded
    var iter = VisibleIterator.init(&root_file.tree);
    var count: usize = 0;
    while (iter.next()) |_| : (count += 1) {}
    try std.testing.expectEqual(@as(usize, 1), count);

    // Expand root -> root + 2 children yielded
    root_file.tree.toggleExpanded();
    iter = VisibleIterator.init(&root_file.tree);

    const item0 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 0), item0.depth);
    try std.testing.expectEqualStrings("src", TestNode.fromTree(item0.node).name);

    const item1 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 1), item1.depth);
    try std.testing.expectEqualStrings("main.zig", TestNode.fromTree(item1.node).name);

    const item2 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 1), item2.depth);
    try std.testing.expectEqualStrings("usertrees.zig", TestNode.fromTree(item2.node).name);

    try std.testing.expect(iter.next() == null);
}
