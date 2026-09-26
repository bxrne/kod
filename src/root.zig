//! Executable root. Wires `lib` and the editor modules.

const std = @import("std");

pub const lib = @import("lib");

pub fn main(init: std.process.Init) !void {
    return @import("main.zig").main(init);
}

test {
    _ = lib;
    _ = @import("main.zig");
    _ = @import("buffer.zig");
    _ = @import("pages.zig");
    _ = @import("docs.zig");
    _ = @import("search.zig");
    _ = @import("tree_usertree.zig");
    _ = @import("mode.zig");
    _ = @import("command.zig");
    _ = @import("fs_usertree.zig");
    _ = @import("buf_usertree.zig");
    _ = @import("git_usertree.zig");
    _ = @import("exec_usertree.zig");
    _ = @import("paint.zig");
    _ = @import("tty.zig");
}
