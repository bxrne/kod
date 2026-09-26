//! Raw terminal: enter/exit, keys, size.

const std = @import("std");
const posix = std.posix;

pub const Size = struct { rows: u16, cols: u16 };

pub const Event = union(enum) {
    none,
    char: u8,
    esc,
    up,
    down,
    left,
    right,
    /// Shift-modified arrows: `ESC [ 1 ; 2 X`. Start and extend the
    /// normal-mode selection overlay.
    s_up,
    s_down,
    s_left,
    s_right,
    backspace,
    enter,
    ctrl_c,
    /// Ctrl+R. Redo, vim-style; `r` is replace.
    ctrl_r,
};

pub const Tty = struct {
    saved: posix.termios = undefined,
    raw: bool = false,

    pub fn enter(self: *Tty) !void {
        self.saved = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = self.saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.oflag.OPOST = false;
        // Poll: wake every 100ms so a resize repaints without a key.
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        self.raw = true;
    }

    pub fn exit(self: *Tty) void {
        if (!self.raw) return;
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.saved) catch {};
        self.raw = false;
    }
};

fn readByte() ?u8 {
    var b: [1]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &b) catch return null;
    return if (n == 0) null else b[0];
}

/// Read one input event. Arrow keys are CSI/SS3 sequences. A lone ESC
/// waits one poll tick so `Esc [ A` is an arrow, not leave-mode.
pub fn readEvent() Event {
    const b = readByte() orelse return .none;
    return switch (b) {
        0x03 => .ctrl_c,
        0x12 => .ctrl_r,
        0x08, 0x7f => .backspace,
        '\r', '\n' => .enter,
        0x1b => readEsc(),
        else => .{ .char = b },
    };
}

fn readEsc() Event {
    const b2 = readByte() orelse return .esc;
    if (b2 == '[') return readCsi();
    if (b2 == 'O') {
        const b3 = readByte() orelse return .esc;
        return arrow(b3);
    }
    return .esc;
}

fn readCsi() Event {
    // Collect parameter bytes; the final byte selects the key.
    var params: [16]u8 = undefined;
    var n: usize = 0;
    var c = readByte() orelse return .esc;
    while (c < 0x40 or c > 0x7e) {
        if (n < params.len) {
            params[n] = c;
            n += 1;
        }
        c = readByte() orelse return .none;
    }
    return parseCsi(params[0..n], c);
}

/// Pure CSI tail parser, split out for tests: `params` holds the
/// bytes between `[` and `final`. Modifier `;2` means shift; any
/// other modifier falls back to the plain key.
pub fn parseCsi(params: []const u8, final: u8) Event {
    var shift = false;
    if (final == 'A' or final == 'B' or final == 'C' or final == 'D') {
        var it = std.mem.splitScalar(u8, params, ';');
        _ = it.next();
        if (it.next()) |mod| {
            // Modifier digit, ignoring trailing `:` extensions.
            if (mod.len > 0 and mod[0] == '2') shift = true;
        }
    }
    return switch (final) {
        'A' => if (shift) .s_up else .up,
        'B' => if (shift) .s_down else .down,
        'C' => if (shift) .s_right else .right,
        'D' => if (shift) .s_left else .left,
        else => arrow(final),
    };
}

fn arrow(c: u8) Event {
    return switch (c) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        else => .none,
    };
}

test "parseCsi maps plain, shift, and other modifiers" {
    try std.testing.expectEqual(Event.up, parseCsi("", 'A'));
    try std.testing.expectEqual(Event.up, parseCsi("1", 'A'));
    try std.testing.expectEqual(Event.s_up, parseCsi("1;2", 'A'));
    try std.testing.expectEqual(Event.s_down, parseCsi("1;2", 'B'));
    try std.testing.expectEqual(Event.s_right, parseCsi("1;2", 'C'));
    try std.testing.expectEqual(Event.s_left, parseCsi("1;2", 'D'));
    try std.testing.expectEqual(Event.up, parseCsi("1;5", 'A'));
    try std.testing.expectEqual(Event.up, parseCsi("1;3", 'A'));
    try std.testing.expectEqual(Event.none, parseCsi("", 'Z'));
    try std.testing.expectEqual(Event.none, parseCsi("1;2", 'Z'));
}

pub fn size() Size {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(
        posix.STDOUT_FILENO,
        posix.T.IOCGWINSZ,
        @intFromPtr(&ws),
    );
    if (posix.errno(rc) != .SUCCESS or ws.row == 0 or ws.col == 0) {
        return .{ .rows = 24, .cols = 80 };
    }
    return .{ .rows = ws.row, .cols = ws.col };
}
