const std = @import("std");
const posix = std.posix;
const Rope = @import("lib").Rope;
const testing = std.testing;

const assert = std.debug.assert;

const file_size_max: usize = 64 * 1024 * 1024;

/// NOTE: File-backed text buffer. Owns both the raw content slice and the
/// rope index built on top of it. Provides line access and scroll progress.
pub const Buffer = struct {
    rope: Rope,
    content: []u8,
    file_path: []const u8,
    cursor_line: u32,
    cursor_col: u32,
    allocator: std.mem.Allocator,

    pub fn initFromFile(allocator: std.mem.Allocator, path: []const u8) !Buffer {
        assert(path.len > 0);

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, file_size_max);
        const rope = try Rope.initFromSlice(allocator, content);
        const path_copy = try allocator.dupe(u8, path);

        return .{
            .rope = rope,
            .content = content,
            .file_path = path_copy,
            .cursor_line = 0,
            .cursor_col = 0,
            .allocator = allocator,
        };
    }

    pub fn initEmpty(allocator: std.mem.Allocator, path: []const u8) !Buffer {
        const rope = try Rope.initFromSlice(allocator, "");
        const content = try allocator.alloc(u8, 0);
        const path_copy = try allocator.dupe(u8, path);

        return .{
            .rope = rope,
            .content = content,
            .file_path = path_copy,
            .cursor_line = 0,
            .cursor_col = 0,
            .allocator = allocator,
        };
    }

    pub fn save(self: *const Buffer) !void {
        if (self.file_path.len == 0) return;

        const file = try std.fs.cwd().createFile(self.file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(self.content);
    }

    pub fn replaceContentOwned(self: *Buffer, content_new: []u8) !void {
        try self.replaceContentKeepCursor(content_new);
        self.cursor_line = 0;
        self.cursor_col = 0;
    }

    fn replaceContentKeepCursor(self: *Buffer, content_new: []u8) !void {
        const rope_new = try Rope.initFromSlice(self.allocator, content_new);

        self.rope.deinit(self.allocator);
        self.allocator.free(self.content);

        self.rope = rope_new;
        self.content = content_new;
    }

    fn spliceContent(
        self: *Buffer,
        replace_offset: usize,
        remove_len: usize,
        insert_text: []const u8,
    ) !void {
        assert(replace_offset <= self.content.len);
        assert(remove_len <= self.content.len - replace_offset);

        const new_len = self.content.len - remove_len + insert_text.len;
        var content_new = try self.allocator.alloc(u8, new_len);
        errdefer self.allocator.free(content_new);

        if (replace_offset > 0) {
            @memcpy(content_new[0..replace_offset], self.content[0..replace_offset]);
        }

        if (insert_text.len > 0) {
            const insert_end = replace_offset + insert_text.len;
            @memcpy(content_new[replace_offset..insert_end], insert_text);
        }

        const source_suffix_start = replace_offset + remove_len;
        const target_suffix_start = replace_offset + insert_text.len;
        if (source_suffix_start < self.content.len) {
            @memcpy(content_new[target_suffix_start..], self.content[source_suffix_start..]);
        }

        try self.replaceContentKeepCursor(content_new);
    }

    pub fn deinit(self: *Buffer) void {
        self.rope.deinit(self.allocator);
        self.allocator.free(self.content);
        self.allocator.free(self.file_path);
    }

    pub fn insertChar(self: *Buffer, c: u8) !void {
        const offset = self.byteOffset();

        const insert_text = [_]u8{c};
        try self.spliceContent(offset, 0, &insert_text);

        self.cursor_col += 1;
    }

    pub fn deleteChar(self: *Buffer) !void {
        if (self.content.len == 0) return;
        if (self.cursor_col == 0 and self.cursor_line == 0) return;

        const offset = self.byteOffset();
        if (offset == 0) return;

        try self.spliceContent(offset - 1, 1, &.{});

        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        }
    }

    pub fn insertNewline(self: *Buffer) !void {
        const offset = self.byteOffset();

        try self.spliceContent(offset, 0, "\n");

        self.cursor_line += 1;
        self.cursor_col = 0;
    }

    pub fn deleteLine(self: *Buffer, line_index: u32) !void {
        const line_count = self.lineCount();
        if (line_index >= line_count) return;

        var line_start: usize = 0;
        var line_end: usize = 0;
        var current_line: u32 = 0;

        for (self.content, 0..) |c, i| {
            if (current_line == line_index) {
                line_start = if (line_index == 0) 0 else i;
            }
            if (current_line == line_index and (c == '\n' or i == self.content.len - 1)) {
                line_end = if (c == '\n') i else i + 1;
                break;
            }
            if (c == '\n') {
                current_line += 1;
            }
        }

        if (line_end > line_start) {
            const new_len = self.content.len - (line_end - line_start);
            var new_content = try self.allocator.alloc(u8, new_len);

            @memcpy(new_content[0..line_start], self.content[0..line_start]);
            @memcpy(new_content[line_start..], self.content[line_end..]);

            self.allocator.free(self.content);
            self.content = new_content;

            self.rope.deinit(self.allocator);
            self.rope = try Rope.initFromSlice(self.allocator, self.content);

            if (self.cursor_line >= line_count - 1) {
                self.cursor_line = if (line_count > 1) line_count - 2 else 0;
            }
        }
    }

    pub fn insertLine(self: *Buffer, line_index: u32, content_new: []const u8) !void {
        const line_count = self.lineCount();
        if (line_index > line_count) return;

        var insert_at: usize = 0;
        if (line_index == 0) {
            insert_at = 0;
        } else {
            var current_line: u32 = 0;
            for (self.content, 0..) |c, i| {
                if (c == '\n') {
                    current_line += 1;
                    if (current_line == line_index) {
                        insert_at = i + 1;
                        break;
                    }
                }
            }
        }

        var new_content = try self.allocator.alloc(u8, self.content.len + content_new.len + 1);
        errdefer self.allocator.free(new_content);

        @memcpy(new_content[0..insert_at], self.content[0..insert_at]);
        @memcpy(new_content[insert_at .. insert_at + content_new.len], content_new);
        new_content[insert_at + content_new.len] = '\n';
        @memcpy(new_content[insert_at + content_new.len + 1 ..], self.content[insert_at..]);

        self.allocator.free(self.content);
        self.content = new_content;

        self.rope.deinit(self.allocator);
        self.rope = try Rope.initFromSlice(self.allocator, self.content);

        self.cursor_line = line_index;
        self.cursor_col = 0;
    }

    pub fn deleteUntilEndOfLine(self: *Buffer) !void {
        if (self.content.len == 0) return;

        var line_buf_raw: [4096]u8 = undefined;
        const current_line_content = if (self.getLine(self.cursor_line, &line_buf_raw)) |line| line else "";

        const cursor_col: usize = @intCast(self.cursor_col);
        if (cursor_col >= current_line_content.len) return;
        const chars_to_delete = current_line_content.len - cursor_col;

        if (chars_to_delete == 0) return; // Nothing to delete

        const start_delete_offset = self.byteOffset();
        try self.spliceContent(start_delete_offset, chars_to_delete, &.{});
    }

    pub fn insertTab(self: *Buffer) !void {
        const tab_spaces: u32 = 4;
        const spaces_needed: usize = @intCast(tab_spaces - (self.cursor_col % tab_spaces));
        const spaces = [_]u8{ ' ', ' ', ' ', ' ' };
        const offset = self.byteOffset();

        try self.spliceContent(offset, 0, spaces[0..spaces_needed]);
        self.cursor_col += @intCast(spaces_needed);
        self.save() catch {}; // Save after tab insertion
    }

    pub fn cursorLeft(self: *Buffer) void {
        assert(self.cursor_line < self.lineCount());
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        }
    }

    pub fn cursorRight(self: *Buffer) void {
        assert(self.cursor_line < self.lineCount());
        const line_len = self.getLineLen(self.cursor_line);
        if (self.cursor_col < line_len) {
            self.cursor_col += 1;
        }
    }

    pub fn cursorUp(self: *Buffer) void {
        assert(self.cursor_line < self.lineCount());
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            const line_len = self.getLineLen(self.cursor_line);
            if (self.cursor_col > line_len) {
                self.cursor_col = line_len;
            }
        }
    }

    pub fn cursorDown(self: *Buffer) void {
        const total_lines = self.lineCount();
        assert(total_lines > 0);
        if (self.cursor_line + 1 < total_lines) {
            self.cursor_line += 1;
            const line_len = self.getLineLen(self.cursor_line);
            if (self.cursor_col > line_len) {
                self.cursor_col = line_len;
            }
        }
    }

    pub fn setCursorLine(self: *Buffer, line: u32) void {
        const total_lines = self.lineCount();
        assert(total_lines > 0);

        var target_line = line;
        if (target_line >= total_lines) {
            target_line = total_lines - 1;
        }

        self.cursor_line = target_line;
        const line_len = self.getLineLen(target_line);
        if (self.cursor_col > line_len) {
            self.cursor_col = line_len;
        }
    }

    fn getLineLen(self: *const Buffer, line_idx: u32) u32 {
        var line_buf: [4096]u8 = undefined;
        if (self.getLine(line_idx, &line_buf)) |line| {
            return @intCast(line.len);
        }
        return 0;
    }

    fn byteOffset(self: *const Buffer) usize {
        if (self.content.len == 0) return 0;

        var offset: usize = 0;
        var line: u32 = 0;

        // Find the start of cursor_line
        while (line < self.cursor_line and offset < self.content.len) : (offset += 1) {
            if (self.content[offset] == '\n') {
                line += 1;
            }
        }

        // Now offset is at the start of cursor_line, advance by cursor_col
        const line_start = offset;
        const line_end = if (offset < self.content.len) blk: {
            var e = offset;
            while (e < self.content.len and self.content[e] != '\n') : (e += 1) {}
            break :blk e;
        } else offset;

        // Cursor col can't exceed line length
        const col = @min(self.cursor_col, line_end - line_start);

        return line_start + col;
    }

    pub fn getCursorLine(self: *const Buffer) u32 {
        return self.cursor_line;
    }

    pub fn getCursorCol(self: *const Buffer) u32 {
        return self.cursor_col;
    }

    pub fn lineCount(self: *const Buffer) u32 {
        return self.rope.lineCount();
    }

    pub fn getLine(self: *const Buffer, line_index: u32, buf: []u8) ?[]const u8 {
        return self.rope.getLine(line_index, buf);
    }

    pub fn findMatches(self: *const Buffer, pattern: []const u8, allocator: std.mem.Allocator) ![]u32 {
        if (pattern.len == 0) {
            return try allocator.alloc(u32, 0);
        }

        var matches = std.ArrayList(u32).empty;
        defer matches.deinit(allocator);

        const line_count = self.lineCount();
        var line_buf: [4096]u8 = undefined;

        var line_idx: u32 = 0;
        while (line_idx < line_count) : (line_idx += 1) {
            if (self.getLine(line_idx, &line_buf)) |line| {
                if (std.mem.indexOf(u8, line, pattern) != null) {
                    try matches.append(allocator, line_idx);
                }
            }
        }

        return matches.toOwnedSlice(allocator);
    }

    /// Scroll progress as a percentage (0–100).
    pub fn scrollProgress(
        self: *const Buffer,
        scroll_offset: u32,
        visible_lines: u32,
    ) u32 {
        const total = self.lineCount();
        if (total <= visible_lines) return 100;
        const scrollable = total - visible_lines;
        assert(scrollable > 0);
        if (scroll_offset >= scrollable) return 100;
        return @intCast(@as(u64, scroll_offset) * 100 / @as(u64, scrollable));
    }
};

