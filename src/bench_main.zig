const std = @import("std");
const build_options = @import("build_options");
const kod = @import("kod");

const Buffer = kod.Buffer;
const Rope = kod.Rope;

const assert = std.debug.assert;

const BenchResult = struct {
    name: []const u8,
    elapsed_ns: u64,
    iterations: u64,
};

pub fn main() !void {
    _ = build_options;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sample_text = try build_sample_text(allocator, 4_096, 72);
    defer allocator.free(sample_text);

    const rope_build_result = try bench_rope_build(allocator, sample_text, 400);
    const line_lookup_result = try bench_rope_line_lookup(allocator, sample_text, 250_000);
    const edit_result = try bench_buffer_edit_roundtrip(allocator, 80_000);

    try print_result(rope_build_result);
    try print_result(line_lookup_result);
    try print_result(edit_result);
}

fn build_sample_text(
    allocator: std.mem.Allocator,
    line_count: u32,
    line_width: u32,
) ![]u8 {
    assert(line_count > 0);
    assert(line_width > 8);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var line_index: u32 = 0;
    while (line_index < line_count) : (line_index += 1) {
        try std.fmt.format(output.writer(allocator), "line-{d:0>5} ", .{line_index});

        var column_index: u32 = 10;
        while (column_index < line_width) : (column_index += 1) {
            const ch: u8 = @intCast('a' + @mod(column_index + line_index, 26));
            try output.append(allocator, ch);
        }

        if (line_index + 1 < line_count) {
            try output.append(allocator, '\n');
        }
    }

    return output.toOwnedSlice(allocator);
}

fn bench_rope_build(
    allocator: std.mem.Allocator,
    sample_text: []const u8,
    iterations: u64,
) !BenchResult {
    assert(iterations > 0);

    var timer = try std.time.Timer.start();
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        var rope = try Rope.initFromSlice(allocator, sample_text);
        rope.deinit(allocator);
    }

    return .{
        .name = "rope_build",
        .elapsed_ns = timer.read(),
        .iterations = iterations,
    };
}

fn bench_rope_line_lookup(
    allocator: std.mem.Allocator,
    sample_text: []const u8,
    iterations: u64,
) !BenchResult {
    assert(iterations > 0);

    var rope = try Rope.initFromSlice(allocator, sample_text);
    defer rope.deinit(allocator);

    const line_count = rope.lineCount();
    assert(line_count > 0);

    var line_buf: [256]u8 = undefined;
    var checksum: u64 = 0;

    var timer = try std.time.Timer.start();
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        const line_index: u32 = @intCast(@mod(index * 1_103_515_245 + 12_345, line_count));
        const line = rope.getLine(line_index, &line_buf) orelse "";
        if (line.len > 0) {
            checksum +%= line[0];
        }
    }

    // Keep the compiler from eliminating the lookup loop.
    assert(checksum != std.math.maxInt(u64));

    return .{
        .name = "rope_line_lookup",
        .elapsed_ns = timer.read(),
        .iterations = iterations,
    };
}

fn bench_buffer_edit_roundtrip(
    allocator: std.mem.Allocator,
    iterations: u64,
) !BenchResult {
    assert(iterations > 0);

    var buffer = try Buffer.initEmpty(allocator, "[bench]");
    defer buffer.deinit();

    var timer = try std.time.Timer.start();
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        const ch: u8 = @intCast('a' + @mod(index, 26));
        try buffer.insertChar(ch);
        try buffer.deleteChar();
    }

    return .{
        .name = "buffer_edit_roundtrip",
        .elapsed_ns = timer.read(),
        .iterations = iterations,
    };
}

fn print_result(result: BenchResult) !void {
    const elapsed_seconds = @as(f64, @floatFromInt(result.elapsed_ns)) / std.time.ns_per_s;
    const ns_per_op = @as(f64, @floatFromInt(result.elapsed_ns)) /
        @as(f64, @floatFromInt(result.iterations));
    const ops_per_second = @as(f64, @floatFromInt(result.iterations)) / elapsed_seconds;

    std.debug.print(
        "{s}: iterations={d} total_ms={d:.3} ns_per_op={d:.1} ops_per_sec={d:.1}\n",
        .{
            result.name,
            result.iterations,
            @as(f64, @floatFromInt(result.elapsed_ns)) / std.time.ns_per_ms,
            ns_per_op,
            ops_per_second,
        },
    );
}
