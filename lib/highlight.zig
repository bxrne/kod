//! Line lexer for viewport highlighting. Costs nothing the frame does
//! not already pay: paint walks exactly the visible bytes, and the
//! lexer rides that walk. No IO beyond paint's reads, no retained
//! memory, no work for unknown extensions.
//!
//! Model: one line at a time with a small carried state (open string,
//! block comment, fence). Paint resyncs from a bounded margin above
//! the viewport, so constructs spanning further back mis-highlight.
//! That bound is the whole tradeoff, and every editor makes it.
//!
//! Extension: add a `Spec` entry plus a sorted keyword table. New
//! constructs need a `Spec` flag plus a branch in the engine. Tables
//! must stay byte-sorted; a test enforces it for binary search.

const std = @import("std");
const assert = std.debug.assert;
const ansi = @import("ansi.zig");

pub const Kind = enum {
    plain,
    keyword,
    string,
    comment,
    number,
    function,
    typ,
};

/// Byte range `[start, end)` in line coords with one kind. Spans from
/// one call always cover `[0, lexed)` with no gaps or overlaps.
pub const Span = struct {
    start: usize,
    end: usize,
    kind: Kind,
};

/// Carried across lines. Fits in four bytes.
pub const State = struct {
    str: u8 = 0,
    multi: bool = false,
    block: bool = false,
};

/// Per-language rules. Only flags the language needs are set.
pub const Spec = struct {
    name: []const u8,
    exts: []const []const u8,
    /// Byte-sorted for binary search. A test enforces the order.
    keywords: []const []const u8,
    /// Single and double quotes always lex strings. Extra quote chars:
    quotes: []const u8 = "\"'",
    /// `"""` and `'''` multiline strings (python, toml).
    triple_quotes: bool = false,
    backtick_multi: bool = false,
    /// `'x'` and `'\n'` char literals (c, zig, go).
    char_literal: bool = false,
    line_comment: ?[]const u8 = null,
    block_start: ?[]const u8 = null,
    block_end: ?[]const u8 = null,
    /// Kind of block spans: comment for `/* */`, string for fences.
    block_kind: Kind = .comment,
    /// `^#{1,6} ` colors the whole line keyword (markdown).
    hash_header: bool = false,
    /// `^\s*#` colors the whole line keyword (c preprocessor).
    hash_directive: bool = false,
    /// `^\s*\[` colors the whole line keyword (toml tables).
    bracket_header: bool = false,
    /// `^\s*\\` colors the whole line string (zig multiline).
    backslash_string: bool = false,
    /// `*x*` and `**x**` color string (markdown emphasis).
    emphasis: bool = false,
    /// `$name` and `${..}` color type (shell vars).
    dollar_var: bool = false,
    /// `key =` colors the key keyword (toml).
    eq_key: bool = false,
    /// `key:` colors the key keyword (yaml).
    colon_key: bool = false,
    /// `<tag>` and `</tag>` color the bracket and the name keyword.
    tag: bool = false,
    /// `attr=` colors the name typ (html, xml).
    attr: bool = false,
};

/// Cap per lexed line. Dense minified lines degrade gracefully: the
/// last span extends to the lexed end once full.
pub const max_spans: usize = 256;

const zig_spec = Spec{
    .name = "zig",
    .exts = &.{"zig"},
    .keywords = &.{
        "align",       "allowzero",      "and",      "anyframe",    "anytype", "asm",
        "async",       "await",          "break",    "callconv",    "catch",   "comptime",
        "const",       "continue",       "defer",    "else",        "enum",    "errdefer",
        "error",       "export",         "extern",   "fn",          "for",     "if",
        "inline",      "linksection",    "noinline", "nosuspend",   "opaque",  "or",
        "orelse",      "packed",         "pub",      "resume",      "return",  "struct",
        "suspend",     "switch",         "test",     "threadlocal", "try",     "union",
        "unreachable", "usingnamespace", "var",      "volatile",    "while",
    },
    .char_literal = true,
    .line_comment = "//",
    .backslash_string = true,
};

const python_spec = Spec{
    .name = "python",
    .exts = &.{ "py", "pyi" },
    .keywords = &.{
        "False",  "None",     "True",  "and",    "as",       "assert",
        "async",  "await",    "break", "class",  "continue", "def",
        "del",    "elif",     "else",  "except", "finally",  "for",
        "from",   "global",   "if",    "import", "in",       "is",
        "lambda", "nonlocal", "not",   "or",     "pass",     "raise",
        "return", "try",      "while", "with",   "yield",
    },
    .triple_quotes = true,
    .line_comment = "#",
};

const go_spec = Spec{
    .name = "go",
    .exts = &.{"go"},
    .keywords = &.{
        "break", "case",   "chan",        "const",     "continue", "default",
        "defer", "else",   "fallthrough", "for",       "func",     "go",
        "goto",  "if",     "import",      "interface", "map",      "package",
        "range", "return", "select",      "struct",    "switch",   "type",
        "var",
    },
    .char_literal = true,
    .quotes = "\"'`",
    .backtick_multi = true,
    .line_comment = "//",
    .block_start = "/*",
    .block_end = "*/",
};

const c_spec = Spec{
    .name = "c",
    .exts = &.{ "c", "h" },
    .keywords = &.{
        "NULL",           "_Bool",         "_Complex", "_Generic", "_Imaginary", "_Noreturn",
        "_Static_assert", "_Thread_local", "auto",     "break",    "case",       "char",
        "const",          "continue",      "default",  "do",       "double",     "else",
        "enum",           "extern",        "false",    "float",    "for",        "goto",
        "if",             "inline",        "int",      "long",     "register",   "restrict",
        "return",         "short",         "signed",   "sizeof",   "static",     "struct",
        "switch",         "true",          "typedef",  "union",    "unsigned",   "void",
        "volatile",       "while",
    },
    .char_literal = true,
    .line_comment = "//",
    .block_start = "/*",
    .block_end = "*/",
    .hash_directive = true,
};

const json_spec = Spec{
    .name = "json",
    .exts = &.{"json"},
    .keywords = &.{ "false", "null", "true" },
    .quotes = "\"",
};

const markdown_spec = Spec{
    .name = "markdown",
    .exts = &.{ "md", "markdown", "mdown" },
    .keywords = &.{},
    .quotes = "`",
    .block_start = "```",
    .block_end = "```",
    .block_kind = .string,
    .hash_header = true,
    .emphasis = true,
};

const toml_spec = Spec{
    .name = "toml",
    .exts = &.{"toml"},
    .keywords = &.{ "false", "true" },
    .triple_quotes = true,
    .line_comment = "#",
    .bracket_header = true,
    .eq_key = true,
};

const shell_spec = Spec{
    .name = "shell",
    .exts = &.{ "sh", "bash", "zsh", "ksh" },
    .keywords = &.{
        "case", "do",    "done",     "elif", "else", "esac",
        "fi",   "for",   "function", "if",   "in",   "select",
        "then", "until", "while",
    },
    .quotes = "\"'`",
    .line_comment = "#",
    .dollar_var = true,
};

const yaml_spec = Spec{
    .name = "yaml",
    .exts = &.{ "yaml", "yml" },
    .keywords = &.{
        "false", "no", "null", "true", "yes",
    },
    .quotes = "\"'",
    .line_comment = "#",
    .colon_key = true,
    .dollar_var = true,
};

const html_spec = Spec{
    .name = "html",
    .exts = &.{ "html", "htm", "xhtml", "xml", "svg" },
    .keywords = &.{},
    .quotes = "\"'",
    .block_start = "<!--",
    .block_end = "-->",
    .block_kind = .comment,
    .tag = true,
    .attr = true,
};