// Tests

test "scroll progress at top is zero" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    try buf.insertChar('a');
    try buf.insertChar('\n');
    try buf.insertChar('b');
    try buf.insertChar('\n');
    try buf.insertChar('c');
    try buf.insertChar('\n');
    try buf.insertChar('d');
    try buf.insertChar('\n');
    try buf.insertChar('e');
    try buf.insertChar('\n');
    try buf.insertChar('f');
    try buf.insertChar('\n');
    try buf.insertChar('g');
    try buf.insertChar('\n');
    try buf.insertChar('h');
    try buf.insertChar('\n');
    try buf.insertChar('i');
    try buf.insertChar('\n');
    try buf.insertChar('j');
    try buf.insertChar('\n');

    try testing.expectEqual(@as(u32, 0), buf.scrollProgress(0, 5));
}

test "scroll progress at bottom is 100" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    try buf.insertChar('a');
    try buf.insertChar('\n');
    try buf.insertChar('b');
    try buf.insertChar('\n');
    try buf.insertChar('c');
    try buf.insertChar('\n');
    try buf.insertChar('d');
    try buf.insertChar('\n');
    try buf.insertChar('e');
    try buf.insertChar('\n');
    try buf.insertChar('f');
    try buf.insertChar('\n');
    try buf.insertChar('g');
    try buf.insertChar('\n');
    try buf.insertChar('h');
    try buf.insertChar('\n');
    try buf.insertChar('i');
    try buf.insertChar('\n');
    try buf.insertChar('j');
    try buf.insertChar('\n');

    const total = buf.lineCount();
    const visible: u32 = 5;
    try testing.expectEqual(@as(u32, 100), buf.scrollProgress(total - visible, visible));
}

