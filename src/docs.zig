//! Open document registry. Owns every open doc, folder verbs that
//! create and switch docs (`:fs`, `:buf`, `:git`, `:help`), the buf-list
//! save that closes/renames/opens docs, and per-doc saving. `main.zig`
//! keeps the event loop and git-verb dispatch; everything about the
//! registry lives here.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const buffer_mod = @import("buffer.zig");
const Mode = @import("mode.zig").Mode;
const command = @import("command.zig");
const fs = @import("fs_usertree.zig");
const bufs = @import("buf_usertree.zig");
const git = @import("git_usertree.zig");
const search = @import("search.zig");
const tree = @import("tree_usertree.zig");
const exec = @import("exec_usertree.zig");
const regex = @import("lib").regex;
const treediff = @import("lib").treediff;

pub const Doc = union(enum) {
    file: FileDoc,
    dir: fs.FsBuffer,
    bufs: bufs.BufBuffer,
    git: git.GitBuffer,
    search: search.SearchBuffer,
    trees: tree.TreeBuffer,
    exec: exec.ExecBuffer,
    diff: DiffDoc,
    welcome: WelcomeDoc,
};

const FileDoc = struct {
    buf: Buffer,
    /// Owned path. `buf.path` points here.
    path_mem: []u8,
};

/// Scratch diff view opened by enter on a git file line. Readonly.
/// `buf.path` points at `title_mem`, never at the file, so a save can
/// not touch the worktree.
const DiffDoc = struct {
    buf: Buffer,
    title_mem: []u8,
};

const WelcomeDoc = struct {
    buf: Buffer,
    /// Owned title. `buf.path` points here.
    title_mem: []u8,
};

const version = @import("config").version;
const welcome_title = "*welcome*";
const help_title = "*help*";

pub fn openWelcomeDoc(gpa: Allocator) !WelcomeDoc {
    const text = try std.fmt.allocPrint(gpa,
        \\kod {s}
        \\
        \\a terminal editor for large files. It pages the file and keeps
        \\only your edits, and every list is the same tree.
        \\
        \\  :fs [path]        open a directory as an editable buffer
        \\  :exec-save <cmd>  run a tool, and rerun it on every save
        \\  :tree [name]      inspect undo, search, exec, buffers, git, commands
        \\
        \\:help lists every command with its keys.
        \\hjkl move, i insert, : commands, q quits.
        \\enter opens the row under the cursor, esc saves and returns.
    , .{version});
    errdefer gpa.free(text);
    const title = try gpa.dupe(u8, welcome_title);
    errdefer gpa.free(title);
    var buf = try Buffer.initOwned(gpa, title, text);
    buf.hl_mode = .listing;
    return .{ .buf = buf, .title_mem = title };
}

/// Full command listing rendered from the table in command.zig.
/// Reuses the welcome doc: scratch text, esc clears it.
fn openHelpDoc(gpa: Allocator) !WelcomeDoc {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "kod {s} commands\n\n", .{version});
    for (command.help_entries) |e| {
        const row = try command.helpLine(gpa, e);
        defer gpa.free(row);
        try out.appendSlice(gpa, row);
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa,
        \\
        \\keys
        \\  normal: hjkl move, 4j counts, 0/$ line ends, gg/G top/bottom,
        \\    13 then Enter jumps to line 13, f/F word jumps, d deletes lines,
        \\    o/O opens a line, c overwrites, r plus a char replaces it,
        \\    u undoes, ctrl+R redoes, i inserts, : commands, q quits.
        \\  select: shift+arrows start it, motions extend, esc cancels.
        \\    d deletes, c swaps in insert, r plus a char overwrites.
        \\  command: type, up/down walks session history, enter submits.
        \\    /pat/repl/flags regex in buffer, f/ filenames, b/ buffers.
        \\    repl empty deletes, flags i insensitive, g all. n/p steps.
        \\  insert: type, arrows move, enter, backspace. esc saves.
        \\  fs view: ../ opens the parent, enter opens, esc saves edits to disk.
        \\  git view: enter folds commits and headers, enter on a file opens its diff.
        \\  exec view: enter opens a hit from any row, n/p walk hits, esc never edits.
    );
    const text = try out.toOwnedSlice(gpa);
    errdefer gpa.free(text);
    const title = try gpa.dupe(u8, help_title);
    errdefer gpa.free(title);
    var buf = try Buffer.initOwned(gpa, title, text);
    buf.hl_mode = .listing;
    return .{ .buf = buf, .title_mem = title };
}

/// `:help`: switch to the listing when open, else create it.
pub fn openHelp(gpa: Allocator, docs: *Docs) void {
    for (docs.entries.items) |*e| {
        if (e.doc == .welcome and std.mem.eql(u8, docPath(&e.doc), help_title)) {
            docs.current = e.id;
            return;
        }
    }
    var help = openHelpDoc(gpa) catch return;
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .welcome = help } }) catch {
        help.buf.close();
        gpa.free(help.title_mem);
        return;
    };
    docs.next_id += 1;
    docs.current = id;
}

/// Open argv path as a dir view or a file, by kind. Missing paths fall
/// through to the file open, which reports the error.
pub fn openArgDoc(gpa: Allocator, io: std.Io, path: []const u8) !Doc {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
        if (st.kind == .directory) {
            return .{ .dir = try fs.FsBuffer.open(gpa, io, .cwd(), path) };
        }
    } else |_| {}
    return .{ .file = try openFileDoc(gpa, io, path) };
}

pub const DocEntry = struct { id: u32, doc: Doc };

/// Open docs with stable ids. The current doc is an id, never an index,
/// so closing one doc never strands the cursor on another.
pub const Docs = struct {
    entries: std.ArrayList(DocEntry) = .empty,
    next_id: u32 = 1,
    current: u32 = 0,
    search: search.State = .{},
    /// At most one exec run at a time. The worker owns its memory
    /// until the main loop joins it in `pollExec`.
    exec_runner: ?exec.Runner = null,
    /// Last exec command and its target doc, for bare `:exec` reruns.
    exec_last_cmd: ?[]u8 = null,
    exec_last_target: u32 = 0,

    fn indexOf(self: *const Docs, id: u32) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.id == id) return i;
        }
        return null;
    }

    pub fn currentIndex(self: *const Docs) usize {
        return self.indexOf(self.current) orelse 0;
    }

    pub fn currentBuffer(self: *Docs) *Buffer {
        return docBuffer(&self.entries.items[self.currentIndex()].doc);
    }
};

pub fn openFileDoc(gpa: Allocator, io: std.Io, path: []const u8) !FileDoc {
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    const buf = try Buffer.openDir(gpa, io, .cwd(), owned);
    return .{ .buf = buf, .path_mem = owned };
}

pub fn closeDoc(gpa: Allocator, doc: *Doc) void {
    switch (doc.*) {
        .file => |*f| {
            f.buf.close();
            gpa.free(f.path_mem);
        },
        .dir => |*d| d.close(),
        .bufs => |*b| b.close(),
        .git => |*g| g.close(),
        .trees => |*t| t.close(),
        .search => |*s| s.close(),
        .exec => |*e| e.close(),
        .diff => |*d| {
            d.buf.close();
            gpa.free(d.title_mem);
        },
        .welcome => |*w| {
            w.buf.close();
            gpa.free(w.title_mem);
        },
    }
    doc.* = undefined;
}

fn docBuffer(doc: *Doc) *Buffer {
    return switch (doc.*) {
        .file => |*f| &f.buf,
        .dir => |*d| &d.buf,
        .bufs => |*b| &b.buf,
        .git => |*g| &g.buf,
        .trees => |*t| &t.buf,
        .search => |*s| &s.buf,
        .exec => |*e| &e.buf,
        .diff => |*d| &d.buf,
        .welcome => |*w| &w.buf,
    };
}

fn docIsDir(doc: *const Doc) bool {
    return doc.* == .dir;
}

pub fn docPath(doc: *const Doc) []const u8 {
    if (doc.* == .file) return doc.file.buf.path;
    if (doc.* == .dir) return doc.dir.dir_path;
    if (doc.* == .bufs) return doc.bufs.buf.path;
    if (doc.* == .git) return doc.git.buf.path;
    if (doc.* == .trees) return doc.trees.buf.path;
    if (doc.* == .search) return doc.search.buf.path;
    if (doc.* == .exec) return doc.exec.buf.path;
    if (doc.* == .diff) return doc.diff.buf.path;
    return doc.welcome.buf.path;
}

fn docDirty(doc: *const Doc) bool {
    if (doc.* == .file) return doc.file.buf.dirty;
    if (doc.* == .dir) return doc.dir.buf.dirty;
    if (doc.* == .bufs) return doc.bufs.buf.dirty;
    if (doc.* == .git) return doc.git.buf.dirty;
    if (doc.* == .trees) return doc.trees.buf.dirty;
    if (doc.* == .search) return doc.search.buf.dirty;
    if (doc.* == .exec) return doc.exec.buf.dirty;
    if (doc.* == .diff) return doc.diff.buf.dirty;
    return doc.welcome.buf.dirty;
}

fn trimSlash(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') end -= 1;
    return p[0..end];
}

/// Index of the open doc showing `name`, or null. Files and dirs with
/// the same spelling are distinct, matching the views.
pub fn findByPath(docs: *const Docs, name: []const u8, is_dir: bool) ?usize {
    const want = trimSlash(name);
    for (docs.entries.items, 0..) |*e, i| {
        if (docIsDir(&e.doc) != is_dir) continue;
        if (std.mem.eql(u8, trimSlash(docPath(&e.doc)), want)) return i;
    }
    return null;
}

/// File-like docs a user reads: files, scratch welcome, and diffs.
/// Views (buf list, dirs, git log) never count: closing every
/// file-like doc would strand the session in an empty list. Main
/// also uses this to pick clamped versus wrapping motion.
pub fn isFileLike(doc: *const Doc) bool {
    return doc.* == .file or doc.* == .welcome or doc.* == .diff;
}

fn fileLikeCount(docs: *const Docs) usize {
    var n: usize = 0;
    for (docs.entries.items) |*e| {
        if (isFileLike(&e.doc)) n += 1;
    }
    return n;
}

/// Close and remove the entry. Never removes the current doc; callers
/// only close other docs.
fn closeEntry(gpa: Allocator, docs: *Docs, idx: usize) void {
    assert(docs.entries.items[idx].id != docs.current);
    closeDoc(gpa, &docs.entries.items[idx].doc);
    _ = docs.entries.swapRemove(idx);
}

/// Open `:fs` target: switch to the doc when already open, else add it.
/// Leaves the registry untouched on failure.
pub fn openFs(
    gpa: Allocator,
    io: std.Io,
    docs: *Docs,
    mode: *Mode,
    arg: []const u8,
) !void {
    var dir_path: []u8 = undefined;
    var select: ?[]const u8 = null;
    if (arg.len == 0) {
        const cur = docPath(&docs.entries.items[docs.currentIndex()].doc);
        dir_path = try gpa.dupe(u8, std.fs.path.dirname(cur) orelse ".");
    } else if (std.Io.Dir.cwd().statFile(io, arg, .{})) |st| {
        if (st.kind == .directory) {
            dir_path = try gpa.dupe(u8, arg);
        } else {
            dir_path = try gpa.dupe(u8, std.fs.path.dirname(arg) orelse ".");
            select = std.fs.path.basename(arg);
        }
    } else |err| {
        return err;
    }
    defer gpa.free(dir_path);

    if (findByPath(docs, dir_path, true)) |idx| {
        if (select) |s| docs.entries.items[idx].doc.dir.selectRow(s);
        docs.current = docs.entries.items[idx].id;
        mode.concludeCommand();
        return;
    }
    var fb = try fs.FsBuffer.open(gpa, io, .cwd(), dir_path);
    if (select) |s| fb.selectRow(s);
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .dir = fb } }) catch {
        fb.close();
        return error.OutOfMemory;
    };
    docs.next_id += 1;
    docs.current = id;
    mode.concludeCommand();
}

/// Enter on a line in a dir view opens that entry. Row `../` opens the
/// parent. Switches when already open. Silent no-op when the line is
/// blank or the entry vanished.
pub fn openSelected(gpa: Allocator, io: std.Io, docs: *Docs) void {
    const fb = &docs.entries.items[docs.currentIndex()].doc.dir;
    var line_buf: [4096]u8 = undefined;
    const row_line = fb.buf.line(fb.buf.row, &line_buf) catch return;
    if (std.mem.eql(u8, row_line, "../")) {
        openParent(gpa, io, docs);
        return;
    }
    const e = fb.entryAtRow(fb.buf.row, &line_buf) orelse return;
    const child = std.fs.path.join(gpa, &.{ fb.dir_path, e.name }) catch return;
    defer gpa.free(child);
    if (findByPath(docs, child, e.is_dir)) |idx| {
        docs.current = docs.entries.items[idx].id;
        return;
    }
    if (e.is_dir) {
        var nb = fs.FsBuffer.open(gpa, io, .cwd(), child) catch return;
        const id = docs.next_id;
        docs.entries.append(gpa, .{ .id = id, .doc = .{ .dir = nb } }) catch {
            nb.close();
            return;
        };
        docs.next_id += 1;
        docs.current = id;
    } else {
        var fd = openFileDoc(gpa, io, child) catch return;
        const id = docs.next_id;
        docs.entries.append(gpa, .{ .id = id, .doc = .{ .file = fd } }) catch {
            fd.buf.close();
            gpa.free(fd.path_mem);
            return;
        };
        docs.next_id += 1;
        docs.current = id;
    }
}

/// Enter on the `../` first row opens the parent directory. Switches
/// when already open. Stays put at the filesystem root.
fn openParent(gpa: Allocator, io: std.Io, docs: *Docs) void {
    const fb = &docs.entries.items[docs.currentIndex()].doc.dir;
    const cur = trimSlash(fb.dir_path);
    const raw: []const u8 = std.fs.path.dirname(cur) orelse blk: {
        if (std.fs.path.isAbsolute(cur)) break :blk cur;
        break :blk "..";
    };
    const parent = if (raw.len == 0) "." else raw;
    if (findByPath(docs, parent, true)) |idx| {
        docs.current = docs.entries.items[idx].id;
        return;
    }
    var nb = fs.FsBuffer.open(gpa, io, .cwd(), parent) catch return;
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .dir = nb } }) catch {
        nb.close();
        return;
    };
    docs.next_id += 1;
    docs.current = id;
}