const env_spec = Spec{
    .name = "env",
    .exts = &.{"env"},
    .keywords = &.{},
    .quotes = "\"'",
    .line_comment = "#",
    .dollar_var = true,
    .eq_key = true,
};

const all_specs = [_]*const Spec{
    &zig_spec,      &python_spec, &go_spec,    &c_spec,   &json_spec,
    &markdown_spec, &toml_spec,   &shell_spec, &yaml_spec,
    &html_spec,     &env_spec,
};

const exact_names = [_]struct { name: []const u8, spec: *const Spec }{
    .{ .name = ".bashrc", .spec = &shell_spec },
    .{ .name = ".zshrc", .spec = &shell_spec },
    // A dotfile has no extension, so the name must be named outright.
    .{ .name = ".env", .spec = &env_spec },
    .{ .name = ".envrc", .spec = &env_spec },
};

fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Language for a path, by exact basename or extension. Null means
/// plain text: no lexing, no cost.
pub fn detect(path: []const u8) ?*const Spec {
    const base = std.fs.path.basename(path);
    for (exact_names) |e| {
        if (eqlFold(base, e.name)) return e.spec;
    }
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    if (dot == 0 or dot + 1 >= base.len) return null;
    const ext = base[dot + 1 ..];
    for (all_specs) |sp| {
        for (sp.exts) |e| {
            if (eqlFold(ext, e)) return sp;
        }
    }
    return null;
}

fn emit(out: []Span, n: *usize, start: usize, end: usize, kind: Kind) void {
    if (start >= end) return;
    if (n.* > 0 and out[n.* - 1].kind == kind and out[n.* - 1].end == start) {
        out[n.* - 1].end = end;
        return;
    }
    if (n.* >= out.len) {
        out[out.len - 1].end = end;
        return;
    }
    out[n.*] = .{ .start = start, .end = end, .kind = kind };
    n.* += 1;
}

fn startsWithAt(line: []const u8, i: usize, pat: []const u8) bool {
    return i + pat.len <= line.len and std.mem.eql(u8, line[i .. i + pat.len], pat);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Command verb byte: identifiers plus the dash and slash the verbs
/// use (`exec-save`, `f/`, `b/`).
fn isCmdNameChar(c: u8) bool {
    return isIdentCont(c) or c == '-' or c == '/';
}

fn isKeyword(sorted: []const []const u8, word: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, sorted[mid], word)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}

/// Closer for an open string honoring backslash escapes. Triple
/// strings close on three quotes. Null when unterminated.
fn stringEnd(line: []const u8, from: usize, q: u8, triple: bool) ?usize {
    if (triple) {
        var i = from;
        while (std.mem.findPos(u8, line, i, &.{ q, q, q })) |m| {
            if (m > 0 and line[m - 1] == '\\' and (m < 2 or line[m - 2] != '\\')) {
                i = m + 3;
                continue;
            }
            return m;
        }
        return null;
    }
    var i = from;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == q) return i;
    }
    return null;
}

/// Lexes one line. Spans cover `[0, line.len)` in order. State
/// carries open strings and blocks to the next line.
pub fn lexLine(spec: *const Spec, line: []const u8, st: *State, out: []Span) usize {
    var n: usize = 0;
    var i: usize = 0;
    var seen_nonws = false;

    while (i < line.len) {
        // Carried or freshly opened multiline constructs consume first.
        // Checking every iteration keeps mid-line opens working for the
        // rest of the line, not just entry state from the last line.
        if (st.block) {
            if (spec.block_end) |end| {
                if (std.mem.find(u8, line[i..], end)) |off| {
                    const m = i + off;
                    emit(out, &n, i, m + end.len, spec.block_kind);
                    i = m + end.len;
                    st.block = false;
                    continue;
                }
            }
            emit(out, &n, i, line.len, spec.block_kind);
            return n;
        }

        if (st.str != 0) {
            const triple = st.multi and (st.str == '"' or st.str == '\'');
            if (stringEnd(line, i, st.str, triple)) |m| {
                const elen: usize = if (triple) 3 else 1;
                emit(out, &n, i, m + elen, .string);
                i = m + elen;
                st.str = 0;
                st.multi = false;
                continue;
            }
            emit(out, &n, i, line.len, .string);
            if (!st.multi) st.str = 0;
            return n;
        }

        const c = line[i];

        if (!seen_nonws and c != ' ' and c != '\t') {
            if (spec.hash_header and c == '#') {
                emit(out, &n, i, line.len, .keyword);
                return n;
            }
            if (spec.hash_directive and c == '#') {
                emit(out, &n, i, line.len, .keyword);
                return n;
            }
            if (spec.bracket_header and c == '[') {
                emit(out, &n, i, line.len, .keyword);
                return n;
            }
            if (spec.backslash_string and startsWithAt(line, i, "\\\\")) {
                emit(out, &n, i, line.len, .string);
                return n;
            }
            seen_nonws = true;
        }

        if (spec.line_comment) |lc| {
            if (startsWithAt(line, i, lc)) {
                emit(out, &n, i, line.len, .comment);
                return n;
            }
        }

        if (spec.block_start) |bs| {
            if (startsWithAt(line, i, bs)) {
                emit(out, &n, i, i + bs.len, spec.block_kind);
                i += bs.len;
                st.block = true;
                continue;
            }
        }

        if (spec.triple_quotes and (c == '"' or c == '\'')) {
            const q3 = [_]u8{ c, c, c };
            if (startsWithAt(line, i, &q3)) {
                emit(out, &n, i, i + 3, .string);
                i += 3;
                st.str = c;
                st.multi = true;
                continue;
            }
        }

        if (std.mem.findScalar(u8, spec.quotes, c) != null) {
            if (spec.char_literal and c == '\'' and charEnd(line, i) != null) {
                const e = charEnd(line, i).?;
                emit(out, &n, i, e, .string);
                i = e;
                continue;
            }
            emit(out, &n, i, i + 1, .string);
            i += 1;
            st.str = c;
            st.multi = c == '`' and spec.backtick_multi;
            continue;
        }

        if (spec.emphasis and (c == '*' or c == '_')) {
            if (emphasisEnd(line, i)) |e| {
                emit(out, &n, i, e, .string);
                i = e;
                continue;
            }
            emit(out, &n, i, i + 1, .plain);
            i += 1;
            continue;
        }

        if (spec.dollar_var and c == '$') {
            if (varEnd(line, i)) |e| {
                emit(out, &n, i, e, .typ);
                i = e;
                continue;
            }
            emit(out, &n, i, i + 1, .plain);
            i += 1;
            continue;
        }

        // `<tag` and `</tag` open a keyword run. Only the opening
        // bracket and the name color; the attributes follow normally.
        if (spec.tag and c == '<') {
            if (tagEnd(line, i)) |e| {
                emit(out, &n, i, e, .keyword);
                i = e;
                continue;
            }
        }

        if (std.ascii.isDigit(c) or (c == '.' and i + 1 < line.len and std.ascii.isDigit(line[i + 1]))) {
            var j = i + 1;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_' or line[j] == '.')) j += 1;
            emit(out, &n, i, j, .number);
            i = j;
            continue;
        }

        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < line.len and isIdentCont(line[j])) j += 1;
            const word = line[i..j];
            if (spec.eq_key or spec.colon_key) {
                var k = j;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
                const has_sep = k < line.len;
                if (has_sep and ((spec.eq_key and line[k] == '=') or
                    (spec.colon_key and line[k] == ':')))
                {
                    emit(out, &n, i, j, .keyword);
                    i = j;
                    continue;
                }
            }
            if (spec.attr) {
                var k = j;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
                if (k < line.len and line[k] == '=') {
                    emit(out, &n, i, j, .typ);
                    i = j;
                    continue;
                }
            }
            if (isKeyword(spec.keywords, word)) {
                emit(out, &n, i, j, .keyword);
            } else if (j < line.len and line[j] == '(') {
                emit(out, &n, i, j, .function);
            } else if (c >= 'A' and c <= 'Z') {
                emit(out, &n, i, j, .typ);
            } else {
                emit(out, &n, i, j, .plain);
            }
            i = j;
            continue;
        }

        emit(out, &n, i, i + 1, .plain);
        i += 1;
    }
    return n;
}

