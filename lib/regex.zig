//! Small byte-oriented regex for interactive search. Thompson ops run
//! on a backtracking VM with an explicit heap stack and a step budget,
//! so hostile patterns cost bounded time, never the C stack. ASCII
//! only: folding and classes work on bytes, UTF-8 passes through
//! untouched. Lines only: callers feed one line at a time, `.` never
//! sees `\n`.
//!
//! Syntax: literals, `.`, `*`, `+`, `?`, `{m,n}`, `(...)` and `(?:...)`,
//! `|` alternation, `[...]` classes with ranges and `[^...]` negation,
//! `^` `$` anchors, `\b` `\B`, `\d \w \s` families, `\` escapes.
//! At most 16 capture groups. Replacement uses `$0`..`$9` and `$$`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_groups: usize = 16;
pub const max_ops: usize = 8192;
pub const step_budget: usize = 2_000_000;
const no_cap: usize = std.math.maxInt(usize);

const Range = struct { lo: u8, hi: u8 };

pub const Class = struct {
    neg: bool = false,
    ranges: std.ArrayList(Range) = .empty,

    fn deinit(self: *Class, gpa: Allocator) void {
        self.ranges.deinit(gpa);
    }

    fn matches(self: *const Class, c: u8) bool {
        return self.matchesFold(c, false);
    }

    /// Fold-aware variant: with `ci`, both the input byte and each
    /// stored bound fold to lowercase before compare. This is the path
    /// the VM uses; `matches` is the exact-match shorthand.
    fn matchesFold(self: *const Class, c: u8, ci: bool) bool {
        var b = c;
        if (ci) b = std.ascii.toLower(b);
        var hit = false;
        for (self.ranges.items) |r| {
            var lo = r.lo;
            var hi = r.hi;
            if (ci) {
                lo = std.ascii.toLower(lo);
                hi = std.ascii.toLower(hi);
            }
            if (b >= lo and b <= hi) {
                hit = true;
                break;
            }
        }
        return if (self.neg) !hit else hit;
    }
};

const Op = union(enum) {
    lit: struct { c: u8, next: u32 },
    any: struct { next: u32 },
    cls: struct { idx: u32, next: u32 },
    save: struct { slot: u32, next: u32 },
    split: struct { a: u32, b: u32 },
    jmp: struct { to: u32 },
    begin: struct { next: u32 },
    end: struct { next: u32 },
    word: struct { neg: bool, next: u32 },
    match: void,
};

const Patch = struct { op: usize, arm: u8 };

pub const Cap = struct { set: bool = false, s: usize = 0, e: usize = 0 };

pub const Hit = struct { s: usize, e: usize };

