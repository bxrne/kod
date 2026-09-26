//! Input state machine. Keys mean different things in each mode.
//! Normal mode takes an optional signed count, then a command: `4j`, `-4j`.
//! `:` enters command mode, which owns its line buffer and interprets it
//! on submit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const Event = @import("tty.zig").Event;
const Jump = @import("buffer.zig").Jump;

pub const Mode = struct {
    kind: Kind = .normal,
    /// Digits typed so far. Meaningful when `typing` is set.
    mag: u64 = 0,
    neg: bool = false,
    typing: bool = false,
    await: Await = .none,
    /// Command line buffer. Meaningful when `kind` is `.command`.
    cmd: command.Line = .{},
    sel: ?Sel = null,
    /// Session command history. Main sets `hist_gpa` once; without it
    /// submits are not recorded but navigation still works on whatever
    /// is already stored.
    cmd_history: command.History = .{},
    hist_gpa: ?Allocator = null,

    /// Start the selection overlay, keeping an existing anchor so
    /// shift+arrows extend rather than restart.
    pub fn selStart(self: *Mode, row: u64, col: u64) void {
        if (self.sel == null) self.sel = .{ .arow = row, .acol = col };
    }

    pub fn selClear(self: *Mode) void {
        self.sel = null;
    }

    /// Enter insert mode, leaving the normal-mode overlay behind.
    pub fn enterInput(self: *Mode) void {
        self.clearPrefix();
        self.selClear();
        self.kind = .input;
    }

    /// Free history entries. Main defers this.
    pub fn deinit(self: *Mode) void {
        if (self.hist_gpa) |g| self.cmd_history.deinit(g);
        self.hist_gpa = null;
    }

    const Kind = enum { normal, input, command };
    const Await = enum { none, g, change, replace };

    /// Selection anchor for the normal-mode overlay. When set, motions
    /// extend the selection instead of just moving; `d`, `c`, and `r`
    /// operate on the anchor-to-cursor range. Shift+arrows start it,
    /// Esc cancels it, any buffer mutation or doc switch clears it.
    pub const Sel = struct { arow: u64, acol: u64 };

    pub fn label(self: Mode) []const u8 {
        if (self.kind == .normal and self.sel != null) return "SELECT";
        return switch (self.kind) {
            .normal => "NORMAL",
            .input => "INPUT",
            .command => "COMMAND",
        };
    }

    /// Count prefix for the header, e.g. `4` or `-12`. Empty when idle.
    pub fn countLabel(self: Mode, out: *[24]u8) []const u8 {
        if (self.kind != .normal or !self.typing) return "";
        if (self.neg and self.mag == 0) return "-";
        return std.fmt.bufPrint(out, "{s}{d}", .{
            if (self.neg) "-" else "",
            self.mag,
        }) catch "";
    }

    pub fn handle(self: *Mode, ev: Event) Action {
        return switch (self.kind) {
            .normal => self.handleNormal(ev),
            .input => self.handleInput(ev),
            .command => self.handleCommand(ev),
        };
    }

    /// Overlay line when in command mode, otherwise null.
    pub fn cmdLine(self: *const Mode) ?*const command.Line {
        return if (self.kind == .command) &self.cmd else null;
    }

    fn handleNormal(self: *Mode, ev: Event) Action {
        if (self.await == .change) return self.finishPending(ev, false);
        if (self.await == .replace) return self.finishPending(ev, true);
        switch (ev) {
            .none, .ctrl_c, .backspace => return .none,
            .ctrl_r => {
                self.clearPrefix();
                self.selClear();
                return .redo;
            },
            // A count on its own is an absolute line. Enter commits it.
            // `13j` still moves relatively; `13` then Enter goes to line 13.
            .enter => return self.finishLineNumber(),
            .esc => {
                self.clearPrefix();
                self.selClear();
                return .none;
            },
            .up => return self.motion(-1, 0),
            .down => return self.motion(1, 0),
            .left => return self.motion(0, -1),
            .right => return self.motion(0, 1),
            // Shift+arrows move like plain arrows; main snapshots the
            // anchor first, so the selection extends from there.
            .s_up => return self.motion(-1, 0),
            .s_down => return self.motion(1, 0),
            .s_left => return self.motion(0, -1),
            .s_right => return self.motion(0, 1),
            .char => |c| return self.normalChar(c),
        }
    }

    fn handleInput(self: *Mode, ev: Event) Action {
        switch (ev) {
            .none => return .none,
            .esc => {
                self.kind = .normal;
                self.clearPrefix();
                return .save;
            },
            .ctrl_c, .ctrl_r => return .none,
            .up => return .{ .move = .{ .drow = -1, .dcol = 0 } },
            .down => return .{ .move = .{ .drow = 1, .dcol = 0 } },
            .left => return .{ .move = .{ .drow = 0, .dcol = -1 } },
            .right => return .{ .move = .{ .drow = 0, .dcol = 1 } },
            .s_up => return .{ .move = .{ .drow = -1, .dcol = 0 } },
            .s_down => return .{ .move = .{ .drow = 1, .dcol = 0 } },
            .s_left => return .{ .move = .{ .drow = 0, .dcol = -1 } },
            .s_right => return .{ .move = .{ .drow = 0, .dcol = 1 } },
            .backspace => return .backspace,
            .enter => return .{ .insert = '\n' },
            .char => |c| {
                if (c == '\t' or c >= 32) return .{ .insert = c };
                return .none;
            },
        }
    }

    fn handleCommand(self: *Mode, ev: Event) Action {
        // History first: Line treats arrows as no-ops.
        if (ev == .up or ev == .down or ev == .s_up or ev == .s_down) {
            self.cmd_history.navigate(ev == .up or ev == .s_up, &self.cmd);
            return .none;
        }
        switch (self.cmd.handle(ev)) {
            .none => return .none,
            .cancel => {
                self.kind = .normal;
                self.cmd = .{};
                self.cmd_history.resetNav();
                return .none;
            },
            .submit => {
                if (self.hist_gpa) |g| self.cmd_history.push(g, self.cmd.text());
                switch (command.interpret(self.cmd.text())) {
                    .empty => {
                        self.kind = .normal;
                        self.cmd = .{};
                        return .none;
                    },
                    .quit => {
                        self.kind = .normal;
                        self.cmd = .{};
                        return .quit;
                    },
                    .unknown => {
                        self.cmd.err = command.err_unknown;
                        return .none;
                    },
                    // Leaves `cmd` intact: main reads the path, opens the
                    // directory, then calls `concludeCommand`.
                    .fs => return .open_fs,
                    // Search keeps its text: main parses scope and spec,
                    // runs it, then calls `concludeCommand`.
                    .search => return .open_search,
                    // Exec keeps its text like search: main reads the
                    // command, spawns the run, then concludes.
                    .exec => return .exec_run,
                    .exec_save => return .exec_arm,
                    // No payload: dismiss here, main switches or opens.
                    .bufs => {
                        self.concludeCommand();
                        return .open_bufs;
                    },
                    // Git verbs keep their text: main reads the arg,
                    // runs git, then calls `concludeCommand`.
                    .git => return .open_git,
                    .help => {
                        self.concludeCommand();
                        return .open_help;
                    },
                    // Trees keeps its text: docs reads the section name,
                    // opens the inspector, then concludes the command.
                    .trees => return .open_trees,
                    .gadd => return .gadd,
                    .gcommit => return .gcommit,
                    .gpush => return .gpush,
                    .gpull => return .gpull,
                    .gswitch => return .gswitch,
                    .gbranch => return .gbranch,
                }
            },
        }
    }

    /// Dismiss the command overlay after main has consumed its text.
    pub fn concludeCommand(self: *Mode) void {
        self.kind = .normal;
        self.cmd = .{};
        self.cmd_history.resetNav();
    }

    /// Put a recorded command back in the box, ready to edit or run.
    /// The trees command rows use this. Allocation-free: the line owns
    /// its bytes and the history cursor is dropped.
    pub fn prefillCommand(self: *Mode, text: []const u8) void {
        self.clearPrefix();
        self.selClear();
        self.kind = .command;
        self.cmd.setText(text);
        self.cmd_history.resetNav();
    }

    /// Show why a submit failed. `reason` is one of the static
    /// strings in `command`, so nothing is copied or owned here.
    pub fn flagCommandError(self: *Mode, reason: []const u8) void {
        self.cmd.err = reason;
    }

    pub fn commandText(self: *const Mode) []const u8 {
        return self.cmd.text();
    }

    /// Bare enter in normal mode with no count or pending key.
    /// Main uses it to open the entry under the cursor in dir views.
    pub fn isBareNormalEnter(self: *const Mode, ev: Event) bool {
        return self.kind == .normal and !self.typing and
            self.await == .none and ev == .enter;
    }

    fn normalChar(self: *Mode, c: u8) Action {
        if (self.await == .g) {
            self.await = .none;
            if (c == 'g') return self.finishVertical(.top);
        }
        if (self.pushCount(c)) return .none;
        return self.normalCommand(c);
    }

    fn normalCommand(self: *Mode, c: u8) Action {
        switch (c) {
            'q' => {
                self.clearPrefix();
                return .quit;
            },
            ':' => {
                self.clearPrefix();
                self.selClear();
                self.kind = .command;
                self.cmd = .{};
                self.cmd_history.resetNav();
                return .none;
            },
            '/' => {
                self.clearPrefix();
                self.selClear();
                self.kind = .command;
                self.cmd.setText("/");
                self.cmd_history.resetNav();
                return .none;
            },
            'n' => {
                self.clearPrefix();
                return .search_next;
            },
            'p' => {
                self.clearPrefix();
                return .search_prev;
            },
            'h' => return self.motion(0, -1),
            'j' => return self.motion(1, 0),
            'k' => return self.motion(-1, 0),
            'l' => return self.motion(0, 1),
            'i' => {
                self.enterInput();
                return .none;
            },
            'd' => {
                // With an active selection the range wins and any
                // count prefix is dropped; main ignores the payload.
                if (self.sel != null) {
                    self.clearPrefix();
                    return .{ .delete_lines = 1 };
                }
                return .{ .delete_lines = self.takeCount().signed };
            },
            'u' => {
                self.clearPrefix();
                self.selClear();
                return .undo;
            },
            'r' => {
                self.await = .replace;
                return .none;
            },
            'o', 'O' => {
                const n: u32 = @intCast(@min(self.takeCount().mag, std.math.maxInt(u32)));
                self.enterInput();
                return .{ .open_line = .{ .below = c == 'o', .n = n } };
            },
            'f' => return .{ .word = self.takeCount().signed },
            'F' => {
                const n = self.takeCount().signed;
                const w: i32 = if (n == std.math.minInt(i32)) std.math.maxInt(i32) else -n;
                return .{ .word = w };
            },
            'c' => {
                self.await = .change;
                return .none;
            },
            '0' => {
                self.clearPrefix();
                return .{ .jump = .line_start };
            },
            '$' => {
                self.clearPrefix();
                return .{ .jump = .line_end };
            },
            'g' => {
                self.await = .g;
                return .none;
            },
            'G' => return self.finishVertical(.bottom),
            else => {
                self.clearPrefix();
                return .none;
            },
        }
    }

    /// Finish `c` or `r` plus a char. `is_replace` tells `r` from `c`
    /// when a selection is active: `r` overwrites the range (`.replace`),
    /// otherwise both degrade to in-place `.change`. Counts work the same.
    fn finishPending(self: *Mode, ev: Event, is_replace: bool) Action {
        self.await = .none;
        switch (ev) {
            .char => |c| {
                if (c != '\t' and c < 32) {
                    self.clearPrefix();
                    return .none;
                }
                const n: u32 = @intCast(@min(self.takeCount().mag, std.math.maxInt(u32)));
                if (is_replace and self.sel != null) {
                    return .{ .replace = .{ .n = n, .byte = c } };
                }
                return .{ .change = .{ .n = n, .byte = c } };
            },
            else => {
                self.clearPrefix();
                return .none;
            },
        }
    }

    fn finishLineNumber(self: *Mode) Action {
        const numbered = self.typing and self.mag != 0 and !self.neg;
        const mag = self.mag;
        self.clearPrefix();
        if (!numbered) return .none;
        return .{ .jump = .{ .line = mag } };
    }

    const VEdge = enum { top, bottom };

    fn finishVertical(self: *Mode, edge: VEdge) Action {
        self.clearPrefix();
        return .{ .jump = if (edge == .top) .top else .bottom };
    }

    fn motion(self: *Mode, drow: i32, dcol: i32) Action {
        const n = self.takeCount().signed;
        const sat = struct {
            fn mul(unit: i32, m: i32) i32 {
                const v = @as(i64, unit) * @as(i64, m);
                if (v > std.math.maxInt(i32)) return std.math.maxInt(i32);
                if (v < std.math.minInt(i32)) return std.math.minInt(i32);
                return @intCast(v);
            }
        }.mul;
        return .{ .move = .{
            .drow = sat(drow, n),
            .dcol = sat(dcol, n),
        } };
    }

    /// Count prefix once consumed. `mag` keeps the raw magnitude for
    /// `o`/`c`/`r` (neg ignored, huge saturates later to u32); `signed`
    /// caps to i32 and applies the sign for motions, `d`, `f`/`F`.
    const Count = struct { mag: u64, signed: i32 };

    /// Consume `-` and digits into the prefix. True when `c` was count
    /// syntax, including a bare `-` that starts a negative prefix.
    /// Bare `0` is not a count: it falls through to `line_start`.
    fn pushCount(self: *Mode, c: u8) bool {
        if (c == '-') {
            if (!self.typing) {
                self.typing = true;
                self.neg = true;
                self.mag = 0;
            }
            return true;
        }
        if (!(c >= '1' and c <= '9' or (c == '0' and self.typing))) return false;
        const digit: u64 = c - '0';
        if (!self.typing) {
            self.typing = true;
            self.mag = digit;
            return true;
        }
        if (self.mag > (std.math.maxInt(u64) - digit) / 10) {
            self.mag = std.math.maxInt(u64);
            return true;
        }
        self.mag = self.mag * 10 + digit;
        return true;
    }

    fn takeCount(self: *Mode) Count {
        const mag: u64 = if (!self.typing or self.mag == 0) 1 else self.mag;
        const capped: i32 = @intCast(@min(mag, std.math.maxInt(i32)));
        const signed: i32 = if (self.neg) -capped else capped;
        self.clearPrefix();
        return .{ .mag = mag, .signed = signed };
    }

    fn clearPrefix(self: *Mode) void {
        self.mag = 0;
        self.neg = false;
        self.typing = false;
        self.await = .none;
    }
};