/// End offset (exclusive) of a `'x'` or `'\n'` literal at `i`, if the
/// pattern matches. Otherwise null, and the quote lexes as a string.
fn charEnd(line: []const u8, i: usize) ?usize {
    if (i + 2 >= line.len) return null;
    if (line[i + 1] == '\\') {
        if (i + 3 < line.len and line[i + 3] == '\'') return i + 4;
        return null;
    }
    if (line[i + 2] == '\'') return i + 3;
    return null;
}

/// End offset (exclusive) of a `*x*` or `**x**` run at `i`.
/// Unclosed markers lex plain.
fn emphasisEnd(line: []const u8, i: usize) ?usize {
    const q = line[i];
    var run: usize = 1;
    if (i + 1 < line.len and line[i + 1] == q) run = 2;
    var j = i + run;
    while (j < line.len) {
        if (line[j] == q) {
            var k: usize = 1;
            if (j + 1 < line.len and line[j + 1] == q) k = 2;
            if (k == run) return j + k;
            j += k;
        } else {
            j += 1;
        }
    }
    return null;
}

/// End offset (exclusive) of a `<tag` or `</tag` name at `i`, or null
/// when the line holds no tag opening there. A bare `<` in prose, a
/// comparison, and a doctype comment all return null.
fn tagEnd(line: []const u8, i: usize) ?usize {
    var j = i + 1;
    if (j < line.len and line[j] == '/') j += 1;
    if (j >= line.len or !isIdentStart(line[j])) return null;
    while (j < line.len and (isIdentCont(line[j]) or line[j] == '-' or line[j] == ':')) j += 1;
    return j;
}

/// End offset (exclusive) of a `$name` or `${..}` var at `i`.
fn varEnd(line: []const u8, i: usize) ?usize {
    if (i + 1 >= line.len) return null;
    const c = line[i + 1];
    if (c == '{') {
        const close = std.mem.findScalarPos(u8, line, i + 2, '}') orelse return null;
        return close + 1;
    }
    if (!isIdentStart(c)) return null;
    var j = i + 2;
    while (j < line.len and isIdentCont(line[j])) j += 1;
    return j;
}

/// How paint highlights a buffer. Set once at open and kept across
/// refresh. `auto` detects by path, `filenames` detects each line as
/// a file name (fs and buf listings), `gitlog` colors hashes, `trees`
/// colors inspector headers, command rows and undo ops, `search` and
/// `exec` color hit prefixes and lex the rest by the hit path's
/// language, `listing` colors the `:welcome` and `:help` text.
pub const Mode = enum { auto, filenames, gitlog, trees, search, exec, listing };

/// Spans for git log lines. `branch X` is keyword, a leading hex hash
/// is number, stat graphs color `+` green and `-` pink, summaries color
/// their `(+)` / `(-)` markers the same way, patch lines color whole
/// (`+` green, `-` pink, `@@` and `+++/---` headers keyword).
/// Everything else is plain.
/// Stateless: each line stands alone, so no resync walk is needed.
pub fn lexGitLine(line: []const u8, out: []Span) usize {
    var n: usize = 0;
    if (std.mem.startsWith(u8, line, "branch ")) {
        emit(out, &n, 0, line.len, .keyword);
        return n;
    }
    var h: usize = 0;
    while (h < line.len and std.ascii.isHex(line[h])) h += 1;
    if (h >= 4 and h < line.len and line[h] == ' ') {
        emit(out, &n, 0, h, .number);
        emit(out, &n, h, line.len, .plain);
        return n;
    }
    if (statGraphStart(line)) |g| {
        return lexInlineMarks(line, out, g);
    }
    if (std.mem.find(u8, line, "changed") != null) {
        return lexInlineMarks(line, out, 0);
    }
    if (std.mem.startsWith(u8, line, "@@")) {
        emit(out, &n, 0, line.len, .keyword);
        return n;
    }
    if (std.mem.startsWith(u8, line, "diff --git")) {
        emit(out, &n, 0, line.len, .keyword);
        return n;
    }
    if (isPatchHeader(line, "+++") or isPatchHeader(line, "---")) {
        emit(out, &n, 0, line.len, .keyword);
        return n;
    }
    if (line.len > 0 and line[0] == '+') {
        emit(out, &n, 0, line.len, .function);
        return n;
    }
    if (line.len > 0 and line[0] == '-') {
        emit(out, &n, 0, line.len, .keyword);
        return n;
    }
    emit(out, &n, 0, line.len, .plain);
    return n;
}

/// Spans for `:tree` inspector lines. Section headers (no indent)
/// and per-doc fold headers (`  title (N nodes)`) are keyword. A
/// leading hex hash after the indent is number, like the git log.
/// Command rows defer to `lexListingLine`, undo rows color the op
/// kind plus the positions and quoted text around it.
/// Everything else is plain.
/// Stateless: each line stands alone, so no resync walk is needed.
pub fn lexTreeLine(line: []const u8, out: []Span) usize {
    var n: usize = 0;
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') indent += 1;
    const trimmed = line[indent..];
    if (trimmed.len == 0) {
        emit(out, &n, 0, line.len, .plain);
        return n;
    }
    if (indent == 0) {
        emit(out, &n, 0, line.len, .keyword);
        return n;
    }
    // Command rows share the listing rules, indent and all.
    if (trimmed[0] == ':') return lexListingLine(line, out);
    if (std.mem.endsWith(u8, trimmed, " nodes)") and std.mem.indexOfScalar(u8, trimmed, '(') != null) {
        emit(out, &n, 0, line.len, .keyword);
        return n;
    }
    // Undo rows (`#1 p=0 insert 2B @0,2 ...`): the op kind carries
    // the color, inserts green, deletes pink, replaces yellow.
    if (trimmed[0] == '#') {
        const kinds = [_]struct { []const u8, Kind }{
            .{ "insert", .function },
            .{ "delete", .keyword },
            .{ "replace", .string },
        };
        for (kinds) |kk| {
            if (std.mem.indexOf(u8, trimmed, kk[0])) |at| {
                const before_ok = at == 0 or trimmed[at - 1] == ' ';
                const after = at + kk[0].len;
                const after_ok = after >= trimmed.len or trimmed[after] == ' ';
                if (before_ok and after_ok) {
                    return lexUndoRow(line, indent, trimmed, at, after, kk[1], out);
                }
            }
        }
        emit(out, &n, 0, line.len, .plain);
        return n;
    }
    var h: usize = 0;
    while (h < trimmed.len and std.ascii.isHex(trimmed[h])) h += 1;
    if (h >= 4 and h < trimmed.len and trimmed[h] == ' ') {
        emit(out, &n, 0, indent + h, .number);
        emit(out, &n, indent + h, line.len, .plain);
        return n;
    }
    emit(out, &n, 0, line.len, .plain);
    return n;
}