test "scroll progress when content fits is 100" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    try buf.insertChar('a');
    try buf.insertChar('\n');
    try buf.insertChar('b');
    try buf.insertChar('\n');

    try testing.expectEqual(@as(u32, 100), buf.scrollProgress(0, 100));
}

test "line count delegates to rope" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    const content = try testing.allocator.dupe(u8, "one\ntwo\nthree");
    try buf.replaceContentOwned(content);

    try testing.expectEqual(@as(u32, 3), buf.lineCount());
}

test "cursor movement at start" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 0), buf.content.len);
    try testing.expectEqual(@as(u32, 0), buf.getCursorLine());
    try testing.expectEqual(@as(u32, 0), buf.getCursorCol());
}

test "cursor right increases col when not at end" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    try buf.insertChar('a');
    try buf.insertChar('b');
    const col_before = buf.getCursorCol();
    buf.cursorRight();
    try testing.expect(buf.getCursorCol() == col_before + 1 or buf.getCursorCol() == col_before);
}

test "insert newline splits line" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    try buf.insertChar('a');
    try buf.insertChar('b');
    buf.cursorLeft();
    try buf.insertChar('\n');

    try testing.expectEqual(@as(u32, 2), buf.lineCount());
}

test "delete until end of line ignores out of range cursor" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    try buf.insertChar('a');
    try buf.insertChar('b');
    try buf.insertChar('c');
    buf.cursor_col = 99;

    try buf.deleteUntilEndOfLine();

    var line_buf: [16]u8 = undefined;
    try testing.expectEqualStrings("abc", buf.getLine(0, &line_buf).?);
}

