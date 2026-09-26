//! Non-hot-path library code. Import as `@import("lib")`.
//!
//! Rule: lib holds pure, reusable pieces with no terminal or editor
//! IO. Anything that reads the tty, owns docs, or shells out to git
//! stays in `src`, however big it gets.

pub const ansi = @import("ansi.zig");
pub const highlight = @import("highlight.zig");
pub const redblacktree = @import("redblacktree.zig");
pub const regex = @import("regex.zig");
pub const treediff = @import("treediff.zig");
pub const undotree = @import("undotree.zig");
pub const usertrees = @import("usertrees.zig");

test {
    _ = ansi;
    _ = highlight;
    _ = redblacktree;
    _ = regex;
    _ = treediff;
    _ = undotree;
    _ = usertrees;
}