/// Undo row tail after the op kind: `@row,col` and a byte count are
/// numbers, a backticked payload is a string, the rest is plain. The
/// walk is single pass and total: unclaimed bytes stay plain.
fn lexUndoRow(
    line: []const u8,
    indent: usize,
    trimmed: []const u8,
    at: usize,
    after: usize,
    kind: Kind,
    out: []Span,
) usize {
    var n: usize = 0;
    emit(out, &n, 0, indent + at, .plain);
    emit(out, &n, indent + at, indent + after, kind);
    var i = after;
    while (i < trimmed.len) {
        if (trimmed[i] == '@') {
            var j = i + 1;
            while (j < trimmed.len and (std.ascii.isDigit(trimmed[j]) or trimmed[j] == ',')) j += 1;
            if (j > i + 1) {
                emit(out, &n, indent + after, indent + i, .plain);
                emit(out, &n, indent + i, indent + j, .number);
                i = j;
                continue;
            }
        }
        if (trimmed[i] == '`') {
            const close = std.mem.findScalarPos(u8, trimmed, i + 1, '`');
            // Unclosed payload runs to the line end, never past it.
            const end = if (close) |c| indent + c + 1 else line.len;
            emit(out, &n, indent + after, indent + i, .plain);
            emit(out, &n, indent + i, end, .string);
            i = if (close) |c| c + 1 else trimmed.len;
            continue;
        }
        if (std.ascii.isDigit(trimmed[i])) {
            var j = i;
            while (j < trimmed.len and (std.ascii.isDigit(trimmed[j]) or trimmed[j] == 'B')) j += 1;
            emit(out, &n, indent + after, indent + i, .plain);
            emit(out, &n, indent + i, indent + j, .number);
            i = j;
            continue;
        }
        i += 1;
    }
    emit(out, &n, indent + after, line.len, .plain);
    return n;
}

/// Spans for the `:welcome` and `:help` listings, and for the command
/// rows of the trees view. A `:verb` is keyword, its argument word is
/// a string, the description is plain. An indented `name:` key group
/// colors the name, a bare word line (`keys`) is a section, and a
/// label plus version (`kod 0.1.0`) colors the number. Prose lines
/// stay plain.
pub fn lexListingLine(line: []const u8, out: []Span) usize {
    var n: usize = 0;
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') indent += 1;
    const rest = line[indent..];
    if (rest.len == 0) return 0;
    if (rest[0] == ':') {
        var verb: usize = 1;
        while (verb < rest.len and isCmdNameChar(rest[verb])) verb += 1;
        // An argument sits between the verb and the two spaces that
        // separate the description. A row with a single space carries
        // no argument, so the rest of the line is prose and stays
        // plain. Without that rule the first word of every
        // description would color as an argument.
        var arg = indent + verb;
        while (arg < line.len and line[arg] == ' ') arg += 1;
        var arg_end = arg;
        while (arg_end < line.len and line[arg_end] != ' ') arg_end += 1;
        var sep = arg_end;
        while (sep < line.len and line[sep] == ' ') sep += 1;
        emit(out, &n, 0, indent + verb, .keyword);
        if (arg_end > arg and sep - arg_end >= 2) {
            emit(out, &n, indent + verb, arg_end, .string);
            emit(out, &n, arg_end, line.len, .plain);
        } else {
            emit(out, &n, indent + verb, line.len, .plain);
        }
        return n;
    }
    var word: usize = 0;
    while (word < rest.len and isIdentCont(rest[word])) word += 1;
    // `normal: hjkl move` and friends: the key name opens the group.
    if (word > 0 and word < rest.len and rest[word] == ':') {
        emit(out, &n, 0, indent + word + 1, .keyword);
        emit(out, &n, indent + word + 1, line.len, .plain);
        return n;
    }
    // A lone word at the left margin is a section header, as in the
    // keys block. A lone word after an indent is a wrapped
    // continuation, and it stays plain.
    if (indent == 0 and word == rest.len) {
        emit(out, &n, 0, line.len, .keyword);
        return n;
    }
    // `kod 0.1.0`: label plus a version number.
    if (word < rest.len and rest[word] == ' ') {
        var num = indent + word;
        while (num < line.len and line[num] == ' ') num += 1;
        var end = num;
        if (end < line.len and std.ascii.isDigit(line[end])) {
            while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '.')) end += 1;
            emit(out, &n, 0, indent + word, .keyword);
            emit(out, &n, num, end, .number);
            emit(out, &n, end, line.len, .plain);
            return n;
        }
    }
    emit(out, &n, 0, line.len, .plain);
    return n;
}

/// File header like `+++ b/f` or `--- a/f`: marker plus blank. An
/// added line whose content starts with `++` (`++++x`) is not a header
/// and stays green; same mirror logic for removals.
fn isPatchHeader(line: []const u8, marker: []const u8) bool {
    if (!std.mem.startsWith(u8, line, marker)) return false;
    if (line.len == marker.len) return true;
    const c = line[marker.len];
    return c == ' ' or c == '\t';
}

/// Start offset of a `+++---` stat graph (`file | 3 ++-`), or null.
/// git aligns the count column with padding spaces (`|   11 +`), so
/// spaces between `|` and the digits are skipped. Author lines like
/// `Ada | 2026-01-02` still fail the digit check.
fn statGraphStart(line: []const u8) ?usize {
    const bar = std.mem.find(u8, line, " | ") orelse return null;
    var j = bar + 3;
    while (j < line.len and line[j] == ' ') j += 1;
    if (j >= line.len or !std.ascii.isDigit(line[j])) return null;
    while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
    if (j >= line.len or line[j] != ' ') return null;
    j += 1;
    var k = j;
    while (k < line.len and (line[k] == '+' or line[k] == '-' or line[k] == ' ')) k += 1;
    if (k != line.len) return null;
    return j;
}

/// Split a `path:row:col: rest` or `path:row: rest` hit line (search
/// results, exec hits) into its prefix length and borrowed path.
/// Null when the line carries no file position.
pub fn splitHitLine(line: []const u8) ?struct { prefix_len: usize, path: []const u8 } {
    const first = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const path = std.mem.trim(u8, line[0..first], " \t");
    if (path.len == 0) return null;
    const rest = line[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const row = std.mem.trim(u8, rest[0..second], " \t");
    if (row.len == 0) return null;
    for (row) |c| if (!std.ascii.isDigit(c)) return null;
    var prefix_end = first + 1 + second + 1;
    if (std.mem.indexOfScalar(u8, rest[second + 1 ..], ':')) |t| {
        const maybe_col = std.mem.trim(u8, rest[second + 1 ..][0..t], " \t");
        var numeric = maybe_col.len > 0;
        for (maybe_col) |c| {
            if (!std.ascii.isDigit(c)) numeric = false;
        }
        if (numeric) prefix_end += t + 1;
    }
    return .{ .prefix_len = prefix_end, .path = path };
}

/// Spans for hit lines: the `path:row:col:` prefix stays plain with
/// number-colored positions, the rest lexes by the hit path's own
/// language. Rows with no position (a file search row, a plain log
/// line) lex as one whole line in the file's language when the row
/// names a known type, and plain otherwise.
/// Stateless per row. The prefix colors per run, not per byte: a
/// path is 60 or 80 bytes, and one span each wrote a hundred escape
/// sequences into a single row, which flickered as the cursor moved.
pub fn lexHitLine(line: []const u8, out: []Span) usize {
    var n: usize = 0;
    const hit = splitHitLine(line) orelse return lexNamedLine(line, out);
    var run: usize = 0; // start of the current digit or non-digit run
    var i: usize = 0;
    while (i < hit.prefix_len) : (i += 1) {
        if (i == run or kindAt(line, i) != kindAt(line, run)) run = i;
        const last = i + 1 >= hit.prefix_len;
        if (last or kindAt(line, i + 1) != kindAt(line, i)) emit(out, &n, run, i + 1, kindAt(line, i));
    }
    const rest = line[hit.prefix_len..];
    if (detectName(hit.path)) |ls| {
        var st: State = .{};
        var tmp: [max_spans]Span = undefined;
        const m = lexLine(ls, rest, &st, &tmp);
        for (tmp[0..m]) |sp| {
            if (n >= out.len) break;
            out[n] = .{
                .start = sp.start + hit.prefix_len,
                .end = sp.end + hit.prefix_len,
                .kind = sp.kind,
            };
            n += 1;
        }
    } else {
        emit(out, &n, hit.prefix_len, line.len, .plain);
    }
    return n;
}

fn kindAt(line: []const u8, i: usize) Kind {
    return if (std.ascii.isDigit(line[i])) .number else .plain;
}

/// One row that names a file, with no `row:col` prefix: a file search
/// hit, or a log line that is a path. Whole line in the file's own
/// language, plain when the name has no known type.
fn lexNamedLine(line: []const u8, out: []Span) usize {
    var n: usize = 0;
    const spec = detectName(line) orelse {
        emit(out, &n, 0, line.len, .plain);
        return n;
    };
    var st: State = .{};
    return lexLine(spec, line, &st, out);
}

/// File name from a stat graph line (` file.zig | 3 ++-`), borrowed
/// from `line`. Null for anything else. Rename summaries
/// (`old => new`) resolve to the new name. Brace renames
/// (`a/{old => new}/f`) give up and return null.
pub fn statFileName(line: []const u8) ?[]const u8 {
    _ = statGraphStart(line) orelse return null;
    const bar = std.mem.find(u8, line, " | ") orelse return null;
    var name = std.mem.trim(u8, line[0..bar], " ");
    if (std.mem.indexOfScalar(u8, name, '{') != null) return null;
    if (std.mem.find(u8, name, " => ")) |arrow| {
        name = std.mem.trim(u8, name[arrow + 4 ..], " ");
    }
    if (name.len == 0) return null;
    return name;
}

/// Colors `+` green and `-` pink from `from`, plain elsewhere. One
/// pass: plain runs merge through `emit`, so coverage stays total.
fn lexInlineMarks(line: []const u8, out: []Span, from: usize) usize {
    var n: usize = 0;
    var ps = from;
    var i = from;
    emit(out, &n, 0, from, .plain);
    while (i < line.len) : (i += 1) {
        const k: ?Kind = if (line[i] == '+') .function else if (line[i] == '-') .keyword else null;
        if (k) |kk| {
            emit(out, &n, ps, i, .plain);
            emit(out, &n, i, i + 1, kk);
            ps = i + 1;
        }
    }
    emit(out, &n, ps, line.len, .plain);
    return n;
}

/// Directory rows and dotfiles render dimmer than plain files.
/// Applies to fs and buf listings, which name files per line.
pub fn isFadedName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[name.len - 1] == '/') return true;
    const base = std.fs.path.basename(name);
    return base.len > 0 and base[0] == '.';
}

