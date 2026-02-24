pub const Buffer = @import("buffer.zig").Buffer;
pub const input = @import("input.zig");
pub const syntax = @import("syntax.zig");

pub const BufferManager = struct {
    buffers: []Buffer,
    active_index: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BufferManager {
        return .{
            .buffers = &.{},
            .active_index = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BufferManager) void {
        for (self.buffers) |*buf| {
            buf.deinit();
        }
        self.allocator.free(self.buffers);
    }

    pub fn addBuffer(self: *BufferManager, path: []const u8) !void {
        var buf = try Buffer.initFromFile(self.allocator, path);
        errdefer buf.deinit();
        const new_buffers = try self.allocator.realloc(self.buffers, self.buffers.len + 1);
        self.buffers = new_buffers;
        self.buffers[self.buffers.len - 1] = buf;
    }

    pub fn addEmptyBuffer(self: *BufferManager, path: []const u8) !void {
        var buf = try Buffer.initEmpty(self.allocator, path);
        errdefer buf.deinit();
        const new_buffers = try self.allocator.realloc(self.buffers, self.buffers.len + 1);
        self.buffers = new_buffers;
        self.buffers[self.buffers.len - 1] = buf;
    }

    pub fn closeActive(self: *BufferManager) void {
        if (self.buffers.len == 0) return;
        if (self.active_index >= self.buffers.len) return;

        self.buffers[self.active_index].deinit();

        if (self.buffers.len == 1) {
            self.allocator.free(self.buffers);
            self.buffers = &.{};
        } else {
            var new_buffers = self.allocator.alloc(Buffer, self.buffers.len - 1) catch return;
            var i: usize = 0;
            var j: usize = 0;
            while (i < self.buffers.len) : (i += 1) {
                if (i != self.active_index) {
                    new_buffers[j] = self.buffers[i];
                    j += 1;
                }
            }
            self.allocator.free(self.buffers);
            self.buffers = new_buffers;

            // Adjust active_index
            if (self.buffers.len == 0) {
                self.active_index = 0;
            } else if (self.active_index >= self.buffers.len) {
                self.active_index = self.buffers.len - 1;
            }
        }
    }

    pub fn getActive(self: *const BufferManager) ?*Buffer {
        if (self.buffers.len == 0) return null;
        if (self.active_index >= self.buffers.len) return null;
        return &self.buffers[self.active_index];
    }

    pub fn nextBuffer(self: *BufferManager) void {
        if (self.buffers.len > 0) {
            self.active_index = (self.active_index + 1) % self.buffers.len;
        }
    }

    pub fn prevBuffer(self: *BufferManager) void {
        if (self.buffers.len > 0) {
            if (self.active_index == 0) {
                self.active_index = self.buffers.len - 1;
            } else {
                self.active_index -= 1;
            }
        }
    }

    pub fn bufferCount(self: *const BufferManager) usize {
        return self.buffers.len;
    }

    pub fn activeIndex(self: *const BufferManager) usize {
        return self.active_index;
    }
};

const std = @import("std");
const testing = std.testing;

test "BufferManager init empty" {
    var mgr = BufferManager.init(testing.allocator);
    defer mgr.deinit();

    try testing.expectEqual(@as(usize, 0), mgr.bufferCount());
    try testing.expect(mgr.getActive() == null);
    try testing.expectEqual(@as(usize, 0), mgr.activeIndex());
}

test "BufferManager addEmptyBuffer" {
    var mgr = BufferManager.init(testing.allocator);
    defer mgr.deinit();

    try mgr.addEmptyBuffer("[test]");
    try testing.expectEqual(@as(usize, 1), mgr.bufferCount());
    try testing.expect(mgr.getActive() != null);
    try testing.expectEqualStrings("[test]", mgr.getActive().?.file_path);
}

test "BufferManager nextBuffer wraps" {
    var mgr = BufferManager.init(testing.allocator);
    defer mgr.deinit();

    try mgr.addEmptyBuffer("a");
    try mgr.addEmptyBuffer("b");
    try testing.expectEqual(@as(usize, 0), mgr.activeIndex());

    mgr.nextBuffer();
    try testing.expectEqual(@as(usize, 1), mgr.activeIndex());

    mgr.nextBuffer();
    try testing.expectEqual(@as(usize, 0), mgr.activeIndex());
}

test "BufferManager prevBuffer wraps" {
    var mgr = BufferManager.init(testing.allocator);
    defer mgr.deinit();

    try mgr.addEmptyBuffer("a");
    try mgr.addEmptyBuffer("b");
    mgr.active_index = 1;

    mgr.prevBuffer();
    try testing.expectEqual(@as(usize, 0), mgr.activeIndex());

    mgr.prevBuffer();
    try testing.expectEqual(@as(usize, 1), mgr.activeIndex());
}

test "BufferManager closeActive single" {
    var mgr = BufferManager.init(testing.allocator);
    defer mgr.deinit();

    try mgr.addEmptyBuffer("only");
    mgr.closeActive();

    try testing.expectEqual(@as(usize, 0), mgr.bufferCount());
    try testing.expect(mgr.getActive() == null);
}

test "BufferManager closeActive adjusts index" {
    var mgr = BufferManager.init(testing.allocator);
    defer mgr.deinit();

    try mgr.addEmptyBuffer("a");
    try mgr.addEmptyBuffer("b");
    try mgr.addEmptyBuffer("c");
    mgr.active_index = 1;

    mgr.closeActive();
    try testing.expectEqual(@as(usize, 2), mgr.bufferCount());
    try testing.expectEqual(@as(usize, 1), mgr.activeIndex());
}

test "BufferManager closeActive last buffer" {
    var mgr = BufferManager.init(testing.allocator);
    defer mgr.deinit();

    try mgr.addEmptyBuffer("a");
    try mgr.addEmptyBuffer("b");
    mgr.active_index = 1;

    mgr.closeActive();
    try testing.expectEqual(@as(usize, 1), mgr.bufferCount());
    try testing.expectEqual(@as(usize, 0), mgr.activeIndex());
}
