//! Paged file original. File bytes stay on disk behind a fixed page
//! cache (64 slots of 64KB, 4MB max). Faults prefetch the next page,
//! and files past the cache get a background readahead thread trailing
//! the reader. `buffer.zig` owns the pieces; this module owns the bytes.

const std = @import("std");
const assert = std.debug.assert;

pub const page_size: u32 = 64 * 1024;
pub const page_slots: u32 = 64;

const Slot = struct {
    base: u64 = std.math.maxInt(u64),
    len: u64 = 0,
    tick: u32 = 0,
    /// Claimed by the background loader. The main thread never takes a
    /// claimed slot, so loader installs never race main installs.
    taken: bool = false,
    data: [page_size]u8 = undefined,
};

/// Cache stays useful past 4MB files: the loader only earns its thread
/// once the file exceeds what the slots hold.
const loader_threshold: u64 = page_slots * page_size;

const LoaderArgs = struct {
    pages: *Pages,
    io: std.Io,
    file: std.Io.File,
    file_len: u64,
};

pub const Pages = struct {
    slots: [page_slots]Slot = [_]Slot{.{}} ** page_slots,
    tick: u32 = 1,
    mutex: std.Io.Mutex = .init,
    /// Background readahead thread. Main-thread owned: only the main
    /// thread spawns, stops, and joins it, so the field itself needs no
    /// lock. Everything the thread touches is mutex-guarded.
    loader: ?std.Thread = null,
    /// Next page base for the loader. Mutex-guarded.
    loader_hint: u64 = 0,
    loader_stop: bool = false,

    pub fn invalidate(self: *Pages) void {
        self.slots = [_]Slot{.{}} ** page_slots;
        self.tick = 1;
    }

    pub fn noteReadAhead(self: *Pages, io: std.Io, off: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (off > self.loader_hint) self.loader_hint = off;
    }

    /// Stops the loader and joins it. No-op when never started. Call
    /// ahead of replacing the file or destroying the pages.
    pub fn stopLoader(self: *Pages, io: std.Io) void {
        if (self.loader == null) return;
        self.mutex.lockUncancelable(io);
        self.loader_stop = true;
        self.mutex.unlock(io);
        const t = self.loader.?;
        self.loader = null;
        t.join();
        self.mutex.lockUncancelable(io);
        self.loader_stop = false;
        self.mutex.unlock(io);
    }

    pub fn slice(
        self: *Pages,
        io: std.Io,
        file: std.Io.File,
        file_len: u64,
        off: u64,
    ) ![]const u8 {
        assert(off < file_len);
        const base = off - (off % page_size);
        const slot = try self.load(io, file, file_len, base);
        return slot.data[off - base .. slot.len];
    }

    fn findHit(self: *Pages, base: u64) ?*Slot {
        for (&self.slots) |*s| {
            if (s.base == base and s.len > 0) return s;
        }
        return null;
    }

    fn findFree(self: *Pages) ?*Slot {
        for (&self.slots) |*s| {
            if (s.len == 0 and !s.taken) return s;
        }
        return null;
    }

    pub fn load(
        self: *Pages,
        io: std.Io,
        file: std.Io.File,
        file_len: u64,
        base: u64,
    ) !*Slot {
        // One mutex, held across the whole miss path. The loader only
        // ever fills free slots, so it stalls briefly instead of
        // racing. No nesting anywhere, so no deadlock.
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.findHit(base)) |s| {
            self.tick += 1;
            s.tick = self.tick;
            return s;
        }
        var victim: *Slot = &self.slots[0];
        for (&self.slots) |*s| {
            if (s.tick < victim.tick and (s.len != 0 or s.taken)) victim = s;
        }
        const slot = self.findFree() orelse victim;
        const want: usize = @min(@as(usize, page_size), @as(usize, @intCast(file_len - base)));
        const n = try file.readPositionalAll(io, slot.data[0..want], base);
        slot.base = base;
        slot.len = @intCast(n);
        self.tick += 1;
        slot.tick = self.tick;
        self.loader_hint = base + 2 * page_size;
        self.prefetchLocked(io, file, file_len, base);
        self.maybeStartLoader(io, file, file_len);
        return slot;
    }

    /// Best-effort synchronous prefetch of the page after a fault.
    /// Linear scans fault in order, so the next page is almost always
    /// wanted. Only fills a free slot, never evicts. Errors stay silent:
    /// the real read surfaces them when the page is actually wanted.
    /// Caller holds the mutex.
    fn prefetchLocked(self: *Pages, io: std.Io, file: std.Io.File, file_len: u64, base: u64) void {
        const next_base = base + page_size;
        if (next_base >= file_len) return;
        if (self.findHit(next_base) != null) return;
        const slot = self.findFree() orelse return;
        const want: usize = @min(@as(usize, page_size), @as(usize, @intCast(file_len - next_base)));
        const n = file.readPositionalAll(io, slot.data[0..want], next_base) catch return;
        if (n == 0) return;
        slot.base = next_base;
        slot.len = @intCast(n);
        self.tick += 1;
        slot.tick = self.tick;
    }

    /// Spawns the background loader once per pages lifetime, only for
    /// files bigger than the cache. Caller holds the mutex. Spawn
    /// failure is silent: the sync paths stay correct alone.
    fn maybeStartLoader(self: *Pages, io: std.Io, file: std.Io.File, file_len: u64) void {
        if (self.loader != null) return;
        if (file_len <= loader_threshold) return;
        const t = std.Thread.spawn(.{}, runLoader, .{LoaderArgs{
            .pages = self,
            .io = io,
            .file = file,
            .file_len = file_len,
        }}) catch return;
        self.loader = t;
    }
};

