const std = @import("std");
const posix = std.posix;
const StateMachine = @import("fsm.zig").StateMachine;

const assert = std.debug.assert;

/// NOTE: Terminal mode states for raw/canonical switching.
const Mode = enum(u32) { canonical, raw };
const ModeFsm = StateMachine(Mode);

const mode_rules = ModeFsm.Rules{
    &.{.raw}, // canonical -> raw
    &.{.canonical}, // raw       -> canonical
};

/// POSIX terminal controller. Manages raw-mode entry/exit via termios.
pub const Terminal = struct {
    mode: ModeFsm,
    original: posix.termios,

    pub fn init() Terminal {
        return .{
            .mode = ModeFsm.init(.canonical),
            .original = undefined,
        };
    }

    /// Enter raw mode: disable echo, canonical processing, and signal
    /// generation. Sets VTIME for non-blocking 100 ms input polling.
    pub fn enter(self: *Terminal) !void {
        self.original = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = self.original;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.oflag.OPOST = false;

        // NOTE: Non-blocking reads with 100 ms timeout for input polling.
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        const ok = self.mode.transition(&mode_rules, .raw);
        assert(ok);
    }

    /// Restore original terminal settings.
    pub fn exit(self: *Terminal) void {
        if (self.mode.get() == .canonical) return;
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        const ok = self.mode.transition(&mode_rules, .canonical);
        assert(ok);
    }
};