pub const Action = union(enum) {
    none,
    quit,
    save,
    /// `:fs` submitted. Path stays in `Mode.cmd` for main to read.
    open_fs,
    /// `:buf` submitted. Already dismissed.
    open_bufs,
    /// `:git` plus `:gadd` etc. Text stays in `Mode.cmd`.
    open_git,
    /// `:help` submitted. Already dismissed.
    open_help,
    /// `:tree` submitted. Text stays in `Mode.cmd` for docs to read
    /// the tree name.
    open_trees,
    /// Search submitted. Text stays in `Mode.cmd` for docs to parse.
    open_search,
    /// `:exec` submitted. Text stays in `Mode.cmd` for docs to read.
    exec_run,
    /// `:exec-save` submitted. Text stays in `Mode.cmd`.
    exec_arm,
    /// Step through the last search results.
    search_next,
    search_prev,
    gadd,
    gcommit,
    gpush,
    gpull,
    gswitch,
    gbranch,
    move: struct { drow: i32, dcol: i32 },
    insert: u8,
    backspace,
    delete_lines: i32,
    undo,
    redo,
    open_line: struct { below: bool, n: u32 },
    word: i32,
    change: struct { n: u32, byte: u8 },
    /// `r` plus a char with an active selection: overwrite the range.
    /// Without one `r` degrades to `.change`; main still guards.
    replace: struct { n: u32, byte: u8 },
    jump: Jump,
};

