const std = @import("std");
const testing = std.testing;

const assert = std.debug.assert;

/// NOTE: Max bytes in a leaf node. Splits above this threshold.
const leaf_size_max: u32 = 1024;

/// NOTE: Hard ceiling on tree depth to bound stack usage during traversal.
/// Sufficient for files up to leaf_size_max * 2^depth_max bytes (~32 TiB).
const depth_max: u32 = 45;

const Node = struct {
    len: u32,
    data: union(enum) {
        leaf: []const u8,
        branch: struct { left: *Node, right: *Node },
    },
};

/// Immutable rope data structure backed by a balanced binary tree.
/// Line offsets are precomputed on construction for O(1) line lookup.
pub const Rope = struct {
    root: *Node,
    line_offsets: []const u32,
    total_len: u32,

    pub fn initFromSlice(allocator: std.mem.Allocator, text: []const u8) !Rope {
        assert(text.len <= std.math.maxInt(u32));
        const len: u32 = @intCast(text.len);

        const root = try buildTree(allocator, text, 0);

        var offsets: std.ArrayList(u32) = .empty;
        defer offsets.deinit(allocator);

        try offsets.append(allocator, 0);
        for (text, 0..) |c, i| {
            if (c == '\n' and i + 1 < text.len) {
                try offsets.append(allocator, @intCast(i + 1));
            }
        }

        return .{
            .root = root,
            .line_offsets = try offsets.toOwnedSlice(allocator),
            .total_len = len,
        };
    }

    pub fn deinit(self: *Rope, allocator: std.mem.Allocator) void {
        freeTree(allocator, self.root);
        allocator.free(self.line_offsets);
    }

    pub fn byteLen(self: *const Rope) u32 {
        return self.total_len;
    }

    pub fn lineCount(self: *const Rope) u32 {
        return @intCast(self.line_offsets.len);
    }

    /// Copy line at `line_index` into `buf`. Returns the filled slice, or
    /// null when `line_index` is out of bounds.
    pub fn getLine(self: *const Rope, line_index: u32, buf: []u8) ?[]const u8 {
        if (line_index >= self.line_offsets.len) return null;

        const start = self.line_offsets[line_index];
        const raw_end: u32 = if (line_index + 1 < self.line_offsets.len)
            self.line_offsets[line_index + 1] - 1
        else
            self.total_len;

        // INFO: Strip trailing newline on the final line when present.
        const end: u32 = if (raw_end > start and raw_end == self.total_len) blk: {
            var tmp: [1]u8 = undefined;
            copyBytes(self.root, start, raw_end, &tmp, 0, raw_end - 1);
            break :blk if (tmp[0] == '\n') raw_end - 1 else raw_end;
        } else raw_end;

        if (end <= start) return buf[0..0];

        const n: u32 = @intCast(@min(end - start, buf.len));
        copyBytes(self.root, 0, self.total_len, buf[0..n], 0, start);
        return buf[0..n];
    }
};

// Tree construction (bounded recursion).
fn buildTree(allocator: std.mem.Allocator, text: []const u8, depth: u32) !*Node {
    assert(depth < depth_max);

    if (text.len <= leaf_size_max) {
        const node = try allocator.create(Node);
        node.* = .{ .len = @intCast(text.len), .data = .{ .leaf = text } };
        return node;
    }

    var mid = text.len / 2;
    // INFO: Prefer splitting on a newline boundary near the midpoint.
    if (std.mem.indexOfScalar(u8, text[mid..], '\n')) |off| {
        if (off < leaf_size_max) mid = mid + off + 1;
    } else if (std.mem.lastIndexOfScalar(u8, text[0..mid], '\n')) |off| {
        mid = off + 1;
    }

    const left = try buildTree(allocator, text[0..mid], depth + 1);
    const right = try buildTree(allocator, text[mid..], depth + 1);

    const node = try allocator.create(Node);
    node.* = .{
        .len = @intCast(text.len),
        .data = .{ .branch = .{ .left = left, .right = right } },
    };
    return node;
}

fn freeTree(allocator: std.mem.Allocator, node: *Node) void {
    if (node.data == .branch) {
        const b = node.data.branch;
        freeTree(allocator, b.left);
        freeTree(allocator, b.right);
    }
    allocator.destroy(node);
}