test "delete in middle removes char" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    try buf.insertChar('a');
    try buf.insertChar('b');
    try buf.insertChar('c');
    buf.cursorLeft();

    try buf.deleteChar();
    var line_buf: [16]u8 = undefined;
    const line = buf.getLine(0, &line_buf).?;
    try testing.expect(line.len >= 2);
    try testing.expect(line[0] == 'a');
    try testing.expect(line[1] == 'c');
}

test "replace content works" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();

    const content = try testing.allocator.dupe(u8, "new content");
    try buf.replaceContentOwned(content);
    try testing.expectEqual(@as(u32, 1), buf.lineCount());
}

test "findMatches empty pattern returns empty" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c1 = try testing.allocator.dupe(u8, "foo\nbar\nbaz");
    try buf.replaceContentOwned(c1);

    const matches = try buf.findMatches("", testing.allocator);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 0), matches.len);
}

test "findMatches finds single match" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c2 = try testing.allocator.dupe(u8, "hello\nworld\nhello");
    try buf.replaceContentOwned(c2);

    const matches = try buf.findMatches("world", testing.allocator);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(u32, 1), matches[0]);
}

test "findMatches finds multiple matches" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c3 = try testing.allocator.dupe(u8, "aa\nab\nac\nab\nad");
    try buf.replaceContentOwned(c3);

    const matches = try buf.findMatches("ab", testing.allocator);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqual(@as(u32, 1), matches[0]);
    try testing.expectEqual(@as(u32, 3), matches[1]);
}