test "normal: hjkl move, i enters input, q quits" {
    var mode: Mode = .{};
    try std.testing.expectEqual(Action.quit, mode.handle(.{ .char = 'q' }));
    try std.testing.expect(mode.kind == .normal);

    switch (mode.handle(.{ .char = 'j' })) {
        .move => |m| {
            try std.testing.expectEqual(@as(i32, 1), m.drow);
            try std.testing.expectEqual(@as(i32, 0), m.dcol);
        },
        else => return error.Unexpected,
    }

    _ = mode.handle(.{ .char = 'i' });
    try std.testing.expect(mode.kind == .input);
}

test "normal: only q quits, esc and ctrl-c do not" {
    var mode: Mode = .{};
    try std.testing.expectEqual(Action.none, mode.handle(.esc));
    try std.testing.expectEqual(Action.none, mode.handle(.ctrl_c));
    try std.testing.expectEqual(Action.quit, mode.handle(.{ .char = 'q' }));
}

test "normal: colon enters command mode" {
    var mode: Mode = .{};
    try std.testing.expectEqual(Action.none, mode.handle(.{ .char = ':' }));
    try std.testing.expect(mode.kind == .command);
    try std.testing.expect(mode.cmdLine() != null);
}

test "normal: signed count scales the next motion" {
    var mode: Mode = .{};
    for ("4") |c| _ = mode.handle(.{ .char = c });
    switch (mode.handle(.{ .char = 'j' })) {
        .move => |m| try std.testing.expectEqual(@as(i32, 4), m.drow),
        else => return error.Unexpected,
    }

    for ("-4") |c| _ = mode.handle(.{ .char = c });
    switch (mode.handle(.{ .char = 'j' })) {
        .move => |m| try std.testing.expectEqual(@as(i32, -4), m.drow),
        else => return error.Unexpected,
    }

    for ("10") |c| _ = mode.handle(.{ .char = c });
    switch (mode.handle(.{ .char = 'h' })) {
        .move => |m| try std.testing.expectEqual(@as(i32, -10), m.dcol),
        else => return error.Unexpected,
    }
}