/// File types a listing leaves plain. A row in a file tree names a
/// file, it does not show its source, so prose gets no colors there.
const listing_plain_exts = [_][]const u8{ "md", "markdown" };

/// True when a listing row naming `name` must stay plain.
pub fn isPlainListingName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return false;
    for (listing_plain_exts) |p| {
        if (std.ascii.eqlIgnoreCase(ext[1..], p)) return true;
    }
    return false;
}

/// Detect by file name rather than path. Directory markers come off,
/// so `sub/` tests as `sub`. Prose types stay plain in a listing.
pub fn detectName(name: []const u8) ?*const Spec {
    var n = name;
    if (n.len > 1 and n[n.len - 1] == '/') n = n[0 .. n.len - 1];
    if (isPlainListingName(n)) return null;
    return detect(n);
}

/// Fixed monokai-ish theme. No engine: theme is the terminal's
/// problem, this table is the only exception, and it never changes.
pub const Theme = struct {
    keyword: []const u8,
    string: []const u8,
    comment: []const u8,
    number: []const u8,
    function: []const u8,
    typ: []const u8,
};

pub const monokai: Theme = .{
    .keyword = ansi.fg_pink,
    .string = ansi.fg_yellow,
    .comment = ansi.fg_grey,
    .number = ansi.fg_purple,
    .function = ansi.fg_green,
    .typ = ansi.fg_cyan,
};

pub fn colorOf(th: Theme, kind: Kind) []const u8 {
    return switch (kind) {
        .plain => "",
        .keyword => th.keyword,
        .string => th.string,
        .comment => th.comment,
        .number => th.number,
        .function => th.function,
        .typ => th.typ,
    };
}

test "keyword tables stay sorted for binary search" {
    for (all_specs) |sp| {
        var i: usize = 1;
        while (i < sp.keywords.len) : (i += 1) {
            try std.testing.expectEqual(std.mem.order(u8, sp.keywords[i - 1], sp.keywords[i]), .lt);
        }
    }
}

test "detect picks languages by extension and name" {
    try std.testing.expectEqualStrings("zig", detect("src/main.zig").?.name);
    try std.testing.expectEqualStrings("zig", detect("MAIN.ZIG").?.name);
    try std.testing.expectEqualStrings("python", detect("a/b.py").?.name);
    try std.testing.expectEqualStrings("go", detect("x.go").?.name);
    try std.testing.expectEqualStrings("c", detect("x.h").?.name);
    try std.testing.expectEqualStrings("json", detect("x.json").?.name);
    try std.testing.expectEqualStrings("markdown", detect("x.md").?.name);
    try std.testing.expectEqualStrings("toml", detect("x.toml").?.name);
    try std.testing.expectEqualStrings("shell", detect("x.sh").?.name);
    try std.testing.expectEqualStrings("shell", detect(".zshrc").?.name);
    try std.testing.expectEqualStrings("yaml", detect("x.yaml").?.name);
    try std.testing.expectEqualStrings("yaml", detect("x.yml").?.name);
    try std.testing.expectEqualStrings("html", detect("x.html").?.name);
    try std.testing.expectEqualStrings("html", detect("x.xml").?.name);
    try std.testing.expectEqualStrings("env", detect("x.env").?.name);
    try std.testing.expectEqualStrings("env", detect(".env").?.name);
    try std.testing.expectEqualStrings("env", detect(".envrc").?.name);
    try std.testing.expect(detect("x.txt") == null);
    try std.testing.expect(detect("*help*") == null);
    try std.testing.expect(detect("Makefile") == null);
}

// Test-only helpers. Not part of the lexer engine: they assert total
// line coverage and report per-span kinds for the tests below.
fn fullCover(line: []const u8, spans: []const Span, n: usize) bool {
    if (n == 0) return line.len == 0;
    if (spans[0].start != 0) return false;
    var end = spans[0].end;
    for (spans[1..n]) |sp| {
        if (sp.start != end) return false;
        end = sp.end;
    }
    return end == line.len;
}

fn lexKinds(spec: *const Spec, line: []const u8, st: *State, out: []Span, kinds: []Kind) []Kind {
    const n = lexLine(spec, line, st, out);
    for (out[0..n], 0..) |sp, i| kinds[i] = sp.kind;
    return kinds[0..n];
}

test "zig lexes keywords strings comments numbers" {
    const sp = &zig_spec;
    var st: State = .{};
    var out: [max_spans]Span = undefined;
    const n = lexLine(sp, "pub fn main() void {", &st, &out);
    try std.testing.expect(fullCover("pub fn main() void {", &out, n));
    // pub keyword, fn keyword, main function, void keyword... void is not
    // a zig keyword, so it lexes by case: lowercase start is plain.
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqualStrings("pub", "pub fn main() void {"[out[0].start..out[0].end]);
    try std.testing.expect(isKeyword(sp.keywords, "fn"));
    try std.testing.expect(!isKeyword(sp.keywords, "main"));

    const nc = lexLine(sp, "// hello", &st, &out);
    try std.testing.expectEqual(Kind.comment, out[nc - 1].kind);
    var st2: State = .{};
    const ns = lexLine(sp, "const s = \"a\\\"b\";", &st2, &out);
    try std.testing.expect(fullCover("const s = \"a\\\"b\";", &out, ns));
    var saw_str = false;
    for (out[0..ns]) |x| {
        if (x.kind == .string) saw_str = true;
    }
    try std.testing.expect(saw_str);
    var st3: State = .{};
    const nn = lexLine(sp, "const x: u64 = 0x1F;", &st3, &out);
    var saw_num = false;
    for (out[0..nn]) |x| {
        if (x.kind == .number) saw_num = true;
    }
    try std.testing.expect(saw_num);
}

