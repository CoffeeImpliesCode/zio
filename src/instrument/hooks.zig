//! Active trace bodies, deliberately kept out of scheduler/coroutine hot paths.
const std = @import("std");
const format = @import("format.zig");
const session = @import("session.zig");
const stack = @import("stack.zig");

pub const BlockingScopeData = struct {
    task: u64 = 0,
    parent: u64 = 0,
    previous_running: u64 = 0,
    coroutine: ?*@import("../task.zig").AnyTask = null,
};

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
    executor.instr.thread = session.enterThread(.executor, executor.id);
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
    if (executor.instr.thread) |thread| {
        if (thread.classes & format.EventClass.io.mask() != 0) {
            // Loop teardown retires these internal operations without callbacks.
            inline for (.{ &executor.shutdown.c, &executor.stack_pool_shrink_timer.c }) |completion| {
                if (completion.loadState().phase == .running)
                    thread.emit(.io_complete, .{ .op = @intFromPtr(completion), .result = .canceled });
            }
        }
    }
    session.exitThread();
}
pub noinline fn threadInit() void {
    _ = session.enterThread(.blocking, format.no_executor);
}
pub noinline fn threadExit() void {
    session.exitThread();
}
pub noinline fn create(task: anytype, entry: u64, executor: u64, group: u64) void {
    const producer = session.getThread(.other, format.no_executor);
    task.instr.id = if (producer) |thread| thread.nextTaskId() else session.unrecordedTaskId();
    if (comptime @hasField(@TypeOf(task.instr), "running_id"))
        task.instr.running_id.store(task.instr.id, .monotonic);
    const thread = producer orelse return;
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
inline fn beginOnThread(thread: *session.Thread, task: u64) void {
    std.debug.assert(task != 0);
    std.debug.assert(thread.current == 0);
    thread.current = task;
    thread.emit(.task_begin, .{ .task = task });
}

pub noinline fn blockingBegin(task: anytype) BlockingScopeData {
    const thread = session.getThread(.other, format.no_executor) orelse return .{};
    const coroutine = if (@import("../runtime.zig").getCurrentExecutorOrNull()) |executor|
        executor.current_task
    else
        null;
    const scope: BlockingScopeData = .{
        .task = task.instr.id,
        .parent = thread.current,
        .previous_running = if (coroutine) |c| c.instr.running_id.load(.monotonic) else 0,
        .coroutine = coroutine,
    };
    if (coroutine) |c| {
        if (c.instr.needs_stack and scope.parent == c.instr.id)
            firstSuspend(thread, c);
        c.instr.running_id.store(scope.task, .monotonic);
    }
    endOnThread(thread, scope.parent, .wait);
    beginOnThread(thread, scope.task);
    return scope;
}

pub noinline fn blockingEnd(scope: BlockingScopeData) void {
    // Inline work can suspend and migrate. Never retain its original producer.
    const thread = session.getThread(.other, format.no_executor) orelse return;
    endOnThread(thread, scope.task, .finish);
    if (scope.coroutine) |c| c.instr.running_id.store(scope.previous_running, .monotonic);
    if (scope.parent != 0) beginOnThread(thread, scope.parent);
}
pub noinline fn beginOn(executor: anytype, task: anytype) void {
    const thread = executor.instr.thread orelse return;
    beginOnThread(thread, task.instr.running_id.load(.monotonic));
}
inline fn endOnThread(thread: *session.Thread, task: u64, reason: format.TaskEndReason) void {
    if (thread.current != task or task == 0) return;
    // Only scheduler-selected begin hooks mount `current`; no second mask load.
    thread.emit(.task_end, .{ .reason = reason });
    thread.current = 0;
}
pub noinline fn endOn(executor: anytype, task: anytype, reason: format.TaskEndReason) void {
    const thread = executor.instr.thread orelse return;
    endOnThread(thread, task.instr.running_id.load(.monotonic), reason);
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
    endOnThread(thread, task.instr.running_id.load(.monotonic), if (mode == .park) .wait else .yield);
}
pub noinline fn mainLeave(executor: anytype, mode: anytype) void {
    if (mode != .until_stopped) endOn(executor, &executor.main_task, .wait);
}
pub noinline fn mainReturn(executor: anytype, mode: anytype) void {
    if (mode != .until_stopped) beginOn(executor, &executor.main_task);
}
pub noinline fn wake(task: anytype) void {
    emit(.task_wake, .{ .task = task.instr.running_id.load(.monotonic) });
}
pub noinline fn pollBegin(loop: anytype, should_poll: bool, duration: anytype) void {
    const thread = loopThread(loop) orelse return;
    if (should_poll) thread.emit(.poll_begin, .{ .timeout_ns = if (duration.value == @import("../time.zig").Duration.max.value) format.infinite_timeout else @intCast(@max(duration.value, 0)) });
}
pub noinline fn pollEnd(loop: anytype, should_poll: bool, timed_out: bool) void {
    const thread = loopThread(loop) orelse return;
    if (should_poll) thread.emit(.poll_end, .{ .timed_out = timed_out });
}
pub noinline fn ioSubmit(completion: anytype) void {
    // Timers can be armed from another thread; only the caller owns this producer.
    const thread = session.getThread(.other, format.no_executor) orelse return;
    thread.emit(.io_submit, .{ .op = @intFromPtr(completion), .kind = @backingInt(completion.op) });
}
pub noinline fn ioComplete(completion: anytype) void {
    const thread = session.getThread(.other, format.no_executor) orelse return;
    thread.emit(.io_complete, .{ .op = @intFromPtr(completion), .result = if (completion.err) |err| (if (err == error.Canceled) .canceled else .err) else .ok });
}
pub noinline fn ioDiscard(completion: anytype) void {
    const thread = session.getThread(.other, format.no_executor) orelse return;
    thread.emit(.io_complete, .{ .op = @intFromPtr(completion), .result = .canceled });
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

fn testInlineInner() !void {
    const span = @import("root.zig").zone(@src());
    defer span.end();
    try @import("../zio.zig").sleep(.fromMilliseconds(1));
}

fn testInlineOuter(runtime: *@import("../runtime.zig").Runtime) !void {
    const span = @import("root.zig").zone(@src());
    defer span.end();
    var inner = try runtime.spawnBlocking(testInlineInner, .{});
    defer inner.cancel();
    try inner.join();
}

fn testInlineCaller(runtime: *@import("../runtime.zig").Runtime) !void {
    const span = @import("root.zig").zone(@src());
    defer span.end();
    var outer = try runtime.spawnBlocking(testInlineOuter, .{runtime});
    defer outer.cancel();
    try outer.join();
}

// Exercise the real inline pool and a timer suspension, then decode its output.
test "instrument inline blocking tasks retain nested ownership across suspension" {
    if (@import("builtin").os.tag != .linux or !@import("root.zig").enabled)
        return error.SkipZigTest;
    const runtime = try @import("../runtime.zig").Runtime.init(std.testing.allocator, .{
        .thread_pool = .{ .min_threads = 0, .max_threads = 0 },
    });
    var initialized = true;
    defer if (initialized) runtime.deinit();
    const required = format.EventClass.sched.mask() | format.EventClass.user.mask();
    if (session.class_mask.load(.monotonic) & required != required)
        return error.SkipZigTest;
    const thread = runtime.main_executor.instr.thread.?;
    var path_buffer: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "/proc/self/fd/{d}", .{thread.fd}, 0);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var caller = try runtime.spawn(testInlineCaller, .{runtime});
    try caller.join();
    caller.cancel();
    runtime.deinit();
    initialized = false;

    const length = std.c.lseek(fd, 0, std.c.SEEK.END);
    try std.testing.expect(length > 0);
    try std.testing.expectEqual(@as(std.c.off_t, 0), std.c.lseek(fd, 0, std.c.SEEK.SET));
    const bytes = try std.testing.allocator.alloc(u8, @intCast(length));
    defer std.testing.allocator.free(bytes);
    var read_len: usize = 0;
    while (read_len < bytes.len) {
        const n = std.c.read(fd, bytes.ptr + read_len, bytes.len - read_len);
        try std.testing.expect(n > 0);
        read_len += @intCast(n);
    }
    var file = try format.FileReader.init(bytes);
    var current: u64 = 0;
    var created: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer created.deinit(std.testing.allocator);
    var finished: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer finished.deinit(std.testing.allocator);
    var zones: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    defer zones.deinit(std.testing.allocator);
    var zone_pairs: usize = 0;
    while (try file.next()) |record| {
        if (record.kind != .chunk) continue;
        var events = (try format.parseChunk(record.payload)).iterator();
        while (try events.next()) |event| {
            switch (event.event) {
                .task_create => |v| if (v.entry != 0) {
                    try created.put(std.testing.allocator, v.task, {});
                },
                .task_begin => |v| {
                    try std.testing.expectEqual(@as(u64, 0), current);
                    current = v.task;
                },
                .task_end => |v| {
                    try std.testing.expect(current != 0);
                    if (v.reason == .finish)
                        try finished.put(std.testing.allocator, current, {});
                    current = 0;
                },
                .zone_begin => {
                    try std.testing.expect(current != 0);
                    const depth = try zones.getOrPut(std.testing.allocator, current);
                    if (!depth.found_existing) depth.value_ptr.* = 0;
                    depth.value_ptr.* += 1;
                },
                .zone_end => {
                    const depth = zones.getPtr(current) orelse return error.StrayZoneEnd;
                    try std.testing.expect(depth.* != 0);
                    depth.* -= 1;
                    zone_pairs += 1;
                },
                else => {},
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 0), current);
    try std.testing.expectEqual(@as(usize, 3), created.count());
    var tasks = created.keyIterator();
    while (tasks.next()) |id| try std.testing.expect(finished.contains(id.*));
    var depths = zones.valueIterator();
    while (depths.next()) |depth| try std.testing.expectEqual(@as(usize, 0), depth.*);
    try std.testing.expectEqual(@as(usize, 3), zone_pairs);
}
