const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const runtime_instrumentation = @import("instrumentation.zig");

const kod = @import("kod");
const StateMachine = kod.StateMachine;
const Terminal = kod.Terminal;
const Logger = kod.Logger;
const Buffer = kod.Buffer;
const BufferManager = kod.BufferManager;
const input = kod.input;

const Event = input.Event;
const Mode = input.Mode;
const Direction = input.Direction;
const Command = input.Command;
const KeyBuffer = input.KeyBuffer;

const AppState = enum(u32) { running, exit };

const assert = std.debug.assert;
const RuntimeInstrumentation = runtime_instrumentation.RuntimeInstrumentation(
    build_options.enable_instrumentation,
);

const AppFsm = StateMachine(AppState);

const app_rules = AppFsm.Rules{
    &.{.exit}, // running -> exit
    &.{}, // exit    -> (terminal)
};

var logger: Logger = undefined;
var term: Terminal = undefined;

var resize_requested: bool = false;
var interrupt_requested: bool = false;

// Render buffer — all frame output is written here first, then flushed in
// a single write(2) call so the terminal never shows a partial frame.

const render_buf_size: u32 = 65_536;
var render_buf: [render_buf_size]u8 = undefined;
const max_panes: usize = 4;

fn getTerminalSize() ![2]u16 {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(
        posix.STDOUT_FILENO,
        posix.T.IOCGWINSZ,
        @intFromPtr(&ws),
    );
    if (posix.errno(rc) != .SUCCESS) return error.IoctlFailed;
    assert(ws.row > 0);
    assert(ws.col > 0);
    return .{ ws.row, ws.col };
}

fn handleInterrupt(_: c_int) callconv(.c) void {
    interrupt_requested = true;
}

fn handleResize(_: c_int) callconv(.c) void {
    resize_requested = true;
}

const AppEvent = union(enum) {
    none,
    quit,
    move: Direction,
    toggle_mode,
    enter_edit,
    enter_normal,
    enter_match,
    scroll_up: u32,
    scroll_down: u32,
    goto_line: u32,
    select_line: u32,
    yank_lines: u32,
    delete_lines: u32,
    yank_range: u32,
    delete_range: u32,
    delete_line,
    delete_until_end_of_line,
    close_buffer,
    open_line_above,
    open_line_below,
    goto_start,
    goto_end,
    indent,
    unindent,
    replace_char: u8,
    undo,
    redo,
    repeat_last,
    paste_below,
    paste_above,
    match_next,
    match_prev,
    match_commit,
    open_help,
    open_directory,
    open_buffer_directory,
    open_mark_directory,
    add_vertical_split,
    focus_next_split,
    next_buffer,
    prev_buffer,
    open_pin: u8,
    normal_submit,
    insert_char: u8,
    backspace,
    delete,
    newline,
    resize,
};

const App = struct {
    fsm: AppFsm,
    mode: Mode,
    redraw_needed: bool,
    scroll_offset: u32,
    col_offset: u32,
    rows: u16,
    cols: u16,
    key_buffer: KeyBuffer,
    command_line: []const u8,
    match_pattern: []const u8,
    match_position: u32,
    match_count: u32,
    match_lines: []u32,
    selected_line: ?u32,
    yank_buffer: []u8,
    undo_stack: [][]u8,
    redo_stack: [][]u8,
    directory_mode: bool,
    buffer_directory_mode: bool,
    mark_directory_mode: bool,
    directory_root: []const u8,
    pin_slots: [10]?usize,
    show_buffer_bar: bool,
    active_buffer_index: usize,
    buffer_count: usize,
    vertical_splits: u8,
    active_split_index: u8,
    split_buffer_indices: [max_panes]?usize,
    allocator: std.mem.Allocator,

    pub fn init(initial_rows: u16, initial_cols: u16, allocator: std.mem.Allocator) App {
        assert(initial_rows > 0);
        assert(initial_cols > 0);
        return .{
            .fsm = AppFsm.init(.running),
            .mode = .normal,
            .redraw_needed = true,
            .scroll_offset = 0,
            .col_offset = 0,
            .rows = initial_rows,
            .cols = initial_cols,
            .key_buffer = .{},
            .command_line = "",
            .match_pattern = "",
            .match_position = 0,
            .match_count = 0,
            .match_lines = &.{},
            .selected_line = null,
            .yank_buffer = &.{},
            .undo_stack = &.{},
            .redo_stack = &.{},
            .directory_mode = false,
            .buffer_directory_mode = false,
            .mark_directory_mode = false,
            .directory_root = ".",
            .pin_slots = [_]?usize{null} ** 10,
            .show_buffer_bar = false,
            .active_buffer_index = 0,
            .buffer_count = 0,
            .vertical_splits = 1,
            .active_split_index = 0,
            .split_buffer_indices = [_]?usize{null} ** max_panes,
            .allocator = allocator,
        };
    }

    fn maxSplitCount(self: *const App) u8 {
        const min_split_width: u16 = 20;
        if (self.cols < min_split_width * 2) return 1;
        const by_width: u16 = @max(1, self.cols / min_split_width);
        return @intCast(@min(@as(u16, max_panes), by_width));
    }

    fn contentRows(self: *const App) u32 {
        return if (self.rows > 1) @as(u32, self.rows) - 1 else 0;
    }

    fn clearMatches(self: *App) void {
        if (self.match_lines.len > 0) {
            self.allocator.free(self.match_lines);
        }
        self.match_lines = &.{};
        self.match_count = 0;
        self.match_position = 0;
    }

    fn maxScroll(self: *const App, buf: *const Buffer) u32 {
        const total = buf.lineCount() + 1; // Reserve one visual line for EOF marker.
        const visible = self.contentRows();
        if (visible == 0 or total <= visible) return 0;
        const scrollable = total - visible;
        assert(scrollable > 0);
        return scrollable;
    }

    fn centerViewport(self: *App, maybe_buffer: ?*Buffer) void {
        if (maybe_buffer) |buf| {
            const cursor_line = buf.getCursorLine();
            const cursor_col = buf.getCursorCol();
            const content_rows = self.contentRows();
            const gutter_width: u32 = 3;
            const visible_cols = if (self.cols > gutter_width) @as(u32, self.cols) - gutter_width else 0;

            // Center cursor vertically
            const ideal_top = if (cursor_line >= content_rows / 2)
                cursor_line - content_rows / 2
            else
                0;

            const max_scroll = self.maxScroll(buf);
            self.scroll_offset = @min(ideal_top, max_scroll);

            // Center cursor horizontally
            const ideal_left = if (cursor_col >= visible_cols / 2)
                cursor_col - visible_cols / 2
            else
                0;
            self.col_offset = ideal_left;
        } else {
            self.scroll_offset = 0;
            self.col_offset = 0;
        }
    }

    fn clampScroll(self: *App, maybe_buffer: ?*const Buffer) void {
        if (maybe_buffer) |buf| {
            const max_scroll = self.maxScroll(buf);
            if (self.scroll_offset > max_scroll) {
                self.scroll_offset = max_scroll;
            }
        } else {
            self.scroll_offset = 0;
        }
    }

    fn clampColScroll(self: *App, maybe_buffer: ?*const Buffer) void {
        if (maybe_buffer) |buf| {
            const cursor_col = buf.getCursorCol();
            const gutter_width: u32 = 3;
            const visible_cols = if (self.cols > gutter_width) @as(u32, self.cols) - gutter_width else 0;
            const max_col = if (cursor_col > visible_cols) cursor_col - visible_cols else 0;

            if (self.col_offset > max_col) {
                self.col_offset = max_col;
            }
        } else {
            self.col_offset = 0;
        }
    }

    fn ensureCursorVisible(self: *App, maybe_buffer: ?*const Buffer) void {
        if (maybe_buffer) |buf| {
            const cursor_line = buf.getCursorLine();
            const cursor_col = buf.getCursorCol();
            const content_rows = self.contentRows();

            if (cursor_line < self.scroll_offset) {
                self.scroll_offset = cursor_line;
            }
            // When cursor is below the visible area, scroll down so the cursor line is visible.
            if (content_rows > 0 and cursor_line > self.scroll_offset + content_rows - 1) {
                self.scroll_offset = cursor_line - (content_rows - 1);
            }

            if (cursor_col < self.col_offset) {
                self.col_offset = cursor_col;
            }

            const max_scroll = self.maxScroll(buf);
            if (self.scroll_offset > max_scroll) {
                self.scroll_offset = max_scroll;
            }

            if (self.col_offset > cursor_col) {
                self.col_offset = cursor_col;
            }
        }
    }

    fn scrollDown(self: *App, maybe_buffer: ?*const Buffer) void {
        if (maybe_buffer) |buf| {
            const max_scroll = self.maxScroll(buf);
            if (self.scroll_offset < max_scroll) {
                self.scroll_offset += 1;
                self.redraw_needed = true;
            }
        }
    }

    fn scrollUp(self: *App) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
            self.redraw_needed = true;
        }
    }

    fn resize(self: *App) !void {
        const size = try getTerminalSize();
        self.rows = size[0];
        self.cols = size[1];
        if (self.vertical_splits > self.maxSplitCount()) {
            self.vertical_splits = self.maxSplitCount();
        }
        if (self.active_split_index >= self.vertical_splits) {
            self.active_split_index = self.vertical_splits - 1;
        }
        self.redraw_needed = true;
    }
};

fn pathMatchesPattern(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    return std.mem.indexOf(u8, path, pattern) != null;
}

