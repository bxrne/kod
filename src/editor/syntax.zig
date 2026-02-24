const std = @import("std");

// TODO: Replace with proper regex/tree-sitter/LSP-based highlighting for accuracy and more languages.

const default_attr = "\x1B[38;5;249m";
const comment_attr = "\x1B[2;38;5;241m";
const keyword_control_attr = "\x1B[1;38;5;255m";
const keyword_storage_attr = "\x1B[1;38;5;253m";
const keyword_modifier_attr = "\x1B[38;5;247m";
const type_attr = "\x1B[1;38;5;254m";
const function_attr = "\x1B[1;38;5;252m";
const literal_attr = "\x1B[1;38;5;251m";
const string_attr = "\x1B[38;5;246m";
const number_attr = "\x1B[1;38;5;250m";
const punctuation_attr = "\x1B[2;38;5;243m";
const operator_attr = "\x1B[38;5;245m";
const reset = "\x1B[0m";

const keywords_control = [_][]const u8{
    "if", "else", "for", "while", "switch", "break", "continue", "return", "try", "catch", "defer", "errdefer",
};

const keywords_storage = [_][]const u8{
    "const", "var", "fn", "pub", "struct", "enum", "union", "opaque", "export",
};

const keywords_modifier = [_][]const u8{
    "inline", "comptime", "noalias", "async", "await", "suspend", "resume", "anytype", "void",
};

const literals = [_][]const u8{
    "true", "false", "null", "undefined",
};

const HastNodeClass = enum {
    identifier,
    comment,
    keyword_control,
    keyword_storage,
    keyword_modifier,
    type,
    function,
    literal,
    string,
    number,
    punctuation,
    operator,
};

fn attrForClass(class: HastNodeClass) []const u8 {
    return switch (class) {
        .identifier => default_attr,
        .comment => comment_attr,
        .keyword_control => keyword_control_attr,
        .keyword_storage => keyword_storage_attr,
        .keyword_modifier => keyword_modifier_attr,
        .type => type_attr,
        .function => function_attr,
        .literal => literal_attr,
        .string => string_attr,
        .number => number_attr,
        .punctuation => punctuation_attr,
        .operator => operator_attr,
    };
}

fn writeStyled(w: anytype, text: []const u8, class: HastNodeClass) void {
    w.writeAll(attrForClass(class)) catch {};
    w.writeAll(text) catch {};
    w.writeAll(reset) catch {};
    w.writeAll(default_attr) catch {};
}

fn writeStyledByte(w: anytype, byte: u8, class: HastNodeClass) void {
    w.writeAll(attrForClass(class)) catch {};
    w.writeByte(byte) catch {};
    w.writeAll(reset) catch {};
    w.writeAll(default_attr) catch {};
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isBracket(c: u8) bool {
    return c == '{' or c == '}' or c == '(' or c == ')' or c == '[' or c == ']';
}

fn isPunctuation(c: u8) bool {
    return isBracket(c) or c == ',' or c == ';' or c == ':' or c == '.';
}

fn isOperator(c: u8) bool {
    return c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == '=' or c == '&' or c == '|' or c == '!' or c == '<' or c == '>' or c == '?' or c == '~' or c == '^';
}

fn containsWord(words: []const []const u8, word: []const u8) bool {
    for (words) |candidate| {
        if (std.mem.eql(u8, candidate, word)) return true;
    }
    return false;
}

fn findPrevNonSpace(slice: []const u8, idx: usize) ?u8 {
    if (idx == 0) return null;
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(slice[i])) return slice[i];
    }
    return null;
}

fn findNextNonSpace(slice: []const u8, idx: usize) ?u8 {
    var i = idx;
    while (i < slice.len) : (i += 1) {
        if (!std.ascii.isWhitespace(slice[i])) return slice[i];
    }
    return null;
}

fn classifyIdentifier(word: []const u8, prev_non_space: ?u8, next_non_space: ?u8) HastNodeClass {
    if (containsWord(&literals, word)) return .literal;
    if (containsWord(&keywords_control, word)) return .keyword_control;
    if (containsWord(&keywords_storage, word)) return .keyword_storage;
    if (containsWord(&keywords_modifier, word)) return .keyword_modifier;

    if (next_non_space == '(' and prev_non_space != '.') {
        return .function;
    }

    if (word.len > 0 and std.ascii.isUpper(word[0])) {
        return .type;
    }

    return .identifier;
}

/// Write a segment of a line using lightweight HAST-style classes
/// (comment/keyword/type/function/literal/string/number/punctuation/operator).
/// The palette intentionally stays grayscale and distinguishes mostly by weight.
pub fn writeLineWithSyntaxHighlight(
    w: anytype,
    line: []const u8,
    start: usize,
    end: usize,
    col_off: u32,
) void {
    if (start >= end) return;
    const slice = line[start..end];

    var i: usize = 0;
    while (i < slice.len) {
        const at_line_start = (start + i == 0);
        if (at_line_start and i < slice.len and slice[i] == '#') {
            writeStyled(w, slice[i..], .comment);
            break;
        }

        if (i + 1 < slice.len and slice[i] == '/' and slice[i + 1] == '/') {
            writeStyled(w, slice[i..], .comment);
            break;
        }

        if (slice[i] == '"' or slice[i] == '\'') {
            const quote = slice[i];
            var j = i + 1;
            while (j < slice.len) : (j += 1) {
                if (slice[j] == '\\' and j + 1 < slice.len) {
                    j += 1;
                    continue;
                }
                if (slice[j] == quote) {
                    j += 1;
                    break;
                }
            }
            writeStyled(w, slice[i..j], .string);
            i = j;
            continue;
        }

        if (std.ascii.isDigit(slice[i])) {
            var j = i + 1;
            while (j < slice.len and (std.ascii.isDigit(slice[j]) or slice[j] == '_' or slice[j] == '.')) : (j += 1) {}
            writeStyled(w, slice[i..j], .number);
            i = j;
            continue;
        }

        if (isPunctuation(slice[i])) {
            writeStyledByte(w, slice[i], .punctuation);
            i += 1;
            continue;
        }

        if (isOperator(slice[i])) {
            var j = i + 1;
            while (j < slice.len and isOperator(slice[j])) : (j += 1) {}
            writeStyled(w, slice[i..j], .operator);
            i = j;
            continue;
        }

        if (isIdentStart(slice[i])) {
            var word_end = i;
            while (word_end < slice.len and isIdentContinue(slice[word_end])) : (word_end += 1) {}
            const word = slice[i..word_end];
            const prev_non_space = findPrevNonSpace(slice, i);
            const next_non_space = findNextNonSpace(slice, word_end);
            const class = classifyIdentifier(word, prev_non_space, next_non_space);
            if (class == .identifier) {
                w.writeAll(word) catch {};
            } else {
                writeStyled(w, word, class);
            }
            i = word_end;
            continue;
        }

        w.writeByte(slice[i]) catch {};
        i += 1;
    }
    _ = col_off;
}