test "normal: d o O f F c and the edge jumps" {
    var mode: Mode = .{};
    try std.testing.expectEqual(
        Action{ .delete_lines = 2 },
        feed(&mode, "2d"),
    );

    switch (feed(&mode, "o")) {
        .open_line => |o| {
            try std.testing.expect(o.below);
            try std.testing.expectEqual(@as(u32, 1), o.n);
        },
        else => return error.Unexpected,
    }
    try std.testing.expect(mode.kind == .input);
    mode.kind = .normal;

    switch (feed(&mode, "3O")) {
        .open_line => |o| {
            try std.testing.expect(!o.below);
            try std.testing.expectEqual(@as(u32, 3), o.n);
        },
        else => return error.Unexpected,
    }
    mode.kind = .normal;

    try std.testing.expectEqual(Action{ .word = 1 }, feed(&mode, "f"));
    try std.testing.expectEqual(Action{ .word = -2 }, feed(&mode, "2F"));
    try std.testing.expectEqual(Action{ .word = -4 }, feed(&mode, "-4f"));

    try std.testing.expectEqual(Action.none, mode.handle(.{ .char = 'c' }));
    switch (mode.handle(.{ .char = 'x' })) {
        .change => |ch| {
            try std.testing.expectEqual(@as(u32, 1), ch.n);
            try std.testing.expectEqual(@as(u8, 'x'), ch.byte);
        },
        else => return error.Unexpected,
    }

    try std.testing.expectEqual(Action{ .jump = .line_start }, feed(&mode, "0"));
    try std.testing.expectEqual(Action{ .jump = .line_end }, feed(&mode, "$"));
    try std.testing.expectEqual(Action.none, mode.handle(.{ .char = 'g' }));
    try std.testing.expectEqual(Action{ .jump = .top }, mode.handle(.{ .char = 'g' }));
    try std.testing.expectEqual(Action{ .jump = .bottom }, feed(&mode, "G"));
    try std.testing.expectEqual(Action{ .jump = .bottom }, feed(&mode, "12G"));
}