fn buildDirectoryContent(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    recursive: bool,
    pattern: []const u8,
) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    // Add parent directory entry at the top
    try output.appendSlice(allocator, "../\n");

    if (recursive) {
        var dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file and entry.kind != .directory) continue;
            if (!pathMatchesPattern(entry.path, pattern)) continue;

            try output.appendSlice(allocator, entry.path);
            if (entry.kind == .directory) {
                try output.append(allocator, '/');
            }
            try output.append(allocator, '\n');
        }
    } else {
        {
            var dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
            defer dir.close();

            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .directory) continue;
                if (!pathMatchesPattern(entry.name, pattern)) continue;

                try output.appendSlice(allocator, entry.name);
                try output.append(allocator, '/');
                try output.append(allocator, '\n');
            }
        }

        var dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!pathMatchesPattern(entry.name, pattern)) continue;

            try output.appendSlice(allocator, entry.name);
            try output.append(allocator, '\n');
        }
    }

    return output.toOwnedSlice(allocator);
}

fn findBufferByPath(manager: *const BufferManager, path: []const u8) ?usize {
    if (manager.buffers.len == 0) return null;
    var i: usize = 0;
    while (i < manager.buffers.len) : (i += 1) {
        if (std.mem.eql(u8, manager.buffers[i].file_path, path)) {
            return i;
        }
    }
    return null;
}

fn buildBufferDirectoryContent(
    allocator: std.mem.Allocator,
    manager: *const BufferManager,
    pin_slots: [10]?usize,
) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var i: usize = 0;
    while (i < manager.buffers.len) : (i += 1) {
        const base = std.fs.path.basename(manager.buffers[i].file_path);
        var slot: usize = 0;
        var pin_slot: ?usize = null;
        while (slot < pin_slots.len) : (slot += 1) {
            if (pin_slots[slot]) |buffer_index| {
                if (buffer_index == i) {
                    pin_slot = slot;
                }
            }
        }

        if (pin_slot) |slot_id| {
            try std.fmt.format(output.writer(allocator), "{d}:{s} [pin:{d}]\n", .{ i, base, slot_id });
        } else {
            try std.fmt.format(output.writer(allocator), "{d}:{s} [pin:-]\n", .{ i, base });
        }
    }

    return output.toOwnedSlice(allocator);
}

fn buildMarkDirectoryContent(
    allocator: std.mem.Allocator,
    manager: *const BufferManager,
    pin_slots: [10]?usize,
) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var slot_index: usize = 0;
    while (slot_index < pin_slots.len) : (slot_index += 1) {
        if (pin_slots[slot_index]) |buffer_index| {
            if (buffer_index < manager.buffers.len) {
                const base = std.fs.path.basename(manager.buffers[buffer_index].file_path);
                try std.fmt.format(
                    output.writer(allocator),
                    "{d}: {d}:{s}\n",
                    .{ slot_index, buffer_index + 1, base },
                );
            } else {
                try std.fmt.format(
                    output.writer(allocator),
                    "{d}: <invalid>\n",
                    .{slot_index},
                );
            }
        } else {
            try std.fmt.format(output.writer(allocator), "{d}: <empty>\n", .{slot_index});
        }
    }

    return output.toOwnedSlice(allocator);
}

fn selectedNonEmptyLine(buf: *const Buffer, line_buf: *[4096]u8) ?[]const u8 {
    var line_index = buf.getCursorLine();

    while (true) {
        if (buf.getLine(line_index, line_buf)) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t");
            if (line.len > 0) {
                return line;
            }
        }
        if (line_index == 0) return null;
        line_index -= 1;
    }
}

fn buildHelpContent(allocator: std.mem.Allocator) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "kod help\n");
    try output.appendSlice(allocator, "\n");
    try output.appendSlice(allocator, "normal mode\n");
    try output.appendSlice(allocator, "h j k l  move cursor\n");
    try output.appendSlice(allocator, "i        enter edit mode\n");
    try output.appendSlice(allocator, "a        open line below and enter edit mode\n");
    try output.appendSlice(allocator, "o        open line above and enter edit mode\n");
    try output.appendSlice(allocator, "S / E    go to start / end\n");
    try output.appendSlice(allocator, "f        open directory browser\n");
    try output.appendSlice(allocator, "b        open buffer list\n");
    try output.appendSlice(allocator, "v        add vertical split\n");
    try output.appendSlice(allocator, "tab      focus next split\n");
    try output.appendSlice(allocator, "[ / ]    previous / next buffer\n");
    try output.appendSlice(allocator, "w        close current buffer\n");
    try output.appendSlice(allocator, "q        close current buffer (legacy)\n");
    try output.appendSlice(allocator, "x        delete char\n");
    try output.appendSlice(allocator, "dd / de  delete line / to end of line\n");
    try output.appendSlice(allocator, "r<char>  replace char\n");
    try output.appendSlice(allocator, "p / P    paste below / above\n");
    try output.appendSlice(allocator, "> / <    indent / unindent\n");
    try output.appendSlice(allocator, "u / .    undo / repeat placeholder\n");
    try output.appendSlice(allocator, "m0..m9   pin current buffer to slot\n");
    try output.appendSlice(allocator, "0..9     jump to pinned buffer\n");
    try output.appendSlice(allocator, "/        search (search only)\n");
    try output.appendSlice(allocator, "{ / }    previous / next search result\n");
    try output.appendSlice(allocator, "?        open this help\n");

    return output.toOwnedSlice(allocator);
}

fn placeCursorAtCenter(app: *App, buf: *Buffer) void {
    const line_count = buf.lineCount();
    if (line_count == 0) return;

    const center_line = app.contentRows() / 2;
    const target_line = @min(center_line, line_count - 1);
    buf.setCursorLine(target_line);
    app.centerViewport(buf);
}

fn findSplitForBuffer(app: *const App, buffer_index: usize) ?u8 {
    var split: u8 = 0;
    while (split < app.vertical_splits) : (split += 1) {
        if (app.split_buffer_indices[split]) |idx| {
            if (idx == buffer_index) return split;
        }
    }
    return null;
}

fn syncSplitState(app: *App, manager: *const BufferManager) void {
    const count = manager.bufferCount();
    if (count == 0) {
        app.vertical_splits = 1;
        app.active_split_index = 0;
        app.split_buffer_indices = [_]?usize{null} ** max_panes;
        return;
    }

    const max_splits: u8 = @intCast(@min(app.maxSplitCount(), @as(u8, @intCast(count))));
    if (app.vertical_splits > max_splits) {
        app.vertical_splits = @max(@as(u8, 1), max_splits);
    }
    if (app.vertical_splits == 0) {
        app.vertical_splits = 1;
    }
    if (app.active_split_index >= app.vertical_splits) {
        app.active_split_index = app.vertical_splits - 1;
    }

    var split: u8 = 0;
    while (split < app.vertical_splits) : (split += 1) {
        if (app.split_buffer_indices[split]) |idx| {
            if (idx < count) continue;
        }
        const fallback = (manager.activeIndex() + split) % count;
        app.split_buffer_indices[split] = fallback;
    }

    while (split < max_panes) : (split += 1) {
        app.split_buffer_indices[split] = null;
    }

    const active_idx = manager.activeIndex();
    if (app.split_buffer_indices[app.active_split_index]) |idx| {
        if (idx == active_idx) return;
    }
    if (findSplitForBuffer(app, active_idx)) |active_split| {
        app.active_split_index = active_split;
    } else {
        app.split_buffer_indices[app.active_split_index] = active_idx;
    }
}

fn focusSplit(app: *App, manager: *BufferManager, split_index: u8) void {
    if (manager.bufferCount() == 0) return;
    if (split_index >= app.vertical_splits) return;
    app.active_split_index = split_index;
    if (app.split_buffer_indices[split_index]) |idx| {
        if (idx < manager.bufferCount()) {
            manager.active_index = idx;
        }
    }
}

fn updateActiveBufferContext(app: *App, manager: *const BufferManager) void {
    app.buffer_count = manager.bufferCount();
    app.show_buffer_bar = manager.bufferCount() > 1;
    app.active_buffer_index = manager.activeIndex();
    syncSplitState(app, manager);

    if (manager.getActive()) |buf| {
        const fp = buf.file_path;
        app.directory_mode = fp.len > 0 and std.mem.startsWith(u8, fp, "[directory]");
        app.buffer_directory_mode = fp.len > 0 and std.mem.startsWith(u8, fp, "[buffers]");
        app.mark_directory_mode = fp.len > 0 and std.mem.startsWith(u8, fp, "[marks]");
    } else {
        app.directory_mode = false;
        app.buffer_directory_mode = false;
        app.mark_directory_mode = false;
    }
}

fn pollAppEvent(app: *App, maybe_buffer: ?*Buffer) AppEvent {
    if (interrupt_requested) {
        interrupt_requested = false;
        return .quit;
    }
    if (resize_requested) {
        resize_requested = false;
        return .resize;
    }

    const ev: Event = input.readEvent();

    return switch (ev) {
        .ctrl_c => .quit,
        .escape => .toggle_mode,
        .char => |c| handleCharEvent(app, c, maybe_buffer),
        .command => |cmd| handleCommandEvent(app, cmd),
        .match_next => .match_next,
        .match_prev => .match_prev,
        .enter_match => .enter_match,
        else => .none,
    };
}

