//! Tree diff planner. Pure snapshot math shared by the editable tree
//! views (`fs_usertree`, `buf_usertree`, and the buf save in `docs`):
//! parse buffer lines into desired entries, then plan old-versus-new
//! into deletes, renames, and creates. No IO, no buffers.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One listed entry. `name` is owned and has no trailing slash.
pub const SnapEntry = struct {
    name: []u8,
    is_dir: bool,
};

/// One parsed buffer line. `name` is borrowed, with no trailing slash.
pub const DesiredEntry = struct {
    name: []const u8,
    is_dir: bool,
};

/// Shared trailing-slash strip for both line parsers. Returns null for
/// lines that carry no intent: empty lines and a bare `/`.
fn stripSlash(line: []const u8) ?DesiredEntry {
    if (line.len == 0) return null;
    var is_dir = false;
    var name = line;
    if (std.mem.endsWith(u8, line, "/")) {
        if (line.len == 1) return null;
        is_dir = true;
        name = line[0 .. line.len - 1];
    }
    if (name.len == 0) return null;
    return .{ .name = name, .is_dir = is_dir };
}

/// Parse a buffer line into a desired entry. Returns null for lines that
/// carry no intent: empty lines, `/`, absolute paths, and anything with
/// `.` / `..` components (keeps every mutation inside the viewed tree).
pub fn parseDesiredLine(line: []const u8) ?DesiredEntry {
    const stripped = stripSlash(line) orelse return null;
    const name = stripped.name;
    if (std.mem.startsWith(u8, name, "/")) return null;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return null;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return null;
    }
    return stripped;
}

/// Parse a buf-list line into a desired entry. Unlike
/// `parseDesiredLine` (fs view, confined to one directory) this accepts
/// absolute paths and dot components: buf entries are registry paths
/// (`*welcome*`, relative or absolute files) that must round-trip.
/// Only empty lines and a bare `/` carry no intent.
pub fn parseBufsLine(line: []const u8) ?DesiredEntry {
    return stripSlash(line);
}

pub fn sameKey(a_name: []const u8, a_dir: bool, b_name: []const u8, b_dir: bool) bool {
    return a_dir == b_dir and std.mem.eql(u8, a_name, b_name);
}

pub fn sameBasename(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(a), std.fs.path.basename(b));
}

/// Filesystem operations derived from old snapshot vs new buffer lines.
pub const Plan = struct {
    deletes: std.ArrayList(usize) = .empty,
    renames: std.ArrayList(Rename) = .empty,
    creates: std.ArrayList(usize) = .empty,

    pub const Rename = struct { from: usize, to: usize };

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        self.deletes.deinit(gpa);
        self.renames.deinit(gpa);
        self.creates.deinit(gpa);
    }
};