/// Enter on a buf-list line switches to the doc shown there. Resolves
/// by visible text (not snapshot row) so unsaved edits still navigate
/// correctly: after `d` the line below moves up, and enter follows it.
pub fn switchBufsSelected(docs: *Docs) void {
    const bb = &docs.entries.items[docs.currentIndex()].doc.bufs;
    var line_buf: [4096]u8 = undefined;
    const line = bb.buf.line(bb.buf.row, &line_buf) catch return;
    const parsed = treediff.parseBufsLine(line) orelse return;
    if (findByPath(docs, parsed.name, parsed.is_dir)) |idx| {
        docs.current = docs.entries.items[idx].id;
    }
}

/// `:buf`: switch to the listing when open (refreshed), else create it.
pub fn openBufs(gpa: Allocator, docs: *Docs) void {
    for (docs.entries.items) |*e| {
        if (e.doc == .bufs) {
            refreshBufsDoc(gpa, docs, e.id) catch {};
            docs.current = e.id;
            return;
        }
    }
    var list = std.ArrayList(bufs.Entry).empty;
    defer list.deinit(gpa);
    collectBufsEntries(gpa, docs, &list) catch return;
    var bb = bufs.BufBuffer.open(gpa, "*buffers*", list.items) catch return;
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .bufs = bb } }) catch {
        bb.close();
        return;
    };
    docs.next_id += 1;
    docs.current = id;
}

fn collectBufsEntries(
    gpa: Allocator,
    docs: *const Docs,
    out: *std.ArrayList(bufs.Entry),
) !void {
    for (docs.entries.items) |*e| {
        if (e.doc == .bufs or e.doc == .dir or e.doc == .git or e.doc == .search or e.doc == .trees) continue;
        try out.append(gpa, .{
            .id = e.id,
            .name = trimSlash(docPath(&e.doc)),
            .is_dir = docIsDir(&e.doc),
        });
    }
}

/// Rebuild a buf listing from the registry. The listing itself and
/// directory views are never listed: each tree kind stays separate.
fn refreshBufsDoc(gpa: Allocator, docs: *Docs, bufs_id: u32) !void {
    const idx = docs.indexOf(bufs_id) orelse return error.NoSuchDoc;
    var list = std.ArrayList(bufs.Entry).empty;
    defer list.deinit(gpa);
    for (docs.entries.items) |*e| {
        if (e.doc == .bufs or e.doc == .dir or e.doc == .git or e.doc == .search or e.doc == .trees) continue;
        try list.append(gpa, .{
            .id = e.id,
            .name = trimSlash(docPath(&e.doc)),
            .is_dir = docIsDir(&e.doc),
        });
    }
    try docs.entries.items[idx].doc.bufs.refresh(list.items);
}

fn note(first_err: *?anyerror, err: anyerror) void {
    if (first_err.* == null) first_err.* = err;
}

/// `:git`: switch to the log when open (refreshed), else create it.
/// Single log doc per session. Leaves the registry untouched on failure.
pub fn openGit(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) void {
    for (docs.entries.items) |*e| {
        if (e.doc == .git) {
            e.doc.git.refreshLive(io) catch {};
            docs.current = e.id;
            mode.concludeCommand();
            return;
        }
    }
    var gb = git.GitBuffer.openLive(gpa, io) catch {
        mode.flagCommandError(command.err_git);
        return;
    };
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .git = gb } }) catch {
        gb.close();
        mode.flagCommandError(command.err_oom);
        return;
    };
    docs.next_id += 1;
    docs.current = id;
    mode.concludeCommand();
}

/// Enter on a git line: file lines open their diff as a scratch
/// buffer, everything else folds or unfolds.
pub fn activateGitSelected(gpa: Allocator, io: std.Io, docs: *Docs) void {
    const gb = &docs.entries.items[docs.currentIndex()].doc.git;
    var line_buf: [4096]u8 = undefined;
    if (gb.diffTargetAtRow(gb.buf.row, &line_buf)) |t| {
        openGitDiff(gpa, io, docs, t);
        return;
    }
    gb.toggleLive(io, gb.buf.row) catch {};
}

/// Open one file diff from the git view as a readonly scratch doc.
/// Same title switches instead of duplicating. Silent no-op on git or
/// allocation failure.
fn openGitDiff(gpa: Allocator, io: std.Io, docs: *Docs, t: git.GitBuffer.DiffTarget) void {
    const file = gpa.dupe(u8, t.file) catch return;
    defer gpa.free(file);
    const hash = gpa.dupe(u8, t.hash) catch return;
    defer gpa.free(hash);
    const title = switch (t.kind) {
        .unstaged => std.fmt.allocPrint(gpa, "*diff unstaged {s}*", .{file}) catch return,
        .staged => std.fmt.allocPrint(gpa, "*diff staged {s}*", .{file}) catch return,
        .commit => std.fmt.allocPrint(gpa, "*diff {s} {s}*", .{
            hash[0..@min(hash.len, 7)],
            file,
        }) catch return,
    };
    defer gpa.free(title);
    if (findByPath(docs, title, false)) |idx| {
        docs.current = docs.entries.items[idx].id;
        return;
    }
    const out = switch (t.kind) {
        .unstaged => git.diffWorktreeFileAlloc(gpa, io, false, file) catch return,
        .staged => git.diffWorktreeFileAlloc(gpa, io, true, file) catch return,
        .commit => git.showCommitFileAlloc(gpa, io, hash, file) catch return,
    };
    defer gpa.free(out);
    const owned_title = gpa.dupe(u8, title) catch return;
    errdefer gpa.free(owned_title);
    const text = gpa.dupe(u8, out) catch {
        gpa.free(owned_title);
        return;
    };
    errdefer gpa.free(text);
    var b = Buffer.initOwned(gpa, owned_title, text) catch {
        gpa.free(owned_title);
        gpa.free(text);
        return;
    };
    b.hl_mode = .gitlog;
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .diff = .{ .buf = b, .title_mem = owned_title } } }) catch {
        b.close();
        gpa.free(owned_title);
        return;
    };
    docs.next_id += 1;
    docs.current = id;
}

/// Esc on any doc. The trees doc re-renders its snapshot, so it takes
/// the mode for the command log.
pub fn saveDoc(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) void {
    const c = &docs.entries.items[docs.currentIndex()].doc;
    if (c.* == .dir) {
        c.dir.save() catch {};
    } else if (c.* == .bufs) {
        applyBufsSave(gpa, io, docs) catch {};
    } else if (c.* == .git) {
        c.git.refreshLive(io) catch {};
        c.git.buf.dirty = false;
    } else if (c.* == .search) {
        c.search.buf.dirty = false;
    } else if (c.* == .trees) {
        refreshTree(gpa, io, docs, mode) catch {};
        c.trees.buf.dirty = false;
    } else if (c.* == .exec) {
        c.exec.buf.dirty = false;
    } else if (c.* == .diff) {
        c.diff.buf.dirty = false;
    } else if (c.* == .welcome) {
        c.welcome.buf.dirty = false;
    } else {
        c.file.buf.save() catch {};
        rerunExecOnSave(gpa, io, docs, docs.current);
    }
}

/// Persist buf-list edits against the registry: deleted lines close
/// their docs (files stay on disk; dirty docs and the last doc are
/// kept), edited lines rename files on disk and rehome their docs,
/// new lines open files or directories.
/// Refreshes the listing afterwards so it shows what is really open.
fn bufsSnapAt(d: *Docs, id: u32) !struct { snap: []treediff.SnapEntry, ids: []u32 } {
    const idx = d.indexOf(id) orelse return error.NoSuchDoc;
    const b = &d.entries.items[idx].doc.bufs;
    return .{ .snap = b.snapshot.items, .ids = b.ids.items };
}

fn descLessThan(_: void, a: usize, b: usize) bool {
    return a > b;
}

fn closeDeletedDocs(gpa: Allocator, docs: *Docs, bufs_id: u32, rows: []const usize) !void {
    for (rows) |row| {
        const s = try bufsSnapAt(docs, bufs_id);
        if (row >= s.ids.len) continue;
        const idx = docs.indexOf(s.ids[row]) orelse continue;
        if (docs.entries.items[idx].doc == .bufs) continue;
        if (docDirty(&docs.entries.items[idx].doc)) continue;
        if (docs.entries.items.len == 1) continue;
        // Never strand the session in an empty list: the last
        // file-like doc is kept and its line comes back on the
        // refresh below.
        if (isFileLike(&docs.entries.items[idx].doc) and fileLikeCount(docs) <= 1) continue;
        closeEntry(gpa, docs, idx);
    }
}

fn renameDocs(gpa: Allocator, io: std.Io, docs: *Docs, bufs_id: u32, renames: []const treediff.Plan.Rename, desired: []const treediff.DesiredEntry, first_err: *?anyerror) !void {
    for (renames) |r| {
        const s = try bufsSnapAt(docs, bufs_id);
        if (r.from >= s.snap.len or r.to >= desired.len) continue;
        const idx = docs.indexOf(s.ids[r.from]) orelse continue;
        if (docs.entries.items[idx].doc != .file) continue;
        const oldp = docPath(&docs.entries.items[idx].doc);
        const newp = desired[r.to].name;
        const abs_old = std.fs.path.isAbsolute(oldp);
        var target: []const u8 = newp;
        var target_mem: ?[]u8 = null;
        defer if (target_mem) |m| gpa.free(m);
        if (abs_old and !std.fs.path.isAbsolute(newp)) {
            const parent = std.fs.path.dirname(oldp) orelse ".";
            target_mem = std.fs.path.join(gpa, &.{ parent, newp }) catch |err| {
                note(first_err, err);
                continue;
            };
            target = target_mem.?;
        }
        if (std.fs.path.dirname(target)) |parent| {
            if (!std.mem.eql(u8, parent, ".")) {
                std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
                    note(first_err, err);
                    continue;
                };
            }
        }
        if (std.Io.Dir.cwd().statFile(io, target, .{})) |_| {
            note(first_err, error.PathAlreadyExists);
            continue;
        } else |_| {}
        std.Io.Dir.rename(.cwd(), oldp, .cwd(), target, io) catch |err| {
            note(first_err, err);
            continue;
        };
        const mem = gpa.dupe(u8, target) catch |err| {
            note(first_err, err);
            continue;
        };
        const f = &docs.entries.items[docs.indexOf(s.ids[r.from]) orelse continue].doc.file;
        gpa.free(f.path_mem);
        f.path_mem = mem;
        f.buf.path = mem;
    }
}

fn createDocs(gpa: Allocator, io: std.Io, docs: *Docs, creates: []const usize, desired: []const treediff.DesiredEntry, first_err: *?anyerror) void {
    for (creates) |ni| {
        const d = desired[ni];
        if (findByPath(docs, d.name, d.is_dir) != null) continue;
        if (d.is_dir) {
            std.Io.Dir.cwd().createDirPath(io, d.name) catch |err| {
                note(first_err, err);
                continue;
            };
            var nb = fs.FsBuffer.open(gpa, io, .cwd(), d.name) catch |err| {
                note(first_err, err);
                continue;
            };
            const id = docs.next_id;
            docs.entries.append(gpa, .{ .id = id, .doc = .{ .dir = nb } }) catch {
                nb.close();
                note(first_err, error.OutOfMemory);
                continue;
            };
            docs.next_id += 1;
        } else {
            if (std.fs.path.dirname(d.name)) |parent| {
                if (!std.mem.eql(u8, parent, ".")) {
                    std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
                        note(first_err, err);
                        continue;
                    };
                }
            }
            if (std.Io.Dir.cwd().statFile(io, d.name, .{})) |_| {} else |_| {
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = d.name, .data = "" }) catch |err| {
                    note(first_err, err);
                    continue;
                };
            }
            var fd = openFileDoc(gpa, io, d.name) catch |err| {
                note(first_err, err);
                continue;
            };
            const id = docs.next_id;
            docs.entries.append(gpa, .{ .id = id, .doc = .{ .file = fd } }) catch {
                fd.buf.close();
                gpa.free(fd.path_mem);
                note(first_err, error.OutOfMemory);
                continue;
            };
            docs.next_id += 1;
        }
    }
}