/// Copy `dest.len` bytes starting at rope offset `start` into `dest`.
fn copyBytes(
    node: *const Node,
    node_start: u32,
    node_end: u32,
    dest: []u8,
    dest_offset: u32,
    start: u32,
) void {
    if (dest.len == 0) return;
    _ = node_end;
    _ = dest_offset;

    switch (node.data) {
        .leaf => |slice| {
            const local = start - node_start;
            @memcpy(dest, slice[local .. local + dest.len]);
        },
        .branch => |b| {
            const left_end = node_start + b.left.len;
            if (start + dest.len <= left_end) {
                copyBytes(b.left, node_start, left_end, dest, 0, start);
            } else if (start >= left_end) {
                copyBytes(b.right, left_end, left_end + b.right.len, dest, 0, start);
            } else {
                const from_left = left_end - start;
                copyBytes(b.left, node_start, left_end, dest[0..from_left], 0, start);
                copyBytes(b.right, left_end, left_end + b.right.len, dest[from_left..], 0, left_end);
            }
        },
    }
}

// Tests

test "empty rope" {
    var rope = try Rope.initFromSlice(testing.allocator, "");
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), rope.byteLen());
    try testing.expectEqual(@as(u32, 1), rope.lineCount());

    var buf: [64]u8 = undefined;
    const line = rope.getLine(0, &buf);
    try testing.expect(line != null);
    try testing.expectEqual(@as(usize, 0), line.?.len);
}

test "single line" {
    const text = "hello world";
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 11), rope.byteLen());
    try testing.expectEqual(@as(u32, 1), rope.lineCount());

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello world", rope.getLine(0, &buf).?);
}

test "multiple lines" {
    const text = "aaa\nbbb\nccc";
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), rope.lineCount());

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("aaa", rope.getLine(0, &buf).?);
    try testing.expectEqualStrings("bbb", rope.getLine(1, &buf).?);
    try testing.expectEqualStrings("ccc", rope.getLine(2, &buf).?);
}

test "trailing newline" {
    const text = "line1\nline2\n";
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), rope.lineCount());

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("line1", rope.getLine(0, &buf).?);
    try testing.expectEqualStrings("line2", rope.getLine(1, &buf).?);
}

test "out-of-bounds line returns null" {
    const text = "only one line";
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    var buf: [64]u8 = undefined;
    try testing.expect(rope.getLine(1, &buf) == null);
    try testing.expect(rope.getLine(99, &buf) == null);
}

test "single character" {
    var rope = try Rope.initFromSlice(testing.allocator, "x");
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), rope.byteLen());
    try testing.expectEqual(@as(u32, 1), rope.lineCount());

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("x", rope.getLine(0, &buf).?);
}

test "only newlines" {
    const text = "\n\n\n";
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), rope.lineCount());

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", rope.getLine(0, &buf).?);
    try testing.expectEqualStrings("", rope.getLine(1, &buf).?);
    try testing.expectEqualStrings("", rope.getLine(2, &buf).?);
}

test "long text forces tree split" {
    // NOTE: Build a string larger than leaf_size_max to exercise branching.
    const line = "abcdefghijklmnopqrstuvwxyz0123456789\n";
    const text = line ** 40; // 40 * 37 = 1480 bytes > 1024
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, @intCast(text.len)), rope.byteLen());
    try testing.expect(rope.lineCount() > 1);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz0123456789", rope.getLine(0, &buf).?);
}

test "getLine with small buffer truncates" {
    const text = "hello world";
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    var buf: [3]u8 = undefined;
    const line = rope.getLine(0, &buf);
    try testing.expect(line != null);
    try testing.expectEqual(@as(usize, 3), line.?.len);
    try testing.expectEqualStrings("hel", line.?);
}

test "lineCount single line no newline" {
    var rope = try Rope.initFromSlice(testing.allocator, "no newline");
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), rope.lineCount());
}

test "byteLen matches input length" {
    const text = "abc\n\ndef\n";
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, text.len), rope.byteLen());
}

test "getLine middle line" {
    const text = "first\nsecond\nthird";
    var rope = try Rope.initFromSlice(testing.allocator, text);
    defer rope.deinit(testing.allocator);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("second", rope.getLine(1, &buf).?);
}

test "empty string has one line" {
    var rope = try Rope.initFromSlice(testing.allocator, "");
    defer rope.deinit(testing.allocator);

    var buf: [1]u8 = undefined;
    const line = rope.getLine(0, &buf);
    try testing.expect(line != null);
    try testing.expectEqual(@as(usize, 0), line.?.len);
}