pub const Regex = struct {
    ops: std.ArrayList(Op) = .empty,
    classes: std.ArrayList(Class) = .empty,
    ngroups: usize = 0,
    ci: bool = false,
    entry: u32 = 0,
    gpa: Allocator = undefined,
    // Scratch reused across finds.
    frames: std.ArrayList(Frame) = .empty,
    trail: std.ArrayList(Trail) = .empty,
    caps: std.ArrayList(Cap) = .empty,

    pub fn deinit(self: *Regex) void {
        for (self.classes.items) |*c| c.deinit(self.gpa);
        self.classes.deinit(self.gpa);
        self.ops.deinit(self.gpa);
        self.frames.deinit(self.gpa);
        self.trail.deinit(self.gpa);
        self.caps.deinit(self.gpa);
    }

    /// Leftmost match at or after `from`, or null. Captures stay
    /// readable via `captures()` until the next find call.
    pub fn find(self: *Regex, text: []const u8, from: usize) ?Hit {
        var start = @min(from, text.len);
        while (start <= text.len) {
            if (self.run(text, start)) |e| return .{ .s = start, .e = e };
            if (start == text.len) break;
            start += 1;
        }
        return null;
    }

    /// Match anchored exactly at `pos`, or null. Powers replace, where
    /// the span is already known.
    pub fn matchAt(self: *Regex, text: []const u8, pos: usize) ?Hit {
        if (pos > text.len) return null;
        if (self.run(text, pos)) |e| return .{ .s = pos, .e = e };
        return null;
    }

    pub fn captures(self: *const Regex) []const Cap {
        return self.caps.items;
    }

    fn run(self: *Regex, text: []const u8, start: usize) ?usize {
        // Entry is always op 0 with caps cleared; slot 0 opens at start.
        return self.exec(text, start, self.entry) catch null;
    }

    const Frame = struct { pc: u32, pos: usize, trail: usize };
    const Trail = struct { slot: u32, set: bool, s: usize, e: usize };

    fn exec(self: *Regex, text: []const u8, start: usize, entry: u32) !?usize {
        var steps: usize = 0;
        self.frames.clearRetainingCapacity();
        self.trail.clearRetainingCapacity();
        for (self.caps.items) |*c| c.set = false;
        var pc: u32 = entry;
        var pos: usize = start;
        while (true) {
            steps += 1;
            if (steps > step_budget) return null;
            const op = self.ops.items[pc];
            switch (op) {
                .lit => |o| {
                    if (pos >= text.len or !eqByte(text[pos], o.c, self.ci)) {
                        if (!self.backtrack(&pc, &pos)) return null;
                        continue;
                    }
                    pos += 1;
                    pc = o.next;
                },
                .any => |o| {
                    if (pos >= text.len or text[pos] == '\n') {
                        if (!self.backtrack(&pc, &pos)) return null;
                        continue;
                    }
                    pos += 1;
                    pc = o.next;
                },
                .cls => |o| {
                    if (pos >= text.len) {
                        if (!self.backtrack(&pc, &pos)) return null;
                        continue;
                    }
                    if (!self.classes.items[o.idx].matchesFold(text[pos], self.ci)) {
                        if (!self.backtrack(&pc, &pos)) return null;
                        continue;
                    }
                    pos += 1;
                    pc = o.next;
                },
                .save => |o| {
                    const cap = &self.caps.items[o.slot];
                    try self.trail.append(self.gpa, .{ .slot = o.slot, .set = cap.set, .s = cap.s, .e = cap.e });
                    if (o.slot % 2 == 0) {
                        cap.s = pos;
                    } else {
                        cap.e = pos;
                    }
                    cap.set = true;
                    // Unset partner check happens at read time.
                    pc = o.next;
                },
                .split => |o| {
                    try self.frames.append(self.gpa, .{ .pc = o.b, .pos = pos, .trail = self.trail.items.len });
                    pc = o.a;
                },
                .jmp => |o| {
                    pc = o.to;
                },
                .begin => |o| {
                    if (pos != 0) {
                        if (!self.backtrack(&pc, &pos)) return null;
                        continue;
                    }
                    pc = o.next;
                },
                .end => |o| {
                    if (pos != text.len) {
                        if (!self.backtrack(&pc, &pos)) return null;
                        continue;
                    }
                    pc = o.next;
                },
                .word => |o| {
                    const before = pos > 0 and isWord(text[pos - 1]);
                    const after = pos < text.len and isWord(text[pos]);
                    if ((before != after) == o.neg) {
                        if (!self.backtrack(&pc, &pos)) return null;
                        continue;
                    }
                    pc = o.next;
                },
                .match => return pos,
            }
        }
    }

    fn backtrack(self: *Regex, pc: *u32, pos: *usize) bool {
        const f = self.frames.pop() orelse return false;
        while (self.trail.items.len > f.trail) {
            const t = self.trail.pop().?;
            const cap = &self.caps.items[t.slot];
            cap.set = t.set;
            cap.s = t.s;
            cap.e = t.e;
        }
        pc.* = f.pc;
        pos.* = f.pos;
        return true;
    }
};