fn handleCharEvent(app: *App, c: u8, maybe_buffer: ?*Buffer) AppEvent {
    switch (app.mode) {
        .normal => {
            if (app.key_buffer.len > 0) {
                const first_char = app.key_buffer.data[0];
                app.key_buffer.reset(); // Reset buffer after processing potential multi-key command

                if (first_char == 'd') {
                    if (c == 'e') { // de - delete until end of line
                        app.redraw_needed = true;
                        return .delete_until_end_of_line;
                    }
                    if (c == 'd') { // dd - delete line
                        app.redraw_needed = true;
                        return .delete_line;
                    }
                }
                // If it was a 'r' command from before, this is its second char.
                if (first_char == 'r') {
                    app.redraw_needed = true;
                    return .{ .replace_char = c };
                }
                // If the buffered command was not handled, try to parse it as a number command.
                if (first_char >= '0' and first_char <= '9') {
                    // Re-push the first char to reconstruct the command.
                    _ = app.key_buffer.push(first_char);
                    _ = app.key_buffer.push(c); // And the current char
                    const cmd = app.key_buffer.parseCommand();
                    app.key_buffer.reset();
                    app.redraw_needed = true;
                    return handleCommandEvent(app, cmd);
                }
                // For other buffered commands that didn't match a sequence, they are now discarded.
                // This implicit reset handles cases like 'z' then 'z' where 'z' isn't part of a sequence.
            }

            // Single character commands and commands that initiate sequences
            if (c == '/') {
                return .enter_match;
            }
            if (c == '?') {
                return .open_help;
            }
            if (c == 'f') {
                return .open_directory;
            }
            if (c == 'b') {
                return .open_buffer_directory;
            }
            if (c == 'v') {
                return .add_vertical_split;
            }
            if (c == ']') {
                return .next_buffer;
            }
            if (c == '[') {
                return .prev_buffer;
            }
            if (c == '\t') {
                return .focus_next_split;
            }
            if (c == 'i') {
                return .enter_edit;
            }
            if (c == 'o') {
                return .open_line_above;
            }
            if (c == 'a') {
                return .open_line_below;
            }
            if (c == 'E') {
                return .goto_end;
            }
            if (c == 'S') {
                return .goto_start;
            }
            if (c == 'u') {
                return .undo;
            }
            if (c == '.') {
                return .repeat_last;
            }
            if (c == 'p') {
                return .paste_below;
            }
            if (c == 'P') {
                return .paste_above;
            }
            if (c == '>') {
                return .indent;
            }
            if (c == '<') {
                return .unindent;
            }
            if (c == 'w' or c == 'q') {
                return .close_buffer;
            }
            if (c == '}') {
                return .match_next;
            }
            if (c == '{') {
                return .match_prev;
            }
            if (c == 'h') { // Horizontal movement left
                if (maybe_buffer) |buf| {
                    (buf.*).cursorLeft();
                    app.centerViewport(buf);
                    app.redraw_needed = true;
                }
                return .none;
            }
            if (c == 'l') { // Horizontal movement right
                if (maybe_buffer) |buf| {
                    (buf.*).cursorRight();
                    app.centerViewport(buf);
                    app.redraw_needed = true;
                }
                return .none;
            }
            if (c == 'j') {
                if (maybe_buffer) |buf| {
                    (buf.*).cursorDown();
                    app.centerViewport(buf);
                    app.ensureCursorVisible(maybe_buffer);
                    app.redraw_needed = true;
                }
                return .none;
            }
            if (c == 'k') {
                if (maybe_buffer) |buf| {
                    (buf.*).cursorUp();
                    app.centerViewport(buf);
                    app.ensureCursorVisible(maybe_buffer);
                    app.redraw_needed = true;
                }
                return .none;
            }
            if (c == 'x') { // Delete character
                return .delete;
            }
            if (c == '+') {
                _ = app.key_buffer.push(c);
                app.redraw_needed = true;
                return .none;
            }
            if (c == '-') {
                _ = app.key_buffer.push(c);
                app.redraw_needed = true;
                return .none;
            }
            if (c >= '0' and c <= '9') {
                if (app.key_buffer.len == 0 and !app.directory_mode and !app.buffer_directory_mode) {
                    const pin_slot = @as(usize, c - '0');
                    if (app.pin_slots[pin_slot] != null) {
                        return .{ .open_pin = @intCast(pin_slot) };
                    }
                }
                _ = app.key_buffer.push(c);
                app.redraw_needed = true;
                return .none;
            }
            if (c == 'm' or c == 'd' or c == 'r' or c == 's' or c == 'y') { // Commands that start a sequence
                _ = app.key_buffer.push(c);
                app.redraw_needed = true;
                return .none;
            }
            if (c == ' ') {
                if (app.key_buffer.len > 0 and app.key_buffer.data[0] == 'm') {
                    _ = app.key_buffer.push(c);
                    app.redraw_needed = true;
                    return .none;
                }
            }
            if (c == 127 or c == 8) { // Backspace
                if ((app.directory_mode or app.buffer_directory_mode) and app.key_buffer.len > 0) {
                    app.key_buffer.len -= 1;
                    app.redraw_needed = true;
                }
                return .none;
            }
            if (c == '\n' or c == '\r') { // Enter/Return
                if (app.directory_mode or app.buffer_directory_mode) {
                    return .normal_submit;
                }
                if (app.key_buffer.len > 0) {
                    const first = app.key_buffer.data[0];
                    if (first == 'm') { // Only 'm' sequences are submitted this way now
                        return .normal_submit;
                    }
                }
                // Handle cases where numerical commands were buffered
                if (app.key_buffer.len > 0) {
                    const cmd = app.key_buffer.parseCommand();
                    app.key_buffer.reset();
                    app.redraw_needed = true;
                    return handleCommandEvent(app, cmd);
                }
            }
            if (app.directory_mode or app.buffer_directory_mode) {
                _ = app.key_buffer.push(c);
                app.redraw_needed = true;
                return .none;
            }
            app.key_buffer.reset(); // Reset for unhandled keys
            return .none;
        },
        .edit => {
            if (c == 127 or c == 8) {
                return .backspace;
            }
            if (c == '\n' or c == '\r') {
                return .newline;
            }
            if (c == 27) {
                return .enter_normal;
            }
            if (c == '\t') { // Tab character
                if (maybe_buffer) |buf| {
                    buf.insertTab() catch |e| {
                        logger.warn("buffer", "insert tab failed: {}", .{e});
                    };
                    app.centerViewport(buf);
                    app.redraw_needed = true;
                }
                return .none;
            }
            return .{ .insert_char = c };
        },
        .match => {
            if (c == '\n' or c == '\r') {
                return .match_commit;
            }
            if (c == 27) {
                return .enter_normal;
            }
            if (c == 127 or c == 8) {
                return .backspace;
            }
            if (c == '}') {
                return .match_next;
            }
            if (c == '{') {
                return .match_prev;
            }
            return .{ .insert_char = c };
        },
    }
}

fn handleCommandEvent(app: *App, cmd: Command) AppEvent {
    if (app.key_buffer.len >= 2 and app.key_buffer.data[0] == 'r') {
        const repl_char = app.key_buffer.data[1];
        app.key_buffer.reset();
        return .{ .replace_char = repl_char };
    }
    return switch (cmd) {
        .scroll_up => |n| .{ .scroll_up = n },
        .scroll_down => |n| .{ .scroll_down = n },
        .goto_line => |n| .{ .goto_line = n },
        .select_line => |n| .{ .select_line = n },
        .yank_lines => |n| .{ .yank_lines = n },
        .delete_lines => |n| .{ .delete_lines = n },
        .yank_range => |n| .{ .yank_range = n },
        .delete_range => |n| .{ .delete_range = n },
        .delete_line => .delete_line,
        .replace_char => |c| .{ .replace_char = c },
        .indent => .indent,
        .unindent => .unindent,
        .goto_start => .goto_start,
        .goto_end => .goto_end,
        .undo => .undo,
        .redo => .redo,
        .repeat_last => .repeat_last,
        .paste_below => .paste_below,
        .paste_above => .paste_above,
        .none => .none,
    };
}

const SplitRole = enum {
    none,
    visible,
    active,
};

fn splitRoleForBuffer(app: *const App, buffer_index: usize) SplitRole {
    var split: u8 = 0;
    while (split < app.vertical_splits) : (split += 1) {
        if (app.split_buffer_indices[split]) |idx| {
            if (idx == buffer_index) {
                if (split == app.active_split_index) {
                    return .active;
                }
                return .visible;
            }
        }
    }
    return .none;
}

fn renderTopBar(
    app: *const App,
    manager: *const BufferManager,
    w: anytype,
) void {
    const cols = app.cols;

    const mode_str = switch (app.mode) {
        .normal => "n",
        .match => "m",
        .edit => "e",
    };
    // Clear top line.
    w.writeAll("\x1B[1;1H\x1B[2K") catch return;

    // Left: kod - mode with styling.
    w.writeAll("\x1B[30;47m") catch {};
    w.writeAll("><") catch {};
    w.writeAll(mode_str[0..1]) catch {};

    w.writeAll(">") catch {};
    w.writeAll("\x1B[0m") catch {};

    // Center: currently typed command or search.
    const kb = &app.key_buffer;
    if (kb.len > 0) {
        var typed_buf: [40]u8 = undefined;
        const raw_typed = kb.data[0..kb.len];
        const prefix = if (app.mode == .match) "/" else "";
        const typed = std.fmt.bufPrint(&typed_buf, "{s}{s}", .{ prefix, raw_typed }) catch "";

        const typed_len: u16 = @intCast(typed.len);
        const col_center: u16 = if (cols > typed_len)
            (cols - typed_len) / 2 + 1
        else
            1;
        std.fmt.format(w, "\x1B[1;{d}H", .{col_center}) catch {};
        w.writeAll("\x1B[37m") catch {};
        w.writeAll(typed) catch {};
        w.writeAll("\x1B[0m") catch {};
    }

    // Right: buffer list with active buffer at the far right.
    if (manager.bufferCount() == 0) return;

    var labels_total_width: u16 = 0;
    var count: usize = manager.bufferCount();
    if (count > 32) {
        count = 32;
    }

    var widths: [32]u16 = undefined;
    var order: [32]usize = undefined;
    var used: usize = 0;

    var i: usize = manager.bufferCount();
    while (i > 0 and used < count) {
        i -= 1;
        const base = std.fs.path.basename(manager.buffers[i].file_path);

        var tmp: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&tmp, " {d}:{s} ", .{ i + 1, base }) catch "";
        const width: u16 = @intCast(label.len);

        if (labels_total_width + width + 1 > cols) break;

        widths[used] = width;
        order[used] = i;
        labels_total_width += width + 1;
        used += 1;
    }

    if (used == 0) return;

    const start_col: u16 = if (cols > labels_total_width)
        cols - labels_total_width + 1
    else
        1;

    var col: u16 = start_col;
    var idx: usize = used;
    while (idx > 0) {
        idx -= 1;
        const buffer_index = order[idx];
        const split_role = splitRoleForBuffer(app, buffer_index);
        const base = std.fs.path.basename(manager.buffers[buffer_index].file_path);

        var tmp: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&tmp, " {d}:{s} ", .{ buffer_index + 1, base }) catch "";

        std.fmt.format(w, "\x1B[1;{d}H", .{col}) catch {};
        switch (split_role) {
            .active => w.writeAll("\x1B[30;47m") catch {},
            .visible => w.writeAll("\x1B[38;5;254;48;5;238m") catch {},
            .none => w.writeAll("\x1B[37m") catch {},
        }
        w.writeAll(label) catch {};
        w.writeAll("\x1B[0m") catch {};

        col += widths[idx] + 1;
    }
}