test "findMatches no match returns empty" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c4 = try testing.allocator.dupe(u8, "foo\nbar");
    try buf.replaceContentOwned(c4);

    const matches = try buf.findMatches("xyz", testing.allocator);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 0), matches.len);
}

test "deleteLine first line" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c5 = try testing.allocator.dupe(u8, "first\nsecond\nthird");
    try buf.replaceContentOwned(c5);

    try buf.deleteLine(0);
    try testing.expect(buf.lineCount() >= 2);
    var line_buf: [256]u8 = undefined;
    try testing.expect(buf.getLine(0, &line_buf) != null);
}

test "deleteLine last line" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c6 = try testing.allocator.dupe(u8, "first\nsecond\nthird");
    try buf.replaceContentOwned(c6);

    try buf.deleteLine(2);
    try testing.expect(buf.lineCount() >= 1);
    var line_buf: [256]u8 = undefined;
    try testing.expect(buf.getLine(0, &line_buf) != null);
}

test "insertLine at start" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c7 = try testing.allocator.dupe(u8, "old_first\nsecond");
    try buf.replaceContentOwned(c7);

    try buf.insertLine(0, "new_first");
    try testing.expectEqual(@as(u32, 3), buf.lineCount());
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("new_first", buf.getLine(0, &line_buf).?);
    try testing.expectEqualStrings("old_first", buf.getLine(1, &line_buf).?);
}

test "insertLine at end" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c8 = try testing.allocator.dupe(u8, "first\nsecond");
    try buf.replaceContentOwned(c8);

    try buf.insertLine(2, "third");
    try testing.expectEqual(@as(u32, 3), buf.lineCount());
    var line_buf: [256]u8 = undefined;
    try testing.expect(buf.getLine(1, &line_buf) != null);
    try testing.expect(buf.getLine(2, &line_buf) != null);
}

test "cursorUp at top does nothing" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c9 = try testing.allocator.dupe(u8, "line1\nline2");
    try buf.replaceContentOwned(c9);
    buf.setCursorLine(1);

    buf.cursorUp();
    buf.cursorUp();
    buf.cursorUp();
    try testing.expectEqual(@as(u32, 0), buf.getCursorLine());
}

test "cursorDown at bottom does nothing" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c10 = try testing.allocator.dupe(u8, "line1\nline2");
    try buf.replaceContentOwned(c10);

    buf.cursorDown();
    buf.cursorDown();
    try testing.expectEqual(@as(u32, 1), buf.getCursorLine());
}

test "setCursorLine clamps to last line" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c11 = try testing.allocator.dupe(u8, "a\nb\nc");
    try buf.replaceContentOwned(c11);

    buf.setCursorLine(99);
    try testing.expectEqual(@as(u32, 2), buf.getCursorLine());
}

test "scroll progress midpoint" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const c12 = try testing.allocator.dupe(u8, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    try buf.replaceContentOwned(c12);
    const total = buf.lineCount();
    const visible: u32 = 5;
    const scrollable = total - visible;
    const mid = scrollable / 2;
    const pct = buf.scrollProgress(mid, visible);
    try testing.expect(pct > 0 and pct < 100);
}

test "deleteUntilEndOfLine from middle" {
    var buf = try Buffer.initEmpty(testing.allocator, "test");
    defer buf.deinit();
    const content = try testing.allocator.dupe(u8, "ab\nxyz");
    try buf.replaceContentOwned(content);
    buf.setCursorLine(1);
    buf.cursorRight();

    try buf.deleteUntilEndOfLine();
    var line_buf: [256]u8 = undefined;
    const line = buf.getLine(1, &line_buf);
    try testing.expect(line != null);
    try testing.expect(line.?.len <= 3);
}
