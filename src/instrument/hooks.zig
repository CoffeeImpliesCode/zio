//! Active trace bodies, deliberately kept out of scheduler/coroutine hot paths.
const std = @import("std");
const format = @import("format.zig");
const session = @import("session.zig");
const stack = @import("stack.zig");

pub noinline fn emit(comptime tag: format.EventTag, payload: format.Payload(tag)) void {
    const thread = session.getThread(.other, format.no_executor) orelse return;
    thread.emit(tag, payload);
}
pub noinline fn emitOn(executor: anytype, comptime tag: format.EventTag, payload: format.Payload(tag)) void {
    const thread = executor.instr.thread orelse return;
    thread.emit(tag, payload);
}

inline fn loopThread(loop: anytype) ?*session.Thread {
    return loop.instr.thread orelse session.getThread(.other, format.no_executor);
}
pub noinline fn executorRegister(executor: anytype) void {
    executor.instr.thread = session.getThread(.executor, executor.id);
}
pub noinline fn executorInit(executor: anytype) void {
    const thread = executor.instr.thread orelse return;
    executor.loop.instr.thread = thread;
    if (thread.classes & format.EventClass.sched.mask() != 0)
        thread.emit(.executor_info, .{ .executor = executor.id, .loop = @intFromPtr(&executor.loop) });
    create(&executor.main_task, 0, executor.id, 0);
    if (thread.classes & format.EventClass.sched.mask() != 0 and executor.runtime.options.enable_main_executor and executor == &executor.runtime.main_executor)
        beginOn(executor, &executor.main_task);
}
pub noinline fn executorExit(executor: anytype) void {
    endOn(executor, &executor.main_task, .finish);
    session.exitThread();
}
pub noinline fn threadInit() void {
    _ = session.getThread(.blocking, format.no_executor);
}
pub noinline fn threadExit() void {
    session.exitThread();
}
pub noinline fn create(task: anytype, entry: u64, executor: u64, group: u64) void {
    const thread = session.getThread(.other, format.no_executor) orelse return;
    task.instr.id = thread.nextTaskId();
    const func = thread.spawn_func;
    thread.spawn_func = 0;
    task.instr.needs_stack = needsStack(entry, func) and thread.classes & format.EventClass.stacks.mask() != 0;
    if (thread.classes & format.EventClass.sched.mask() != 0) {
        thread.emit(.task_create, .{ .task = task.instr.id, .entry = entry, .executor = executor, .parent = thread.current, .group = group });
        if (func != 0) thread.emit(.task_func, .{ .task = task.instr.id, .func = func });
    }
    if (task.instr.needs_stack) {
        var frames: [16]usize = undefined;
        const count = stack.capture(thread.stack_bounds, &frames);
        thread.emit(.task_stack, .{ .task = task.instr.id, .kind = .spawn, .frames = .{ .items = frames[0..count] } });
    }
}
pub noinline fn taskCreate(task: anytype, start: anytype, executor: u64, group: anytype) void {
    create(task, switch (start) {
        inline else => |func| @intFromPtr(func),
    }, executor, if (group) |g| @intFromPtr(g) else 0);
}
pub noinline fn spawnFunction(func: anytype) void {
    const thread = session.getThread(.other, format.no_executor) orelse return;
    thread.spawn_func = @intFromPtr(func);
}
pub noinline fn clearSpawnFunction() void {
    const thread = session.getThread(.other, format.no_executor) orelse return;
    thread.spawn_func = 0;
}
pub noinline fn parkBegin(executor: anytype, duration: anytype) void {
    emitOn(executor, .park_begin, .{ .kind = if (duration.value == 0) .probe else if (duration.value == @import("../time.zig").Duration.max.value) .full else .baton });
}
pub noinline fn begin(task: anytype) void {
    const thread = session.getThread(.other, format.no_executor) orelse return;
    thread.current = task.instr.id;
    thread.emit(.task_begin, .{ .task = task.instr.id });
}
pub noinline fn beginOn(executor: anytype, task: anytype) void {
    const thread = executor.instr.thread orelse return;
    thread.current = task.instr.id;
    thread.emit(.task_begin, .{ .task = task.instr.id });
}
inline fn endOnThread(thread: *session.Thread, task: u64, reason: format.TaskEndReason) void {
    if (thread.current != task or task == 0) return;
    // Only scheduler-selected begin hooks mount `current`; no second mask load.
    thread.emit(.task_end, .{ .reason = reason });
    thread.current = 0;
}
pub noinline fn end(task: anytype, reason: format.TaskEndReason) void {
    const thread = session.getThread(.other, format.no_executor) orelse return;
    endOnThread(thread, task.instr.id, reason);
}
pub noinline fn endOn(executor: anytype, task: anytype, reason: format.TaskEndReason) void {
    const thread = executor.instr.thread orelse return;
    endOnThread(thread, task.instr.id, reason);
}
noinline fn firstSuspend(thread: *session.Thread, task: anytype) void {
    task.instr.needs_stack = false;
    var frames: [32]usize = undefined;
    const count = stack.capture(thread.stack_bounds, &frames);
    thread.emit(.task_stack, .{ .task = task.instr.id, .kind = .first_suspend, .frames = .{ .items = frames[0..count] } });
}
pub noinline fn suspendTask(task: anytype, comptime mode: anytype, executor: anytype) void {
    const thread = executor.instr.thread orelse return;
    if (task.instr.needs_stack) {
        @branchHint(.unlikely);
        firstSuspend(thread, task);
    }
    endOnThread(thread, task.instr.id, if (mode == .park) .wait else .yield);
}
pub noinline fn mainLeave(executor: anytype, mode: anytype) void {
    if (mode != .until_stopped) endOn(executor, &executor.main_task, .wait);
}
pub noinline fn mainReturn(executor: anytype, mode: anytype) void {
    if (mode != .until_stopped) beginOn(executor, &executor.main_task);
}
pub noinline fn wake(task: anytype) void {
    emit(.task_wake, .{ .task = task.instr.id });
}
pub noinline fn pollBegin(loop: anytype, should_poll: bool, duration: anytype) void {
    const thread = loopThread(loop) orelse return;
    if (should_poll) thread.emit(.poll_begin, .{ .timeout_ns = if (duration.value == @import("../time.zig").Duration.max.value) format.infinite_timeout else @intCast(@max(duration.value, 0)) });
}
pub noinline fn pollEnd(loop: anytype, should_poll: bool, timed_out: bool) void {
    const thread = loopThread(loop) orelse return;
    if (should_poll) thread.emit(.poll_end, .{ .timed_out = timed_out });
}
pub noinline fn ioSubmit(loop: anytype, completion: anytype) void {
    const thread = loopThread(loop) orelse return;
    thread.emit(.io_submit, .{ .op = @intFromPtr(completion), .kind = @backingInt(completion.op) });
}
pub noinline fn ioComplete(loop: anytype, completion: anytype) void {
    const thread = loopThread(loop) orelse return;
    thread.emit(.io_complete, .{ .op = @intFromPtr(completion), .result = if (completion.err) |err| (if (err == error.Canceled) .canceled else .err) else .ok });
}
pub noinline fn loopWake(loop: anytype, issued: bool) void {
    if (issued) emit(.loop_wake, .{ .loop = @intFromPtr(loop) });
}
pub noinline fn workEnd(work: anytype) void {
    emit(.work_end, .{ .work = @intFromPtr(work), .canceled = workCanceled(work) });
}
fn workCanceled(work: anytype) bool {
    const token = work.cancel_token orelse return false;
    return switch (token.state.load(.monotonic)) {
        .canceled, .blocked_canceling => true,
        .idle, .blocked => false,
    };
}
pub noinline fn zoneEnd(id: u64) void {
    if (id != 0) emit(.zone_end, .{ .srcloc = id });
}
pub noinline fn zone(comptime source: std.builtin.SourceLocation) u64 {
    const Location = struct {
        const value = source;
    };
    const id = @intFromPtr(&Location.value);
    const thread = session.getThread(.other, format.no_executor) orelse return 0;
    if (!thread.defineSource(id, source)) return 0;
    thread.emit(.zone_begin, .{ .srcloc = id });
    return id;
}
test "instrument blocking work retains acknowledged cancellation" {
    if (!@import("../os/syscall_cancel.zig").enabled) return error.SkipZigTest;
    var token: @import("../os/syscall_cancel.zig").Token = .{};
    const work = .{ .cancel_token = @as(?*@TypeOf(token), &token) };
    try std.testing.expect(!workCanceled(work));
    _ = token.cancel();
    try std.testing.expect(workCanceled(work));
}

fn needsStack(entry: u64, func: u64) bool {
    return entry != 0 and func == 0;
}

test "instrument stacks are only needed for unknown non-main entries" {
    try std.testing.expect(!needsStack(100, 200));
    try std.testing.expect(!needsStack(0, 0));
    try std.testing.expect(needsStack(100, 0));
}