const syntax = kod.syntax;

const ContentAreaOpts = struct {
    scroll_override: ?u32 = null,
    col_offset_override: ?u32 = null,
    dim: bool = false,
};

fn writeSpaces(w: anytype, count: u16) void {
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        w.writeAll(" ") catch {};
    }
}

fn renderContentAreaAt(
    app: *const App,
    maybe_buffer: ?*const Buffer,
    w: anytype,
    opts: ContentAreaOpts,
    left_col: u16,
    width: u16,
) void {
    const content_rows: u32 = app.contentRows();
    const scroll = opts.scroll_override orelse app.scroll_offset;
    const col_off = opts.col_offset_override orelse app.col_offset;

    if (width == 0) return;

    var clear_row: u32 = 0;
    while (clear_row < content_rows) : (clear_row += 1) {
        std.fmt.format(w, "\x1B[{d};{d}H", .{ clear_row + 2, left_col }) catch {};
        writeSpaces(w, width);
    }

    if (maybe_buffer) |buf| {
        const total = buf.lineCount();
        const total_visual_lines = total + 1; // Include EOF marker row.
        const visible: u32 = @intCast(@min(total_visual_lines -| scroll, content_rows));
        const cursor_line = buf.getCursorLine();
        const cursor_col = buf.getCursorCol();

        var line_num_width: u32 = 1;
        var tmp_total: u32 = if (total_visual_lines == 0) 1 else total_visual_lines;
        while (tmp_total >= 10) : (tmp_total /= 10) {
            line_num_width += 1;
        }
        if (line_num_width < 2) line_num_width = 2;
        const gutter_width: u32 = line_num_width + 1;

        const content_cols: u16 = if (width > gutter_width)
            width - @as(u16, @intCast(gutter_width))
        else
            0;

        var line_idx: u32 = 0;
        var line_buf: [4096]u8 = undefined;
        var ln_buf: [32]u8 = undefined;
        while (line_idx < visible) : (line_idx += 1) {
            const abs_line_index: u32 = scroll + line_idx;
            const is_eof_line = abs_line_index >= total;
            const is_selected = if (app.selected_line) |line| line == abs_line_index else false;
            const is_current_line = app.mode != .match and !is_eof_line and abs_line_index == cursor_line;

            var is_match: bool = false;
            var is_current_match: bool = false;
            var mi: usize = 0;
            while (mi < app.match_count) : (mi += 1) {
                if (mi >= app.match_lines.len) break;
                if (app.match_lines[mi] == abs_line_index) {
                    is_match = true;
                    if (mi == app.match_position) {
                        is_current_match = true;
                    }
                    break;
                }
            }

            const line_number: u32 = scroll + line_idx + 1;
            const ln = std.fmt.bufPrint(&ln_buf, "{d}", .{line_number}) catch "";
            const ln_len: u32 = @intCast(ln.len);
            const padding: u32 = if (line_num_width > ln_len) line_num_width - ln_len else 0;

            std.fmt.format(w, "\x1B[{d};{d}H", .{ line_idx + 2, left_col }) catch {};

            if (opts.dim) {
                w.writeAll("\x1B[38;5;240m") catch {};
            } else if (is_selected or is_current_match or is_current_line) {
                w.writeAll("\x1B[30;47m") catch {};
            } else if (is_match) {
                w.writeAll("\x1B[38;5;250m") catch {};
            }

            var pi: u32 = 0;
            while (pi < padding) : (pi += 1) {
                w.writeAll(" ") catch {};
            }
            w.writeAll(ln) catch {};
            w.writeAll(" ") catch {};

            if (content_cols > 0) {
                if (is_eof_line) {
                    w.writeAll("\x1B[31mEOF") catch {};
                } else if (buf.getLine(abs_line_index, &line_buf)) |line| {
                    const use_syntax = !opts.dim and !app.directory_mode and !app.buffer_directory_mode and !app.mark_directory_mode and !std.mem.startsWith(u8, buf.file_path, "[");

                    if (opts.dim) {
                        w.writeAll("\x1B[38;5;240m") catch {};
                    } else if (!is_selected and !is_current_match and !is_current_line and !is_match) {
                        w.writeAll("\x1B[38;5;252m") catch {};
                    }
                    const is_folder_entry = app.directory_mode and line.len > 0 and line[line.len - 1] == '/';
                    if (is_folder_entry) {
                        w.writeAll("\x1B[1m") catch {};
                    }

                    const start_col = @min(@as(usize, col_off), line.len);
                    const display_len = @min(line.len - start_col, @as(usize, content_cols));
                    const cursor_in_line = abs_line_index == cursor_line;
                    const cursor_col_usize: usize = @intCast(cursor_col);
                    const cursor_screen_col = cursor_col_usize -| @as(usize, col_off);
                    const cursor_visible = cursor_in_line and cursor_screen_col <= content_cols;

                    if (cursor_visible and cursor_screen_col < content_cols) {
                        const prefix_len = @min(cursor_screen_col, display_len);
                        if (prefix_len > 0) {
                            if (use_syntax) {
                                syntax.writeLineWithSyntaxHighlight(w, line, start_col, start_col + prefix_len, col_off);
                            } else {
                                w.writeAll(line[start_col .. start_col + prefix_len]) catch {};
                            }
                        }

                        const cursor_char = if (cursor_col_usize < line.len)
                            line[cursor_col_usize]
                        else
                            ' ';
                        w.writeAll("\x1B[37;40m") catch {};
                        w.writeByte(cursor_char) catch {};

                        if (is_selected or is_current_match or is_current_line) {
                            w.writeAll("\x1B[30;47m") catch {};
                        } else if (is_match) {
                            w.writeAll("\x1B[38;5;250m") catch {};
                        } else if (is_folder_entry) {
                            w.writeAll("\x1B[38;5;252m\x1B[1m") catch {};
                        } else {
                            w.writeAll("\x1B[38;5;252m") catch {};
                        }

                        const drawn_len = prefix_len + 1;
                        const rest_len = display_len -| drawn_len;
                        if (rest_len > 0 and cursor_col_usize + 1 <= line.len) {
                            const rest_start = @max(cursor_col_usize + 1, start_col + drawn_len);
                            const rest_end = @min(rest_start + rest_len, line.len);
                            if (rest_end > rest_start) {
                                if (use_syntax) {
                                    syntax.writeLineWithSyntaxHighlight(w, line, rest_start, rest_end, col_off);
                                } else {
                                    w.writeAll(line[rest_start..rest_end]) catch {};
                                }
                            }
                        }
                    } else {
                        if (display_len > 0) {
                            if (use_syntax) {
                                syntax.writeLineWithSyntaxHighlight(w, line, start_col, start_col + display_len, col_off);
                            } else {
                                w.writeAll(line[start_col .. start_col + display_len]) catch {};
                            }
                        }
                    }
                }
            }
            w.writeAll("\x1B[0m") catch {};
        }
    } else {
        const placeholder = "><kod>";
        const middle_row = app.rows / 2;
        const col_start: u16 = if (width > placeholder.len)
            (width - @as(u16, @intCast(placeholder.len))) / 2
        else
            0;
        std.fmt.format(w, "\x1B[{d};{d}H", .{ middle_row, left_col + col_start }) catch {};
        w.writeAll(placeholder) catch {};
    }
}

fn renderContentArea(
    app: *const App,
    maybe_buffer: ?*const Buffer,
    w: anytype,
    opts: ContentAreaOpts,
) void {
    renderContentAreaAt(app, maybe_buffer, w, opts, 1, app.cols);
}

fn bufferForSplit(app: *const App, manager: *const BufferManager, split_index: u8) ?*const Buffer {
    if (manager.bufferCount() == 0) return null;
    if (split_index >= app.vertical_splits) return null;
    const idx = app.split_buffer_indices[split_index] orelse return null;
    if (idx >= manager.bufferCount()) return null;
    return &manager.buffers[idx];
}

fn renderVerticalSplits(app: *const App, manager: *const BufferManager, w: anytype) void {
    const split_count: u16 = @intCast(@max(@as(u8, 1), app.vertical_splits));
    if (split_count <= 1) {
        renderContentArea(app, manager.getActive(), w, .{});
        return;
    }

    const separators = split_count - 1;
    if (app.cols <= separators) {
        renderContentArea(app, manager.getActive(), w, .{});
        return;
    }

    const pane_width_total = app.cols - separators;
    const base_width = pane_width_total / split_count;
    const extra = pane_width_total % split_count;

    var pane: u16 = 0;
    var left_col: u16 = 1;
    while (pane < split_count) : (pane += 1) {
        const pane_width = base_width + @as(u16, if (pane < extra) 1 else 0);
        const split_idx: u8 = @intCast(pane);
        const pane_buffer = bufferForSplit(app, manager, split_idx);

        renderContentAreaAt(
            app,
            pane_buffer,
            w,
            .{
                .scroll_override = if (pane == app.active_split_index) app.scroll_offset else 0,
                .col_offset_override = if (pane == app.active_split_index) app.col_offset else 0,
                .dim = pane != app.active_split_index,
            },
            left_col,
            pane_width,
        );

        left_col += pane_width;
        if (pane + 1 < split_count) {
            var row: u32 = 0;
            while (row < app.contentRows()) : (row += 1) {
                std.fmt.format(w, "\x1B[{d};{d}H", .{ row + 2, left_col }) catch {};
                w.writeAll("\x1B[38;5;240m|\x1B[0m") catch {};
            }
            left_col += 1;
        }
    }
}