/// Pure diff. Order is irrelevant for keeps, so reorders are no-ops.
/// Unmatched olds pair with unmatched news as renames: first by shared
/// basename (a move like `old.zig` to `keep/old.zig`), then the rest in
/// order. A same-name file/dir type change becomes delete + create.
/// When deletes and creates are otherwise indistinguishable the pairing
/// preserves content as a rename instead of destroying it.
pub fn planOps(
    gpa: Allocator,
    old: []const SnapEntry,
    new: []const DesiredEntry,
) !Plan {
    var plan: Plan = .{};
    errdefer plan.deinit(gpa);

    const matched = try gpa.alloc(bool, old.len);
    defer gpa.free(matched);
    @memset(matched, false);

    var newcomers = std.ArrayList(usize).empty;
    defer newcomers.deinit(gpa);

    for (new, 0..) |n, ni| {
        var dup = false;
        for (new[0..ni]) |prev| {
            if (sameKey(prev.name, prev.is_dir, n.name, n.is_dir)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        var found: ?usize = null;
        for (old, 0..) |o, oi| {
            if (!matched[oi] and sameKey(o.name, o.is_dir, n.name, n.is_dir)) {
                found = oi;
                break;
            }
        }
        if (found) |oi| {
            matched[oi] = true;
        } else {
            try newcomers.append(gpa, ni);
        }
    }

    var gone = std.ArrayList(usize).empty;
    defer gone.deinit(gpa);
    for (old, 0..) |_, oi| {
        if (!matched[oi]) try gone.append(gpa, oi);
    }

    const gone_used = try gpa.alloc(bool, gone.items.len);
    defer gpa.free(gone_used);
    @memset(gone_used, false);
    const new_done = try gpa.alloc(bool, newcomers.items.len);
    defer gpa.free(new_done);
    @memset(new_done, false);

    // Pass 1: shared basenames are moves.
    for (newcomers.items, 0..) |ni, k| {
        for (gone.items, 0..) |oi, gi| {
            if (gone_used[gi]) continue;
            if (old[oi].is_dir != new[ni].is_dir) continue;
            if (!sameBasename(old[oi].name, new[ni].name)) continue;
            try plan.renames.append(gpa, .{ .from = oi, .to = ni });
            gone_used[gi] = true;
            new_done[k] = true;
            break;
        }
    }

    // Pass 2: the rest pair in order.
    var rest_new = std.ArrayList(usize).empty;
    defer rest_new.deinit(gpa);
    for (newcomers.items, 0..) |ni, k| {
        if (!new_done[k]) try rest_new.append(gpa, ni);
    }
    var rest_gone = std.ArrayList(usize).empty;
    defer rest_gone.deinit(gpa);
    for (gone.items, 0..) |oi, gi| {
        if (!gone_used[gi]) try rest_gone.append(gpa, oi);
    }

    var gi: usize = 0;
    for (rest_new.items) |ni| {
        if (gi >= rest_gone.items.len) {
            try plan.creates.append(gpa, ni);
            continue;
        }
        const from = rest_gone.items[gi];
        if (sameBasename(old[from].name, new[ni].name) and old[from].is_dir != new[ni].is_dir) {
            try plan.deletes.append(gpa, from);
            try plan.creates.append(gpa, ni);
        } else {
            try plan.renames.append(gpa, .{ .from = from, .to = ni });
        }
        gi += 1;
    }
    while (gi < rest_gone.items.len) : (gi += 1) {
        try plan.deletes.append(gpa, rest_gone.items[gi]);
    }
    return plan;
}

test "parseDesiredLine accepts names and guards escapes" {
    try std.testing.expect(parseDesiredLine("") == null);
    try std.testing.expect(parseDesiredLine("/") == null);
    try std.testing.expect(parseDesiredLine("/abs") == null);
    try std.testing.expect(parseDesiredLine("..") == null);
    try std.testing.expect(parseDesiredLine("../x") == null);
    try std.testing.expect(parseDesiredLine("a/../../x") == null);
    try std.testing.expect(parseDesiredLine("a//b") == null);

    const f = parseDesiredLine("main.zig").?;
    try std.testing.expectEqualStrings("main.zig", f.name);
    try std.testing.expect(!f.is_dir);

    const d = parseDesiredLine("src/").?;
    try std.testing.expectEqualStrings("src", d.name);
    try std.testing.expect(d.is_dir);

    const m = parseDesiredLine("sub/new.zig").?;
    try std.testing.expectEqualStrings("sub/new.zig", m.name);
    try std.testing.expect(!m.is_dir);
}

test "parseBufsLine round-trips registry paths" {
    try std.testing.expect(parseBufsLine("") == null);
    try std.testing.expect(parseBufsLine("/") == null);
    // Unlike the fs view, absolute paths, dot parts, and scratch
    // titles are real buf entries and must survive a save.
    const abs = parseBufsLine("/abs/path.txt").?;
    try std.testing.expectEqualStrings("/abs/path.txt", abs.name);
    try std.testing.expect(!abs.is_dir);
    const dot = parseBufsLine("a/../b").?;
    try std.testing.expectEqualStrings("a/../b", dot.name);
    const w = parseBufsLine("*welcome*").?;
    try std.testing.expectEqualStrings("*welcome*", w.name);
    try std.testing.expect(!w.is_dir);
    const d = parseBufsLine("/abs/dir/").?;
    try std.testing.expectEqualStrings("/abs/dir", d.name);
    try std.testing.expect(d.is_dir);
}

test "planOps pairs a move by shared basename" {
    const gpa = std.testing.allocator;
    var old = std.ArrayList(SnapEntry).empty;
    defer {
        for (old.items) |e| gpa.free(e.name);
        old.deinit(gpa);
    }
    for ([_]struct { []const u8, bool }{ .{ "gone.zig", false }, .{ "old.zig", false } }) |e| {
        try old.append(gpa, .{ .name = try gpa.dupe(u8, e[0]), .is_dir = e[1] });
    }

    const new = [_]DesiredEntry{
        .{ .name = "keep/old.zig", .is_dir = false },
        .{ .name = "new.zig", .is_dir = false },
    };
    var plan = try planOps(gpa, old.items, &new);
    defer plan.deinit(gpa);
    // The move is detected by basename. The leftover pairs as a
    // content-preserving rename rather than delete plus create.
    try std.testing.expectEqual(@as(usize, 0), plan.deletes.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.creates.items.len);
    try std.testing.expectEqual(@as(usize, 2), plan.renames.items.len);
    try std.testing.expectEqualStrings("old.zig", old.items[plan.renames.items[0].from].name);
    try std.testing.expectEqualStrings("keep/old.zig", new[plan.renames.items[0].to].name);
    try std.testing.expectEqualStrings("gone.zig", old.items[plan.renames.items[1].from].name);
    try std.testing.expectEqualStrings("new.zig", new[plan.renames.items[1].to].name);
}

test "planOps deletes the missing and creates the added" {
    const gpa = std.testing.allocator;
    var old = std.ArrayList(SnapEntry).empty;
    defer {
        for (old.items) |e| gpa.free(e.name);
        old.deinit(gpa);
    }
    for ([_]struct { []const u8, bool }{ .{ "keep", false }, .{ "drop", false } }) |e| {
        try old.append(gpa, .{ .name = try gpa.dupe(u8, e[0]), .is_dir = e[1] });
    }

    const gone = [_]DesiredEntry{.{ .name = "keep", .is_dir = false }};
    var del = try planOps(gpa, old.items, &gone);
    defer del.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), del.deletes.items.len);
    try std.testing.expectEqualStrings("drop", old.items[del.deletes.items[0]].name);

    const more = [_]DesiredEntry{
        .{ .name = "keep", .is_dir = false },
        .{ .name = "drop", .is_dir = false },
        .{ .name = "fresh", .is_dir = false },
    };
    var add = try planOps(gpa, old.items, &more);
    defer add.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), add.creates.items.len);
    try std.testing.expectEqualStrings("fresh", more[add.creates.items[0]].name);
}

test "planOps turns a same-name type change into delete plus create" {
    const gpa = std.testing.allocator;
    var old = std.ArrayList(SnapEntry).empty;
    defer {
        for (old.items) |e| gpa.free(e.name);
        old.deinit(gpa);
    }
    try old.append(gpa, .{ .name = try gpa.dupe(u8, "foo"), .is_dir = false });

    const new = [_]DesiredEntry{.{ .name = "foo", .is_dir = true }};
    var plan = try planOps(gpa, old.items, &new);
    defer plan.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), plan.deletes.items.len);
    try std.testing.expectEqual(@as(usize, 1), plan.creates.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.renames.items.len);
}
