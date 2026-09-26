//! kod, a small performant terminal editor.
//!
//! The event loop. `docs.zig` owns the open docs and every verb that
//! manages them; this file dispatches mode actions and runs git verbs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ansi = @import("lib").ansi;
const config = @import("config");
const Docs = @import("docs.zig");
const Mode = @import("mode.zig").Mode;
const command = @import("command.zig");
const git = @import("git_usertree.zig");
const paint = @import("paint.zig");
const tty_mod = @import("tty.zig");

var tty: tty_mod.Tty = .{};

fn isShiftArrow(ev: tty_mod.Event) bool {
    return ev == .s_up or ev == .s_down or ev == .s_left or ev == .s_right;
}

fn refreshGitDoc(io: std.Io, docs: *Docs.Docs) void {
    for (docs.entries.items) |*e| {
        if (e.doc == .git) e.doc.git.refreshLive(io) catch {};
    }
}

/// Run one `:gadd` etc verb, then refresh the log when open.
fn runGitVerb(gpa: Allocator, io: std.Io, docs: *Docs.Docs, mode: *Mode) void {
    const cmd = command.interpret(mode.commandText());
    const ok = switch (cmd) {
        .gadd => |p| blk: {
            if (p.len == 0) {
                break :blk runGitOp(gpa, io, git.add, &.{});
            }
            var paths = std.ArrayList([]const u8).empty;
            defer paths.deinit(gpa);
            var it = std.mem.tokenizeAny(u8, p, " \t");
            while (it.next()) |tok| paths.append(gpa, tok) catch break;
            break :blk runGitOp(gpa, io, git.add, paths.items);
        },
        .gcommit => |m| blk: {
            git.commit(gpa, io, m) catch break :blk false;
            break :blk true;
        },
        .gpush => blk: {
            git.push(gpa, io) catch break :blk false;
            break :blk true;
        },
        .gpull => blk: {
            git.pull(gpa, io) catch break :blk false;
            break :blk true;
        },
        .gswitch => |b| blk: {
            git.switchBranch(gpa, io, b) catch break :blk false;
            break :blk true;
        },
        .gbranch => |b| blk: {
            git.createBranch(gpa, io, b) catch break :blk false;
            break :blk true;
        },
        else => false,
    };
    if (!ok) {
        mode.flagCommandError(command.err_git);
        return;
    }
    refreshGitDoc(io, docs);
    mode.concludeCommand();
}

fn runGitOp(
    gpa: Allocator,
    io: std.Io,
    comptime op: fn (Allocator, std.Io, []const []const u8) anyerror!void,
    paths: []const []const u8,
) bool {
    op(gpa, io, paths) catch return false;
    return true;
}

const SelEdit = enum { delete, change, replace };

/// Selection path for delete/change/replace. True means handled and
/// the caller must continue. Delete clears and removes the range,
/// change deletes then enters insert vim-visual style, replace
/// overwrites keeping newlines. A failed range lookup also handles.
fn applySelectionEdit(
    gpa: Allocator,
    io: std.Io,
    docs: *Docs.Docs,
    mode: *Mode,
    kind: SelEdit,
    byte: u8,
) bool {
    const sl = mode.sel orelse return false;
    const b = docs.currentBuffer();
    const r = b.selBytes(sl.arow, sl.acol) catch return true;
    switch (kind) {
        .delete => {
            mode.selClear();
            b.deleteByteRange(r[0], r[1]) catch {};
        },
        .change => {
            b.deleteByteRange(r[0], r[1]) catch {};
            Docs.saveDoc(gpa, io, docs, mode);
            mode.enterInput();
            return true;
        },
        .replace => {
            mode.selClear();
            b.replaceRangeWithChar(r[0], r[1], byte) catch {};
        },
    }
    Docs.saveDoc(gpa, io, docs, mode);
    return true;
}