fn applyBufsSave(gpa: Allocator, io: std.Io, docs: *Docs) !void {
    const bufs_id = docs.current;
    const bidx = docs.indexOf(bufs_id) orelse return;
    if (docs.entries.items[bidx].doc != .bufs) return;
    if (!docs.entries.items[bidx].doc.bufs.buf.dirty) return;

    var line_buf: [4096]u8 = undefined;
    const bb = &docs.entries.items[bidx].doc.bufs;
    const nlines = bb.buf.lineCount();
    var i: u64 = 0;
    while (i < nlines) : (i += 1) {
        if (try bb.buf.lineLen(i) > @as(u64, line_buf.len)) return error.NameTooLong;
    }

    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }
    var desired = std.ArrayList(treediff.DesiredEntry).empty;
    defer desired.deinit(gpa);
    i = 0;
    while (i < nlines) : (i += 1) {
        const b = &docs.entries.items[docs.indexOf(bufs_id) orelse return error.NoSuchDoc].doc.bufs.buf;
        const line = try b.line(i, &line_buf);
        const parsed = treediff.parseBufsLine(line) orelse continue;
        var dup = false;
        for (desired.items) |prev| {
            if (prev.is_dir == parsed.is_dir and std.mem.eql(u8, prev.name, parsed.name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const kept = try gpa.dupe(u8, parsed.name);
        try owned.append(gpa, kept);
        try desired.append(gpa, .{ .name = kept, .is_dir = parsed.is_dir });
    }

    var plan = blk: {
        const s = try bufsSnapAt(docs, bufs_id);
        break :blk try treediff.planOps(gpa, s.snap, desired.items);
    };
    defer plan.deinit(gpa);

    var first_err: ?anyerror = null;

    // Bottom-up: the topmost row closes last, so when the guard below
    // refuses, the surviving doc is the top of the list.
    std.mem.sort(usize, plan.deletes.items, {}, descLessThan);
    try closeDeletedDocs(gpa, docs, bufs_id, plan.deletes.items);
    try renameDocs(gpa, io, docs, bufs_id, plan.renames.items, desired.items, &first_err);
    createDocs(gpa, io, docs, plan.creates.items, desired.items, &first_err);

    try refreshBufsDoc(gpa, docs, bufs_id);
    if (first_err) |e| return e;
}

/// Text buffer with real content: files and scratch views. Views
/// with generated text (dirs, listings, logs, results) never match.
fn fileLikeBuffer(doc: *Doc) ?*Buffer {
    return switch (doc.*) {
        .file => |*f| &f.buf,
        .welcome => |*w| &w.buf,
        .diff => |*d| &d.buf,
        else => null,
    };
}

const search_title = "*search*";
const max_search_hits: usize = 1000;
const max_walk_files: usize = 50000;
const max_walk_scanned: usize = 200000;
const preview_len: usize = 120;

/// Run one `/`, `f/`, `b/`, or `bl/` submit. Bad specs and patterns
/// flag the command box and keep the previous working query.
pub fn searchRun(
    gpa: Allocator,
    io: std.Io,
    docs: *Docs,
    mode: *Mode,
    scope: command.SearchScope,
    spec_text: []const u8,
) void {
    const spec = search.parseSpec(spec_text) catch {
        mode.flagCommandError(command.err_bad_spec);
        return;
    };
    // Scope must be viable before the submit clobbers the query.
    if (scope == .buffer) {
        if (fileLikeBuffer(&docs.entries.items[docs.currentIndex()].doc) == null) {
            mode.flagCommandError(command.err_no_buffer);
            return;
        }
    } else if (scope == .buffers) {
        var any = false;
        for (docs.entries.items) |*e| {
            if (fileLikeBuffer(&e.doc) != null) {
                any = true;
                break;
            }
        }
        if (!any) {
            mode.flagCommandError(command.err_no_buffer);
            return;
        }
    }
    docs.search.submit(gpa, scope, spec) catch |e| {
        mode.flagCommandError(if (e == error.OutOfMemory) command.err_oom else command.err_bad_spec);
        return;
    };
    switch (scope) {
        .buffer => runBufferScope(gpa, io, docs, mode),
        .buffers => runBuffersScope(gpa, io, docs, mode),
        .files => runFilesScope(gpa, io, docs, mode),
    }
}

fn runBufferScope(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) void {
    const st = &docs.search;
    const idx = docs.currentIndex();
    st.last_doc = docs.entries.items[idx].id;
    const buf = fileLikeBuffer(&docs.entries.items[idx].doc).?;
    var re = st.compile(gpa) catch {
        mode.flagCommandError(command.err_bad_spec);
        return;
    };
    defer re.deinit();
    if (st.has_repl) {
        if (st.global) {
            replaceAllBuffer(gpa, buf, &re, st.replacement) catch {};
        } else {
            replaceNextBuffer(gpa, buf, &re, st.replacement, false) catch {};
        }
    } else {
        jumpNextBuffer(buf, &re) catch {};
    }
    refreshSearchResults(gpa, io, std.Io.Dir.cwd(), docs) catch {};
    // Editing scopes stay put: the cursor is already placed.
    mode.concludeCommand();
}

fn runBuffersScope(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) void {
    const st = &docs.search;
    var re = st.compile(gpa) catch {
        mode.flagCommandError(command.err_bad_spec);
        return;
    };
    defer re.deinit();
    for (docs.entries.items) |*e| {
        const buf = fileLikeBuffer(&e.doc) orelse continue;
        if (!st.has_repl) continue;
        if (st.global) {
            replaceAllBuffer(gpa, buf, &re, st.replacement) catch {};
        } else {
            replaceFirstBuffer(gpa, buf, &re, st.replacement) catch {};
        }
    }
    // n continues in the first hit doc; without hits it no-ops.
    st.last_doc = firstHitDoc(gpa, docs, &re) orelse docs.current;
    moveDocCursorToFirst(gpa, docs, &re);
    refreshSearchResults(gpa, io, std.Io.Dir.cwd(), docs) catch {};
    openSearchDoc(gpa, docs);
    mode.concludeCommand();
}

fn runFilesScope(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) void {
    const st = &docs.search;
    var re = st.compile(gpa) catch {
        mode.flagCommandError(command.err_bad_spec);
        return;
    };
    defer re.deinit();
    // One real handle for the whole action: bare cwd handles
    // are not iterable (see walkFiles).
    var cwd = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch {
        mode.flagCommandError(command.err_no_buffer);
        return;
    };
    defer cwd.close(io);
    if (st.has_repl) {
        renameMatches(gpa, io, cwd, &re, st.replacement, st.global) catch {};
    }
    if (firstFileMatch(gpa, io, cwd, &re)) |p| {
        defer gpa.free(p);
        setLastPath(gpa, st, p);
    }
    refreshSearchResults(gpa, io, cwd, docs) catch {};
    openSearchDoc(gpa, docs);
    mode.concludeCommand();
}

/// `n`/`p` stepping: re-scan from the cursor and land on the next or
/// previous hit, replacing it when the query carries one. Never
/// touches stored spans, so edits cannot stale the walk.
pub fn searchStep(gpa: Allocator, io: std.Io, docs: *Docs, dir: i32) void {
    const st = &docs.search;
    if (st.empty()) return;
    var re = st.compile(gpa) catch return;
    defer re.deinit();
    const fwd = dir >= 0;
    switch (st.scope) {
        .buffer => {
            const idx = docs.indexOf(st.last_doc) orelse return;
            if (fileLikeBuffer(&docs.entries.items[idx].doc) == null) return;
            docs.current = st.last_doc;
            const buf = fileLikeBuffer(&docs.entries.items[docs.currentIndex()].doc).?;
            if (st.has_repl) {
                replaceNextBuffer(gpa, buf, &re, st.replacement, true) catch {};
            } else {
                jumpNextBufferDir(buf, &re, fwd) catch {};
            }
            refreshSearchResults(gpa, io, std.Io.Dir.cwd(), docs) catch {};
        },
        .buffers => {
            stepBufs(gpa, docs, &re, fwd);
            refreshSearchResults(gpa, io, std.Io.Dir.cwd(), docs) catch {};
        },
        .files => {
            var cwd = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return;
            defer cwd.close(io);
            stepFiles(gpa, io, docs, cwd, &re, fwd);
            refreshSearchResults(gpa, io, cwd, docs) catch {};
        },
    }
}

/// Enter on a results row jumps without editing.
pub fn activateSearchSelected(gpa: Allocator, io: std.Io, docs: *Docs) void {
    const idx = docs.currentIndex();
    if (docs.entries.items[idx].doc != .search) return;
    const sb = &docs.entries.items[idx].doc.search;
    const t = sb.targetAtRow(sb.buf.row) orelse return;
    jumpToTarget(gpa, io, docs, t);
}

fn jumpToTarget(gpa: Allocator, io: std.Io, docs: *Docs, t: search.RowTarget) void {
    switch (t) {
        .open => |o| {
            const idx = docs.indexOf(o.id) orelse return;
            docs.current = o.id;
            if (fileLikeBuffer(&docs.entries.items[idx].doc)) |b| b.goTo(o.row, o.col) catch {};
        },
        .file => |f| {
            setLastPath(gpa, &docs.search, f.path);
            if (findByToolPath(docs, f.path)) |idx| {
                docs.current = docs.entries.items[idx].id;
                return;
            }
            var fd = openFileDoc(gpa, io, f.path) catch return;
            errdefer {
                fd.buf.close();
                gpa.free(fd.path_mem);
            }
            const id = docs.next_id;
            docs.entries.append(gpa, .{ .id = id, .doc = .{ .file = fd } }) catch return;
            docs.next_id += 1;
            docs.current = id;
        },
    }
}

/// Open file doc that a tool-relative path names. A tool reports paths
/// relative to its own root, so `findByPath` misses a doc that kod
/// opened through another path. Suffix matching settles it, the same
/// rule the diagnostic marks use.
fn findByToolPath(docs: *const Docs, rel: []const u8) ?usize {
    for (docs.entries.items, 0..) |*e, i| {
        if (e.doc != .file) continue;
        if (pathMatchesDoc(docPath(&e.doc), rel)) return i;
    }
    return null;
}

fn setLastPath(gpa: Allocator, st: *search.State, p: []const u8) void {
    if (st.last_path.len > 0) gpa.free(st.last_path);
    st.last_path = gpa.dupe(u8, p) catch &.{};
}

/// Cursor byte offset in `buf`.
fn cursorByte(buf: *Buffer) u64 {
    const ls = buf.lineStart(buf.row) catch return 0;
    return ls + buf.col;
}

/// All non-empty matches on one row as buffer byte spans.
const Span = struct { row: u64, from: u64, to: u64, col: usize };

fn rowSpans(gpa: Allocator, re: *regex.Regex, buf: *Buffer, row: u64) !std.ArrayList(Span) {
    var out = std.ArrayList(Span).empty;
    errdefer out.deinit(gpa);
    const line = try buf.readFullLine(gpa, row);
    defer gpa.free(line);
    const base = try buf.lineStart(row);
    var hits: std.ArrayList(search.LineHit) = .empty;
    defer hits.deinit(gpa);
    try search.lineHits(re, line, &hits, gpa);
    for (hits.items) |h| {
        try out.append(gpa, .{ .row = row, .from = base + h.col, .to = base + h.col + h.len, .col = h.col });
    }
    return out;
}

/// First match overall, or null when bare.
fn firstOverall(gpa: Allocator, re: *regex.Regex, buf: *Buffer) !?Span {
    const n = buf.lineCount();
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        var spans = try rowSpans(gpa, re, buf, r);
        defer spans.deinit(gpa);
        if (spans.items.len > 0) return spans.items[0];
    }
    return null;
}

/// Last match overall, or null when bare.
fn lastOverall(gpa: Allocator, re: *regex.Regex, buf: *Buffer) !?Span {
    var found: ?Span = null;
    const n = buf.lineCount();
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        var spans = try rowSpans(gpa, re, buf, r);
        defer spans.deinit(gpa);
        for (spans.items) |sp| found = sp;
    }
    return found;
}

/// First match at or after the cursor (`strict` = strictly after).
/// Non-strict wraps to the first match overall; strict reports bare.
fn firstAtAfter(
    gpa: Allocator,
    re: *regex.Regex,
    buf: *Buffer,
    strict: bool,
) !?Span {
    const cur = cursorByte(buf);
    const n = buf.lineCount();
    var first: ?Span = null;
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        var spans = try rowSpans(gpa, re, buf, r);
        defer spans.deinit(gpa);
        for (spans.items) |sp| {
            if (first == null) first = sp;
            const past = if (strict) sp.from > cur else sp.to > cur;
            if (past) return sp;
        }
    }
    if (strict) return null;
    return first;
}

/// Last match strictly before the cursor, else the last overall.
fn lastBefore(gpa: Allocator, re: *regex.Regex, buf: *Buffer) !?Span {
    const cur = cursorByte(buf);
    var found: ?Span = null;
    var last: ?Span = null;
    const n = buf.lineCount();
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        var spans = try rowSpans(gpa, re, buf, r);
        defer spans.deinit(gpa);
        for (spans.items) |sp| {
            last = sp;
            if (sp.from < cur) found = sp;
        }
    }
    if (found) |f| return f;
    return last;
}

/// Expand the replacement against a re-verified match, then swap it in
/// as one undo step. Skips silently when the text moved on.
fn applyReplacement(
    gpa: Allocator,
    buf: *Buffer,
    re: *regex.Regex,
    row: u64,
    col: usize,
    len: usize,
    repl: []const u8,
) !void {
    const line = try buf.readFullLine(gpa, row);
    defer gpa.free(line);
    if (col > line.len) return;
    const m = re.matchAt(line, col) orelse return;
    if (m.e - m.s != len) return;
    var exp: std.ArrayList(u8) = .empty;
    defer exp.deinit(gpa);
    try regex.expand(repl, line, m, re.captures(), &exp, gpa);
    const from = try buf.lineStart(row) + @as(u64, m.s);
    try buf.replaceRange(from, from + @as(u64, len), exp.items);
}

/// Replace every match in `buf`, back to front so offsets hold.
/// Cursor ends on the first replacement.
fn replaceAllBuffer(gpa: Allocator, buf: *Buffer, re: *regex.Regex, repl: []const u8) !void {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(gpa);
    const n = buf.lineCount();
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        var row = try rowSpans(gpa, re, buf, r);
        defer row.deinit(gpa);
        try spans.appendSlice(gpa, row.items);
        if (spans.items.len > max_search_hits) break;
    }
    var i = spans.items.len;
    while (i > 0) {
        i -= 1;
        const sp = spans.items[i];
        applyReplacement(gpa, buf, re, sp.row, sp.col, @intCast(sp.to - sp.from), repl) catch {};
    }
}

/// Replace the first match in `buf`, or nothing when bare.
fn replaceFirstBuffer(gpa: Allocator, buf: *Buffer, re: *regex.Regex, repl: []const u8) !void {
    const n = buf.lineCount();
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        var spans = try rowSpans(gpa, re, buf, r);
        defer spans.deinit(gpa);
        if (spans.items.len == 0) continue;
        const sp = spans.items[0];
        return applyReplacement(gpa, buf, re, sp.row, sp.col, @intCast(sp.to - sp.from), repl);
    }
}

/// Replace the first match at/after the cursor (`strict` = strictly
/// after, for `n`), wrapping once. Powers submit and stepping.
fn replaceNextBuffer(gpa: Allocator, buf: *Buffer, re: *regex.Regex, repl: []const u8, strict: bool) !void {
    const sp = try firstAtAfter(gpa, re, buf, strict) orelse return;
    // firstAtAfter already wraps; without wrap there is no match.
    try applyReplacement(gpa, buf, re, sp.row, sp.col, @intCast(sp.to - sp.from), repl);
}

/// Jump to the first match at/after the cursor, wrapping once.
fn jumpNextBuffer(buf: *Buffer, re: *regex.Regex) !void {
    const gpa = buf.gpa;
    const sp = try firstAtAfter(gpa, re, buf, false) orelse return;
    try buf.goTo(sp.row, @intCast(sp.col));
}

