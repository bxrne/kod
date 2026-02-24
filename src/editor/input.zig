const std = @import("std");
const posix = std.posix;
const testing = std.testing;

const assert = std.debug.assert;

pub const Mode = enum {
    edit,
    normal,
    match,
};

pub const Direction = enum {
    north,
    south,
    east,
    west,
};

pub const Command = union(enum) {
    scroll_up: u32,
    scroll_down: u32,
    goto_line: u32,
    select_line: u32,
    yank_lines: u32,
    delete_lines: u32,
    yank_range: u32,
    delete_range: u32,
    delete_line,
    replace_char: u8,
    undo,
    redo,
    repeat_last,
    paste_below,
    paste_above,
    goto_start,
    goto_end,
    indent,
    unindent,
    none,
};

pub const MatchState = enum {
    idle,
    searching,
    found,
};

/// NOTE: Keyboard event types recognised by the editor.
pub const Event = union(enum) {
    char: u8,
    ctrl_c,
    escape,
    command: Command,
    match_next,
    match_prev,
    enter_match,
    none,
};

// INFO: ASCII control code constants for readable dispatch.
const ctrl_c: u8 = 3;
const esc: u8 = 27;
const printable_min: u8 = 32;
const printable_max: u8 = 126;

pub const KeyBuffer = struct {
    data: [32]u8 = undefined,
    len: usize = 0,

    pub fn reset(self: *KeyBuffer) void {
        self.len = 0;
    }

    pub fn push(self: *KeyBuffer, c: u8) bool {
        if (self.len >= self.data.len) return false;
        self.data[self.len] = c;
        self.len += 1;
        return true;
    }

    pub fn parseCommand(self: *const KeyBuffer) Command {
        if (self.len == 0) return .none;

        const first = self.data[0];

        if (first == '+') {
            return self.parseNumber(1, .scroll_up);
        } else if (first == '-') {
            return self.parseNumber(1, .scroll_down);
        } else if (first == 's') {
            if (self.len > 1) {
                if (self.contains(':')) {
                    return self.parseRange(.select_line);
                }
                return self.parseNumber(1, .select_line);
            }
        } else if (first == 'y') {
            if (self.len > 1) {
                if (self.contains(':')) {
                    return self.parseRange(.yank_range);
                }
                return self.parseNumber(1, .yank_lines);
            }
        } else if (first == 'd') {
            if (self.len == 2 and self.data[1] == 'd') {
                return .delete_line;
            }
            if (self.len > 1) {
                if (self.contains(':')) {
                    return self.parseRange(.delete_range);
                }
                return self.parseNumber(1, .delete_lines);
            }
        } else if (first == '>') {
            return .indent;
        } else if (first == '<') {
            return .unindent;
        } else if (first >= '0' and first <= '9') {
            return self.parseNumber(0, .goto_line);
        }

        return .none;
    }

    const CommandTag = enum { scroll_up, scroll_down, goto_line, select_line, yank_lines, delete_lines, yank_range, delete_range, delete_line, indent, unindent };

    fn parseNumber(self: *const KeyBuffer, start: usize, tag: CommandTag) Command {
        var value: u32 = 0;
        var has_digits = false;

        var i = start;
        while (i < self.len) : (i += 1) {
            const c = self.data[i];
            if (c >= '0' and c <= '9') {
                value = value * 10 + (c - '0');
                has_digits = true;
            } else {
                return .none;
            }
        }

        if (!has_digits) return .none;
        return switch (tag) {
            .scroll_up => .{ .scroll_up = value },
            .scroll_down => .{ .scroll_down = value },
            .goto_line => .{ .goto_line = value },
            .select_line => .{ .select_line = value },
            .yank_lines => .{ .yank_lines = value },
            .delete_lines => .{ .delete_lines = value },
            .yank_range => .{ .yank_range = value },
            .delete_range => .{ .delete_range = value },
            .delete_line => .delete_line,
            .indent => .indent,
            .unindent => .unindent,
        };
    }

    fn contains(self: *const KeyBuffer, c: u8) bool {
        for (self.data[0..self.len]) |byte| {
            if (byte == c) return true;
        }
        return false;
    }

    fn parseRange(self: *const KeyBuffer, tag: CommandTag) Command {
        var start: u32 = 0;
        var end: u32 = 0;
        var parsing_end = false;
        var has_start = false;
        var has_end = false;

        var i: usize = 1;
        while (i < self.len) : (i += 1) {
            const c = self.data[i];
            if (c == ':') {
                parsing_end = true;
                continue;
            }
            if (c >= '0' and c <= '9') {
                if (!parsing_end) {
                    start = start * 10 + (c - '0');
                    has_start = true;
                } else {
                    end = end * 10 + (c - '0');
                    has_end = true;
                }
            }
        }

        if (!has_start or !has_end) return .none;
        if (start == 0 or end == 0) return .none;
        if (start > end) return .none;

        const combined = (start - 1) * 10000 + (end - 1);
        return switch (tag) {
            .select_line => .{ .select_line = combined },
            .yank_range => .{ .yank_range = combined },
            .delete_range => .{ .delete_range = combined },
            else => .none,
        };
    }
};