fn eqByte(a: u8, b: u8, ci: bool) bool {
    if (!ci) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Expand `repl` with `$0`..`$9` (whole match, groups) and `$$`.
/// Unset groups expand empty. A `$` before anything else is literal.
pub fn expand(repl: []const u8, text: []const u8, hit: Hit, caps: []const Cap, out: *std.ArrayList(u8), gpa: Allocator) !void {
    var i: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c != '$' or i + 1 >= repl.len) {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        const d = repl[i + 1];
        if (d == '$') {
            try out.append(gpa, '$');
            i += 2;
            continue;
        }
        if (d >= '0' and d <= '9') {
            const n: usize = @intCast(d - '0');
            if (n == 0) {
                try out.appendSlice(gpa, text[hit.s..hit.e]);
            } else if (n * 2 + 1 < caps.len and caps[n * 2].set and caps[n * 2 + 1].set) {
                try out.appendSlice(gpa, text[caps[n * 2].s..caps[n * 2 + 1].e]);
            }
            i += 2;
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
}

const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    pos: usize = 0,
    ops: std.ArrayList(Op) = .empty,
    classes: std.ArrayList(Class) = .empty,
    ngroups: usize = 0,
    ci: bool = false,
    entry: u32 = 0,

    const Frag = struct { start: u32, outs: std.ArrayList(Patch) };

    fn deinit(self: *Parser) void {
        for (self.classes.items) |*c| c.deinit(self.gpa);
        self.classes.deinit(self.gpa);
        self.ops.deinit(self.gpa);
    }

    fn emit(self: *Parser, op: Op) !u32 {
        if (self.ops.items.len >= max_ops) return error.RegexTooBig;
        const at: u32 = @intCast(self.ops.items.len);
        try self.ops.append(self.gpa, op);
        return at;
    }

    fn patchOne(self: *Parser, p: Patch, target: u32) void {
        switch (self.ops.items[p.op]) {
            .lit => |*o| o.next = target,
            .any => |*o| o.next = target,
            .cls => |*o| o.next = target,
            .save => |*o| o.next = target,
            .begin => |*o| o.next = target,
            .end => |*o| o.next = target,
            .word => |*o| o.next = target,
            .split => |*o| {
                if (p.arm == 0) o.a = target else o.b = target;
            },
            .jmp => |*o| o.to = target,
            .match => {},
        }
    }

    fn patch(self: *Parser, outs: std.ArrayList(Patch), target: u32) void {
        for (outs.items) |p| self.patchOne(p, target);
    }

    fn frag(self: *Parser, start: u32, outs: std.ArrayList(Patch)) Frag {
        _ = self;
        return .{ .start = start, .outs = outs };
    }

    fn single(self: *Parser, op: Op) !Frag {
        const at = try self.emit(op);
        var outs: std.ArrayList(Patch) = .empty;
        try outs.append(self.gpa, .{ .op = at, .arm = 0 });
        return self.frag(at, outs);
    }

    fn concat(self: *Parser, a: Frag, b: Frag) Frag {
        self.patch(a.outs, b.start);
        var aa = a;
        aa.outs.deinit(self.gpa);
        return Frag{ .start = a.start, .outs = b.outs };
    }

    fn alt(self: *Parser, a: Frag, b: Frag) !Frag {
        const s = try self.emit(.{ .split = .{ .a = a.start, .b = b.start } });
        var outs = a.outs;
        try outs.appendSlice(self.gpa, b.outs.items);
        var bb = b;
        bb.outs.deinit(self.gpa);
        return self.frag(s, outs);
    }
};

/// Compile `pattern`. Errors are `error.BadPattern` and `error.RegexTooBig`.
/// `error.OutOfMemory` propagates from the allocator.
pub fn compile(gpa: Allocator, pattern: []const u8, ci: bool) !Regex {
    var p = Parser{ .gpa = gpa, .src = pattern, .ci = ci };
    errdefer p.deinit();
    const f = try parseAlt(&p);
    if (p.pos != pattern.len) return error.BadPattern;
    // Whole-match capture around everything.
    const open = try p.emit(.{ .save = .{ .slot = 0, .next = 0 } });
    const close = try p.emit(.{ .save = .{ .slot = 1, .next = 0 } });
    const done = try p.emit(.{ .match = {} });
    p.patchOne(.{ .op = open, .arm = 0 }, f.start);
    p.patch(f.outs, close);
    var ff = f;
    ff.outs.deinit(gpa);
    p.patchOne(.{ .op = close, .arm = 0 }, done);
    var caps: std.ArrayList(Cap) = .empty;
    const nslots = (p.ngroups + 1) * 2;
    try caps.appendNTimes(gpa, .{}, nslots);
    return .{
        .ops = p.ops,
        .classes = p.classes,
        .ngroups = p.ngroups,
        .entry = open,
        .ci = ci,
        .gpa = gpa,
        .caps = caps,
    };
}

fn parseAlt(p: *Parser) anyerror!Parser.Frag {
    var left = try parseConcat(p);
    errdefer {
        left.outs.deinit(p.gpa);
    }
    if (p.pos < p.src.len and p.src[p.pos] == '|') {
        p.pos += 1;
        var right = try parseAlt(p);
        errdefer right.outs.deinit(p.gpa);
        return try p.alt(left, right);
    }
    return left;
}

fn parseConcat(p: *Parser) anyerror!Parser.Frag {
    var head: ?Parser.Frag = null;
    errdefer {
        if (head) |h| {
            var hh = h;
            hh.outs.deinit(p.gpa);
        }
    }
    while (p.pos < p.src.len and p.src[p.pos] != '|' and p.src[p.pos] != ')') {
        const atom_start = p.pos;
        var next = try parseAtom(p, atom_start);
        errdefer next.outs.deinit(p.gpa);
        next = try parseQuant(p, next, atom_start);
        if (head) |h| {
            head = p.concat(h, next);
        } else {
            head = next;
        }
    }
    if (head) |h| return h;
    // Empty concat matches empty: jmp placeholder patched by caller.
    const at = try p.emit(.{ .jmp = .{ .to = 0 } });
    var outs: std.ArrayList(Patch) = .empty;
    try outs.append(p.gpa, .{ .op = at, .arm = 0 });
    return p.frag(at, outs);
}

fn parseQuant(p: *Parser, f: Parser.Frag, atom_start: usize) anyerror!Parser.Frag {
    if (p.pos >= p.src.len) return f;
    const c = p.src[p.pos];
    if (c == '*') {
        p.pos += 1;
        const s = try p.emit(.{ .split = .{ .a = f.start, .b = 0 } });
        p.patch(f.outs, s);
        var ff = f;
        ff.outs.deinit(p.gpa);
        var outs: std.ArrayList(Patch) = .empty;
        try outs.append(p.gpa, .{ .op = s, .arm = 1 });
        return p.frag(s, outs);
    }
    if (c == '+') {
        p.pos += 1;
        const s = try p.emit(.{ .split = .{ .a = f.start, .b = 0 } });
        p.patch(f.outs, s);
        var ff = f;
        ff.outs.deinit(p.gpa);
        var outs: std.ArrayList(Patch) = .empty;
        try outs.append(p.gpa, .{ .op = s, .arm = 1 });
        // Entry is f.start; loop back through s.
        return Parser.Frag{ .start = f.start, .outs = outs };
    }
    if (c == '?') {
        p.pos += 1;
        const s = try p.emit(.{ .split = .{ .a = f.start, .b = 0 } });
        var outs: std.ArrayList(Patch) = .empty;
        try outs.append(p.gpa, .{ .op = s, .arm = 1 });
        try outs.appendSlice(p.gpa, f.outs.items);
        var ff = f;
        ff.outs.deinit(p.gpa);
        return p.frag(s, outs);
    }
    if (c == '{') {
        return try parseCounted(p, f, atom_start);
    }
    return f;
}

fn parseCounted(p: *Parser, f: Parser.Frag, atom_start: usize) anyerror!Parser.Frag {
    const save = p.pos;
    p.pos += 1;
    const m = parseNum(p) orelse {
        p.pos = save;
        return f;
    };
    var n = m;
    var open = false;
    if (p.pos < p.src.len and p.src[p.pos] == ',') {
        open = true;
        p.pos += 1;
        if (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) {
            n = parseNum(p).?;
            open = false;
        }
    }
    if (p.pos >= p.src.len or p.src[p.pos] != '}') {
        p.pos = save;
        return f;
    }
    if ((!open and n < m) or m > 64 or n > 64) return error.BadPattern;
    p.pos += 1;
    const atom_src = p.src[atom_start..save];
    if (m == 0) {
        // f holds one unneeded copy; drop it for the all-optional build.
        var f0 = f;
        f0.outs.deinit(p.gpa);
        if (open) {
            const cp = try parseAtomSlice(p, atom_src);
            const s = try p.emit(.{ .split = .{ .a = cp.start, .b = 0 } });
            p.patch(cp.outs, s);
            var cp0 = cp;
            cp0.outs.deinit(p.gpa);
            var outs: std.ArrayList(Patch) = .empty;
            try outs.append(p.gpa, .{ .op = s, .arm = 1 });
            return p.frag(s, outs);
        }
        var head: ?Parser.Frag = null;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const cp = try parseAtomSlice(p, atom_src);
            const s = try p.emit(.{ .split = .{ .a = cp.start, .b = 0 } });
            var outs: std.ArrayList(Patch) = .empty;
            try outs.append(p.gpa, .{ .op = s, .arm = 1 });
            try outs.appendSlice(p.gpa, cp.outs.items);
            var cp0 = cp;
            cp0.outs.deinit(p.gpa);
            const opt = Parser.Frag{ .start = s, .outs = outs };
            head = if (head) |h| p.concat(h, opt) else opt;
        }
        if (head) |h| return h;
        const at = try p.emit(.{ .jmp = .{ .to = 0 } });
        var outs: std.ArrayList(Patch) = .empty;
        try outs.append(p.gpa, .{ .op = at, .arm = 0 });
        return p.frag(at, outs);
    }
    // f already holds copy one. Build copies 2..m, then optionals.
    var head: ?Parser.Frag = f;
    var i: usize = 1;
    while (i < m) : (i += 1) {
        const cp = try parseAtomSlice(p, atom_src);
        head = p.concat(head.?, cp);
    }
    if (open) {
        // m copies then star of atom.
        const cp = try parseAtomSlice(p, atom_src);
        const s = try p.emit(.{ .split = .{ .a = cp.start, .b = 0 } });
        p.patch(cp.outs, s);
        var cp0 = cp;
        cp0.outs.deinit(p.gpa);
        var outs: std.ArrayList(Patch) = .empty;
        try outs.append(p.gpa, .{ .op = s, .arm = 1 });
        const tail = Parser.Frag{ .start = cp.start, .outs = outs };
        head = p.concat(head.?, tail);
        return head.?;
    }
    while (i < n) : (i += 1) {
        const cp = try parseAtomSlice(p, atom_src);
        const s = try p.emit(.{ .split = .{ .a = cp.start, .b = 0 } });
        var outs: std.ArrayList(Patch) = .empty;
        try outs.append(p.gpa, .{ .op = s, .arm = 1 });
        try outs.appendSlice(p.gpa, cp.outs.items);
        var cp1 = cp;
        cp1.outs.deinit(p.gpa);
        const opt = Parser.Frag{ .start = s, .outs = outs };
        head = p.concat(head.?, opt);
    }
    return head.?;
}