/// Jump to the next or previous match for `n`/`p`, wrapping.
fn jumpNextBufferDir(buf: *Buffer, re: *regex.Regex, fwd: bool) !void {
    const gpa = buf.gpa;
    if (fwd) {
        if (try firstAtAfter(gpa, re, buf, true)) |sp| {
            try buf.goTo(sp.row, @intCast(sp.col));
            return;
        }
        const w = try firstOverall(gpa, re, buf) orelse return;
        try buf.goTo(w.row, @intCast(w.col));
        return;
    }
    const sp = try lastBefore(gpa, re, buf) orelse return;
    try buf.goTo(sp.row, @intCast(sp.col));
}

/// Doc id holding the first match in registry order, if any.
fn firstHitDoc(gpa: Allocator, docs: *Docs, re: *regex.Regex) ?u32 {
    for (docs.entries.items) |*e| {
        const buf = fileLikeBuffer(&e.doc) orelse continue;
        const n = buf.lineCount();
        var r: u64 = 0;
        while (r < n) : (r += 1) {
            const line = buf.readFullLine(gpa, r) catch continue;
            defer gpa.free(line);
            var hits: std.ArrayList(search.LineHit) = .empty;
            defer hits.deinit(gpa);
            search.lineHits(re, line, &hits, gpa) catch continue;
            if (hits.items.len > 0) return e.id;
        }
    }
    return null;
}

/// Move that doc's cursor onto its first match. Best effort.
fn moveDocCursorToFirst(gpa: Allocator, docs: *Docs, re: *regex.Regex) void {
    const id = firstHitDoc(gpa, docs, re) orelse return;
    const idx = docs.indexOf(id) orelse return;
    const buf = fileLikeBuffer(&docs.entries.items[idx].doc) orelse return;
    const n = buf.lineCount();
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        const line = buf.readFullLine(gpa, r) catch continue;
        defer gpa.free(line);
        var hits: std.ArrayList(search.LineHit) = .empty;
        defer hits.deinit(gpa);
        search.lineHits(re, line, &hits, gpa) catch continue;
        if (hits.items.len > 0) {
            buf.goTo(r, @intCast(hits.items[0].col)) catch {};
            return;
        }
    }
}

/// Step across open buffers in registry order with wrap. The anchor
/// doc scans from its cursor; the rest scan whole. A replacement
/// applies to the landed match only.
fn stepBufs(gpa: Allocator, docs: *Docs, re: *regex.Regex, fwd: bool) void {
    const st = &docs.search;
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    var anchor: ?usize = null;
    for (docs.entries.items) |*e| {
        if (fileLikeBuffer(&e.doc) == null) continue;
        if (e.id == st.last_doc) anchor = ids.items.len;
        ids.append(gpa, e.id) catch return;
    }
    if (ids.items.len == 0) return;
    const start_at: usize = anchor orelse 0;
    var k: usize = 0;
    while (k < ids.items.len) : (k += 1) {
        const at = if (fwd)
            (start_at + k) % ids.items.len
        else
            (start_at + ids.items.len - k) % ids.items.len;
        const id = ids.items[at];
        const idx = docs.indexOf(id) orelse continue;
        const buf = fileLikeBuffer(&docs.entries.items[idx].doc) orelse continue;
        const from_cursor = k == 0 and anchor != null;
        const sp: ?Span = stepBufDir(gpa, buf, re, from_cursor, fwd) catch continue;
        if (sp) |s| {
            docs.current = id;
            st.last_doc = id;
            buf.goTo(s.row, @intCast(s.col)) catch {};
            if (st.has_repl) applyReplacement(gpa, buf, re, s.row, s.col, @intCast(s.to - s.from), st.replacement) catch {};
            return;
        }
    }
}

fn stepBufDir(gpa: Allocator, buf: *Buffer, re: *regex.Regex, from_cursor: bool, fwd: bool) !?Span {
    if (!from_cursor) return if (fwd) firstOverall(gpa, re, buf) else lastOverall(gpa, re, buf);
    const cur = cursorByte(buf);
    if (fwd) {
        const n = buf.lineCount();
        var r: u64 = 0;
        while (r < n) : (r += 1) {
            var spans = try rowSpans(gpa, re, buf, r);
            defer spans.deinit(gpa);
            for (spans.items) |sp| {
                if (sp.from > cur) return sp;
            }
        }
        return null;
    }
    var found: ?Span = null;
    const n = buf.lineCount();
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        var spans = try rowSpans(gpa, re, buf, r);
        defer spans.deinit(gpa);
        for (spans.items) |sp| {
            if (sp.from < cur) found = sp;
        }
    }
    return found;
}

/// Basename match spans for rename and file hits.
const NameHit = struct { s: usize, e: usize };

fn matchBasename(re: *regex.Regex, path: []const u8) ?NameHit {
    const base = std.fs.path.basename(path);
    const h = re.find(base, 0) orelse return null;
    if (h.e == h.s) return null;
    // Offset back into the full path for display spans.
    const off = base.ptr - path.ptr;
    return .{ .s = off + h.s, .e = off + h.e };
}

/// Rename one file by expanding `repl` over its basename. Returns the
/// owned new relative path on success, null on any skip: no match,
/// empty or slashed result, unchanged name, collision, IO error.
fn renameFileMatch(gpa: Allocator, io: std.Io, dir: std.Io.Dir, re: *regex.Regex, rel: []const u8, repl: []const u8) ?[]u8 {
    const base = std.fs.path.basename(rel);
    const h = re.find(base, 0) orelse return null;
    if (h.e == h.s) return null;
    const m = re.matchAt(base, h.s) orelse return null;
    var exp: std.ArrayList(u8) = .empty;
    defer exp.deinit(gpa);
    regex.expand(repl, base, m, re.captures(), &exp, gpa) catch return null;
    // Splice like sed: untouched head and tail stay put.
    var newbase = std.ArrayList(u8).empty;
    defer newbase.deinit(gpa);
    newbase.appendSlice(gpa, base[0..m.s]) catch return null;
    newbase.appendSlice(gpa, exp.items) catch return null;
    newbase.appendSlice(gpa, base[m.e..]) catch return null;
    if (newbase.items.len == 0 or std.mem.indexOfScalar(u8, newbase.items, '/') != null) return null;
    if (std.mem.eql(u8, newbase.items, base)) return null;
    const parent = std.fs.path.dirname(rel);
    const target = if (parent == null or std.mem.eql(u8, parent.?, "."))
        gpa.dupe(u8, newbase.items) catch return null
    else
        std.fs.path.join(gpa, &.{ parent.?, newbase.items }) catch return null;
    defer gpa.free(target);
    if (dir.statFile(io, target, .{})) |_| return null else |_| {}
    std.Io.Dir.rename(dir, rel, dir, target, io) catch return null;
    return gpa.dupe(u8, target) catch null;
}

/// Rename every basename match (global) or just the first, cwd rooted.
fn renameMatches(gpa: Allocator, io: std.Io, dir: std.Io.Dir, re: *regex.Regex, repl: []const u8, global: bool) !void {
    var files = std.ArrayList([]u8).empty;
    defer {
        for (files.items) |p| gpa.free(p);
        files.deinit(gpa);
    }
    try search.walkFiles(gpa, io, dir, &files, max_walk_files, max_walk_scanned);
    for (files.items) |rel| {
        if (matchBasename(re, rel) == null) continue;
        if (renameFileMatch(gpa, io, dir, re, rel, repl)) |new_rel| {
            defer gpa.free(new_rel);
            if (!global) return;
        }
    }
}

fn firstFileMatch(gpa: Allocator, io: std.Io, dir: std.Io.Dir, re: *regex.Regex) ?[]u8 {
    var files = std.ArrayList([]u8).empty;
    defer {
        for (files.items) |p| gpa.free(p);
        files.deinit(gpa);
    }
    search.walkFiles(gpa, io, dir, &files, max_walk_files, max_walk_scanned) catch return null;
    for (files.items) |rel| {
        if (matchBasename(re, rel) == null) continue;
        return gpa.dupe(u8, rel) catch null;
    }
    return null;
}

/// Step across filenames in sorted walk order with wrap, opening each.
fn stepFiles(gpa: Allocator, io: std.Io, docs: *Docs, dir: std.Io.Dir, re: *regex.Regex, fwd: bool) void {
    const st = &docs.search;
    var files = std.ArrayList([]u8).empty;
    defer {
        for (files.items) |p| gpa.free(p);
        files.deinit(gpa);
    }
    search.walkFiles(gpa, io, dir, &files, max_walk_files, max_walk_scanned) catch return;
    var hits: std.ArrayList([]u8) = .empty;
    defer hits.deinit(gpa);
    for (files.items) |rel| {
        if (matchBasename(re, rel) != null) hits.append(gpa, rel) catch return;
    }
    if (hits.items.len == 0) return;
    const anchor: []const u8 = blk: {
        const ci = docs.currentIndex();
        if (docs.entries.items[ci].doc == .file) break :blk docPath(&docs.entries.items[ci].doc);
        break :blk st.last_path;
    };
    var pick: usize = 0;
    if (fwd) {
        pick = hits.items.len;
        for (hits.items, 0..) |h, k| {
            if (std.mem.order(u8, h, anchor) == .gt) {
                pick = k;
                break;
            }
        }
        if (pick == hits.items.len) pick = 0;
    } else {
        var found = false;
        var k = hits.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.order(u8, hits.items[k], anchor) == .lt) {
                pick = k;
                found = true;
                break;
            }
        }
        if (!found) pick = hits.items.len - 1;
    }
    const rel = hits.items[pick];
    if (st.has_repl) {
        // Rename first so the jump below opens the new name.
        if (renameFileMatch(gpa, io, std.Io.Dir.cwd(), re, rel, st.replacement)) |new_rel| {
            defer gpa.free(new_rel);
            setLastPath(gpa, st, new_rel);
            jumpToTarget(gpa, io, docs, .{ .file = .{ .path = new_rel } });
            return;
        }
    }
    setLastPath(gpa, st, rel);
    jumpToTarget(gpa, io, docs, .{ .file = .{ .path = rel } });
}

/// Single `*search*` results doc, created empty on demand.
fn ensureSearchDoc(gpa: Allocator, docs: *Docs) ?*search.SearchBuffer {
    for (docs.entries.items) |*e| {
        if (e.doc == .search) return &e.doc.search;
    }
    var sb = search.SearchBuffer.open(gpa, search_title) catch return null;
    errdefer sb.close();
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .search = sb } }) catch {
        sb.close();
        return null;
    };
    docs.next_id += 1;
    return &docs.entries.items[docs.entries.items.len - 1].doc.search;
}

/// Switch to the results doc, creating it empty when missing.
fn openSearchDoc(gpa: Allocator, docs: *Docs) void {
    for (docs.entries.items) |*e| {
        if (e.doc == .search) {
            docs.current = e.id;
            return;
        }
    }
    var sb = search.SearchBuffer.open(gpa, search_title) catch return;
    errdefer sb.close();
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .search = sb } }) catch {
        sb.close();
        return;
    };
    docs.next_id += 1;
    docs.current = id;
}

/// Rows of a rendered result tree. The set owns its line text and the
/// paths of its `.file` targets, so a caller may drop its own copies
/// before the render. Target paths handed out earlier died here: the
/// file walk freed its list before the render, and the tree duped
/// freed memory.
const RowSet = struct {
    targets: std.ArrayList(search.RowTarget) = .empty,
    lines: std.ArrayList([]u8) = .empty,
    paths: std.ArrayList([]u8) = .empty,

    /// One file row: owned line text plus an owned path.
    fn pushFile(self: *RowSet, gpa: Allocator, path: []const u8) !void {
        const kept_path = try gpa.dupe(u8, path);
        errdefer gpa.free(kept_path);
        const kept_line = try gpa.dupe(u8, path);
        errdefer gpa.free(kept_line);
        try self.paths.append(gpa, kept_path);
        errdefer _ = self.paths.pop();
        try self.lines.append(gpa, kept_line);
        errdefer _ = self.lines.pop();
        try self.targets.append(gpa, .{ .file = .{ .path = kept_path } });
    }

    fn deinit(self: *RowSet, gpa: Allocator) void {
        for (self.lines.items) |l| gpa.free(l);
        self.lines.deinit(gpa);
        for (self.paths.items) |p| gpa.free(p);
        self.paths.deinit(gpa);
        self.targets.deinit(gpa);
    }
};

fn previewOf(line: []const u8) []const u8 {
    return line[0..@min(line.len, preview_len)];
}

/// Re-collect the current matches and render the results buffer.
fn refreshSearchResults(gpa: Allocator, io: std.Io, dir: std.Io.Dir, docs: *Docs) !void {
    const st = &docs.search;
    if (st.empty()) return;
    var re = try st.compile(gpa);
    defer re.deinit();
    var rows = RowSet{};
    defer rows.deinit(gpa);
    switch (st.scope) {
        .buffer => {
            const idx = docs.indexOf(st.last_doc) orelse return;
            const buf = fileLikeBuffer(&docs.entries.items[idx].doc) orelse return;
            const title = docPath(&docs.entries.items[idx].doc);
            try collectBufferRows(gpa, &re, buf, docs.entries.items[idx].id, title, &rows);
        },
        .buffers => {
            for (docs.entries.items) |*e| {
                const buf = fileLikeBuffer(&e.doc) orelse continue;
                try collectBufferRows(gpa, &re, buf, e.id, docPath(&e.doc), &rows);
                if (rows.targets.items.len >= max_search_hits) break;
            }
        },
        .files => {
            var files = std.ArrayList([]u8).empty;
            defer {
                for (files.items) |p| gpa.free(p);
                files.deinit(gpa);
            }
            try search.walkFiles(gpa, io, dir, &files, max_walk_files, max_walk_scanned);
            for (files.items) |rel| {
                if (matchBasename(&re, rel) == null) continue;
                try rows.pushFile(gpa, rel);
                if (rows.targets.items.len >= max_search_hits) break;
            }
        },
    }
    const sb = ensureSearchDoc(gpa, docs) orelse return error.OutOfMemory;
    try sb.refresh(rows.targets.items, rows.lines.items);
}

