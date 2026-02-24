const std = @import("std");
const testing = std.testing;

const assert = std.debug.assert;

/// NOTE: Compile-time generic finite state machine. Parameterised by a state
/// enum so that transitions are type-safe and @intFromEnum boilerplate is
/// eliminated. Rules are passed by pointer so they live in static storage and
/// the machine itself stays small (one enum field).
pub fn StateMachine(comptime State: type) type {
    comptime {
        assert(@typeInfo(State) == .@"enum");
    }

    const state_count = @typeInfo(State).@"enum".fields.len;

    return struct {
        state: State,

        const Self = @This();

        /// Transition rule table: maps each state to its valid targets.
        pub const Rules = [state_count][]const State;

        pub fn init(initial: State) Self {
            return .{ .state = initial };
        }

        /// Attempt to move to `target`. Returns true only when the
        /// transition is permitted by `rules`.
        pub fn transition(self: *Self, rules: *const Rules, target: State) bool {
            const from = @intFromEnum(self.state);
            assert(from < state_count);

            const allowed = rules[from];
            for (allowed) |valid| {
                if (valid == target) {
                    self.state = target;
                    return true;
                }
            }
            return false;
        }

        /// Read current state without mutation.
        pub fn get(self: *const Self) State {
            return self.state;
        }
    };
}

// Tests

const TestState = enum(u32) { idle, running, stopped };

const test_rules = StateMachine(TestState).Rules{
    &.{.running}, // idle    -> running
    &.{ .stopped, .idle }, // running -> stopped | idle
    &.{}, // stopped -> (terminal)
};

test "valid transition updates state" {
    var m = StateMachine(TestState).init(.idle);

    try testing.expect(m.transition(&test_rules, .running));
    try testing.expectEqual(TestState.running, m.get());
}

test "invalid transition leaves state unchanged" {
    var m = StateMachine(TestState).init(.idle);

    try testing.expect(!m.transition(&test_rules, .stopped));
    try testing.expectEqual(TestState.idle, m.get());
}

test "terminal state rejects all transitions" {
    var m = StateMachine(TestState).init(.idle);

    try testing.expect(m.transition(&test_rules, .running));
    try testing.expect(m.transition(&test_rules, .stopped));
    // Stopped is terminal: no outgoing edges.
    try testing.expect(!m.transition(&test_rules, .idle));
    try testing.expect(!m.transition(&test_rules, .running));
    try testing.expectEqual(TestState.stopped, m.get());
}

test "cyclic transition" {
    var m = StateMachine(TestState).init(.idle);

    try testing.expect(m.transition(&test_rules, .running));
    try testing.expect(m.transition(&test_rules, .idle));
    try testing.expectEqual(TestState.idle, m.get());
}

test "self-transition rejected when not in rules" {
    var m = StateMachine(TestState).init(.idle);

    try testing.expect(!m.transition(&test_rules, .idle));
    try testing.expectEqual(TestState.idle, m.get());
}

test "init sets correct initial state" {
    const m = StateMachine(TestState).init(.running);
    try testing.expectEqual(TestState.running, m.get());
}

test "multiple sequential transitions" {
    var m = StateMachine(TestState).init(.idle);

    try testing.expect(m.transition(&test_rules, .running));
    try testing.expect(m.transition(&test_rules, .idle));
    try testing.expect(m.transition(&test_rules, .running));
    try testing.expect(m.transition(&test_rules, .stopped));
    try testing.expectEqual(TestState.stopped, m.get());
}

test "two-state toggle" {
    const Toggle = enum(u32) { off, on };
    const rules = StateMachine(Toggle).Rules{
        &.{.on}, // off -> on
        &.{.off}, // on  -> off
    };

    var m = StateMachine(Toggle).init(.off);

    try testing.expect(m.transition(&rules, .on));
    try testing.expect(m.transition(&rules, .off));
    try testing.expect(m.transition(&rules, .on));
    try testing.expectEqual(Toggle.on, m.get());
}

test "get returns current state" {
    var m = StateMachine(TestState).init(.running);
    try testing.expectEqual(TestState.running, m.get());
    _ = m.transition(&test_rules, .stopped);
    try testing.expectEqual(TestState.stopped, m.get());
}

test "invalid transition from idle" {
    var m = StateMachine(TestState).init(.idle);
    try testing.expect(!m.transition(&test_rules, .idle));
    try testing.expect(!m.transition(&test_rules, .stopped));
    try testing.expectEqual(TestState.idle, m.get());
}

test "rules table length matches state count" {
    try testing.expectEqual(@as(usize, 3), test_rules.len);
}