fn parseNum(p: *Parser) ?usize {
    const from = p.pos;
    var v: usize = 0;
    while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) {
        v = v * 10 + @as(usize, @intCast(p.src[p.pos] - '0'));
        p.pos += 1;
    }
    if (p.pos == from) return null;
    return v;
}

fn parseAtomSlice(p: *Parser, atom_src: []const u8) anyerror!Parser.Frag {
    var sub = Parser{ .gpa = p.gpa, .src = atom_src, .ci = p.ci };
    // Share group numbering and output arrays with the parent.
    sub.ops = p.ops;
    sub.classes = p.classes;
    sub.ngroups = p.ngroups;
    const atom_start = @as(usize, 0);
    const f = try parseAtom(&sub, atom_start);
    // Empty slice cannot happen: caller passes a real atom.
    p.ops = sub.ops;
    p.classes = sub.classes;
    p.ngroups = sub.ngroups;
    return f;
}

fn parseAtom(p: *Parser, atom_start: usize) anyerror!Parser.Frag {
    _ = atom_start;
    if (p.pos >= p.src.len) return error.BadPattern;
    const c = p.src[p.pos];
    if (c == '(') {
        p.pos += 1;
        var capture = true;
        if (p.pos + 1 < p.src.len and p.src[p.pos] == '?' and p.src[p.pos + 1] == ':') {
            capture = false;
            p.pos += 2;
        }
        var slot: u32 = 0;
        if (capture) {
            if (p.ngroups >= max_groups) return error.RegexTooBig;
            p.ngroups += 1;
            slot = @intCast(p.ngroups * 2);
        }
        var inner = try parseAlt(p);
        if (p.pos >= p.src.len or p.src[p.pos] != ')') {
            inner.outs.deinit(p.gpa);
            return error.BadPattern;
        }
        p.pos += 1;
        if (!capture) return inner;
        const open = try p.emit(.{ .save = .{ .slot = slot, .next = inner.start } });
        const close = try p.emit(.{ .save = .{ .slot = slot + 1, .next = 0 } });
        p.patch(inner.outs, close);
        inner.outs.deinit(p.gpa);
        var outs: std.ArrayList(Patch) = .empty;
        try outs.append(p.gpa, .{ .op = close, .arm = 0 });
        return p.frag(open, outs);
    }
    if (c == '[') return try parseClass(p);
    if (c == '\\') {
        p.pos += 1;
        if (p.pos >= p.src.len) return error.BadPattern;
        const e = p.src[p.pos];
        p.pos += 1;
        switch (e) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                var cls = Class{};
                errdefer cls.deinit(p.gpa);
                switch (e) {
                    'd' => try cls.ranges.append(p.gpa, .{ .lo = '0', .hi = '9' }),
                    'D' => {},
                    'w' => {
                        try cls.ranges.append(p.gpa, .{ .lo = 'a', .hi = 'z' });
                        try cls.ranges.append(p.gpa, .{ .lo = 'A', .hi = 'Z' });
                        try cls.ranges.append(p.gpa, .{ .lo = '0', .hi = '9' });
                        try cls.ranges.append(p.gpa, .{ .lo = '_', .hi = '_' });
                    },
                    'W' => {},
                    's' => {
                        try cls.ranges.append(p.gpa, .{ .lo = ' ', .hi = ' ' });
                        try cls.ranges.append(p.gpa, .{ .lo = '\t', .hi = '\t' });
                        try cls.ranges.append(p.gpa, .{ .lo = '\n', .hi = '\n' });
                        try cls.ranges.append(p.gpa, .{ .lo = '\r', .hi = '\r' });
                    },
                    else => {},
                }
                if (e == 'D' or e == 'W') {
                    // Negated families via explicit ranges are awkward;
                    // reuse negation flag with the positive set rebuilt.
                    cls.neg = true;
                    if (e == 'D') try cls.ranges.append(p.gpa, .{ .lo = '0', .hi = '9' });
                    if (e == 'W') {
                        try cls.ranges.append(p.gpa, .{ .lo = 'a', .hi = 'z' });
                        try cls.ranges.append(p.gpa, .{ .lo = 'A', .hi = 'Z' });
                        try cls.ranges.append(p.gpa, .{ .lo = '0', .hi = '9' });
                        try cls.ranges.append(p.gpa, .{ .lo = '_', .hi = '_' });
                    }
                }
                if (e == 'S') {
                    cls.neg = true;
                    try cls.ranges.append(p.gpa, .{ .lo = ' ', .hi = ' ' });
                    try cls.ranges.append(p.gpa, .{ .lo = '\t', .hi = '\t' });
                    try cls.ranges.append(p.gpa, .{ .lo = '\n', .hi = '\n' });
                    try cls.ranges.append(p.gpa, .{ .lo = '\r', .hi = '\r' });
                }
                const idx: u32 = @intCast(p.classes.items.len);
                try p.classes.append(p.gpa, cls);
                return try p.single(.{ .cls = .{ .idx = idx, .next = 0 } });
            },
            'b' => {
                // \b would clash with word assert; backspace is rare in
                // search, assert wins. Use \x08 for the byte.
                return try p.single(.{ .word = .{ .neg = false, .next = 0 } });
            },
            'B' => return try p.single(.{ .word = .{ .neg = true, .next = 0 } }),
            'n' => return try p.single(.{ .lit = .{ .c = '\n', .next = 0 } }),
            't' => return try p.single(.{ .lit = .{ .c = '\t', .next = 0 } }),
            'r' => return try p.single(.{ .lit = .{ .c = '\r', .next = 0 } }),
            else => return try p.single(.{ .lit = .{ .c = e, .next = 0 } }),
        }
    }
    if (c == '.') {
        p.pos += 1;
        return try p.single(.{ .any = .{ .next = 0 } });
    }
    if (c == '^') {
        p.pos += 1;
        return try p.single(.{ .begin = .{ .next = 0 } });
    }
    if (c == '$') {
        p.pos += 1;
        return try p.single(.{ .end = .{ .next = 0 } });
    }
    if (c == '*' or c == '+' or c == '?' or c == '|' or c == ')' or c == '{' or c == '}') return error.BadPattern;
    p.pos += 1;
    return try p.single(.{ .lit = .{ .c = c, .next = 0 } });
}