test "yaml colors keys scalars comments and vars" {
    const sp = &yaml_spec;
    var st: State = .{};
    var out: [max_spans]Span = undefined;
    const line = "name: kod # a comment";
    const n = lexLine(sp, line, &st, &out);
    try std.testing.expect(fullCover(line, &out, n));
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqualStrings("name", line[out[0].start..out[0].end]);
    try std.testing.expectEqual(Kind.comment, out[n - 1].kind);
    // Scalars and interpolation.
    const b = lexLine(sp, "build: true", &st, &out);
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expect(sawKind(&out, b, .keyword));
    const v = lexLine(sp, "path: $HOME/bin", &st, &out);
    try std.testing.expect(sawKind(&out, v, .typ));
    // A colon inside a value is not a key.
    const u = lexLine(sp, "url: http://x:80", &st, &out);
    try std.testing.expect(fullCover("url: http://x:80", &out, u));
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqual(@as(usize, 3), out[0].end);
}

test "html colors tags attributes strings and comments" {
    const sp = &html_spec;
    var st: State = .{};
    var out: [max_spans]Span = undefined;
    const line = "<a href=\"x\" id=y>t</a>";
    const n = lexLine(sp, line, &st, &out);
    try std.testing.expect(fullCover(line, &out, n));
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqualStrings("<a", line[out[0].start..out[0].end]);
    try std.testing.expect(sawKind(&out, n, .typ));
    try std.testing.expect(sawKind(&out, n, .string));
    // The closing tag colors too, and a bare `<` in prose does not.
    const c = lexLine(sp, "</div>", &st, &out);
    try std.testing.expect(fullCover("</div>", &out, c));
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqualStrings("</div", "</div>"[out[0].start..out[0].end]);
    const p = lexLine(sp, "a < b and c > d", &st, &out);
    try std.testing.expectEqual(@as(usize, 1), p);
    try std.testing.expectEqual(Kind.plain, out[0].kind);
    // Comments carry across lines.
    var st2: State = .{};
    const o = lexLine(sp, "<!-- note", &st2, &out);
    try std.testing.expectEqual(Kind.comment, out[o - 1].kind);
    try std.testing.expect(st2.block);
    const q = lexLine(sp, "still note --> tail", &st2, &out);
    try std.testing.expectEqual(Kind.comment, out[0].kind);
    try std.testing.expect(out[q - 1].end >= 11);
    try std.testing.expect(!st2.block);
}

test "env colors keys values comments and vars" {
    const sp = &env_spec;
    var st: State = .{};
    var out: [max_spans]Span = undefined;
    const line = "PATH=/usr/bin:$PATH # where";
    const n = lexLine(sp, line, &st, &out);
    try std.testing.expect(fullCover(line, &out, n));
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqualStrings("PATH", line[out[0].start..out[0].end]);
    try std.testing.expect(sawKind(&out, n, .typ));
    try std.testing.expectEqual(Kind.comment, out[n - 1].kind);
    // A quoted value stays a string, and a bare word is not a key.
    const q = lexLine(sp, "MSG=\"hello there\"", &st, &out);
    try std.testing.expect(sawKind(&out, q, .string));
    const w = lexLine(sp, "just some words", &st, &out);
    try std.testing.expect(!sawKind(&out, w, .keyword));
}

fn sawKind(out: []const Span, n: usize, want: Kind) bool {
    for (out[0..n]) |sp| {
        if (sp.kind == want) return true;
    }
    return false;
}

test "c block comments and directives carry state" {
    const sp = &c_spec;
    var st: State = .{};
    var out: [max_spans]Span = undefined;
    const a = lexLine(sp, "int x; /* open", &st, &out);
    try std.testing.expect(st.block);
    try std.testing.expectEqual(Kind.comment, out[a - 1].kind);
    _ = lexLine(sp, "still comment */ int y;", &st, &out);
    try std.testing.expect(!st.block);
    try std.testing.expectEqual(Kind.comment, out[0].kind);
    try std.testing.expect(isKeyword(sp.keywords, "int"));

    var st2: State = .{};
    const d = lexLine(sp, "#include <x.h>", &st2, &out);
    try std.testing.expectEqual(Kind.keyword, out[d - 1].kind);

    var st3: State = .{};
    const e = lexLine(sp, "char c = 'x';", &st3, &out);
    var saw_str = false;
    for (out[0..e]) |x| {
        if (x.kind == .string) saw_str = true;
    }
    try std.testing.expect(saw_str);
}

test "python triple strings span lines" {
    const sp = &python_spec;
    var st: State = .{};
    var out: [max_spans]Span = undefined;
    _ = lexLine(sp, "s = \"\"\"open", &st, &out);
    try std.testing.expect(st.str == '"');
    const b = lexLine(sp, "middle", &st, &out);
    try std.testing.expectEqual(Kind.string, out[0].kind);
    try std.testing.expectEqual(@as(usize, 1), b);
    _ = lexLine(sp, "shut\"\"\" + x", &st, &out);
    try std.testing.expect(st.str == 0);
}

test "go backticks shell vars toml keys json words" {
    var out: [max_spans]Span = undefined;
    var st: State = .{};

    _ = lexLine(&go_spec, "s := `open", &st, &out);
    try std.testing.expect(st.str == '`');
    _ = lexLine(&go_spec, "shut` + 1", &st, &out);
    try std.testing.expect(st.str == 0);
    try std.testing.expectEqual(Kind.string, out[0].kind);

    var sh: State = .{};
    const v = lexLine(&shell_spec, "echo $HOME ${x} # c", &sh, &out);
    try std.testing.expect(fullCover("echo $HOME ${x} # c", &out, v));
    var saw_typ = false;
    var saw_comment = false;
    for (out[0..v]) |x| {
        if (x.kind == .typ) saw_typ = true;
        if (x.kind == .comment) saw_comment = true;
    }
    try std.testing.expect(saw_typ and saw_comment);

    var tm: State = .{};
    _ = lexLine(&toml_spec, "name = \"x\"", &tm, &out);
    try std.testing.expectEqual(Kind.keyword, out[0].kind);

    var js: State = .{};
    const j = lexLine(&json_spec, "{\"a\": true}", &js, &out);
    var saw_kw = false;
    for (out[0..j]) |x| {
        if (x.kind == .keyword) saw_kw = true;
    }
    try std.testing.expect(saw_kw);
}

test "markdown headers fences emphasis" {
    var out: [max_spans]Span = undefined;
    var st: State = .{};
    const h = lexLine(&markdown_spec, "## head", &st, &out);
    try std.testing.expectEqual(Kind.keyword, out[h - 1].kind);
    _ = lexLine(&markdown_spec, "```", &st, &out);
    try std.testing.expect(st.block);
    const f = lexLine(&markdown_spec, "code", &st, &out);
    try std.testing.expectEqual(Kind.string, out[0].kind);
    try std.testing.expectEqual(@as(usize, 1), f);
    _ = lexLine(&markdown_spec, "```", &st, &out);
    try std.testing.expect(!st.block);
    var st2: State = .{};
    const e = lexLine(&markdown_spec, "a *b* c", &st2, &out);
    var saw_str = false;
    for (out[0..e]) |x| {
        if (x.kind == .string) saw_str = true;
    }
    try std.testing.expect(saw_str);
}