test "normal: a count then enter jumps to that absolute line" {
    var mode: Mode = .{};
    try std.testing.expectEqual(Action.none, mode.handle(.enter));
    for ("13") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(
        Action{ .jump = .{ .line = 13 } },
        mode.handle(.enter),
    );
    try std.testing.expect(!mode.typing);
}

fn feed(mode: *Mode, keys: []const u8) Action {
    var last: Action = .none;
    for (keys) |c| last = mode.handle(.{ .char = c });
    return last;
}

test "input: letters including q are inserts, esc returns to normal" {
    var mode: Mode = .{ .kind = .input };
    switch (mode.handle(.{ .char = 'q' })) {
        .insert => |c| try std.testing.expectEqual(@as(u8, 'q'), c),
        else => return error.Unexpected,
    }
    try std.testing.expect(mode.kind == .input);

    try std.testing.expectEqual(Action.save, mode.handle(.esc));
    try std.testing.expect(mode.kind == .normal);
}

test "input: arrows move, enter becomes a newline" {
    var mode: Mode = .{ .kind = .input };
    switch (mode.handle(.left)) {
        .move => |m| try std.testing.expectEqual(@as(i32, -1), m.dcol),
        else => return error.Unexpected,
    }
    try std.testing.expect(mode.kind == .input);
    switch (mode.handle(.enter)) {
        .insert => |c| try std.testing.expectEqual(@as(u8, '\n'), c),
        else => return error.Unexpected,
    }
}

