//! Compile-time optional tracing. Public hooks contain only the inactive gate.
const std = @import("std");
const format = @import("format.zig");
const session = @import("session.zig");
const hooks = @import("hooks.zig");
pub const enabled = @import("../options.zig").options.instrument;
pub const TaskData = if (enabled) struct { id: u64 = 0, needs_stack: bool = false } else struct {};
pub const ThreadData = if (enabled) struct { thread: ?*session.Thread = null } else struct {};

pub inline fn active() bool {
    if (comptime !enabled) return false;
    return session.class_mask.load(.monotonic) != 0;
}

inline fn selected(comptime tag: format.EventTag) bool {
    if (comptime !enabled) return false;
    const mask = comptime if (format.classOf(tag)) |class| class.mask() else format.all_classes;
    return session.class_mask.load(.monotonic) & mask != 0;
}

inline fn suspendSelected() bool {
    if (comptime !enabled) return false;
    return session.class_mask.load(.monotonic) &
        (format.EventClass.sched.mask() | format.EventClass.stacks.mask()) != 0;
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
    if (!selected(tag)) {
        @branchHint(.likely);
        return;
    }
    hooks.emit(tag, payload);
}
pub inline fn emitOn(executor: anytype, comptime tag: format.EventTag, payload: format.Payload(tag)) void {
    if (comptime !enabled) return;
    if (!selected(tag)) {
        @branchHint(.likely);
        return;
    }
    hooks.emitOn(executor, tag, payload);
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
pub inline fn parkBegin(executor: anytype, duration: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.park_begin)) {
        @branchHint(.likely);
        return;
    }
    hooks.parkBegin(executor, duration);
}
pub inline fn begin(task: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.task_begin)) {
        @branchHint(.likely);
        return;
    }
    hooks.begin(task);
}
pub inline fn beginOn(executor: anytype, task: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.task_begin)) {
        @branchHint(.likely);
        return;
    }
    hooks.beginOn(executor, task);
}
pub inline fn end(task: anytype, reason: format.TaskEndReason) void {
    if (comptime !enabled) return;
    if (!selected(.task_end)) {
        @branchHint(.likely);
        return;
    }
    hooks.end(task, reason);
}
pub inline fn endOn(executor: anytype, task: anytype, reason: format.TaskEndReason) void {
    if (comptime !enabled) return;
    if (!selected(.task_end)) {
        @branchHint(.likely);
        return;
    }
    hooks.endOn(executor, task, reason);
}
pub inline fn suspendTask(task: anytype, comptime mode: anytype, executor: anytype) void {
    if (comptime !enabled) return;
    if (!suspendSelected()) {
        @branchHint(.likely);
        return;
    }
    hooks.suspendTask(task, mode, executor);
}
pub inline fn mainLeave(executor: anytype, mode: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.task_end)) {
        @branchHint(.likely);
        return;
    }
    hooks.mainLeave(executor, mode);
}
pub inline fn mainReturn(executor: anytype, mode: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.task_begin)) {
        @branchHint(.likely);
        return;
    }
    hooks.mainReturn(executor, mode);
}
pub inline fn wake(task: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.task_wake)) {
        @branchHint(.likely);
        return;
    }
    hooks.wake(task);
}
pub inline fn pollBegin(loop: anytype, should_poll: bool, duration: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.poll_begin)) {
        @branchHint(.likely);
        return;
    }
    hooks.pollBegin(loop, should_poll, duration);
}
pub inline fn pollEnd(loop: anytype, should_poll: bool, timed_out: bool) void {
    if (comptime !enabled) return;
    if (!selected(.poll_end)) {
        @branchHint(.likely);
        return;
    }
    hooks.pollEnd(loop, should_poll, timed_out);
}
pub inline fn ioSubmit(loop: anytype, completion: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.io_submit)) {
        @branchHint(.likely);
        return;
    }
    hooks.ioSubmit(loop, completion);
}
pub inline fn ioComplete(loop: anytype, completion: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.io_complete)) {
        @branchHint(.likely);
        return;
    }
    hooks.ioComplete(loop, completion);
}
pub inline fn loopWake(loop: anytype, issued: bool) void {
    if (comptime !enabled) return;
    if (!selected(.loop_wake)) {
        @branchHint(.likely);
        return;
    }
    hooks.loopWake(loop, issued);
}
pub inline fn workEnd(work: anytype) void {
    if (comptime !enabled) return;
    if (!selected(.work_end)) {
        @branchHint(.likely);
        return;
    }
    hooks.workEnd(work);
}
pub const Zone = struct {
    id: if (enabled) u64 else void = if (enabled) 0 else {},
    pub inline fn end(self: Zone) void {
        if (comptime !enabled) return;
        if (!selected(.zone_end)) {
            @branchHint(.likely);
            return;
        }
        hooks.zoneEnd(self.id);
    }
};
pub inline fn zone(comptime source: std.builtin.SourceLocation) Zone {
    if (comptime !enabled) return .{};
    if (!selected(.zone_begin)) {
        @branchHint(.likely);
        return .{};
    }
    return .{ .id = hooks.zone(source) };
}
pub inline fn message(text: []const u8) void {
    if (comptime !enabled) return;
    if (!selected(.message)) {
        @branchHint(.likely);
        return;
    }
    hooks.emit(.message, .{ .text = text });
}
pub inline fn plot(name: []const u8, value: i64) void {
    if (comptime !enabled) return;
    if (!selected(.plot)) {
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
        _ = @import("classes.zig");
    }
}