/// `kod --help`: the same command table `:help` prints, plus the
/// usage line and the keys that have no command. The table comes
/// from `command.help_entries`, so the flag and the command can never
/// disagree. Owned by `gpa`; the caller frees it.
fn cliHelp(gpa: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("kod {s} - terminal editor for large files\n", .{config.version});
    try w.writeAll("usage: kod [--help|--version] [file|dir]\n\n");
    for (command.help_entries) |e| {
        const row = try command.helpLine(gpa, e);
        defer gpa.free(row);
        try w.writeAll(row);
        try w.writeAll("\n");
    }
    try w.print(
        \\
        \\keys
        \\  normal: hjkl move, 4j counts, 0/$ line ends, gg/G top/bottom,
        \\    13 then Enter jumps to line 13, f/F word jumps, d deletes lines,
        \\    o/O opens a line, c overwrites, r plus a char replaces it,
        \\    u undoes, ctrl+R redoes, i inserts, : commands, n/p step hits,
        \\    q quits.
        \\  select: shift+arrows start it, motions extend, esc cancels.
        \\  command: type, up/down walks session history, enter submits.
        \\  insert: type, arrows move, enter, backspace, esc saves.
        \\
    , .{});
    return out.toOwnedSlice();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    // Flags answer before the terminal changes mode: no alternate
    // screen, no raw keys, just one line on stdout.
    if (argv.len >= 2) {
        if (std.mem.eql(u8, argv[1], "--version")) {
            var wb: [64]u8 = undefined;
            const msg = try std.fmt.bufPrint(&wb, "kod {s}\n", .{config.version});
            try std.Io.File.stdout().writeStreamingAll(io, msg);
            return;
        }
        if (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
            const text = try cliHelp(gpa);
            defer gpa.free(text);
            try std.Io.File.stdout().writeStreamingAll(io, text);
            return;
        }
    }

    var docs: Docs.Docs = .{};
    defer {
        Docs.joinExec(gpa, &docs);
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            Docs.closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const first: Docs.Doc = if (argv.len < 2)
        .{ .welcome = try Docs.openWelcomeDoc(gpa) }
    else
        try Docs.openArgDoc(gpa, io, argv[1]);
    const first_id: u32 = 1;
    try docs.entries.append(gpa, .{ .id = first_id, .doc = first });
    docs.next_id = 2;
    docs.current = first_id;

    try tty.enter();
    defer tty.exit();

    const out = std.Io.File.stdout();
    try out.writeStreamingAll(io, ansi.alt_enter);
    defer out.writeStreamingAll(io, ansi.alt_exit) catch {};

    var mode: Mode = .{};
    mode.hist_gpa = gpa;
    defer mode.deinit();
    var last_current: u32 = first_id;
    while (true) {
        // Finished background exec runs land before paint: the tree
        // and gutter marks appear on the next frame, never mid-frame.
        Docs.pollExec(gpa, io, &docs, &mode);
        // Doc switches strand the anchor, so drop the overlay and
        // resync. Runs before paint: no stale frame ever draws.
        if (docs.current != last_current) {
            mode.selClear();
            last_current = docs.current;
        }
        paint.paint(io, docs.currentBuffer(), tty_mod.size(), mode) catch {};
        const ev = tty_mod.readEvent();
        const cur = &docs.entries.items[docs.currentIndex()].doc;
        if (mode.isBareNormalEnter(ev)) {
            if (cur.* == .dir) {
                Docs.openSelected(gpa, io, &docs);
                continue;
            }
            if (cur.* == .bufs) {
                Docs.switchBufsSelected(&docs);
                continue;
            }
            if (cur.* == .git) {
                Docs.activateGitSelected(gpa, io, &docs);
                continue;
            }
            if (cur.* == .search) {
                Docs.activateSearchSelected(gpa, io, &docs);
                continue;
            }
            if (cur.* == .trees) {
                Docs.activateTreeSelected(gpa, io, &docs, &mode);
                continue;
            }
            if (cur.* == .exec) {
                Docs.activateExecSelected(gpa, io, &docs);
                continue;
            }
        }
        const buf = docs.currentBuffer();
        const readonly = cur.* == .git or cur.* == .diff or cur.* == .search or cur.* == .trees or cur.* == .exec;
        // Shift+arrows snapshot the anchor before the motion runs, so
        // the selection extends from the pre-move cursor.
        if (mode.kind == .normal and isShiftArrow(ev) and mode.sel == null) {
            mode.selStart(buf.row, buf.col);
        }
        switch (mode.handle(ev)) {
            .none => {},
            .quit => break,
            .save => Docs.saveDoc(gpa, io, &docs, &mode),
            .open_fs => {
                const arg = switch (command.interpret(mode.commandText())) {
                    .fs => |p| p,
                    else => {
                        mode.flagCommandError(command.err_unknown);
                        continue;
                    },
                };
                Docs.openFs(gpa, io, &docs, &mode, arg) catch {
                    mode.flagCommandError(command.err_no_buffer);
                };
            },
            .open_bufs => Docs.openBufs(gpa, &docs),
            .open_trees => Docs.openTrees(gpa, io, &docs, &mode),
            .open_help => Docs.openHelp(gpa, &docs),
            .open_search => {
                const run = command.interpret(mode.commandText());
                const spec = switch (run) {
                    .search => |s| s,
                    else => {
                        mode.flagCommandError(command.err_unknown);
                        continue;
                    },
                };
                Docs.searchRun(gpa, io, &docs, &mode, spec.scope, spec.spec);
            },
            .search_next => {
                mode.selClear();
                if (docs.entries.items[docs.currentIndex()].doc == .exec) {
                    Docs.execStep(gpa, io, &docs, 1);
                } else {
                    Docs.searchStep(gpa, io, &docs, 1);
                }
            },
            .search_prev => {
                mode.selClear();
                if (docs.entries.items[docs.currentIndex()].doc == .exec) {
                    Docs.execStep(gpa, io, &docs, -1);
                } else {
                    Docs.searchStep(gpa, io, &docs, -1);
                }
            },
            .open_git => Docs.openGit(gpa, io, &docs, &mode),
            .exec_run => {
                const run = command.interpret(mode.commandText());
                const c = switch (run) {
                    .exec => |x| x,
                    else => {
                        mode.flagCommandError(command.err_unknown);
                        continue;
                    },
                };
                Docs.runExec(gpa, io, &docs, &mode, c, false);
            },
            .exec_arm => {
                const run = command.interpret(mode.commandText());
                const c = switch (run) {
                    .exec_save => |x| x,
                    else => {
                        mode.flagCommandError(command.err_unknown);
                        continue;
                    },
                };
                Docs.runExec(gpa, io, &docs, &mode, c, true);
            },
            .gadd, .gcommit, .gpush, .gpull, .gswitch, .gbranch => runGitVerb(gpa, io, &docs, &mode),
            .move => |m| {
                // Views cycle past the ends; files clamp so edits
                // never wrap the cursor. Camera follows either way.
                if (Docs.isFileLike(cur)) {
                    buf.move(m.drow, m.dcol) catch {};
                } else {
                    buf.moveWrap(m.drow, m.dcol) catch {};
                }
            },
            .insert => |ch| {
                if (readonly) continue;
                buf.insert(ch) catch {};
            },
            .backspace => {
                if (readonly) continue;
                buf.backspace() catch {};
            },
            .delete_lines => |n| {
                if (readonly) continue;
                // With an active selection the range wins; counts die
                // in mode, and the payload is ignored here.
                if (applySelectionEdit(gpa, io, &docs, &mode, .delete, 0)) continue;
                docs.currentBuffer().deleteLines(n) catch {};
                // Normal-mode edits save at once: there is no
                // insert session to leave.
                Docs.saveDoc(gpa, io, &docs, &mode);
            },
            .undo => {
                if (readonly) continue;
                mode.selClear();
                _ = docs.currentBuffer().undo() catch {};
                Docs.saveDoc(gpa, io, &docs, &mode);
            },
            .redo => {
                if (readonly) continue;
                mode.selClear();
                _ = docs.currentBuffer().redo() catch {};
                Docs.saveDoc(gpa, io, &docs, &mode);
            },
            .open_line => |o| {
                if (readonly) continue;
                buf.openLine(o.below, o.n) catch {};
            },
            .word => |n| buf.skipWord(n) catch {},
            .change => |c| {
                if (readonly) continue;
                // `c` on a selection deletes it and drops into insert,
                // vim-visual style. Plain `c` overwrites in place.
                if (applySelectionEdit(gpa, io, &docs, &mode, .change, c.byte)) continue;
                docs.currentBuffer().changeChars(c.n, c.byte) catch {};
                Docs.saveDoc(gpa, io, &docs, &mode);
            },
            .replace => |c| {
                if (readonly) continue;
                // `r` overwrites every selected char but keeps newlines,
                // so line structure survives. Without a selection this
                // arm is unreachable: mode degrades `r` to `.change`.
                if (applySelectionEdit(gpa, io, &docs, &mode, .replace, c.byte)) continue;
                docs.currentBuffer().changeChars(c.n, c.byte) catch {};
                Docs.saveDoc(gpa, io, &docs, &mode);
            },
            .jump => |j| buf.jump(j) catch {},
        }
    }
}

test {
    _ = Docs;
    _ = Mode;
    _ = command;
    _ = paint;
}