test "command: typing, cancel, and submit" {
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    try std.testing.expect(mode.kind == .command);

    // `q` is text here, not the normal-mode quit key.
    try std.testing.expectEqual(Action.none, mode.handle(.{ .char = 'q' }));
    try std.testing.expectEqualStrings("q", mode.cmd.text());
    try std.testing.expect(mode.kind == .command);

    // Unknown input stays in command mode and flags the error.
    try std.testing.expectEqual(Action.none, mode.handle(.{ .char = 'x' }));
    try std.testing.expectEqual(Action.none, mode.handle(.enter));
    try std.testing.expect(mode.kind == .command);
    try std.testing.expectEqualStrings(command.err_unknown, mode.cmd.err);

    // Esc cancels back to normal with a fresh line.
    try std.testing.expectEqual(Action.none, mode.handle(.esc));
    try std.testing.expect(mode.kind == .normal);
    try std.testing.expect(mode.cmdLine() == null);
}

test "command: empty submit dismisses, quit quits" {
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    try std.testing.expectEqual(Action.none, mode.handle(.enter));
    try std.testing.expect(mode.kind == .normal);

    _ = mode.handle(.{ .char = ':' });
    _ = mode.handle(.{ .char = 'q' });
    try std.testing.expectEqual(Action.quit, mode.handle(.enter));
    try std.testing.expect(mode.kind == .normal);
}

test "command: fs submit keeps its text for main to open" {
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("fs src") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.open_fs, mode.handle(.enter));
    try std.testing.expect(mode.kind == .command);
    try std.testing.expectEqualStrings("fs src", mode.commandText());
    mode.concludeCommand();
    try std.testing.expect(mode.kind == .normal);
    try std.testing.expect(mode.cmdLine() == null);
}

test "command: buf submit dismisses itself" {
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("buf") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.open_bufs, mode.handle(.enter));
    try std.testing.expect(mode.kind == .normal);
    try std.testing.expect(mode.cmdLine() == null);
}

test "command: tree submit keeps its text for docs" {
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("tree exec") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.open_trees, mode.handle(.enter));
    // Docs reads the section name, then concludes the command.
    try std.testing.expect(mode.kind == .command);
    try std.testing.expectEqualStrings("tree exec", mode.commandText());
    mode.concludeCommand();
    try std.testing.expect(mode.kind == .normal);
    // The plural spelling is unknown now.
    _ = mode.handle(.{ .char = ':' });
    for ("trees") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.none, mode.handle(.enter));
    try std.testing.expectEqualStrings(command.err_unknown, mode.cmd.err);
}

test "command: help submit dismisses itself" {
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("help") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.open_help, mode.handle(.enter));
    try std.testing.expect(mode.kind == .normal);
    try std.testing.expect(mode.cmdLine() == null);
}

test "command: git verbs keep text for main to run" {
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("git") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.open_git, mode.handle(.enter));
    try std.testing.expect(mode.kind == .command);
    mode.concludeCommand();

    _ = mode.handle(.{ .char = ':' });
    for ("gcommit fix it") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.gcommit, mode.handle(.enter));
    try std.testing.expectEqualStrings("gcommit fix it", mode.commandText());
    mode.concludeCommand();

    _ = mode.handle(.{ .char = ':' });
    for ("gswitch main") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.gswitch, mode.handle(.enter));
    try std.testing.expect(mode.kind == .command);
    mode.concludeCommand();
}

test "command: up and down walk history in the box" {
    const gpa = std.testing.allocator;
    var mode: Mode = .{};
    mode.hist_gpa = gpa;
    defer mode.deinit();

    _ = mode.handle(.{ .char = ':' });
    for ("fs src") |c| _ = mode.handle(.{ .char = c });
    _ = mode.handle(.enter);
    mode.concludeCommand();
    _ = mode.handle(.{ .char = ':' });
    for ("buf") |c| _ = mode.handle(.{ .char = c });
    _ = mode.handle(.enter);
    mode.concludeCommand();

    _ = mode.handle(.{ .char = ':' });
    try std.testing.expectEqual(Action.none, mode.handle(.up));
    try std.testing.expectEqualStrings("buf", mode.commandText());
    try std.testing.expectEqual(Action.none, mode.handle(.up));
    try std.testing.expectEqualStrings("fs src", mode.commandText());
    try std.testing.expectEqual(Action.none, mode.handle(.down));
    try std.testing.expectEqualStrings("buf", mode.commandText());
    try std.testing.expectEqual(Action.none, mode.handle(.down));
    try std.testing.expectEqualStrings("", mode.commandText());
    try std.testing.expectEqual(Action.none, mode.handle(.esc));
    try std.testing.expect(mode.kind == .normal);
}