fn collectBufferRows(
    gpa: Allocator,
    re: *regex.Regex,
    buf: *Buffer,
    id: u32,
    title: []const u8,
    rows: *RowSet,
) !void {
    const n = buf.lineCount();
    var r: u64 = 0;
    while (r < n) : (r += 1) {
        const line = try buf.readFullLine(gpa, r);
        defer gpa.free(line);
        var hits: std.ArrayList(search.LineHit) = .empty;
        defer hits.deinit(gpa);
        try search.lineHits(re, line, &hits, gpa);
        for (hits.items) |h| {
            try rows.targets.append(gpa, .{ .open = .{ .id = id, .row = r, .col = @intCast(h.col) } });
            try rows.lines.append(gpa, try std.fmt.allocPrint(gpa, "{s}:{d}:{d}: {s}", .{
                title,
                r + 1,
                h.col + 1,
                previewOf(line),
            }));
            if (rows.targets.items.len >= max_search_hits) return;
        }
    }
}

/// `:tree` opens the whole inspector, `:tree <name>` opens one
/// section in a buffer of its own, with the same rows, styling, and
/// Enter behavior. One doc per section, refreshed on every open.
/// `mode` supplies the command text and the session command log.
pub fn openTrees(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) void {
    const name: ?[]const u8 = switch (command.interpret(mode.commandText())) {
        .trees => |n| n,
        else => {
            mode.flagCommandError(command.err_unknown);
            return;
        },
    };
    const one: ?tree.Section = if (name) |n| tree.sectionOf(n) orelse {
        mode.flagCommandError(command.err_no_tree);
        return;
    } else null;
    const title: []const u8 = if (one) |s| tree.sectionTitle(s) else "*tree*";
    for (docs.entries.items) |*e| {
        if (e.doc == .trees and e.doc.trees.single == one) {
            docs.current = e.id;
            refreshTree(gpa, io, docs, mode) catch {};
            mode.concludeCommand();
            return;
        }
    }
    var tb = tree.TreeBuffer.open(gpa, title) catch {
        mode.flagCommandError(command.err_oom);
        return;
    };
    errdefer tb.close();
    tb.single = one;
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .trees = tb } }) catch {
        tb.close();
        mode.flagCommandError(command.err_oom);
        return;
    };
    docs.next_id += 1;
    docs.current = id;
    refreshTree(gpa, io, docs, mode) catch {};
    mode.concludeCommand();
}

/// Enter on a trees row folds it or jumps to its target. Doc rows
/// switch to open buffers, file rows open files, git rows open the
/// log, and a recorded command row goes back in the command box.
pub fn activateTreeSelected(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) void {
    const idx = docs.currentIndex();
    if (docs.entries.items[idx].doc != .trees) return;
    const tb = &docs.entries.items[idx].doc.trees;
    const t = tb.toggle(tb.buf.row) orelse {
        refreshTree(gpa, io, docs, mode) catch {};
        return;
    };
    switch (t) {
        .doc => |d| {
            const di = docs.indexOf(d.id) orelse return;
            docs.current = d.id;
            if (fileLikeBuffer(&docs.entries.items[di].doc)) |b| b.goTo(d.row, d.col) catch {};
        },
        .file => |f| {
            if (findByToolPath(docs, f.path)) |i| {
                docs.current = docs.entries.items[i].id;
            } else {
                jumpToTarget(gpa, io, docs, .{ .file = .{ .path = f.path } });
            }
        },
        .hit => |h| jumpToToolHit(gpa, io, docs, h.path, h.row, h.col),
        .git => openGit(gpa, io, docs, mode),
        .command => |i| {
            if (tb.commandAt(i)) |text| mode.prefillCommand(text);
        },
        else => {},
    }
}

/// Rebuild the inspector from live snapshots. Borrowed strings stay
/// alive through the synchronous render call.
fn collectUndoViews(gpa: Allocator, docs: *Docs, out: *std.ArrayList(tree.UndoView)) !void {
    for (docs.entries.items) |*e| {
        const buf = fileLikeBuffer(&e.doc) orelse continue;
        try out.append(gpa, .{ .id = e.id, .title = docPath(&e.doc), .tree = &buf.undo_tree });
    }
}

fn collectBufViews(gpa: Allocator, docs: *Docs, out: *std.ArrayList(tree.BufView)) !void {
    for (docs.entries.items) |*e| {
        var row: u64 = 0;
        var col: u64 = 0;
        if (fileLikeBuffer(&e.doc)) |b| {
            row = b.row;
            col = b.col;
        }
        try out.append(gpa, .{
            .id = e.id,
            .title = docPath(&e.doc),
            .kind = @tagName(e.doc),
            .row = row,
            .col = col,
        });
    }
}

fn collectGitCommits(gpa: Allocator, gb: *const git.GitBuffer, out: *std.ArrayList(tree.CommitView)) !void {
    for (gb.commits.items) |*c| {
        try out.append(gpa, .{
            .hash = c.hash[0..@min(c.hash.len, 7)],
            .subject = c.subject,
        });
    }
}

fn collectSearchHits(gpa: Allocator, io: std.Io, docs: *Docs, rows: *RowSet, hits: *std.ArrayList(tree.SearchHit), query_buf: *?[]u8) !void {
    const st = &docs.search;
    const query = try std.fmt.allocPrint(gpa, "{s} /{s}/{s}/{s}{s}", .{
        @tagName(st.scope),
        st.pattern,
        if (st.has_repl) st.replacement else "",
        if (st.ci) "i" else "",
        if (st.global) "g" else "",
    });
    query_buf.* = query;
    var walk = std.ArrayList([]u8).empty;
    defer {
        for (walk.items) |w| gpa.free(w);
        walk.deinit(gpa);
    }
    if (!st.empty()) {
        var re = st.compile(gpa) catch null;
        if (re) |*r| {
            defer r.deinit();
            switch (st.scope) {
                .buffer => {
                    const bi = docs.indexOf(st.last_doc) orelse docs.currentIndex();
                    if (fileLikeBuffer(&docs.entries.items[bi].doc)) |buf| {
                        try collectBufferRows(gpa, r, buf, docs.entries.items[bi].id, docPath(&docs.entries.items[bi].doc), rows);
                    }
                },
                .buffers => {
                    for (docs.entries.items) |*e| {
                        const buf = fileLikeBuffer(&e.doc) orelse continue;
                        try collectBufferRows(gpa, r, buf, e.id, docPath(&e.doc), rows);
                        if (rows.targets.items.len >= max_search_hits) break;
                    }
                },
                .files => {
                    if (std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true })) |cwd| {
                        defer cwd.close(io);
                        try search.walkFiles(gpa, io, cwd, &walk, max_walk_files, max_walk_scanned);
                        for (walk.items) |rel| {
                            if (matchBasename(r, rel) == null) continue;
                            try rows.pushFile(gpa, rel);
                            if (rows.targets.items.len >= max_search_hits) break;
                        }
                    } else |_| {}
                },
            }
        }
    }
    for (rows.targets.items, 0..) |t, k| {
        const target: tree.TreeTarget = switch (t) {
            .open => |o| .{ .doc = .{ .id = o.id, .row = o.row, .col = o.col } },
            .file => |f| .{ .file = .{ .path = f.path } },
        };
        try hits.append(gpa, .{ .label = rows.lines.items[k], .target = target });
    }
}

/// Find the exec doc entry, or null.
fn execIndex(docs: *Docs) ?usize {
    for (docs.entries.items, 0..) |*e, k| {
        if (e.doc == .exec) return k;
    }
    return null;
}

/// Ensure the `*exec*` doc exists. Null means out of memory; runs
/// still record spans without it.
fn ensureExecId(gpa: Allocator, docs: *Docs) ?u32 {
    if (execIndex(docs)) |k| return docs.entries.items[k].id;
    var eb = exec.ExecBuffer.open(gpa, exec.exec_title) catch return null;
    errdefer eb.close();
    const id = docs.next_id;
    docs.entries.append(gpa, .{ .id = id, .doc = .{ .exec = eb } }) catch {
        eb.close();
        return null;
    };
    docs.next_id += 1;
    return id;
}

/// Why a run did not start. Null in `spawnExec` means it started.
pub const SpawnFail = enum { busy, memory };

/// Spawn a background run for `target_id`. Shows a running header,
/// and switches to the tree when `switch_to` (manual runs show,
/// save reruns stay silent).
fn spawnExec(gpa: Allocator, io: std.Io, docs: *Docs, target_id: u32, cmd: []const u8, switch_to: bool) ?SpawnFail {
    if (docs.exec_runner != null) return .busy;
    const id = ensureExecId(gpa, docs) orelse return .memory;
    docs.exec_runner = .{
        .thread = undefined,
        .done = std.atomic.Value(bool).init(false),
        .result = null,
    };
    if (!exec.spawn(&docs.exec_runner.?, io, cmd, target_id, switch_to)) {
        docs.exec_runner = null;
        return .memory;
    }
    const eb = &docs.entries.items[docs.indexOf(id).?].doc.exec;
    eb.refreshRunning(cmd) catch {};
    if (switch_to) docs.current = id;
    return null;
}

/// File doc that `:exec-save` arms: the current doc when it is a
/// file, else the newest file doc. Arming from a tree view is the
/// normal case, because the tree is where the last run left you.
fn execSaveTarget(docs: *Docs) ?u32 {
    if (docs.entries.items[docs.currentIndex()].doc == .file) return docs.current;
    var k = docs.entries.items.len;
    while (k > 0) {
        k -= 1;
        if (docs.entries.items[k].doc == .file) return docs.entries.items[k].id;
    }
    return null;
}

/// `:exec [cmd]` and `:exec-save <cmd>`. Empty cmd reruns the last
/// one. Armed runs also rerun on save for the current file.
pub fn runExec(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode, cmd_in: []const u8, arm: bool) void {
    if (cmd_in.len > 0) {
        const kept = gpa.dupe(u8, cmd_in) catch {
            mode.flagCommandError(command.err_oom);
            return;
        };
        if (docs.exec_last_cmd) |old| gpa.free(old);
        docs.exec_last_cmd = kept;
    }
    const cmd = docs.exec_last_cmd orelse {
        mode.flagCommandError(command.err_unknown);
        return;
    };
    var target: u32 = docs.exec_last_target;
    if (docs.entries.items[docs.currentIndex()].doc == .file) {
        target = docs.current;
    }
    if (arm) {
        const id = execSaveTarget(docs) orelse {
            mode.flagCommandError(command.err_needs_file);
            return;
        };
        const b = &docs.entries.items[docs.indexOf(id).?].doc.file.buf;
        if (b.exec_cmd) |old| gpa.free(old);
        b.exec_cmd = gpa.dupe(u8, cmd) catch {
            mode.flagCommandError(command.err_oom);
            return;
        };
        target = id;
    }
    docs.exec_last_target = target;
    if (spawnExec(gpa, io, docs, target, cmd, true)) |why| {
        mode.flagCommandError(switch (why) {
            .busy => command.err_busy,
            .memory => command.err_oom,
        });
        return;
    }
    mode.concludeCommand();
}

/// Rerun the armed command after a file save. Silent: no doc switch,
/// no overlay touch. Skips when a run is already active.
pub fn rerunExecOnSave(gpa: Allocator, io: std.Io, docs: *Docs, id: u32) void {
    const idx = docs.indexOf(id) orelse return;
    if (docs.entries.items[idx].doc != .file) return;
    const cmd = docs.entries.items[idx].doc.file.buf.exec_cmd orelse return;
    if (docs.exec_runner != null) return;
    if (docs.exec_last_cmd) |old| gpa.free(old);
    docs.exec_last_cmd = gpa.dupe(u8, cmd) catch return;
    docs.exec_last_target = id;
    _ = spawnExec(gpa, io, docs, id, cmd, false);
}
fn diagLess(_: void, a: buffer_mod.Diag, b: buffer_mod.Diag) bool {
    if (a.row != b.row) return a.row < b.row;
    return a.col < b.col;
}

/// Hit paths are tool-relative, doc paths are open-relative: exact
/// match or either side suffixing the other past a separator.
fn pathMatchesDoc(doc_path: []const u8, hit_path: []const u8) bool {
    if (std.mem.eql(u8, doc_path, hit_path)) return true;
    if (doc_path.len > hit_path.len and
        std.mem.endsWith(u8, doc_path, hit_path) and
        doc_path[doc_path.len - hit_path.len - 1] == '/') return true;
    if (hit_path.len > doc_path.len and
        std.mem.endsWith(u8, hit_path, doc_path) and
        hit_path[hit_path.len - doc_path.len - 1] == '/') return true;
    return false;
}

/// Adopt a finished background run: parse output, stamp spans on every
/// open file the hits name, repaint the exec tree. Call once per event
/// loop tick, before paint. A trees doc in view re-renders too, so its
/// exec tree never shows a run that already finished. `mode` is only
/// read for that re-render.
///
/// Reads through the real runner field, never a copy: the worker's
/// result is only touched after the acquire-load observes `done` and
/// the join synchronizes with the worker's final write.
pub fn pollExec(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) void {
    if (docs.exec_runner == null) return;
    if (!docs.exec_runner.?.done.load(.acquire)) return;
    docs.exec_runner.?.thread.join();
    var res = docs.exec_runner.?.result orelse {
        docs.exec_runner = null;
        return;
    };
    defer exec.freeResult(&res);
    docs.exec_runner = null;
    if (docs.exec_last_cmd) |old| gpa.free(old);
    docs.exec_last_cmd = gpa.dupe(u8, res.cmd) catch null;
    docs.exec_last_target = res.target_id;
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(gpa);
    var hits = std.ArrayList(?exec.ParsedHit).empty;
    defer hits.deinit(gpa);
    // Compilers report on stderr, linters on stdout; problems first.
    const streams = [_][]u8{ res.stderr, res.stdout };
    for (streams) |text| {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            lines.append(gpa, line) catch continue;
            hits.append(gpa, exec.parseExecLine(line)) catch {
                _ = lines.pop();
                continue;
            };
        }
    }
    // Spans for every open file the hits name, sorted by row.
    for (docs.entries.items) |*e| {
        if (e.doc != .file) continue;
        const b = &e.doc.file.buf;
        b.diags.clearRetainingCapacity();
        for (hits.items) |h| {
            const hit = h orelse continue;
            if (!pathMatchesDoc(docPath(&e.doc), hit.path)) continue;
            b.diags.append(gpa, .{
                .row = hit.row,
                .col = hit.col,
                .kind = if (hit.kind == .warn) .warn else .err,
            }) catch continue;
        }
        std.mem.sort(buffer_mod.Diag, b.diags.items, {}, diagLess);
        b.diag_gen = b.edit_gen;
    }
    const id = ensureExecId(gpa, docs) orelse return;
    const eb = &docs.entries.items[docs.indexOf(id).?].doc.exec;
    eb.refresh(res.cmd, res.exit_code, lines.items, hits.items) catch {};
    if (res.switch_to) docs.current = id;
    // A trees doc in view carries an exec tree, so refresh it now: a
    // stale row would point at the paths this run just freed.
    const cur = docs.currentIndex();
    if (docs.entries.items[cur].doc == .trees) {
        const one = docs.entries.items[cur].doc.trees.single;
        if (one == null or one == .exec) refreshTree(gpa, io, docs, mode) catch {};
    }
}