fn parseClass(p: *Parser) anyerror!Parser.Frag {
    p.pos += 1; // [
    var cls = Class{};
    errdefer cls.deinit(p.gpa);
    if (p.pos < p.src.len and p.src[p.pos] == '^') {
        cls.neg = true;
        p.pos += 1;
    }
    var first = true;
    var prev: ?u8 = null;
    while (true) {
        if (p.pos >= p.src.len) return error.BadPattern;
        const c = p.src[p.pos];
        if (c == ']' and !first) {
            p.pos += 1;
            break;
        }
        var byte: u8 = c;
        if (c == '\\') {
            p.pos += 1;
            if (p.pos >= p.src.len) return error.BadPattern;
            const e = p.src[p.pos];
            byte = switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => e,
            };
            p.pos += 1;
        } else {
            p.pos += 1;
        }
        if (p.pos < p.src.len and p.src[p.pos] == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
            // Range a-z. A leading `prev-` with no partner is literal.
            p.pos += 1;
            var hi: u8 = p.src[p.pos];
            if (hi == '\\') {
                p.pos += 1;
                if (p.pos >= p.src.len) return error.BadPattern;
                hi = p.src[p.pos];
            }
            p.pos += 1;
            const lo = prev orelse byte;
            if (hi < lo) return error.BadPattern;
            // Drop the single already recorded when prev exists.
            if (prev != null) _ = cls.ranges.pop();
            try cls.ranges.append(p.gpa, .{ .lo = lo, .hi = hi });
            prev = null;
        } else {
            try cls.ranges.append(p.gpa, .{ .lo = byte, .hi = byte });
            prev = byte;
        }
        first = false;
    }
    if (cls.ranges.items.len == 0) return error.BadPattern;
    const idx: u32 = @intCast(p.classes.items.len);
    try p.classes.append(p.gpa, cls);
    return try p.single(.{ .cls = .{ .idx = idx, .next = 0 } });
}

