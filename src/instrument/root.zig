//! Compile-time optional tracing. Public hooks contain only the inactive gate.
const std = @import("std");
const format = @import("format.zig");
const session = @import("session.zig");
const hooks = @import("hooks.zig");
pub const enabled = @import("../options.zig").options.instrument;
pub const TaskData = if (enabled) struct { id: u64 = 0, suspended: bool = false } else struct {};

pub inline fn active() bool {
    if (comptime !enabled) return false;
    return session.running.load(.monotonic);
}

// Lifecycle calls must run while inactive, to start a session and balance refs.
pub inline fn runtimeInit() void {
    if (comptime !enabled) return;
    session.acquire();
}
pub inline fn runtimeDeinit() void {
    if (comptime !enabled) return;
    session.release();
}
pub inline fn emit(comptime tag: format.EventTag, payload: format.Payload(tag)) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.emit(tag, payload);
}
pub inline fn executorRegister(executor: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.executorRegister(executor);
}
pub inline fn executorInit(executor: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.executorInit(executor);
}
pub inline fn executorExit(executor: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.executorExit(executor);
}
pub inline fn threadInit() void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.threadInit();
}
pub inline fn threadExit() void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.threadExit();
}
pub inline fn create(task: anytype, entry: u64, executor: u64, group: u64) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.create(task, entry, executor, group);
}
pub inline fn taskCreate(task: anytype, start: anytype, executor: u64, group: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.taskCreate(task, start, executor, group);
}
pub inline fn spawnFunction(func: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.spawnFunction(func);
}
pub inline fn clearSpawnFunction() void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.clearSpawnFunction();
}
pub inline fn parkBegin(duration: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.parkBegin(duration);
}
pub inline fn begin(task: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.begin(task);
}
pub inline fn end(task: anytype, reason: format.TaskEndReason) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.end(task, reason);
}
pub inline fn suspendTask(task: anytype, comptime mode: anytype, executor: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.suspendTask(task, mode, executor);
}
pub inline fn mainLeave(executor: anytype, mode: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.mainLeave(executor, mode);
}
pub inline fn mainReturn(executor: anytype, mode: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.mainReturn(executor, mode);
}
pub inline fn wake(task: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.wake(task);
}
pub inline fn pollBegin(should_poll: bool, duration: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.pollBegin(should_poll, duration);
}
pub inline fn pollEnd(should_poll: bool, timed_out: bool) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.pollEnd(should_poll, timed_out);
}
pub inline fn ioSubmit(completion: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.ioSubmit(completion);
}
pub inline fn ioComplete(completion: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.ioComplete(completion);
}
pub inline fn loopWake(loop: anytype, issued: bool) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.loopWake(loop, issued);
}
pub inline fn workEnd(work: anytype) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.workEnd(work);
}
pub const Zone = struct {
    id: if (enabled) u64 else void = if (enabled) 0 else {},
    pub inline fn end(self: Zone) void {
        if (comptime !enabled) return;
        if (!active()) {
            @branchHint(.likely);
            return;
        }
        hooks.zoneEnd(self.id);
    }
};
pub inline fn zone(comptime source: std.builtin.SourceLocation) Zone {
    if (comptime !enabled) return .{};
    if (!active()) {
        @branchHint(.likely);
        return .{};
    }
    return .{ .id = hooks.zone(source) };
}
pub inline fn message(text: []const u8) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.emit(.message, .{ .text = text });
}
pub inline fn plot(name: []const u8, value: i64) void {
    if (comptime !enabled) return;
    if (!active()) {
        @branchHint(.likely);
        return;
    }
    hooks.emit(.plot, .{ .name = name, .value = value });
}

/// The public `zio.instrument` namespace: user markers only. The runtime hooks
/// above are internal to zio.
pub const user = struct {
    pub const enabled = instrument.enabled;
    pub const active = instrument.active;
    pub const Zone = instrument.Zone;
    pub const zone = instrument.zone;
    pub const message = instrument.message;
    pub const plot = instrument.plot;
};
const instrument = @This();

test {
    if (enabled) {
        _ = @import("buffer.zig");
        _ = @import("hooks.zig");
        _ = @import("stack.zig");
    }
}
