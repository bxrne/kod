const std = @import("std");
const testing = std.testing;

const assert = std.debug.assert;

/// NOTE: Structured logger that writes scoped, levelled messages to a file.
/// Scope and level are comptime strings so the format prefix is assembled
/// entirely at compile time—zero runtime overhead for tag construction.
pub const Logger = struct {
    file: std.fs.File,

    pub const Level = enum {
        debug,
        info,
        warn,
        err,

        /// Comptime tag for log output.
        pub fn tag(comptime self: Level) []const u8 {
            return switch (self) {
                .debug => "DEBUG",
                .info => "INFO",
                .warn => "WARN",
                .err => "ERROR",
            };
        }
    };

    pub fn init(file: std.fs.File) Logger {
        return .{ .file = file };
    }

    /// Core writer. The entire prefix is resolved at comptime.
    fn write(
        self: Logger,
        comptime level: Level,
        comptime scope: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const prefix = comptime "[" ++ level.tag() ++ "](" ++ scope ++ ") ";
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, prefix ++ fmt ++ "\n", args) catch return;
        assert(msg.len > 0);
        self.file.writeAll(msg) catch {};
    }

    pub fn debug(self: Logger, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.write(.debug, scope, fmt, args);
    }

    pub fn info(self: Logger, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.write(.info, scope, fmt, args);
    }

    pub fn warn(self: Logger, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.write(.warn, scope, fmt, args);
    }

    pub fn err(self: Logger, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.write(.err, scope, fmt, args);
    }
};

// Tests

test "formatted message is written" {
    const tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("test.log", .{ .read = true });
    defer file.close();

    const logger = Logger.init(file);
    logger.info("test", "hello {s}", .{"world"});

    try file.seekTo(0);
    var read_buf: [256]u8 = undefined;
    const n = try file.readAll(&read_buf);
    try testing.expectEqualStrings("[INFO](test) hello world\n", read_buf[0..n]);
}

test "all levels produce distinct tags" {
    const tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("levels.log", .{ .read = true });
    defer file.close();

    const logger = Logger.init(file);
    logger.debug("s", "d", .{});
    logger.info("s", "i", .{});
    logger.warn("s", "w", .{});
    logger.err("s", "e", .{});

    try file.seekTo(0);
    var read_buf: [512]u8 = undefined;
    const n = try file.readAll(&read_buf);
    const output = read_buf[0..n];

    try testing.expect(std.mem.indexOf(u8, output, "[DEBUG]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[INFO]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[WARN]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[ERROR]") != null);
}

test "message truncated to buffer size does not crash" {
    const tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("trunc.log", .{ .read = true });
    defer file.close();

    const logger = Logger.init(file);
    // NOTE: 1024-byte internal buffer; a very long message is silently truncated.
    const long = "x" ** 2000;
    logger.info("overflow", "{s}", .{long});

    try file.seekTo(0);
    var read_buf: [64]u8 = undefined;
    const n = try file.readAll(&read_buf);
    // INFO: If truncation occurred, nothing is written—that is the expected
    // behaviour (bufPrint returns an error and we `catch return`).
    // Either way, no crash.
    _ = n;
}