test "lexKinds helper reports per-span kinds" {
    var out: [max_spans]Span = undefined;
    var kindbuf: [max_spans]Kind = undefined;
    var st: State = .{};
    const kinds = lexKinds(&go_spec, "return 1", &st, &out, &kindbuf);
    try std.testing.expectEqual(Kind.keyword, kinds[0]);
    try std.testing.expectEqual(Kind.number, kinds[kinds.len - 1]);
}

test "lexGitLine colors branch hash and plain lines" {
    var out: [max_spans]Span = undefined;
    const b = lexGitLine("branch main", &out);
    try std.testing.expectEqual(Kind.keyword, out[b - 1].kind);

    const c = lexGitLine("abc1234 first subj", &out);
    try std.testing.expectEqual(Kind.number, out[0].kind);
    try std.testing.expectEqual(@as(usize, 0), out[0].start);
    try std.testing.expectEqual(@as(usize, 7), out[0].end);
    try std.testing.expectEqual(Kind.plain, out[c - 1].kind);

    const d = lexGitLine("  Ada | 2026-01-02", &out);
    try std.testing.expectEqual(Kind.plain, out[d - 1].kind);

    const e = lexGitLine("(empty)", &out);
    try std.testing.expectEqual(Kind.plain, out[e - 1].kind);
}

test "detectName strips directory markers" {
    try std.testing.expectEqualStrings("zig", detectName("main.zig").?.name);
    try std.testing.expectEqualStrings("zig", detectName("sub/main.zig").?.name);
    try std.testing.expect(detectName("sub/") == null);
    try std.testing.expect(detectName("../") == null);
}

test "isFadedName dims dirs and dotfiles only" {
    try std.testing.expect(isFadedName("sub/"));
    try std.testing.expect(isFadedName("../"));
    try std.testing.expect(isFadedName(".gitignore"));
    try std.testing.expect(isFadedName("sub/.env"));
    try std.testing.expect(!isFadedName("main.zig"));
    try std.testing.expect(!isFadedName("README.md"));
    try std.testing.expect(!isFadedName(""));
}

test "lexGitLine colors stat graphs and summaries" {
    var out: [max_spans]Span = undefined;
    const line = " file.zig | 3 ++-";
    const n = lexGitLine(line, &out);
    try std.testing.expectEqual(Kind.plain, out[0].kind);
    var plus = false;
    var minus = false;
    for (out[0..n]) |sp| {
        if (sp.kind == .function) plus = true;
        if (sp.kind == .keyword) minus = true;
    }
    try std.testing.expect(plus and minus);

    const s = lexGitLine(" 1 file changed, 2 insertions(+), 1 deletion(-)", &out);
    var sp2 = false;
    var sm2 = false;
    for (out[0..s]) |x| {
        if (x.kind == .function) sp2 = true;
        if (x.kind == .keyword) sm2 = true;
    }
    try std.testing.expect(sp2 and sm2);

    // Author dates with dashes stay plain.
    const a = lexGitLine("  Ada | 2026-01-02", &out);
    for (out[0..a]) |x| try std.testing.expectEqual(Kind.plain, x.kind);
}

test "lexGitLine colors stat graphs despite count padding" {
    var out: [max_spans]Span = undefined;
    // git aligns the count column: `|   11 +`, not just `| 11 +`.
    const padded = [_][]const u8{
        " lib/root.zig         |   11 +",
        " README.md            |   89 +++",
        " src/buffer.zig       | 1467 ++++++++++++++++++++++++++++++++++++++++++++++++++",
        " lib/usertrees.zig    |  174 ++++++",
    };
    for (padded) |line| {
        const n = lexGitLine(line, &out);
        var plus = false;
        for (out[0..n]) |sp| {
            if (sp.kind == .function) plus = true;
        }
        try std.testing.expect(plus);
    }
}

test "lexGitLine colors patch lines" {
    var out: [max_spans]Span = undefined;
    const a = lexGitLine("+added line", &out);
    try std.testing.expectEqual(Kind.function, out[a - 1].kind);
    const d = lexGitLine("-gone line", &out);
    try std.testing.expectEqual(Kind.keyword, out[d - 1].kind);
    const h = lexGitLine("@@ -1,2 +3,4 @@", &out);
    try std.testing.expectEqual(Kind.keyword, out[h - 1].kind);
    // File headers are red.
    const f = lexGitLine("+++ b/f", &out);
    try std.testing.expectEqual(Kind.keyword, out[f - 1].kind);
    const g = lexGitLine("--- a/f", &out);
    try std.testing.expectEqual(Kind.keyword, out[g - 1].kind);
    // Added lines whose content starts with `++` stay green, and
    // removed lines starting with `--` stay pink: only marker plus
    // blank is a header.
    const ax = lexGitLine("++++x", &out);
    try std.testing.expectEqual(Kind.function, out[ax - 1].kind);
    const dx = lexGitLine("---x", &out);
    try std.testing.expectEqual(Kind.keyword, out[dx - 1].kind);
}

test "statFileName resolves stat lines and renames" {
    try std.testing.expectEqualStrings("file.zig", statFileName(" file.zig | 3 ++-").?);
    try std.testing.expectEqualStrings("lib/root.zig", statFileName(" lib/root.zig         |   11 +").?);
    try std.testing.expectEqualStrings("new.zig", statFileName(" old.zig => new.zig | 4 ++--").?);
    try std.testing.expect(statFileName(" a/{old => new}/f.zig | 4 ++--") == null);
    try std.testing.expect(statFileName("  Ada | 2026-01-02") == null);
    try std.testing.expect(statFileName(" 2 files changed, 25 insertions(+)") == null);
    try std.testing.expect(statFileName("branch main") == null);
    try std.testing.expect(statFileName("abc1234 first") == null);
}

test "splitHitLine splits hit prefixes" {
    const a = splitHitLine("src/main.zig:12:4: use of undeclared identifier").?;
    try std.testing.expectEqualStrings("src/main.zig", a.path);
    try std.testing.expectEqual(@as(usize, 18), a.prefix_len);
    const b = splitHitLine("a.zig:3: just a row").?;
    try std.testing.expectEqualStrings("a.zig", b.path);
    try std.testing.expectEqual(@as(usize, 8), b.prefix_len);
    // Message colons without a numeric col stay in the rest.
    const c = splitHitLine("a.zig:3: note: detailed").?;
    try std.testing.expectEqual(@as(usize, 8), c.prefix_len);
    try std.testing.expect(splitHitLine("just a log line") == null);
    try std.testing.expect(splitHitLine(":12:4: missing path") == null);
    try std.testing.expect(splitHitLine("a.zig:xx: no digits") == null);
}

test "lexHitLine colors prefixes and previews by language" {
    var out: [max_spans]Span = undefined;
    // Prefix positions number-colored, preview lexed as zig.
    const n = lexHitLine("src/main.zig:12:4: pub fn f() void {", &out);
    var saw_number = false;
    var saw_keyword = false;
    for (out[0..n]) |sp| {
        if (sp.kind == .number and sp.end <= 18) saw_number = true;
        if (sp.kind == .keyword and sp.start >= 18) saw_keyword = true;
    }
    try std.testing.expect(saw_number and saw_keyword);
    // Unknown extension: rest stays plain, prefix positions numbered.
    const m = lexHitLine("data.xyz:1: some text", &out);
    try std.testing.expectEqual(Kind.plain, out[m - 1].kind);
    var saw_num = false;
    for (out[0..m]) |sp| {
        if (sp.kind == .number) saw_num = true;
    }
    try std.testing.expect(saw_num);
    // No file position: whole-line plain.
    const p = lexHitLine("plain log line", &out);
    try std.testing.expectEqual(@as(usize, 1), p);
    try std.testing.expectEqual(Kind.plain, out[0].kind);
}