/// Join an in-flight run at quit and drop its result. Blocks until
/// the worker finishes: quitting waits on the tool, never leaks it.
/// Payload pointer addresses the real field, not a snapshot copy.
/// Always frees the last command, even with no run active.
pub fn joinExec(gpa: Allocator, docs: *Docs) void {
    if (docs.exec_runner != null) {
        docs.exec_runner.?.thread.join();
        if (docs.exec_runner.?.result) |*res| exec.freeResult(res);
        docs.exec_runner = null;
    }
    if (docs.exec_last_cmd) |c| {
        gpa.free(c);
        docs.exec_last_cmd = null;
    }
}

/// Open or switch to the file a tool row names, then place the
/// cursor on the reported line. Tool-relative paths match open docs
/// by suffix, so a row finds a doc that kod opened by another path.
fn jumpToToolHit(gpa: Allocator, io: std.Io, docs: *Docs, path: []const u8, row: u64, col: u64) void {
    if (findByToolPath(docs, path)) |i| {
        docs.current = docs.entries.items[i].id;
    } else {
        var fd = openFileDoc(gpa, io, path) catch return;
        errdefer {
            fd.buf.close();
            gpa.free(fd.path_mem);
        }
        const id = docs.next_id;
        docs.entries.append(gpa, .{ .id = id, .doc = .{ .file = fd } }) catch {
            fd.buf.close();
            gpa.free(fd.path_mem);
            return;
        };
        docs.next_id += 1;
        docs.current = id;
    }
    docs.currentBuffer().goTo(row, col) catch {};
}

/// Enter on an exec row opens a diagnostic. A hit row opens its own
/// file at its line; a plain log row opens the next hit below it, so
/// no row of the run is a dead end. The cursor follows the hit, which
/// keeps `n` and `p` walking from there.
pub fn activateExecSelected(gpa: Allocator, io: std.Io, docs: *Docs) void {
    const idx = docs.currentIndex();
    if (docs.entries.items[idx].doc != .exec) return;
    const eb = &docs.entries.items[idx].doc.exec;
    const at = eb.hitAtOrAfter(eb.buf.row) orelse return;
    eb.buf.goTo(at, 0) catch {};
    const t = eb.targetAtRow(at) orelse return;
    if (t != .file) return;
    const f = t.file;
    jumpToToolHit(gpa, io, docs, f.path, f.row, f.col);
}

/// `n`/`p` inside the exec tree: step to the next hit and jump to
/// it, wrapping once. Silent on plain log rows.
pub fn execStep(gpa: Allocator, io: std.Io, docs: *Docs, dir: i32) void {
    const idx = docs.currentIndex();
    if (docs.entries.items[idx].doc != .exec) return;
    const eb = &docs.entries.items[idx].doc.exec;
    const at = eb.step(dir >= 0) orelse return;
    eb.buf.goTo(at, 0) catch {};
    activateExecSelected(gpa, io, docs);
}

/// Snapshot of the last run for the inspector: what ran, its exit
/// code, and one row per jumpable hit. Labels are duped; the paths
/// borrow the exec doc, which `pushRow` dupes again on render.
fn collectExecView(gpa: Allocator, docs: *Docs, out: *std.ArrayList(tree.SearchHit)) !?tree.ExecView {
    const ei = execIndex(docs) orelse return null;
    const eb = &docs.entries.items[ei].doc.exec;
    if (eb.cmd_text.len == 0) return null;
    var line_buf: [4096]u8 = undefined;
    var r: u64 = 1; // row 0 is the run header
    while (!eb.running and r < eb.buf.lineCount()) : (r += 1) {
        const t = eb.targetAtRow(r) orelse continue;
        if (t != .file) continue;
        const line = try eb.buf.line(r, &line_buf);
        const kept = try gpa.dupe(u8, line);
        errdefer gpa.free(kept);
        try out.append(gpa, .{
            .label = kept,
            .target = .{ .hit = .{ .path = t.file.path, .row = t.file.row, .col = t.file.col } },
        });
    }
    return .{
        .cmd = eb.cmd_text,
        .exit_code = if (eb.running) null else eb.exit_code orelse 0,
        .hits = out.items,
    };
}

/// Re-render the trees doc in view. One doc per tree, so this must
/// follow the current doc: rendering the first trees entry left every
/// `:tree <name>` buffer empty.
fn refreshTree(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) !void {
    const idx = docs.currentIndex();
    if (docs.entries.items[idx].doc != .trees) return;
    var undo = std.ArrayList(tree.UndoView).empty;
    defer undo.deinit(gpa);
    try collectUndoViews(gpa, docs, &undo);
    var views = std.ArrayList(tree.BufView).empty;
    defer views.deinit(gpa);
    try collectBufViews(gpa, docs, &views);
    var git_view: ?tree.GitView = null;
    var commits = std.ArrayList(tree.CommitView).empty;
    defer commits.deinit(gpa);
    for (docs.entries.items) |*e| {
        if (e.doc != .git) continue;
        const gb = &e.doc.git;
        try collectGitCommits(gpa, gb, &commits);
        git_view = .{
            .branch = gb.branch,
            .base = gb.base,
            .unstaged = gb.unstaged.items.len,
            .staged = gb.staged.items.len,
            .commits = commits.items,
        };
        break;
    }
    var rows = RowSet{};
    defer rows.deinit(gpa);
    var hits = std.ArrayList(tree.SearchHit).empty;
    defer hits.deinit(gpa);
    var query: ?[]u8 = null;
    defer if (query) |q| gpa.free(q);
    try collectSearchHits(gpa, io, docs, &rows, &hits, &query);
    var exec_hits = std.ArrayList(tree.SearchHit).empty;
    defer {
        for (exec_hits.items) |h| gpa.free(h.label);
        exec_hits.deinit(gpa);
    }
    const run = try collectExecView(gpa, docs, &exec_hits);
    const tb = &docs.entries.items[idx].doc.trees;
    try tb.render(undo.items, .{ .query = query.?, .hits = hits.items }, views.items, git_view, run, mode.cmd_history.entries.items);
}

test {
    _ = Buffer;
    _ = Mode;
    _ = command;
    _ = fs;
    _ = bufs;
    _ = git;
}

fn tmpPath(gpa: Allocator, tmp: *std.testing.TmpDir, leaf: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, leaf });
}

test "doc: bare fs opens the parent, enter reopens the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "hi" });

    const file_path = try tmpPath(gpa, &tmp, "note.txt");
    defer gpa.free(file_path);

    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const first = try openFileDoc(gpa, io, file_path);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = first } });
    docs.next_id = 2;
    docs.current = 1;

    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("fs") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expect(mode.handle(.enter) == .open_fs);
    const arg = switch (command.interpret(mode.commandText())) {
        .fs => |p| p,
        else => return error.Unexpected,
    };
    try std.testing.expectEqualStrings("", arg);
    try openFs(gpa, io, &docs, &mode, arg);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .dir);
    try std.testing.expect(mode.kind == .normal);
    try std.testing.expectEqual(@as(usize, 2), docs.entries.items.len);

    docs.entries.items[docs.currentIndex()].doc.dir.selectRow("note.txt");
    openSelected(gpa, io, &docs);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .file);
    var line_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "hi",
        try docs.entries.items[docs.currentIndex()].doc.file.buf.line(0, &line_buf),
    );
}

test "doc: welcome shows title and version, save is scratch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const w = try openWelcomeDoc(gpa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .welcome = w } });
    docs.next_id = 2;
    docs.current = 1;

    try std.testing.expectEqualStrings("*welcome*", docPath(&docs.entries.items[0].doc));
    var line_buf: [256]u8 = undefined;
    const buf = docs.currentBuffer();
    const first_line = try buf.line(0, &line_buf);
    try std.testing.expect(std.mem.startsWith(u8, first_line, "kod "));
    try std.testing.expect(first_line.len > "kod ".len);

    buf.dirty = true;
    var mode: Mode = .{};
    saveDoc(gpa, io, &docs, &mode);
    try std.testing.expect(!buf.dirty);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, "*welcome*", .{}),
    );
}

test "doc: help opens once and lists every command" {
    const gpa = std.testing.allocator;
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const w = try openWelcomeDoc(gpa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .welcome = w } });
    docs.next_id = 2;
    docs.current = 1;

    openHelp(gpa, &docs);
    try std.testing.expectEqual(@as(usize, 2), docs.entries.items.len);
    openHelp(gpa, &docs);
    try std.testing.expectEqual(@as(usize, 2), docs.entries.items.len);
    try std.testing.expectEqualStrings("*help*", docPath(&docs.entries.items[docs.currentIndex()].doc));

    const hb = docs.currentBuffer();
    var line_buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try hb.line(0, &line_buf), "kod "));
    for (command.help_entries) |e| {
        var seen = false;
        var r: u64 = 0;
        while (r < hb.lineCount()) : (r += 1) {
            const l = try hb.line(r, &line_buf);
            if (l.len > e.name.len + 3 and
                std.mem.startsWith(u8, l, "  :") and
                std.mem.startsWith(u8, l[3..], e.name)) seen = true;
        }
        try std.testing.expect(seen);
    }
}

test "doc: arg opens dirs as fs and files as files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "x" });

    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);
    const file_path = try std.fs.path.join(gpa, &.{ dir_path, "f.txt" });
    defer gpa.free(file_path);

    var dd = try openArgDoc(gpa, io, dir_path);
    defer closeDoc(gpa, &dd);
    try std.testing.expect(dd == .dir);

    var fd = try openArgDoc(gpa, io, file_path);
    defer closeDoc(gpa, &fd);
    try std.testing.expect(fd == .file);
}

test "doc: buf lists, switches, closes, renames, and opens" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "A" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "B" });

    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);
    const pb = try std.fs.path.join(gpa, &.{ base, "b.txt" });
    defer gpa.free(pb);

    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    const fb = try openFileDoc(gpa, io, pb);
    try docs.entries.append(gpa, .{ .id = 2, .doc = .{ .file = fb } });
    docs.next_id = 3;
    docs.current = 1;

    var mode: Mode = .{};
    _ = mode.handle(.{ .char = ':' });
    for ("buf") |c| _ = mode.handle(.{ .char = c });
    try std.testing.expect(mode.handle(.enter) == .open_bufs);
    openBufs(gpa, &docs);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .bufs);
    try std.testing.expectEqual(@as(usize, 3), docs.entries.items.len);

    // Enter on the second row switches to b.txt.
    const bb = &docs.entries.items[docs.currentIndex()].doc.bufs;
    bb.buf.row = 1;
    switchBufsSelected(&docs);
    try std.testing.expectEqualStrings(pb, docPath(&docs.entries.items[docs.currentIndex()].doc));

    // Back to the list. Save one drops b.txt and renames a.txt.
    openBufs(gpa, &docs);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .bufs);
    const renamed = try std.fs.path.join(gpa, &.{ base, "a2.txt" });
    defer gpa.free(renamed);
    const cur = &docs.entries.items[docs.currentIndex()].doc.bufs;
    try cur.buf.replaceAll(renamed);
    cur.buf.dirty = true;
    try applyBufsSave(gpa, io, &docs);

    try std.testing.expectEqual(@as(usize, 2), docs.entries.items.len);
    try std.testing.expect(findByPath(&docs, renamed, false) != null);
    try std.testing.expect(findByPath(&docs, pb, false) == null);
    var got: [8]u8 = undefined;
    try std.testing.expectEqualStrings("A", try tmp.dir.readFile(io, "a2.txt", &got));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "a.txt", .{}));
    // Closing a buffer keeps its file: deletion lives in the fs view.
    try std.testing.expectEqualStrings("B", try tmp.dir.readFile(io, "b.txt", &got));

    // Save two adds c.txt as an empty file and opens it.
    const pc = try std.fs.path.join(gpa, &.{ base, "c.txt" });
    defer gpa.free(pc);
    const want = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ renamed, pc });
    defer gpa.free(want);
    const cur2 = &docs.entries.items[docs.currentIndex()].doc.bufs;
    try cur2.buf.replaceAll(want);
    cur2.buf.dirty = true;
    try applyBufsSave(gpa, io, &docs);

    try std.testing.expectEqual(@as(usize, 3), docs.entries.items.len);
    try std.testing.expect(findByPath(&docs, pc, false) != null);
    try std.testing.expectEqualStrings("", try tmp.dir.readFile(io, "c.txt", &got));
}

test "doc: buf enter follows the line after an unsaved delete" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "A" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "B" });

    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);
    const pb = try std.fs.path.join(gpa, &.{ base, "b.txt" });
    defer gpa.free(pb);

    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    const fb = try openFileDoc(gpa, io, pb);
    try docs.entries.append(gpa, .{ .id = 2, .doc = .{ .file = fb } });
    docs.next_id = 3;
    docs.current = 1;

    openBufs(gpa, &docs);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .bufs);

    // `d` on row 0 removes a.txt's line without saving. Row 0 now
    // shows b.txt, and enter must follow it, not the stale row id.
    const bb = &docs.entries.items[docs.currentIndex()].doc.bufs;
    try bb.buf.deleteLines(1);
    switchBufsSelected(&docs);
    try std.testing.expectEqualStrings(pb, docPath(&docs.entries.items[docs.currentIndex()].doc));
}