test "literal and dot" {
    const gpa = std.testing.allocator;
    var re = try compile(gpa, "h.llo", false);
    defer re.deinit();
    const h = re.find("say hello", 0).?;
    try std.testing.expectEqual(@as(usize, 4), h.s);
    try std.testing.expectEqual(@as(usize, 9), h.e);
    try std.testing.expect(re.find("say hello", 5) == null);
}

test "star plus quest are greedy" {
    const gpa = std.testing.allocator;
    var re = try compile(gpa, "ab*c", false);
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 7), re.find("xxabbbc", 0).?.e);
    var re2 = try compile(gpa, "ab+c", false);
    defer re2.deinit();
    try std.testing.expect(re2.find("xxac", 0) == null);
    try std.testing.expectEqual(@as(usize, 2), re2.find("xxabbc", 0).?.s);
    var re3 = try compile(gpa, "colou?r", false);
    defer re3.deinit();
    try std.testing.expectEqual(@as(usize, 5), re3.find("color and colour", 0).?.e);
}

test "alternation and groups" {
    const gpa = std.testing.allocator;
    var re = try compile(gpa, "(foo|bar)baz", false);
    defer re.deinit();
    const h = re.find("xxbarbaz", 0).?;
    try std.testing.expectEqual(@as(usize, 2), h.s);
    const caps = re.captures();
    try std.testing.expect(caps[2].set);
    try std.testing.expectEqualStrings("bar", "xxbarbaz"[caps[2].s..caps[3].e]);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try expand("[$1]", "xxbarbaz", h, caps, &out, gpa);
    try std.testing.expectEqualStrings("[bar]", out.items);
}