test "lexHitLine colors a hit prefix in runs, not per byte" {
    var out: [max_spans]Span = undefined;
    // Three runs in the prefix: the path with its colon, the row, and
    // the colon that closes it. A per byte loop wrote a hundred
    // escapes into this row.
    const n = lexHitLine("src/main.zig:12:4: boom", &out);
    try std.testing.expect(n <= 8);
    try std.testing.expectEqual(@as(usize, 0), out[0].start);
    try std.testing.expectEqual(@as(usize, 13), out[0].end);
    try std.testing.expectEqual(Kind.plain, out[0].kind);
    try std.testing.expectEqual(@as(usize, 13), out[1].start);
    try std.testing.expectEqual(@as(usize, 15), out[1].end);
    try std.testing.expectEqual(Kind.number, out[1].kind);
    try std.testing.expectEqual(@as(usize, 15), out[2].start);
    try std.testing.expectEqual(@as(usize, 16), out[2].end);
    try std.testing.expectEqual(Kind.plain, out[2].kind);
    // Spans stay ordered and never gap.
    var at: usize = 0;
    for (out[0..n]) |sp| {
        try std.testing.expectEqual(at, sp.start);
        at = sp.end;
    }
    try std.testing.expectEqual(@as(usize, "src/main.zig:12:4: boom".len), at);
}

test "lexHitLine colors a bare file row by its own language" {
    var out: [max_spans]Span = undefined;
    // File search rows carry no position, only the name.
    const f = lexHitLine("src/main.zig", &out);
    try std.testing.expect(f >= 1);
    try std.testing.expectEqual(Kind.plain, out[f - 1].kind);
    // A log line that names a file lexes in that language too.
    const g = lexHitLine("a.txt", &out);
    try std.testing.expect(g >= 1);
    // A name with no known type stays plain.
    const n = lexHitLine("notafile", &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Kind.plain, out[0].kind);
}

test "lexListingLine colors commands keys and the version" {
    var out: [max_spans]Span = undefined;
    // `:verb args  desc`: verb keyword, args string, rest plain. The
    // two spaces are the only thing that marks an argument, so a
    // description word never colors as one.
    const c = lexListingLine(":exec-save <cmd>  run and rerun on save", &out);
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqual(@as(usize, 0), out[0].start);
    try std.testing.expectEqual(@as(usize, 10), out[0].end);
    try std.testing.expectEqual(Kind.string, out[1].kind);
    try std.testing.expectEqual(Kind.plain, out[c - 1].kind);
    // An argumentless command: the first description word stays plain.
    const q = lexListingLine(":q  quit, same as quit", &out);
    try std.testing.expectEqual(@as(usize, 2), q);
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqual(Kind.plain, out[1].kind);
    // Prose after a verb with a single space is prose too.
    const h = lexListingLine(":help lists every command with its keys.", &out);
    try std.testing.expectEqual(@as(usize, 2), h);
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqual(Kind.plain, out[1].kind);
    // Indented key group and bare section word.
    const k = lexListingLine("  normal: hjkl move", &out);
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqual(Kind.plain, out[k - 1].kind);
    const s = lexListingLine("keys", &out);
    try std.testing.expectEqual(Kind.keyword, out[s - 1].kind);
    // A wrapped continuation is a lone word after an indent, and it
    // stays plain: only the left margin opens a section.
    const wrap = lexListingLine("                    commands", &out);
    try std.testing.expectEqual(@as(usize, 1), wrap);
    try std.testing.expectEqual(Kind.plain, out[0].kind);
    // Label plus version.
    const v = lexListingLine("kod 0.1.0", &out);
    try std.testing.expectEqual(@as(usize, 2), v);
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqual(Kind.number, out[1].kind);
    try std.testing.expectEqual(@as(usize, 9), out[1].end);
    // Prose stays plain, and a blank line emits nothing.
    const p = lexListingLine("enter opens the entry under the cursor.", &out);
    try std.testing.expectEqual(@as(usize, 1), p);
    try std.testing.expectEqual(Kind.plain, out[0].kind);
    try std.testing.expectEqual(@as(usize, 0), lexListingLine("   ", &out));
}

test "listings leave prose files plain" {
    var out: [max_spans]Span = undefined;
    // Markdown is for reading, not for coloring in a file tree.
    try std.testing.expect(isPlainListingName("README.md"));
    try std.testing.expect(isPlainListingName("notes.MARKDOWN"));
    try std.testing.expect(!isPlainListingName("main.zig"));
    try std.testing.expect(!isPlainListingName("sub/"));
    try std.testing.expectEqual(@as(?*const Spec, null), detectName("README.md"));
    // Opening a markdown file still highlights it.
    try std.testing.expect(detect("README.md") != null);
    const n = lexHitLine("README.md", &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Kind.plain, out[0].kind);
}

test "lexTreeLine defers command rows to the listing rules" {
    var out: [max_spans]Span = undefined;
    const c = lexTreeLine("  :fs [path]  open a directory", &out);
    try std.testing.expectEqual(Kind.keyword, out[0].kind);
    try std.testing.expectEqual(Kind.string, out[1].kind);
    try std.testing.expectEqual(Kind.plain, out[c - 1].kind);
}

test "lexTreeLine colors undo positions and payloads" {
    var out: [max_spans]Span = undefined;
    const a = lexTreeLine("    #1 p=0 insert 2B @0,2 `ab`", &out);
    var saw_num = false;
    var saw_str = false;
    for (out[0..a]) |sp| {
        if (sp.kind == .number) saw_num = true;
        if (sp.kind == .string) saw_str = true;
    }
    try std.testing.expect(saw_num);
    try std.testing.expect(saw_str);
    // Unclosed backtick still ends at the line end, never past it.
    const u = lexTreeLine("    #3 p=2 replace 1B @4,0 `open", &out);
    for (out[0..u]) |sp| {
        try std.testing.expect(sp.end <= "    #3 p=2 replace 1B @4,0 `open".len);
    }
}

test "lexTreeLine colors undo op kinds" {
    var out: [max_spans]Span = undefined;
    const a = lexTreeLine("    #1 p=0 insert 2B @0,2 `ab`", &out);
    var saw_fn = false;
    for (out[0..a]) |sp| {
        if (sp.kind == .function) saw_fn = true;
    }
    try std.testing.expect(saw_fn);
    const d = lexTreeLine("    #2 p=1 delete 4B @1,0 `gone` (fork)", &out);
    var saw_kw = false;
    for (out[0..d]) |sp| {
        if (sp.kind == .keyword) saw_kw = true;
    }
    try std.testing.expect(saw_kw);
    const r = lexTreeLine("    #0 root", &out);
    try std.testing.expectEqual(Kind.plain, out[r - 1].kind);
}

test "lexTreeLine colors headers hashes and plain leaves" {
    var out: [max_spans]Span = undefined;
    const h = lexTreeLine("undo (1 docs, 2 nodes)", &out);
    try std.testing.expectEqual(Kind.keyword, out[h - 1].kind);
    const g = lexTreeLine("git: main <- origin/main (+1/-2)", &out);
    try std.testing.expectEqual(Kind.keyword, out[g - 1].kind);
    const sub = lexTreeLine("  a.txt (2 nodes)", &out);
    try std.testing.expectEqual(Kind.keyword, out[sub - 1].kind);
    const c = lexTreeLine("  abc1234 first subject", &out);
    try std.testing.expectEqual(Kind.number, out[0].kind);
    try std.testing.expectEqual(@as(usize, 0), out[0].start);
    try std.testing.expectEqual(@as(usize, 9), out[0].end);
    try std.testing.expectEqual(Kind.plain, out[c - 1].kind);
    const b = lexTreeLine("  a.txt [file]", &out);
    try std.testing.expectEqual(Kind.plain, out[b - 1].kind);
}