test "doc: buf d closes at once through save" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "A" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "B" });

    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);
    const pb = try std.fs.path.join(gpa, &.{ base, "b.txt" });
    defer gpa.free(pb);

    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    const fb = try openFileDoc(gpa, io, pb);
    try docs.entries.append(gpa, .{ .id = 2, .doc = .{ .file = fb } });
    docs.next_id = 3;
    docs.current = 1;

    openBufs(gpa, &docs);
    // `d` on row 0 plus save, the way the main loop runs a
    // normal-mode delete. No insert session involved.
    const bb = &docs.entries.items[docs.currentIndex()].doc.bufs;
    try bb.buf.deleteLines(1);
    var mode: Mode = .{};
    saveDoc(gpa, io, &docs, &mode);

    try std.testing.expect(findByPath(&docs, pa, false) == null);
    try std.testing.expect(findByPath(&docs, pb, false) != null);
    var got: [8]u8 = undefined;
    try std.testing.expectEqualStrings("A", try tmp.dir.readFile(io, "a.txt", &got));
}

test "doc: file d saves at once through save" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a\nb\n" });

    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const pa = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "a.txt" });
    defer gpa.free(pa);

    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;

    const b = docs.currentBuffer();
    try b.deleteLines(1);
    var mode: Mode = .{};
    saveDoc(gpa, io, &docs, &mode);

    var got: [8]u8 = undefined;
    try std.testing.expectEqualStrings("b\n", try tmp.dir.readFile(io, "a.txt", &got));
}

test "buf single delete of welcome keeps the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "A" });
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);

    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    const w = try openWelcomeDoc(gpa);
    try docs.entries.append(gpa, .{ .id = 2, .doc = .{ .welcome = w } });
    docs.next_id = 3;
    docs.current = 1;

    openBufs(gpa, &docs);
    const bb = &docs.entries.items[docs.currentIndex()].doc.bufs;
    bb.buf.row = 1;
    try bb.buf.deleteLines(1);
    var mode: Mode = .{};
    saveDoc(gpa, io, &docs, &mode);

    try std.testing.expect(findByPath(&docs, pa, false) != null);
    try std.testing.expectEqual(@as(usize, 2), docs.entries.items.len);
}

test "buf dd on welcome closes welcome and keeps the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "A" });
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);

    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    const w = try openWelcomeDoc(gpa);
    try docs.entries.append(gpa, .{ .id = 2, .doc = .{ .welcome = w } });
    docs.next_id = 3;
    docs.current = 1;

    // kod has no d-await: each d deletes one line and the main loop
    // saves at once. dd on the welcome row must not take the file too.
    openBufs(gpa, &docs);
    const bb = &docs.entries.items[docs.currentIndex()].doc.bufs;
    bb.buf.row = 1;
    try bb.buf.deleteLines(1);
    var mode: Mode = .{};
    saveDoc(gpa, io, &docs, &mode);
    const bb2 = &docs.entries.items[docs.currentIndex()].doc.bufs;
    try bb2.buf.deleteLines(1);
    saveDoc(gpa, io, &docs, &mode);

    try std.testing.expect(findByPath(&docs, pa, false) != null);
    try std.testing.expectEqual(@as(usize, 2), docs.entries.items.len);
    var line_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(pa, try docs.currentBuffer().line(0, &line_buf));
}

test "buf never strands: the last file-like doc is kept" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "A" });
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);

    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;

    openBufs(gpa, &docs);
    const bb = &docs.entries.items[docs.currentIndex()].doc.bufs;
    try bb.buf.deleteLines(1);
    var mode: Mode = .{};
    saveDoc(gpa, io, &docs, &mode);

    // Refused: the file stays open and its line comes back clean.
    try std.testing.expect(findByPath(&docs, pa, false) != null);
    try std.testing.expectEqual(@as(usize, 2), docs.entries.items.len);
    var line_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(pa, try docs.currentBuffer().line(0, &line_buf));
    try std.testing.expect(!docs.currentBuffer().dirty);
}

test "buf d on welcome row 0 with absolute file keeps the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    // Registry order matches a fresh launch: welcome first, then the
    // file opened with an absolute path. The buf list shows welcome
    // on row 0. `d` there must close welcome, not the file. Before
    // the fix the absolute line failed to parse, so the save saw an
    // empty desired set and closed the file while the last-file guard
    // kept welcome.
    const w = try openWelcomeDoc(gpa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .welcome = w } });
    const abs_path = try gpa.dupe(u8, "/tmp/kod-abs-a.txt");
    errdefer gpa.free(abs_path);
    const abs_text = try gpa.dupe(u8, "A");
    errdefer gpa.free(abs_text);
    const abs_buf = try Buffer.initOwned(gpa, abs_path, abs_text);
    try docs.entries.append(gpa, .{ .id = 2, .doc = .{ .file = .{ .buf = abs_buf, .path_mem = abs_path } } });
    docs.next_id = 3;
    docs.current = 2;

    openBufs(gpa, &docs);
    const bb = &docs.entries.items[docs.currentIndex()].doc.bufs;
    try std.testing.expectEqual(@as(u64, 2), bb.buf.lineCount());
    bb.buf.row = 0;
    try bb.buf.deleteLines(1);
    var mode: Mode = .{};
    saveDoc(gpa, io, &docs, &mode);

    try std.testing.expect(findByPath(&docs, abs_path, false) != null);
    try std.testing.expectEqual(@as(usize, 2), docs.entries.items.len);
    var line_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(abs_path, try docs.currentBuffer().line(0, &line_buf));
    // Enter on the remaining absolute line still switches to it.
    switchBufsSelected(&docs);
    try std.testing.expectEqualStrings(abs_path, docPath(&docs.entries.items[docs.currentIndex()].doc));
}

fn searchTestDocs(gpa: Allocator, io: std.Io, tmp: *std.testing.TmpDir) !struct {
    docs: Docs,
    pa: []u8,
    pb: []u8,
} {
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello world hello\nsecond line\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "nothing here\nhello again\n" });
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    errdefer gpa.free(pa);
    const pb = try std.fs.path.join(gpa, &.{ base, "b.txt" });
    errdefer gpa.free(pb);
    var docs: Docs = .{};
    errdefer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    const fb = try openFileDoc(gpa, io, pb);
    try docs.entries.append(gpa, .{ .id = 2, .doc = .{ .file = fb } });
    docs.next_id = 3;
    docs.current = 1;
    return .{ .docs = docs, .pa = pa, .pb = pb };
}

test "search buffer find jumps and lists hits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fix = try searchTestDocs(gpa, io, &tmp);
    defer gpa.free(fix.pa);
    defer gpa.free(fix.pb);
    defer {
        var k: usize = fix.docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &fix.docs.entries.items[k].doc);
        }
        fix.docs.search.deinit(gpa);
        fix.docs.entries.deinit(gpa);
    }
    var mode: Mode = .{};
    searchRun(gpa, io, &fix.docs, &mode, .buffer, "hello");
    try std.testing.expect(mode.cmd.err.len == 0);
    // Cursor on the first hit, still in the file.
    try std.testing.expect(fix.docs.entries.items[fix.docs.currentIndex()].doc == .file);
    try std.testing.expectEqual(@as(u64, 0), fix.docs.currentBuffer().row);
    try std.testing.expectEqual(@as(u64, 0), fix.docs.currentBuffer().col);
    // Results buffer lists both hits in this file.
    var found = false;
    for (fix.docs.entries.items) |*e| {
        if (e.doc != .search) continue;
        found = true;
        try std.testing.expectEqual(@as(u64, 2), e.doc.search.buf.lineCount());
    }
    try std.testing.expect(found);
}

test "search buffer replace single then n does next" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "foo foo\n" });
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;

    var mode: Mode = .{};
    searchRun(gpa, io, &docs, &mode, .buffer, "foo/bar/");
    var line_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("bar foo", try docs.currentBuffer().line(0, &line_buf));
    // n replaces the next one.
    searchStep(gpa, io, &docs, 1);
    try std.testing.expectEqualStrings("bar bar", try docs.currentBuffer().line(0, &line_buf));
    // Undo walks both replacements back one by one.
    try std.testing.expect(try docs.currentBuffer().undo());
    try std.testing.expectEqualStrings("bar foo", try docs.currentBuffer().line(0, &line_buf));
}

test "search buffer global replaces all" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a a a\n" });
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;

    var mode: Mode = .{};
    searchRun(gpa, io, &docs, &mode, .buffer, "a/b/g");
    var line_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("b b b", try docs.currentBuffer().line(0, &line_buf));
}

test "search buffers scope lists hits across docs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fix = try searchTestDocs(gpa, io, &tmp);
    defer gpa.free(fix.pa);
    defer gpa.free(fix.pb);
    defer {
        var k: usize = fix.docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &fix.docs.entries.items[k].doc);
        }
        fix.docs.search.deinit(gpa);
        fix.docs.entries.deinit(gpa);
    }
    var mode: Mode = .{};
    searchRun(gpa, io, &fix.docs, &mode, .buffers, "hello");
    // Switched to results with three hits across two files.
    try std.testing.expect(fix.docs.entries.items[fix.docs.currentIndex()].doc == .search);
    const sb = &fix.docs.entries.items[fix.docs.currentIndex()].doc.search;
    try std.testing.expectEqual(@as(u64, 3), sb.buf.lineCount());
    // n jumps into the first hit doc.
    searchStep(gpa, io, &fix.docs, 1);
    try std.testing.expect(fix.docs.entries.items[fix.docs.currentIndex()].doc == .file);
}

test "search bad pattern flags and keeps the old query" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fix = try searchTestDocs(gpa, io, &tmp);
    defer gpa.free(fix.pa);
    defer gpa.free(fix.pb);
    defer {
        var k: usize = fix.docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &fix.docs.entries.items[k].doc);
        }
        fix.docs.search.deinit(gpa);
        fix.docs.entries.deinit(gpa);
    }
    var mode: Mode = .{};
    searchRun(gpa, io, &fix.docs, &mode, .buffer, "hello");
    try std.testing.expect(mode.cmd.err.len == 0);
    searchRun(gpa, io, &fix.docs, &mode, .buffer, "(oops");
    try std.testing.expectEqualStrings(command.err_bad_spec, mode.cmd.err);
    try std.testing.expectEqualStrings("hello", fix.docs.search.pattern);
}

test "search files rename in tmp dir" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "old1.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "x" });
    var re = try regex.compile(gpa, "old(.*)", false);
    defer re.deinit();
    try renameMatches(gpa, io, tmp.dir, &re, "new$1", false);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("x", try tmp.dir.readFile(io, "new1.txt", &buf));
    try std.testing.expectEqualStrings("x", try tmp.dir.readFile(io, "keep.txt", &buf));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "old1.txt", .{}));
}

test "search files rename skips collisions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "x" });
    var re = try regex.compile(gpa, "a", false);
    defer re.deinit();
    // a.txt -> b.txt collides, so nothing renames and nothing errors.
    try renameMatches(gpa, io, tmp.dir, &re, "b", true);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("x", try tmp.dir.readFile(io, "a.txt", &buf));
}

test "trees opens with sections and jumps" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "A" });
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const pa = try std.fs.path.join(gpa, &.{ base, "a.txt" });
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;

    var mode: Mode = .{};
    mode.prefillCommand("tree");
    openTrees(gpa, io, &docs, &mode);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .trees);
    var line_buf: [256]u8 = undefined;
    const l0 = try docs.currentBuffer().line(0, &line_buf);
    try std.testing.expect(std.mem.startsWith(u8, l0, "undo ("));
    // Enter on the buffers header folds it; enter on a buffer row jumps.
    var tbrow: ?u64 = null;
    var r: u64 = 0;
    while (r < docs.currentBuffer().lineCount()) : (r += 1) {
        const l = try docs.currentBuffer().line(r, &line_buf);
        if (std.mem.startsWith(u8, l, "buffers (")) tbrow = r;
    }
    const bh = tbrow.?;
    docs.currentBuffer().row = bh;
    activateTreeSelected(gpa, io, &docs, &mode);
    // Sections start folded: the first enter opened it. Find the
    // buffers-section file row and jump back to it.
    r = 0;
    while (r < docs.currentBuffer().lineCount()) : (r += 1) {
        const l = try docs.currentBuffer().line(r, &line_buf);
        if (std.mem.indexOf(u8, l, "a.txt") != null and std.mem.indexOf(u8, l, "[file]") != null) {
            docs.currentBuffer().row = r;
            activateTreeSelected(gpa, io, &docs, &mode);
            break;
        }
    }
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .file);
}

test "trees command rows recall the session history" {
    // The inspector lists what the user ran, newest first, and Enter
    // puts a row back in the command box ready to run or edit.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi\n" });
    const pa = try tmpPath(gpa, &tmp, "a.txt");
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;
    var mode: Mode = .{};
    mode.hist_gpa = gpa;
    defer mode.deinit();
    mode.cmd_history.push(gpa, "fs src");
    mode.cmd_history.push(gpa, "exec-save zig build");
    mode.prefillCommand("tree");
    openTrees(gpa, io, &docs, &mode);
    const tb = &docs.entries.items[docs.currentIndex()].doc.trees;
    var line_buf: [256]u8 = undefined;
    // The section header counts both, folded at first.
    var r: u64 = 0;
    var head: ?u64 = null;
    while (r < tb.buf.lineCount()) : (r += 1) {
        const l = try tb.buf.line(r, &line_buf);
        if (std.mem.startsWith(u8, l, "commands (")) head = r;
    }
    const h = head.?;
    try std.testing.expectEqualStrings("commands (2)", try tb.buf.line(h, &line_buf));
    tb.buf.row = h;
    activateTreeSelected(gpa, io, &docs, &mode);
    // Unfolded: newest first, and the newest row recalls its command.
    try std.testing.expectEqualStrings("  :exec-save zig build", try tb.buf.line(h + 1, &line_buf));
    try std.testing.expectEqualStrings("  :fs src", try tb.buf.line(h + 2, &line_buf));
    tb.buf.row = h + 2;
    activateTreeSelected(gpa, io, &docs, &mode);
    try std.testing.expect(mode.kind == .command);
    try std.testing.expectEqualStrings("fs src", mode.commandText());
    try std.testing.expect(mode.cmd.err.len == 0);
    // Running it fills the exec tree like any other command.
    try std.testing.expect(command.interpret(mode.commandText()) == .fs);
}