/// Read a single input event from stdin. Non-blocking: returns `.none`
/// when no data is available within the VTIME window.
pub fn readEvent() Event {
    var buf: [8]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch return .none;
    if (n == 0) return .none;
    assert(n <= buf.len);

    const c = buf[0];

    // INFO: Single-byte inputs: control characters and printable ASCII.
    if (n == 1) {
        return switch (c) {
            ctrl_c => .ctrl_c,
            esc => .escape,
            '\n', '\r' => .{ .char = c },
            '\t' => .{ .char = c }, // Tab (edit mode inserts spaces)
            127, 8 => .{ .char = c }, // DEL and Backspace
            printable_min...printable_max => .{ .char = c },
            else => .none,
        };
    }

    // INFO: Multi-byte escape sequences: CSI arrow keys (ESC [ A/B/C/D).
    // if (c == esc and n >= 3 and buf[1] == '[') {
    //     return switch (buf[2]) {
    //         'A' => .arrow_up,
    //         'B' => .arrow_down,
    //         'C' => .arrow_right,
    //         'D' => .arrow_left,
    //         else => .none,
    //     };
    // }

    return .none;
}

// Tests

test "event char stores correct byte" {
    const event = Event{ .char = 'z' };
    try testing.expectEqual(@as(u8, 'z'), event.char);
}

test "none is the default timeout event" {
    const event: Event = .none;
    try testing.expectEqual(Event.none, event);
}

test "key buffer parses scroll up" {
    var kb: KeyBuffer = .{};
    _ = kb.push('+');
    _ = kb.push('3');
    _ = kb.push('0');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .scroll_up = 30 }, cmd);
}

test "key buffer parses scroll down" {
    var kb: KeyBuffer = .{};
    _ = kb.push('-');
    _ = kb.push('5');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .scroll_down = 5 }, cmd);
}

test "key buffer parses goto line" {
    var kb: KeyBuffer = .{};
    _ = kb.push('1');
    _ = kb.push('0');
    _ = kb.push('0');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .goto_line = 100 }, cmd);
}

test "key buffer parses select line" {
    var kb: KeyBuffer = .{};
    _ = kb.push('s');
    _ = kb.push('4');
    _ = kb.push('2');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .select_line = 42 }, cmd);
}

test "key buffer resets properly" {
    var kb: KeyBuffer = .{};
    _ = kb.push('+');
    _ = kb.push('1');
    kb.reset();

    try testing.expectEqual(@as(usize, 0), kb.len);
    try testing.expectEqual(Command.none, kb.parseCommand());
}

test "key buffer rejects invalid command" {
    var kb: KeyBuffer = .{};
    _ = kb.push('x');
    _ = kb.push('y');
    _ = kb.push('z');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command.none, cmd);
}

test "key buffer handles zero properly" {
    var kb: KeyBuffer = .{};
    _ = kb.push('+');
    _ = kb.push('0');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command.none, cmd);
}

test "key buffer overflow is prevented" {
    var kb: KeyBuffer = .{};
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        _ = kb.push('1');
    }

    try testing.expectEqual(@as(usize, 32), kb.len);
}

test "key buffer parses large numbers" {
    var kb: KeyBuffer = .{};
    _ = kb.push('+');
    _ = kb.push('1');
    _ = kb.push('0');
    _ = kb.push('0');
    _ = kb.push('0');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .scroll_up = 1000 }, cmd);
}

test "key buffer parses yank lines" {
    var kb: KeyBuffer = .{};
    _ = kb.push('y');
    _ = kb.push('3');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .yank_lines = 3 }, cmd);
}

test "key buffer parses delete lines" {
    var kb: KeyBuffer = .{};
    _ = kb.push('d');
    _ = kb.push('5');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .delete_lines = 5 }, cmd);
}

test "key buffer parses indent" {
    var kb: KeyBuffer = .{};
    _ = kb.push('>');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command.indent, cmd);
}

test "key buffer parses unindent" {
    var kb: KeyBuffer = .{};
    _ = kb.push('<');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command.unindent, cmd);
}

test "key buffer empty returns none" {
    var kb: KeyBuffer = .{};
    try testing.expectEqual(Command.none, kb.parseCommand());
}

test "key buffer parseRange select_line" {
    var kb: KeyBuffer = .{};
    _ = kb.push('s');
    _ = kb.push('1');
    _ = kb.push(':');
    _ = kb.push('3');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .select_line = 0 * 10000 + 2 }, cmd);
}

test "key buffer parseRange yank_range" {
    var kb: KeyBuffer = .{};
    _ = kb.push('y');
    _ = kb.push('2');
    _ = kb.push(':');
    _ = kb.push('4');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .yank_range = 1 * 10000 + 3 }, cmd);
}

test "key buffer parseRange delete_range" {
    var kb: KeyBuffer = .{};
    _ = kb.push('d');
    _ = kb.push('1');
    _ = kb.push(':');
    _ = kb.push('1');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .delete_range = 0 * 10000 + 0 }, cmd);
}

test "key buffer parseRange invalid start greater than end" {
    var kb: KeyBuffer = .{};
    _ = kb.push('s');
    _ = kb.push('5');
    _ = kb.push(':');
    _ = kb.push('2');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command.none, cmd);
}

test "key buffer parseRange missing colon returns none" {
    var kb: KeyBuffer = .{};
    _ = kb.push('s');
    _ = kb.push('1');
    _ = kb.push('2');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command{ .select_line = 12 }, cmd);
}

test "key buffer dd returns delete_line" {
    var kb: KeyBuffer = .{};
    _ = kb.push('d');
    _ = kb.push('d');

    const cmd = kb.parseCommand();
    try testing.expectEqual(Command.delete_line, cmd);
}

test "key buffer push returns false when full" {
    var kb: KeyBuffer = .{};
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        _ = kb.push('a');
    }
    try testing.expect(!kb.push('b'));
}

// test "ctrl events are distinguishable" {
//     const c: Event = .ctrl_c;
//     const q: Event = .ctrl_q;
//     try testing.expect(c != q);
// }