/// Background readahead. Trails `loader_hint`, filling free slots
/// ahead of the reader. Reads through the same handle with explicit
/// offsets, which carry no shared cursor state. Exits on stop or EOF.
/// Never evicts, never touches a taken slot it did not claim.
fn runLoader(args: LoaderArgs) void {
    const self = args.pages;
    const io = args.io;
    while (true) {
        self.mutex.lockUncancelable(io);
        if (self.loader_stop) {
            self.mutex.unlock(io);
            return;
        }
        const hint = self.loader_hint;
        var present = hint >= args.file_len;
        if (self.findHit(hint) != null) present = true;
        const slot = self.findFree();
        if (present) {
            self.loader_hint = hint + page_size;
            self.mutex.unlock(io);
            continue;
        }
        const target = slot orelse {
            self.mutex.unlock(io);
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
            continue;
        };
        target.taken = true;
        self.mutex.unlock(io);

        const want: usize = @min(@as(usize, page_size), @as(usize, @intCast(args.file_len - hint)));
        const n = args.file.readPositionalAll(io, target.data[0..want], hint) catch {
            self.mutex.lockUncancelable(io);
            target.taken = false;
            self.mutex.unlock(io);
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
            continue;
        };

        self.mutex.lockUncancelable(io);
        if (self.loader_stop or n == 0) {
            target.taken = false;
            self.mutex.unlock(io);
            if (n == 0 and !self.loader_stop) {
                std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
                continue;
            }
            return;
        }
        target.base = hint;
        target.len = @intCast(n);
        target.taken = false;
        self.tick += 1;
        target.tick = self.tick;
        self.loader_hint = hint + page_size;
        self.mutex.unlock(io);
    }
}

test "page fault prefetches the next page" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const big = try gpa.alloc(u8, 100 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = big });
    const f = try tmp.dir.openFile(io, "f", .{ .mode = .read_only });
    defer f.close(io);
    const st = try f.stat(io);
    const len: u64 = @intCast(st.size);

    var pages: Pages = .{};
    _ = try pages.load(io, f, len, 0);
    var found = false;
    for (&pages.slots) |*s| {
        if (s.len > 0 and s.base == page_size) found = true;
    }
    try std.testing.expect(found);
}