test "exec save rerun stamps spans and paints the tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi\n" });
    const pa = try tmpPath(gpa, &tmp, "a.txt");
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        joinExec(gpa, &docs);
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;
    // Arm the file, then take the save-rerun path.
    {
        const b = &docs.entries.items[0].doc.file.buf;
        b.exec_cmd = try gpa.dupe(u8, "printf 'a.txt:1:2: boom\\nplain\\n'");
    }
    rerunExecOnSave(gpa, io, &docs, 1);
    var spins: usize = 0;
    while (docs.exec_runner != null and spins < 500) : (spins += 1) {
        var mode: Mode = .{};
        pollExec(gpa, io, &docs, &mode);
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(docs.exec_runner == null);
    // One span stamped on the open file by suffix match.
    const b = &docs.entries.items[docs.indexOf(1).?].doc.file.buf;
    try std.testing.expectEqual(@as(usize, 1), b.diags.items.len);
    try std.testing.expectEqual(@as(u64, 0), b.diags.items[0].row);
    try std.testing.expectEqual(@as(u64, 1), b.diags.items[0].col);
    try std.testing.expect(b.diagAt(0).? == .err);
    try std.testing.expect(!b.diagStale());
    // Tree holds the header plus both output rows.
    const ei = execIndex(&docs) orelse return error.Unexpected;
    const eb = &docs.entries.items[ei].doc.exec;
    try std.testing.expectEqual(@as(u64, 3), eb.buf.lineCount());
    try std.testing.expect(eb.targetAtRow(1).? == .file);
    try std.testing.expect(eb.targetAtRow(2).? == .none);
    // Editing past the run stales the marks instead of clearing them.
    try b.insert('x');
    try std.testing.expect(b.diagStale());
    // Bare rerun reuses the last command and target.
    var mode: Mode = .{};
    runExec(gpa, io, &docs, &mode, "", false);
    spins = 0;
    while (docs.exec_runner != null and spins < 500) : (spins += 1) {
        pollExec(gpa, io, &docs, &mode);
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(docs.exec_runner == null);
    try std.testing.expect(mode.kind == .normal);
}

test "exec stderr output stays readable through poll" {
    // The worker used to free stderr before the main thread parsed it.
    // Any tool that reports on stderr (every compiler error) unmapped
    // the page, so `pollExec` scanned freed memory and the process
    // died in the vectorized newline search. Stdout-only runs never
    // showed it, which is why the run above missed the bug.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi\n" });
    const pa = try tmpPath(gpa, &tmp, "a.txt");
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        joinExec(gpa, &docs);
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;
    const b = &docs.entries.items[0].doc.file.buf;
    b.exec_cmd = try gpa.dupe(u8, "printf 'a.txt:1:2: boom\\n' 1>&2");
    rerunExecOnSave(gpa, io, &docs, 1);
    var spins: usize = 0;
    while (docs.exec_runner != null and spins < 500) : (spins += 1) {
        var mode: Mode = .{};
        pollExec(gpa, io, &docs, &mode);
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(docs.exec_runner == null);
    // The stderr row reached the tree and stamped the open file.
    const ei = execIndex(&docs) orelse return error.Unexpected;
    const eb = &docs.entries.items[ei].doc.exec;
    try std.testing.expectEqual(@as(u64, 2), eb.buf.lineCount());
    try std.testing.expect(eb.targetAtRow(1).? == .file);
    try std.testing.expectEqual(@as(usize, 1), b.diags.items.len);
}

test "trees name opens one tree in its own buffer" {
    // `:tree exec` opens the exec section alone, with its rows, its
    // styling, and its Enter behavior. The full inspector is a
    // different doc, so both stay open.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi\n" });
    const pa = try tmpPath(gpa, &tmp, "a.txt");
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        joinExec(gpa, &docs);
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;
    var mode: Mode = .{};
    // An unknown name keeps the command box and says why.
    mode.prefillCommand("tree nope");
    openTrees(gpa, io, &docs, &mode);
    try std.testing.expectEqualStrings(command.err_no_tree, mode.cmd.err);
    try std.testing.expectEqual(@as(usize, 1), docs.entries.items.len);
    // A known name opens one section, and it renders open.
    mode.prefillCommand("tree exec");
    openTrees(gpa, io, &docs, &mode);
    try std.testing.expect(mode.cmd.err.len == 0);
    try std.testing.expect(mode.kind == .normal);
    const tb = &docs.entries.items[docs.currentIndex()].doc.trees;
    try std.testing.expect(tb.single == .exec);
    try std.testing.expect(tb.buf.hl_mode == .trees);
    try std.testing.expectEqualStrings("*tree exec*", tb.buf.path);
    // Only the exec section, its header first and no other header.
    var line_buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 1), tb.buf.lineCount());
    try std.testing.expectEqualStrings("exec (no run yet)", try tb.buf.line(0, &line_buf));
    // The full inspector is its own doc, and reopens the same buffer.
    mode.prefillCommand("tree");
    openTrees(gpa, io, &docs, &mode);
    try std.testing.expectEqual(@as(usize, 3), docs.entries.items.len);
    try std.testing.expectEqualStrings("*tree*", docs.currentBuffer().path);
    mode.prefillCommand("tree exec");
    openTrees(gpa, io, &docs, &mode);
    try std.testing.expectEqual(@as(usize, 3), docs.entries.items.len);
    try std.testing.expectEqualStrings("*tree exec*", docs.currentBuffer().path);
}

test "trees exec section shows the run hits and jumps to the file" {
    // The inspector carries the `path:row:col:` rows of the last run,
    // so the diagnostics of a run are visible without switching to the
    // `*exec*` tree, and Enter on a row opens the file.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi\nthere\n" });
    const pa = try tmpPath(gpa, &tmp, "a.txt");
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        joinExec(gpa, &docs);
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;
    const b = &docs.entries.items[0].doc.file.buf;
    b.exec_cmd = try gpa.dupe(u8, "printf 'a.txt:2:3: boom\\nplain\\n'");
    rerunExecOnSave(gpa, io, &docs, 1);
    var mode: Mode = .{};
    try spinExec(gpa, io, &docs, &mode);
    mode.prefillCommand("tree");
    openTrees(gpa, io, &docs, &mode);
    const tb = &docs.entries.items[docs.currentIndex()].doc.trees;
    var line_buf: [256]u8 = undefined;
    // Row 2 is the exec section, and the fold opens onto the hit row.
    // Only jumpable rows list here; the whole run stays in `*exec*`.
    try std.testing.expect(tb.targetAtRow(2).? == .section);
    tb.buf.row = 2;
    activateTreeSelected(gpa, io, &docs, &mode);
    try std.testing.expectEqualStrings("exec: printf 'a.txt:2:3: boom\\nplain\\n' (exit 0, 1 problems)", try tb.buf.line(2, &line_buf));
    try std.testing.expectEqualStrings("  a.txt:2:3: boom", try tb.buf.line(3, &line_buf));
    try std.testing.expectEqualStrings("buffers (3)", try tb.buf.line(4, &line_buf));
    try std.testing.expect(tb.targetAtRow(3).? == .hit);
    // Enter on the hit opens the file at the reported row.
    tb.buf.row = 3;
    activateTreeSelected(gpa, io, &docs, &mode);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .file);
    try std.testing.expectEqual(@as(u64, 1), docs.currentBuffer().row);
}

test "exec save arms the newest file doc from any view" {
    // The tree view is where a run leaves the cursor, so `:exec-save`
    // from there must still arm the file doc. It used to flag the box,
    // which read as `unknown command` with no reason given.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi\n" });
    const pa = try tmpPath(gpa, &tmp, "a.txt");
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        joinExec(gpa, &docs);
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;
    var mode: Mode = .{};
    // A plain run shows the tree and moves the cursor into it.
    runExec(gpa, io, &docs, &mode, "true", false);
    try std.testing.expect(mode.cmd.err.len == 0);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .exec);
    try spinExec(gpa, io, &docs, &mode);
    // Arming from the tree still finds the file doc.
    runExec(gpa, io, &docs, &mode, "true", true);
    try std.testing.expect(mode.cmd.err.len == 0);
    const b = &docs.entries.items[docs.indexOf(1).?].doc.file.buf;
    try std.testing.expectEqualStrings("true", b.exec_cmd.?);
    try spinExec(gpa, io, &docs, &mode);
    // Saving the file reruns the armed command.
    saveDoc(gpa, io, &docs, &mode);
    const eb = &docs.entries.items[execIndex(&docs).?].doc.exec;
    try std.testing.expectEqual(@as(u64, 1), eb.buf.lineCount());
    try spinExec(gpa, io, &docs, &mode);
}

/// Poll until no run is in flight. Bounded: a hung worker fails the
/// expectation instead of hanging the suite.
fn spinExec(gpa: Allocator, io: std.Io, docs: *Docs, mode: *Mode) !void {
    var spins: usize = 0;
    while (docs.exec_runner != null and spins < 500) : (spins += 1) {
        pollExec(gpa, io, docs, mode);
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(docs.exec_runner == null);
}

/// Arm doc 1 for `cmd`. The file doc is reached through the id every
/// time: appending the exec or a tree doc moves `entries.items`, so a
/// pointer taken earlier would dangle.
fn armWith(gpa: Allocator, docs: *Docs, cmd: []const u8) !void {
    const b = &docs.entries.items[docs.indexOf(1).?].doc.file.buf;
    if (b.exec_cmd) |old| gpa.free(old);
    b.exec_cmd = try gpa.dupe(u8, cmd);
}

test "trees exec rows survive a rerun and still land on the line" {
    // The trees buffer kept borrowed exec paths, so a rerun freed them
    // and Enter on a row read freed memory. Rows now own their paths,
    // and a finished run re-renders the trees doc in view.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hi\nthere\nthree\n" });
    const pa = try tmpPath(gpa, &tmp, "a.txt");
    defer gpa.free(pa);
    var docs: Docs = .{};
    defer {
        joinExec(gpa, &docs);
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const fa = try openFileDoc(gpa, io, pa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;
    var mode: Mode = .{};
    try armWith(gpa, &docs, "printf 'a.txt:2:3: boom\\n'");
    rerunExecOnSave(gpa, io, &docs, 1);
    try spinExec(gpa, io, &docs, &mode);
    mode.prefillCommand("tree exec");
    openTrees(gpa, io, &docs, &mode);
    const tb = &docs.entries.items[docs.currentIndex()].doc.trees;
    var line_buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 2), tb.buf.lineCount());
    try std.testing.expectEqualStrings("  a.txt:2:3: boom", try tb.buf.line(1, &line_buf));
    // A rerun with a different line, then the row must follow it.
    try armWith(gpa, &docs, "printf 'a.txt:3:1: later\\n'");
    rerunExecOnSave(gpa, io, &docs, 1);
    // The poll happens with the trees doc in view, as the main loop does.
    var spins: usize = 0;
    while (docs.exec_runner != null and spins < 500) : (spins += 1) {
        pollExec(gpa, io, &docs, &mode);
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .trees);
    try std.testing.expectEqualStrings("  a.txt:3:1: later", try tb.buf.line(1, &line_buf));
    // Enter on the refreshed row lands on the new line.
    tb.buf.row = 1;
    activateTreeSelected(gpa, io, &docs, &mode);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .file);
    try std.testing.expectEqual(@as(u64, 2), docs.currentBuffer().row);
    try std.testing.expectEqual(@as(u64, 0), docs.currentBuffer().col);
}

test "search files submit lists cwd hits" {
    // End to end for `:f/<pat>`: walks the real repo root the way the
    // live command does (this crashed with BADF before walkCwd).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const w = try openWelcomeDoc(gpa);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .welcome = w } });
    docs.next_id = 2;
    docs.current = 1;

    var mode: Mode = .{};
    searchRun(gpa, io, &docs, &mode, .files, "main");
    try std.testing.expect(mode.cmd.err.len == 0);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .search);
    const sb = &docs.entries.items[docs.currentIndex()].doc.search;
    try std.testing.expect(sb.buf.lineCount() >= 1);
    var line_buf: [4096]u8 = undefined;
    var seen = false;
    var r: u64 = 0;
    while (r < sb.buf.lineCount()) : (r += 1) {
        const l = try sb.buf.line(r, &line_buf);
        if (std.mem.eql(u8, l, "src/main.zig")) seen = true;
    }
    try std.testing.expect(seen);
}

test "search file hit switches to the open buffer, else opens it" {
    // Enter on a `f/` result goes to the buffer that already holds the
    // file, so results never open a second copy of the same path, and
    // it opens the file when nothing holds it.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var docs: Docs = .{};
    defer {
        var k: usize = docs.entries.items.len;
        while (k > 0) {
            k -= 1;
            closeDoc(gpa, &docs.entries.items[k].doc);
        }
        docs.search.deinit(gpa);
        docs.entries.deinit(gpa);
    }
    const main_path = try gpa.dupe(u8, "src/main.zig");
    defer gpa.free(main_path);
    const fa = try openFileDoc(gpa, io, main_path);
    try docs.entries.append(gpa, .{ .id = 1, .doc = .{ .file = fa } });
    docs.next_id = 2;
    docs.current = 1;
    var mode: Mode = .{};
    searchRun(gpa, io, &docs, &mode, .files, "main");
    try std.testing.expect(mode.cmd.err.len == 0);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .search);
    // The open file switches instead of opening a second copy of it.
    const open_before = docs.entries.items.len;
    try pressSearchRow(gpa, io, &docs, "src/main.zig");
    try std.testing.expect(docs.current == 1);
    try std.testing.expectEqual(open_before, docs.entries.items.len);
    // A file with no buffer is opened by the same key.
    searchRun(gpa, io, &docs, &mode, .files, "command");
    try pressSearchRow(gpa, io, &docs, "src/command.zig");
    try std.testing.expectEqual(open_before + 1, docs.entries.items.len);
    try std.testing.expect(docs.entries.items[docs.currentIndex()].doc == .file);
}

/// Park the cursor on the search row that reads `want` and press
/// Enter. Fails the test when the walk reported no such row.
fn pressSearchRow(gpa: Allocator, io: std.Io, docs: *Docs, want: []const u8) !void {
    const idx = docs.currentIndex();
    if (docs.entries.items[idx].doc != .search) return error.Unexpected;
    const sb = &docs.entries.items[idx].doc.search;
    var line_buf: [4096]u8 = undefined;
    var r: u64 = 0;
    while (r < sb.buf.lineCount()) : (r += 1) {
        const l = try sb.buf.line(r, &line_buf);
        if (!std.mem.eql(u8, l, want)) continue;
        sb.buf.row = r;
        activateSearchSelected(gpa, io, docs);
        return;
    }
    return error.Unexpected;
}
