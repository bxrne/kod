const std = @import("std");

const assert = std.debug.assert;

pub const TimerKind = enum(u8) {
    frame,
    render,
    poll,
    dispatch,
};

pub const CounterKind = enum(u8) {
    frame,
    render,
    event,
};

const timer_kind_count = std.meta.fields(TimerKind).len;
const counter_kind_count = std.meta.fields(CounterKind).len;

pub fn RuntimeInstrumentation(comptime enabled: bool) type {
    return struct {
        const Self = @This();

        timer_total_ns: [timer_kind_count]u64,
        timer_samples: [timer_kind_count]u64,
        counters: [counter_kind_count]u64,

        pub fn init() Self {
            return .{
                .timer_total_ns = [_]u64{0} ** timer_kind_count,
                .timer_samples = [_]u64{0} ** timer_kind_count,
                .counters = [_]u64{0} ** counter_kind_count,
            };
        }

        pub fn begin_timer(_: *Self, _: TimerKind) i128 {
            if (!enabled) {
                return 0;
            }
            return std.time.nanoTimestamp();
        }

        pub fn end_timer(self: *Self, kind: TimerKind, start_time_ns: i128) void {
            if (!enabled) {
                return;
            }

            const end_time_ns = std.time.nanoTimestamp();
            if (end_time_ns < start_time_ns) {
                return;
            }

            assert(start_time_ns >= 0);
            const delta_ns: u64 = @intCast(end_time_ns - start_time_ns);
            const index: usize = @intFromEnum(kind);
            self.timer_total_ns[index] += delta_ns;
            self.timer_samples[index] += 1;
        }

        pub fn increment_counter(self: *Self, kind: CounterKind) void {
            if (!enabled) {
                return;
            }

            const index: usize = @intFromEnum(kind);
            self.counters[index] += 1;
        }

        pub fn emit_summary(self: *const Self) void {
            if (!enabled) {
                return;
            }

            std.debug.print("\n=== Runtime Instrumentation ===\n", .{});
            std.debug.print("frames={d} renders={d} events={d}\n", .{
                self.counters[@intFromEnum(CounterKind.frame)],
                self.counters[@intFromEnum(CounterKind.render)],
                self.counters[@intFromEnum(CounterKind.event)],
            });

            emit_timer_line(self, .frame, "frame");
            emit_timer_line(self, .render, "render");
            emit_timer_line(self, .poll, "poll");
            emit_timer_line(self, .dispatch, "dispatch");
        }

        fn emit_timer_line(self: *const Self, kind: TimerKind, label: []const u8) void {
            const index: usize = @intFromEnum(kind);
            const sample_count = self.timer_samples[index];
            if (sample_count == 0) {
                std.debug.print("{s}: no samples\n", .{label});
                return;
            }

            const total_ns = self.timer_total_ns[index];
            const avg_ns = @divFloor(total_ns, sample_count);
            std.debug.print("{s}: samples={d} total_ms={d:.3} avg_us={d:.3}\n", .{
                label,
                sample_count,
                @as(f64, @floatFromInt(total_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(avg_ns)) / std.time.ns_per_us,
            });
        }
    };
}