test "normal: u undoes, ctrl_r redoes" {
    var mode: Mode = .{};
    try std.testing.expectEqual(Action.undo, mode.handle(.{ .char = 'u' }));
    try std.testing.expectEqual(Action.redo, mode.handle(.ctrl_r));
}

test "normal: r with selection returns replace" {
    var mode: Mode = .{};
    mode.selStart(1, 1);
    try std.testing.expectEqual(Action.none, mode.handle(.{ .char = 'r' }));
    switch (mode.handle(.{ .char = 'X' })) {
        .replace => |c| {
            try std.testing.expectEqual(@as(u32, 1), c.n);
            try std.testing.expectEqual(@as(u8, 'X'), c.byte);
        },
        else => return error.Unexpected,
    }
}

test "normal: r without selection degrades to change" {
    var mode: Mode = .{};
    try std.testing.expectEqual(Action.none, mode.handle(.{ .char = 'r' }));
    switch (mode.handle(.{ .char = 'X' })) {
        .change => |c| {
            try std.testing.expectEqual(@as(u32, 1), c.n);
            try std.testing.expectEqual(@as(u8, 'X'), c.byte);
        },
        else => return error.Unexpected,
    }
}

test "normal: selection overlay starts, extends, cancels" {
    var mode: Mode = .{};
    try std.testing.expect(mode.sel == null);
    mode.selStart(2, 5);
    try std.testing.expect(mode.sel != null);
    try std.testing.expectEqual(@as(u64, 2), mode.sel.?.arow);
    // Second start keeps the anchor.
    mode.selStart(9, 9);
    try std.testing.expectEqual(@as(u64, 2), mode.sel.?.arow);
    try std.testing.expectEqual(@as(u64, 5), mode.sel.?.acol);
    // Shift motions move without touching the anchor.
    switch (mode.handle(.s_right)) {
        .move => |m| try std.testing.expectEqual(@as(i32, 1), m.dcol),
        else => return error.Unexpected,
    }
    try std.testing.expect(mode.sel != null);
    // Esc cancels; label flips back.
    try std.testing.expectEqualStrings("SELECT", mode.label());
    _ = mode.handle(.esc);
    try std.testing.expect(mode.sel == null);
    try std.testing.expectEqualStrings("NORMAL", mode.label());
}

test "normal: ops clear the selection, counts die with it" {
    var mode: Mode = .{};
    mode.selStart(0, 0);
    for ("4") |c| _ = mode.handle(.{ .char = c });
    // `d` with a selection ignores the pending count.
    switch (mode.handle(.{ .char = 'd' })) {
        .delete_lines => |n| try std.testing.expectEqual(@as(i32, 1), n),
        else => return error.Unexpected,
    }
    try std.testing.expect(!mode.typing);
}

test "normal: entering command or input drops the selection" {
    var mode: Mode = .{};
    mode.selStart(0, 0);
    _ = mode.handle(.{ .char = ':' });
    try std.testing.expect(mode.sel == null);
    try std.testing.expect(mode.kind == .command);
    mode.kind = .normal;
    mode.selStart(0, 0);
    _ = mode.handle(.{ .char = 'i' });
    try std.testing.expect(mode.sel == null);
    try std.testing.expect(mode.kind == .input);
}

test "normal: slash opens command prefilled, n and p step search" {
    var mode: Mode = .{};
    try std.testing.expectEqual(Action.none, mode.handle(.{ .char = '/' }));
    try std.testing.expect(mode.kind == .command);
    try std.testing.expectEqualStrings("/", mode.commandText());
    try std.testing.expectEqual(Action.none, mode.handle(.esc));
    try std.testing.expectEqual(Action.search_next, mode.handle(.{ .char = 'n' }));
    try std.testing.expectEqual(Action.search_prev, mode.handle(.{ .char = 'p' }));
}

test "command: search submit keeps text for docs to run" {
    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("/foo/bar/i") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expectEqual(Action.open_search, mode.handle(.enter));
    try std.testing.expect(mode.kind == .command);
    try std.testing.expectEqualStrings("/foo/bar/i", mode.commandText());
    mode.concludeCommand();
    try std.testing.expect(mode.kind == .normal);
}