/// Build the entire frame into `render_buf` and flush once.
fn render(
    app: *const App,
    stdout: posix.fd_t,
    maybe_buffer: ?*const Buffer,
    manager: *const BufferManager,
) void {
    var fbs = std.io.fixedBufferStream(&render_buf);
    const w = fbs.writer();

    w.writeAll("\x1B[?25l") catch return;
    w.writeAll("\x1B[2J\x1B[H") catch return;

    renderTopBar(app, manager, w);

    if (app.vertical_splits > 1 and manager.bufferCount() > 0) {
        renderVerticalSplits(app, manager, w);
    } else {
        renderContentArea(app, maybe_buffer, w, .{});
    }

    _ = posix.write(stdout, fbs.getWritten()) catch {};
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = std.fs.cwd();

    const log_file = try cwd.createFile("app.log", .{ .truncate = true });
    defer log_file.close();

    logger = Logger.init(log_file);
    logger.debug("app", "starting", .{});

    var instrumentation = RuntimeInstrumentation.init();
    defer instrumentation.emit_summary();

    var buffer_manager = BufferManager.init(allocator);
    defer buffer_manager.deinit();

    term = Terminal.init();

    //  Register signal handlers.
    const sigact = posix.Sigaction{
        .handler = .{ .handler = handleInterrupt },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sigact, null);

    const winch_act = posix.Sigaction{
        .handler = .{ .handler = handleResize },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &winch_act, null);

    term.enter() catch |e| {
        logger.warn("term", "raw mode failed (expected in non-TTY): {}", .{e});
    };

    const size = try getTerminalSize();
    var app = App.init(size[0], size[1], allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const launch_path = if (args.len > 1) args[1] else ".";
    const is_directory = blk: {
        var dir = cwd.openDir(launch_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (is_directory) {
        if (!std.mem.eql(u8, launch_path, ".")) {
            app.directory_root = try allocator.dupe(u8, launch_path);
        }

        const content = buildDirectoryContent(allocator, app.directory_root, false, "") catch |e| {
            logger.warn("directory", "startup list failed: {}", .{e});
            return e;
        };

        const listing_path = "[directory] .";
        try buffer_manager.addEmptyBuffer(listing_path);
        buffer_manager.active_index = buffer_manager.buffers.len - 1;
        if (buffer_manager.getActive()) |buf| {
            buf.replaceContentOwned(content) catch |e| {
                logger.warn("directory", "startup update failed: {}", .{e});
                allocator.free(content);
                return e;
            };
            placeCursorAtCenter(&app, buf);
        }

        app.clearMatches();
        app.selected_line = null;
        app.directory_mode = true;
        app.redraw_needed = true;
    } else {
        buffer_manager.addBuffer(launch_path) catch |e| switch (e) {
            error.FileNotFound => {
                const file = try cwd.createFile(launch_path, .{ .truncate = false });
                file.close();
                try buffer_manager.addBuffer(launch_path);
            },
            else => return e,
        };
        buffer_manager.active_index = buffer_manager.buffers.len - 1;
        if (buffer_manager.getActive()) |buf| {
            placeCursorAtCenter(&app, buf);
        }
        app.redraw_needed = true;
    }

    const stdout = posix.STDOUT_FILENO;

    // --- ANSI Terminal Setup ---
    // Enable alternate screen buffer, hide cursor, set scroll region
    var escape_buf: [128]u8 = undefined;
    const setup_seq = std.fmt.bufPrint(&escape_buf, "\x1B[?1049h\x1B[H\x1B[?25l\x1B[2;{d}r", .{app.rows}) catch unreachable;
    _ = posix.write(stdout, setup_seq) catch {};

    defer {
        // --- ANSI Terminal Teardown ---
        // Show cursor, reset scroll region, disable alternate screen buffer
        _ = posix.write(stdout, "\x1B[?25h\x1B[r\x1B[?1049l") catch {};
        term.exit(); // Restore termios settings
    }

    //  Retained-mode loop: render if dirty, poll event, update state.
    while (app.fsm.get() == .running) {
        instrumentation.increment_counter(.frame);
        const frame_start = instrumentation.begin_timer(.frame);
        defer instrumentation.end_timer(.frame, frame_start);

        updateActiveBufferContext(&app, &buffer_manager);
        const maybe_buffer = buffer_manager.getActive();

        if (app.redraw_needed) {
            instrumentation.increment_counter(.render);
            const render_start = instrumentation.begin_timer(.render);
            app.redraw_needed = false;
            app.clampScroll(maybe_buffer);
            render(
                &app,
                stdout,
                maybe_buffer,
                &buffer_manager,
            );
            instrumentation.end_timer(.render, render_start);
        }

        const poll_start = instrumentation.begin_timer(.poll);
        const ev = pollAppEvent(&app, maybe_buffer);
        instrumentation.end_timer(.poll, poll_start);

        if (ev != .none) {
            instrumentation.increment_counter(.event);
        }

        const dispatch_start = instrumentation.begin_timer(.dispatch);
        defer instrumentation.end_timer(.dispatch, dispatch_start);

        switch (ev) {
            .none => {},
            .quit => {
                _ = app.fsm.transition(&app_rules, .exit);
            },
            .move => |dir| switch (app.mode) {
                .normal => switch (dir) {
                    .north => {
                        if (app.directory_mode or app.buffer_directory_mode or app.mark_directory_mode) {
                            if (maybe_buffer) |buf| {
                                buf.cursorUp();
                                app.ensureCursorVisible(maybe_buffer);
                            }
                            app.redraw_needed = true;
                        } else {
                            app.scrollUp();
                        }
                    },
                    .south => {
                        if (app.directory_mode or app.buffer_directory_mode or app.mark_directory_mode) {
                            if (maybe_buffer) |buf| {
                                buf.cursorDown();
                                app.ensureCursorVisible(maybe_buffer);
                            }
                            app.redraw_needed = true;
                        } else {
                            app.scrollDown(maybe_buffer);
                        }
                    },
                    .east => {},
                    .west => {},
                },
                .match => {},
                .edit => {},
            },
            .toggle_mode => {
                if (app.mode != .normal) {
                    app.mode = .normal;
                    app.key_buffer.reset();
                }
                app.redraw_needed = true;
            },
            .enter_edit => {
                if (!app.directory_mode and !app.buffer_directory_mode) {
                    app.mode = .edit;
                }
                app.redraw_needed = true;
            },
            .open_line_above => {
                if (!app.directory_mode and !app.buffer_directory_mode) {
                    if (maybe_buffer) |buf| {
                        buf.cursorUp();
                        buf.insertNewline() catch {};
                        buf.save() catch {};
                        app.centerViewport(buf);
                    }
                    app.mode = .edit;
                }
                app.redraw_needed = true;
            },
            .open_line_below => {
                if (!app.directory_mode and !app.buffer_directory_mode) {
                    if (maybe_buffer) |buf| {
                        buf.cursorDown();
                        buf.insertNewline() catch {};
                        buf.cursorUp();
                        buf.save() catch {};
                        app.centerViewport(buf);
                    }
                    app.mode = .edit;
                }
                app.redraw_needed = true;
            },
            .goto_start => {
                if (maybe_buffer) |buf| {
                    buf.setCursorLine(0);
                    app.centerViewport(buf);
                }
                app.redraw_needed = true;
            },
            .goto_end => {
                if (maybe_buffer) |buf| {
                    const last_line = buf.lineCount() - 1;
                    buf.setCursorLine(last_line);
                    app.centerViewport(buf);
                }
                app.redraw_needed = true;
            },
            .indent => {
                if (maybe_buffer) |buf| {
                    const line = buf.getCursorLine();
                    var line_buf: [4096]u8 = undefined;
                    if (buf.getLine(line, &line_buf)) |content| {
                        const indented = std.mem.concat(app.allocator, u8, &[_][]const u8{ "    ", content }) catch content;
                        if (indented.len > content.len) {
                            buf.deleteLine(line) catch {};
                            buf.insertLine(line, indented) catch {};
                            app.allocator.free(indented);
                            buf.save() catch {};
                        }
                    }
                }
                app.redraw_needed = true;
            },
            .unindent => {
                if (maybe_buffer) |buf| {
                    const line = buf.getCursorLine();
                    var line_buf: [4096]u8 = undefined;
                    if (buf.getLine(line, &line_buf)) |content| {
                        var trimmed = content;
                        while (trimmed.len > 0 and trimmed[0] == ' ') : (trimmed = trimmed[1..]) {}
                        if (trimmed.len != content.len) {
                            buf.deleteLine(line) catch {};
                            buf.insertLine(line, trimmed) catch {};
                            buf.save() catch {};
                        }
                    }
                }
                app.redraw_needed = true;
            },
            .replace_char => |c| {
                if (maybe_buffer) |buf| {
                    buf.deleteChar() catch {};
                    buf.insertChar(c) catch {};
                    buf.save() catch {};
                }
                app.redraw_needed = true;
            },
            .delete_line => {
                if (maybe_buffer) |buf| {
                    const line = buf.getCursorLine();
                    buf.deleteLine(line) catch {};
                    buf.save() catch {};
                }
                app.redraw_needed = true;
            },
            .delete_until_end_of_line => {
                if (maybe_buffer) |buf| {
                    buf.deleteUntilEndOfLine() catch {};
                    buf.save() catch {};
                }
                app.redraw_needed = true;
            },
            .undo => {
                app.redraw_needed = true;
            },
            .redo => {
                app.redraw_needed = true;
            },
            .repeat_last => {
                app.redraw_needed = true;
            },
            .paste_below => {
                if (maybe_buffer) |buf| {
                    if (app.yank_buffer.len > 0) {
                        buf.insertNewline() catch {};
                        var i: usize = 0;
                        while (i < app.yank_buffer.len) : (i += 1) {
                            buf.insertChar(app.yank_buffer[i]) catch {};
                            if (app.yank_buffer[i] == '\n') {
                                buf.cursorDown();
                            }
                        }
                        buf.save() catch {};
                    }
                }
                app.redraw_needed = true;
            },
            .paste_above => {
                if (maybe_buffer) |buf| {
                    if (app.yank_buffer.len > 0) {
                        buf.cursorUp();
                        buf.insertNewline() catch {};
                        buf.cursorUp();
                        var i: usize = 0;
                        while (i < app.yank_buffer.len) : (i += 1) {
                            buf.insertChar(app.yank_buffer[i]) catch {};
                            if (app.yank_buffer[i] == '\n') {
                                buf.cursorDown();
                            }
                        }
                        buf.save() catch {};
                    }
                }
                app.redraw_needed = true;
            },
            .close_buffer => {
                if (buffer_manager.buffers.len > 0 and buffer_manager.active_index < buffer_manager.buffers.len) {
                    buffer_manager.closeActive();
                    updateActiveBufferContext(&app, &buffer_manager);
                    app.redraw_needed = true;
                }
            },
            .enter_normal => {
                app.mode = .normal;
                app.key_buffer.reset();
                app.redraw_needed = true;
            },
            .enter_match => {
                app.mode = .match;
                app.key_buffer.reset();
                app.redraw_needed = true;
            },
            .scroll_up => |n| {
                if (maybe_buffer) |buf| {
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        buf.cursorUp();
                    }
                    app.centerViewport(buf);
                    app.redraw_needed = true;
                }
            },
            .scroll_down => |n| {
                if (maybe_buffer) |buf| {
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        buf.cursorDown();
                    }
                    app.centerViewport(buf);
                    app.redraw_needed = true;
                }
            },
            .goto_line => |n| {
                if (maybe_buffer) |buf| {
                    if (n > 0) { // Ensure n is at least 1
                        buf.setCursorLine(n - 1);
                        app.centerViewport(buf);
                        app.redraw_needed = true;
                    }
                }
            },
            .select_line => |n| {
                if (maybe_buffer) |buf| {
                    buf.setCursorLine(n - 1);
                    app.selected_line = n - 1;
                    app.centerViewport(buf);
                    app.redraw_needed = true;
                }
            },
            .yank_lines => |n| {
                if (maybe_buffer) |buf| {
                    const line_count = buf.lineCount();
                    const start_line: u32 = if (app.selected_line) |sel|
                        @min(sel, n - 1)
                    else
                        n - 1;
                    const end_line: u32 = @min(n - 1, line_count - 1);

                    if (start_line <= end_line) {
                        if (app.yank_buffer.len > 0) {
                            app.allocator.free(app.yank_buffer);
                        }
                        var yank_list = std.ArrayList(u8).empty;
                        var line_idx: u32 = start_line;
                        while (line_idx <= end_line) : (line_idx += 1) {
                            var line_buf: [4096]u8 = undefined;
                            if (buf.getLine(line_idx, &line_buf)) |line_content| {
                                yank_list.appendSlice(app.allocator, line_content) catch {};
                                yank_list.append(app.allocator, '\n') catch {};
                            }
                        }
                        if (yank_list.items.len > 0 and yank_list.items[yank_list.items.len - 1] == '\n') {
                            yank_list.items.len -= 1;
                        }
                        app.yank_buffer = yank_list.toOwnedSlice(app.allocator) catch &.{};
                    }
                    app.key_buffer.reset();
                    app.redraw_needed = true;
                }
            },
            .delete_lines => |n| {
                if (maybe_buffer) |buf| {
                    if (n > 0) { // Ensure n is at least 1
                        const line_count = buf.lineCount();
                        const target_line: u32 = n - 1;
                        if (target_line < line_count) {
                            buf.deleteLine(target_line) catch {};
                            buf.save() catch {};
                        }
                    }
                    app.key_buffer.reset();
                    app.redraw_needed = true;
                }
            },
            .yank_range => |n| {
                if (maybe_buffer) |buf| {
                    const start_line = n / 10000;
                    const end_line = n % 10000;
                    const line_count = buf.lineCount();

                    const actual_start = @min(start_line, line_count - 1);
                    const actual_end = @min(end_line, line_count - 1);

                    if (actual_start <= actual_end) {
                        if (app.yank_buffer.len > 0) {
                            app.allocator.free(app.yank_buffer);
                        }
                        var yank_list = std.ArrayList(u8).empty;
                        var line_idx: u32 = actual_start;
                        while (line_idx <= actual_end) : (line_idx += 1) {
                            var line_buf: [4096]u8 = undefined;
                            if (buf.getLine(line_idx, &line_buf)) |line_content| {
                                yank_list.appendSlice(app.allocator, line_content) catch {};
                                yank_list.append(app.allocator, '\n') catch {};
                            }
                        }
                        if (yank_list.items.len > 0 and yank_list.items[yank_list.items.len - 1] == '\n') {
                            yank_list.items.len -= 1;
                        }
                        app.yank_buffer = yank_list.toOwnedSlice(app.allocator) catch &.{};
                    }
                    app.key_buffer.reset();
                    app.redraw_needed = true;
                }
            },
            .delete_range => |n| {
                if (maybe_buffer) |buf| {
                    const start_line = n / 10000;
                    const end_line = n % 10000;
                    const line_count = buf.lineCount();

                    const actual_start = @min(start_line, line_count - 1);
                    const actual_end = @min(end_line, line_count - 1);

                    if (actual_start <= actual_end) {
                        var line_idx: u32 = actual_end;
                        while (line_idx >= actual_start) : (line_idx -%= 1) {
                            buf.deleteLine(line_idx) catch {};
                        }
                        buf.save() catch {};
                    }
                    app.key_buffer.reset();
                    app.redraw_needed = true;
                }
            },
            .match_next => {
                if (app.match_count > 0 and app.match_lines.len > 0) {
                    app.match_position = if (app.match_position + 1 < app.match_count)
                        app.match_position + 1
                    else
                        0;
                    if (maybe_buffer) |buf| {
                        const idx: usize = @intCast(app.match_position);
                        if (idx < app.match_lines.len) {
                            buf.setCursorLine(app.match_lines[idx]);
                            app.centerViewport(buf);
                        }
                    }
                    app.redraw_needed = true;
                }
            },
            .match_prev => {
                if (app.match_count > 0 and app.match_lines.len > 0) {
                    app.match_position = if (app.match_position > 0) app.match_position - 1 else app.match_count - 1;
                    if (maybe_buffer) |buf| {
                        const idx: usize = @intCast(app.match_position);
                        if (idx < app.match_lines.len) {
                            buf.setCursorLine(app.match_lines[idx]);
                            app.centerViewport(buf);
                        }
                    }
                    app.redraw_needed = true;
                }
            },
            .match_commit => {
                // Commit the current search pattern and return to normal mode.
                app.mode = .normal;

                const kb = &app.key_buffer;
                const pattern = kb.data[0..kb.len];

                if (maybe_buffer) |buf| {
                    app.clearMatches();

                    if (app.directory_mode) {
                        const content = buildDirectoryContent(
                            allocator,
                            app.directory_root,
                            true,
                            pattern,
                        ) catch |e| {
                            logger.warn("match", "directory match failed: {}", .{e});
                            kb.reset();
                            app.redraw_needed = true;
                            break;
                        };

                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("match", "directory buffer update failed: {}", .{e});
                            allocator.free(content);
                            kb.reset();
                            app.redraw_needed = true;
                            break;
                        };

                        const line_count = buf.lineCount();
                        const matches = app.allocator.alloc(u32, line_count) catch |e| {
                            logger.warn("match", "directory match alloc failed: {}", .{e});
                            kb.reset();
                            app.redraw_needed = true;
                            break;
                        };
                        var match_idx: u32 = 0;
                        while (match_idx < line_count) : (match_idx += 1) {
                            matches[match_idx] = match_idx;
                        }
                        app.clearMatches();
                        app.match_lines = matches;
                        app.match_count = line_count;
                        app.match_position = 0;

                        app.selected_line = null;
                        app.centerViewport(buf);
                    } else {
                        if (pattern.len > 0) {
                            const matches = buf.findMatches(pattern, app.allocator) catch |e| {
                                logger.warn("match", "findMatches failed: {}", .{e});
                                kb.reset();
                                app.redraw_needed = true;
                                break;
                            };

                            app.clearMatches();
                            app.match_lines = matches;
                            app.match_count = @intCast(matches.len);
                            app.match_position = 0;

                            if (app.match_count > 0 and matches.len > 0) {
                                buf.setCursorLine(matches[0]);
                                app.centerViewport(buf);
                            }
                        }
                    }
                }

                kb.reset();
                app.redraw_needed = true;
            },
            .add_vertical_split => {
                if (buffer_manager.bufferCount() > 0) {
                    const max_splits: u8 = @intCast(@min(app.maxSplitCount(), @as(u8, @intCast(buffer_manager.bufferCount()))));
                    if (app.vertical_splits < max_splits) {
                        const current = app.active_split_index;
                        app.vertical_splits += 1;
                        const new_split = app.vertical_splits - 1;
                        var next_idx = (buffer_manager.activeIndex() + 1) % buffer_manager.bufferCount();
                        // Prefer a buffer not already visible in another pane.
                        var tries: usize = 0;
                        while (tries < buffer_manager.bufferCount()) : (tries += 1) {
                            if (findSplitForBuffer(&app, next_idx) == null) break;
                            next_idx = (next_idx + 1) % buffer_manager.bufferCount();
                        }
                        app.split_buffer_indices[new_split] = next_idx;
                        app.active_split_index = current;
                    }
                    syncSplitState(&app, &buffer_manager);
                    app.redraw_needed = true;
                }
            },
            .focus_next_split => {
                if (app.vertical_splits > 1) {
                    const next_split = (app.active_split_index + 1) % app.vertical_splits;
                    focusSplit(&app, &buffer_manager, next_split);
                    updateActiveBufferContext(&app, &buffer_manager);
                    if (buffer_manager.getActive()) |buf| {
                        app.centerViewport(buf);
                    }
                    app.redraw_needed = true;
                }
            },
            .next_buffer => {
                if (buffer_manager.bufferCount() > 0) {
                    const split = app.active_split_index;
                    const cur = app.split_buffer_indices[split] orelse buffer_manager.activeIndex();
                    const next = (cur + 1) % buffer_manager.bufferCount();
                    app.split_buffer_indices[split] = next;
                    buffer_manager.active_index = next;
                }
                updateActiveBufferContext(&app, &buffer_manager);
                if (buffer_manager.getActive()) |buf| {
                    app.centerViewport(buf);
                }
                app.redraw_needed = true;
            },
            .prev_buffer => {
                if (buffer_manager.bufferCount() > 0) {
                    const split = app.active_split_index;
                    const cur = app.split_buffer_indices[split] orelse buffer_manager.activeIndex();
                    const prev = if (cur == 0) buffer_manager.bufferCount() - 1 else cur - 1;
                    app.split_buffer_indices[split] = prev;
                    buffer_manager.active_index = prev;
                }
                updateActiveBufferContext(&app, &buffer_manager);
                if (buffer_manager.getActive()) |buf| {
                    app.centerViewport(buf);
                }
                app.redraw_needed = true;
            },
            .open_help => {
                const content = buildHelpContent(allocator) catch |e| {
                    logger.warn("help", "build failed: {}", .{e});
                    break;
                };

                const help_path = "[help]";
                if (findBufferByPath(&buffer_manager, help_path)) |index| {
                    buffer_manager.active_index = index;
                    if (buffer_manager.getActive()) |buf| {
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("help", "update failed: {}", .{e});
                            allocator.free(content);
                            break;
                        };
                        placeCursorAtCenter(&app, buf);
                    }
                } else {
                    try buffer_manager.addEmptyBuffer(help_path);
                    buffer_manager.active_index = buffer_manager.buffers.len - 1;
                    if (buffer_manager.getActive()) |buf| {
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("help", "update failed: {}", .{e});
                            allocator.free(content);
                            break;
                        };
                        placeCursorAtCenter(&app, buf);
                    }
                }

                app.clearMatches();
                app.selected_line = null;
                app.redraw_needed = true;
            },
            .open_directory => {
                const content = buildDirectoryContent(allocator, app.directory_root, false, "") catch |e| {
                    logger.warn("directory", "list failed: {}", .{e});
                    break;
                };

                const listing_path = "[directory] .";
                if (findBufferByPath(&buffer_manager, listing_path)) |index| {
                    buffer_manager.active_index = index;
                    if (buffer_manager.getActive()) |buf| {
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("directory", "update failed: {}", .{e});
                            allocator.free(content);
                            break;
                        };
                        placeCursorAtCenter(&app, buf);
                    }
                } else {
                    try buffer_manager.addEmptyBuffer(listing_path);
                    buffer_manager.active_index = buffer_manager.buffers.len - 1;
                    if (buffer_manager.getActive()) |buf| {
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("directory", "update failed: {}", .{e});
                            allocator.free(content);
                            break;
                        };
                        placeCursorAtCenter(&app, buf);
                    }
                }

                app.clearMatches();
                app.selected_line = null;
                app.key_buffer.reset();
                app.directory_mode = true;
                app.redraw_needed = true;
            },
            .open_buffer_directory => {
                const content = buildBufferDirectoryContent(allocator, &buffer_manager, app.pin_slots) catch |e| {
                    logger.warn("buffers", "list failed: {}", .{e});
                    break;
                };

                const listing_path = "[buffers]";
                if (findBufferByPath(&buffer_manager, listing_path)) |index| {
                    buffer_manager.active_index = index;
                    if (buffer_manager.getActive()) |buf| {
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("buffers", "update failed: {}", .{e});
                            allocator.free(content);
                            break;
                        };
                        placeCursorAtCenter(&app, buf);
                    }
                } else {
                    try buffer_manager.addEmptyBuffer(listing_path);
                    buffer_manager.active_index = buffer_manager.buffers.len - 1;
                    if (buffer_manager.getActive()) |buf| {
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("buffers", "update failed: {}", .{e});
                            allocator.free(content);
                            break;
                        };
                        placeCursorAtCenter(&app, buf);
                    }
                }

                app.clearMatches();
                app.selected_line = null;
                app.buffer_directory_mode = true;
                app.redraw_needed = true;
            },
            .open_mark_directory => {
                const content = buildMarkDirectoryContent(allocator, &buffer_manager, app.pin_slots) catch |e| {
                    logger.warn("marks", "list failed: {}", .{e});
                    break;
                };

                const listing_path = "[marks]";
                if (findBufferByPath(&buffer_manager, listing_path)) |index| {
                    buffer_manager.active_index = index;
                    if (buffer_manager.getActive()) |buf| {
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("marks", "update failed: {}", .{e});
                            allocator.free(content);
                            break;
                        };
                        placeCursorAtCenter(&app, buf);
                    }
                } else {
                    try buffer_manager.addEmptyBuffer(listing_path);
                    buffer_manager.active_index = buffer_manager.buffers.len - 1;
                    if (buffer_manager.getActive()) |buf| {
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("marks", "update failed: {}", .{e});
                            allocator.free(content);
                            break;
                        };
                        placeCursorAtCenter(&app, buf);
                    }
                }

                app.clearMatches();
                app.selected_line = null;
                app.mark_directory_mode = true;
                app.redraw_needed = true;
            },
            .open_pin => |slot| {
                const slot_index: usize = @intCast(slot);
                if (slot_index < app.pin_slots.len) {
                    if (app.pin_slots[slot_index]) |index| {
                        if (index < buffer_manager.buffers.len) {
                            buffer_manager.active_index = index;
                            if (buffer_manager.getActive()) |buf| {
                                app.centerViewport(buf);
                            }
                            app.redraw_needed = true;
                        }
                    }
                }
            },
            .normal_submit => blk: {
                if (maybe_buffer) |buf| {
                    if (app.buffer_directory_mode) {
                        if (app.key_buffer.len > 0) {
                            const key = app.key_buffer.data[0];
                            if (key >= '0' and key <= '9') {
                                const idx = @as(usize, key - '0');
                                if (idx < buffer_manager.buffers.len) {
                                    buffer_manager.active_index = idx;
                                }
                            }
                            app.key_buffer.reset();
                        } else {
                            var line_buf: [4096]u8 = undefined;
                            if (selectedNonEmptyLine(buf, &line_buf)) |line| {
                                if (std.mem.indexOfScalar(u8, line, ':')) |sep| {
                                    const index_text = std.mem.trim(u8, line[0..sep], " \t");
                                    const idx = std.fmt.parseInt(usize, index_text, 10) catch 0;
                                    if (idx < buffer_manager.buffers.len) {
                                        buffer_manager.active_index = idx;
                                    }
                                }
                            }
                        }
                    } else if (app.mark_directory_mode) {
                        if (app.key_buffer.len > 0) {
                            const key = app.key_buffer.data[0];
                            if (key >= '0' and key <= '9') {
                                const slot_index = @as(usize, key - '0');
                                if (slot_index < app.pin_slots.len) {
                                    if (app.pin_slots[slot_index]) |buffer_index| {
                                        if (buffer_index < buffer_manager.buffers.len) {
                                            buffer_manager.active_index = buffer_index;
                                            if (buffer_manager.getActive()) |active_buf| {
                                                app.centerViewport(active_buf);
                                            }
                                        }
                                    }
                                }
                            }
                            app.key_buffer.reset();
                        } else {
                            var line_buf: [4096]u8 = undefined;
                            if (selectedNonEmptyLine(buf, &line_buf)) |line| {
                                if (std.mem.indexOfScalar(u8, line, ':')) |sep| {
                                    const slot_text = std.mem.trim(u8, line[0..sep], " \t");
                                    const slot_index = std.fmt.parseInt(usize, slot_text, 10) catch 0;
                                    if (slot_index < app.pin_slots.len) {
                                        if (app.pin_slots[slot_index]) |buffer_index| {
                                            if (buffer_index < buffer_manager.buffers.len) {
                                                buffer_manager.active_index = buffer_index;
                                                if (buffer_manager.getActive()) |active_buf| {
                                                    app.centerViewport(active_buf);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else if (app.directory_mode and app.key_buffer.len > 0) {
                        const typed_name = app.key_buffer.data[0..app.key_buffer.len];
                        const path_new = try std.fs.path.join(allocator, &.{ app.directory_root, typed_name });
                        defer allocator.free(path_new);

                        if (std.mem.endsWith(u8, typed_name, "/")) {
                            const dir_path = path_new[0 .. path_new.len - 1];
                            try std.fs.cwd().makePath(dir_path);
                        } else {
                            if (std.fs.path.dirname(path_new)) |parent| {
                                try std.fs.cwd().makePath(parent);
                            }
                            const file = try std.fs.cwd().createFile(path_new, .{ .truncate = false });
                            file.close();
                        }

                        const content = buildDirectoryContent(allocator, app.directory_root, false, "") catch |e| {
                            logger.warn("directory", "refresh failed: {}", .{e});
                            app.key_buffer.reset();
                            app.redraw_needed = true;
                            break :blk;
                        };
                        buf.replaceContentOwned(content) catch |e| {
                            logger.warn("directory", "refresh update failed: {}", .{e});
                            allocator.free(content);
                            app.key_buffer.reset();
                            app.redraw_needed = true;
                            break :blk;
                        };
                        app.key_buffer.reset();
                        placeCursorAtCenter(&app, buf);
                    } else if (!app.directory_mode and app.key_buffer.len > 0 and app.key_buffer.data[0] == 'm') {
                        if (app.key_buffer.len >= 2) {
                            const slot_char = app.key_buffer.data[app.key_buffer.len - 1];
                            if (slot_char >= '0' and slot_char <= '9') {
                                const pin_slot = @as(usize, slot_char - '0');
                                app.pin_slots[pin_slot] = buffer_manager.activeIndex();
                            }
                        }
                        app.key_buffer.reset();
                    } else {
                        var line_buf: [4096]u8 = undefined;
                        if (selectedNonEmptyLine(buf, &line_buf)) |line| {
                            if (line.len > 0) {
                                if (line[line.len - 1] == '/') {
                                    const next_dir = line[0 .. line.len - 1];
                                    const old_root = app.directory_root;
                                    app.directory_root = try std.fs.path.join(
                                        allocator,
                                        &.{ app.directory_root, next_dir },
                                    );
                                    if (!std.mem.eql(u8, old_root, ".")) {
                                        allocator.free(old_root);
                                    }

                                    const content = buildDirectoryContent(
                                        allocator,
                                        app.directory_root,
                                        false,
                                        "",
                                    ) catch |e| {
                                        logger.warn("directory", "open dir failed: {}", .{e});
                                        app.redraw_needed = true;
                                        break :blk;
                                    };
                                    buf.replaceContentOwned(content) catch |e| {
                                        logger.warn("directory", "open dir update failed: {}", .{e});
                                        allocator.free(content);
                                        app.redraw_needed = true;
                                        break :blk;
                                    };
                                    app.key_buffer.reset();
                                    placeCursorAtCenter(&app, buf);
                                } else {
                                    const file_target = std.fs.path.join(
                                        allocator,
                                        &.{ app.directory_root, line },
                                    ) catch |e| {
                                        logger.warn("directory", "path join failed: {}", .{e});
                                        break :blk;
                                    };
                                    defer allocator.free(file_target);
                                    buffer_manager.addBuffer(file_target) catch |e| {
                                        logger.warn("directory", "open file failed: {}", .{e});
                                        break :blk;
                                    };
                                    buffer_manager.active_index = buffer_manager.buffers.len - 1;
                                    updateActiveBufferContext(&app, &buffer_manager);
                                    if (buffer_manager.getActive()) |active_buf| {
                                        placeCursorAtCenter(&app, active_buf);
                                    }
                                    app.key_buffer.reset();
                                    app.clearMatches();
                                }
                            }
                        }
                    }
                }
                app.redraw_needed = true;
            },
            .insert_char => |c| {
                switch (app.mode) {
                    .edit => {
                        if (!app.directory_mode and !app.buffer_directory_mode) {
                            if (maybe_buffer) |buf| {
                                buf.insertChar(c) catch |e| {
                                    logger.warn("buffer", "insert char failed: {}", .{e});
                                };
                                buf.save() catch |e| {
                                    logger.warn("buffer", "auto save failed: {}", .{e});
                                };
                                app.centerViewport(buf);
                                app.redraw_needed = true;
                            }
                        }
                    },
                    .match => {
                        // In match mode, build the search pattern in the key buffer.
                        _ = app.key_buffer.push(c);
                        app.redraw_needed = true;
                    },
                    .normal => {
                        // Ignore insert_char in normal mode.
                    },
                }
            },
            .backspace => {
                switch (app.mode) {
                    .edit => {
                        if (!app.directory_mode and !app.buffer_directory_mode) {
                            if (maybe_buffer) |buf| {
                                buf.deleteChar() catch |e| {
                                    logger.warn("buffer", "delete char failed: {}", .{e});
                                };
                                buf.save() catch |e| {
                                    logger.warn("buffer", "auto save failed: {}", .{e});
                                };
                                app.centerViewport(buf);
                                app.redraw_needed = true;
                            }
                        }
                    },
                    .match => {
                        if (app.key_buffer.len > 0) {
                            app.key_buffer.len -= 1;
                            app.redraw_needed = true;
                        }
                    },
                    .normal => {},
                }
            },
            .delete => {
                if (app.directory_mode) {
                    if (maybe_buffer) |buf| {
                        var line_buf: [4096]u8 = undefined;
                        if (buf.getLine(buf.getCursorLine(), &line_buf)) |line_raw| {
                            const line = std.mem.trim(u8, line_raw, " \t");
                            if (line.len > 0 and !std.mem.eql(u8, line, "../")) {
                                const target_path = std.fs.path.join(
                                    allocator,
                                    &.{
                                        app.directory_root,
                                        if (line[line.len - 1] == '/') line[0 .. line.len - 1] else line,
                                    },
                                ) catch continue;
                                defer allocator.free(target_path);

                                const is_dir = line[line.len - 1] == '/';

                                if (is_dir) {
                                    std.fs.cwd().deleteTree(target_path) catch |e| {
                                        logger.warn("directory", "delete dir failed: {}", .{e});
                                    };
                                } else {
                                    std.fs.cwd().deleteFile(target_path) catch |e| {
                                        logger.warn("directory", "delete file failed: {}", .{e});
                                    };
                                }

                                const content = buildDirectoryContent(allocator, app.directory_root, false, "") catch |e| {
                                    logger.warn("directory", "refresh failed: {}", .{e});
                                    break;
                                };
                                buf.replaceContentOwned(content) catch |e| {
                                    logger.warn("directory", "buffer update failed: {}", .{e});
                                    allocator.free(content);
                                    break;
                                };
                                app.redraw_needed = true;
                            }
                        }
                    }
                } else if (app.buffer_directory_mode) {
                    if (maybe_buffer) |buf| {
                        var line_buf: [4096]u8 = undefined;
                        if (buf.getLine(buf.getCursorLine(), &line_buf)) |line_raw| {
                            const line = std.mem.trim(u8, line_raw, " \t");
                            if (line.len > 0) {
                                const colon_idx = std.mem.indexOf(u8, line, ":");
                                if (colon_idx) |idx| {
                                    const index_str = line[0..idx];
                                    const buffer_idx = std.fmt.parseInt(usize, index_str, 10) catch continue;
                                    if (buffer_idx > 0 and buffer_idx <= buffer_manager.buffers.len) {
                                        const to_remove = buffer_idx - 1;

                                        buffer_manager.buffers[to_remove].deinit();

                                        const last = buffer_manager.buffers.len - 1;
                                        if (to_remove != last) {
                                            buffer_manager.buffers[to_remove] = buffer_manager.buffers[last];
                                        }
                                        buffer_manager.buffers.len -= 1;

                                        if (buffer_manager.active_index >= buffer_manager.buffers.len and buffer_manager.buffers.len > 0) {
                                            buffer_manager.active_index = buffer_manager.buffers.len - 1;
                                        }

                                        updateActiveBufferContext(&app, &buffer_manager);

                                        const content = buildBufferDirectoryContent(allocator, &buffer_manager, app.pin_slots) catch |e| {
                                            logger.warn("buffers", "refresh failed: {}", .{e});
                                            break;
                                        };
                                        buf.replaceContentOwned(content) catch |e| {
                                            logger.warn("buffers", "buffer update failed: {}", .{e});
                                            allocator.free(content);
                                        };
                                        app.redraw_needed = true;
                                    }
                                }
                            }
                        }
                    }
                } else if (app.mark_directory_mode) {
                    // In mark directory mode, x clears the mark
                    if (maybe_buffer) |buf| {
                        var line_buf: [4096]u8 = undefined;
                        if (buf.getLine(buf.getCursorLine(), &line_buf)) |line_raw| {
                            const line = std.mem.trim(u8, line_raw, " \t");
                            if (line.len > 0) {
                                const colon_idx = std.mem.indexOf(u8, line, ":");
                                if (colon_idx) |idx| {
                                    const slot_str = line[0..idx];
                                    const slot = std.fmt.parseInt(usize, slot_str, 10) catch continue;
                                    if (slot < app.pin_slots.len) {
                                        app.pin_slots[slot] = null;

                                        const content = buildMarkDirectoryContent(allocator, &buffer_manager, app.pin_slots) catch |e| {
                                            logger.warn("marks", "refresh failed: {}", .{e});
                                            break;
                                        };
                                        buf.replaceContentOwned(content) catch |e| {
                                            logger.warn("marks", "buffer update failed: {}", .{e});
                                            allocator.free(content);
                                        };
                                        app.redraw_needed = true;
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Normal buffer: delete character
                    if (maybe_buffer) |buf| {
                        buf.deleteChar() catch |e| {
                            logger.warn("buffer", "delete char failed: {}", .{e});
                        };
                        buf.save() catch |e| {
                            logger.warn("buffer", "auto save failed: {}", .{e});
                        };
                        app.centerViewport(buf);
                        app.redraw_needed = true;
                    }
                }
            },
            .newline => {
                if (!app.directory_mode and !app.buffer_directory_mode) {
                    if (maybe_buffer) |buf| {
                        buf.insertNewline() catch |e| {
                            logger.warn("buffer", "insert newline failed: {}", .{e});
                        };
                        buf.save() catch |e| {
                            logger.warn("buffer", "auto save failed: {}", .{e});
                        };
                        app.centerViewport(buf);
                        app.redraw_needed = true;
                    }
                }
            },
            .resize => {
                app.resize() catch |e| {
                    logger.warn("term", "size query failed: {}", .{e});
                };
            },
        }
    }

    const default_root: []const u8 = ".";
    if (app.directory_root.ptr != default_root.ptr) {
        app.allocator.free(app.directory_root);
    }
    logger.debug("app", "shutdown", .{});
}