test "classes anchors and escapes" {
    const gpa = std.testing.allocator;
    var re = try compile(gpa, "^[a-z]+[0-9]+$", false);
    defer re.deinit();
    try std.testing.expect(re.find("abc123", 0) != null);
    try std.testing.expect(re.find("abc123x", 0) == null);
    var re2 = try compile(gpa, "\\d+\\.\\d+", false);
    defer re2.deinit();
    try std.testing.expectEqual(@as(usize, 3), re2.find("pi=3.14!", 0).?.s);
    var re3 = try compile(gpa, "[^0-9]+", false);
    defer re3.deinit();
    try std.testing.expectEqualStrings("abc", "abc123"[re3.find("abc123", 0).?.s..re3.find("abc123", 0).?.e]);
}

test "case flag and word bounds" {
    const gpa = std.testing.allocator;
    var re = try compile(gpa, "\\bfoo\\B", false);
    defer re.deinit();
    try std.testing.expect(re.find("a food", 0) != null);
    var re2 = try compile(gpa, "HELLO", true);
    defer re2.deinit();
    try std.testing.expect(re2.find("say hello", 0) != null);
    var re3 = try compile(gpa, "HELLO", false);
    defer re3.deinit();
    try std.testing.expect(re3.find("say hello", 0) == null);
}

test "counted repetition" {
    const gpa = std.testing.allocator;
    var re = try compile(gpa, "a{2,4}", false);
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 4), re.find("aaaaa", 0).?.e);
    var re2 = try compile(gpa, "a{3}", false);
    defer re2.deinit();
    try std.testing.expectEqual(@as(usize, 3), re2.find("aaaaa", 0).?.e);
}

test "bad patterns error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadPattern, compile(gpa, "(foo", false));
    try std.testing.expectError(error.BadPattern, compile(gpa, "*foo", false));
    try std.testing.expectError(error.BadPattern, compile(gpa, "[z-a]", false));
}
