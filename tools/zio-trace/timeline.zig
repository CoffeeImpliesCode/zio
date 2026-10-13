const std = @import("std");
const session_mod = @import("session.zig");
const format = session_mod.format;
pub const State = enum { task, scheduler, poll_check, poll_wait, flush, work, idle, unknown };
pub const state_count = @typeInfo(State).@"enum".field_names.len;
pub const Slice = struct {
    thread: u64,
    start: f64,
    end: f64,
    kind: enum { task, state, park, zone },
    id: u64 = 0,
    state: State = .scheduler,
};
pub const Flow = struct { task: u64, source_thread: u64, target_thread: u64, start: f64, end: f64 };
pub const Thread = struct {
    info: format.record.Thread,
    metadata_known: bool = true,
    classes: ?u64 = null,
    durations: [state_count]f64 = @splat(0),
    first: ?f64 = null,
    last: f64 = 0,
    cursor_ns: ?f64 = null,
    has_thread_begin: bool = false,
    has_thread_end: bool = false,
    task: ?u64 = null,
    task_start: f64 = 0,
    poll: ?State = null,
    flush: bool = false,
    work_depth: usize = 0,
    park_start: ?f64 = null,
    steals: u64 = 0,
    parks: u64 = 0,
    state_slice: ?usize = null,

    pub fn kindName(self: Thread) []const u8 {
        return if (self.metadata_known) @tagName(self.info.kind) else "unknown";
    }

    pub fn hasClass(self: Thread, class: format.EventClass) bool {
        return if (self.classes) |mask| mask & class.mask() != 0 else false;
    }

    fn state(self: Thread) State {
        if (self.flush) return .flush;
        if (!self.metadata_known) return .unknown;
        return switch (self.info.kind) {
            .executor => self.poll orelse if (self.task != null)
                State.task
            else if (self.hasClass(.sched) and self.hasClass(.loop))
                State.scheduler
            else
                State.unknown,
            .blocking => if (!self.hasClass(.work))
                .unknown
            else if (self.work_depth != 0)
                .work
            else
                .idle,
            .other => .idle,
        };
    }

    pub fn unavailableReason(self: Thread) ?[]const u8 {
        if (!self.metadata_known) return "thread metadata missing";
        if (self.info.kind == .other) return "point events only";
        if (self.classes == null) return "recorded classes unknown";
        if (self.info.kind == .executor) {
            if (!self.hasClass(.sched)) return "sched not recorded";
            if (!self.hasClass(.loop)) return "loop not recorded";
        } else if (!self.hasClass(.work)) return "work not recorded";
        if (self.first == null or self.last <= self.first.?) return "no observed interval";
        return null;
    }

    pub fn busyPercent(self: Thread) ?f64 {
        if (self.unavailableReason() != null) return null;
        const wall = self.last - self.first.?;
        const busy = self.durations[@backingInt(State.task)] +
            self.durations[@backingInt(State.scheduler)] +
            self.durations[@backingInt(State.poll_check)] +
            self.durations[@backingInt(State.work)];
        return 100 * busy / wall;
    }
};
pub const Task = struct {
    id: u64,
    entry: u64 = 0,
    func: ?u64 = null,
    executor: u64 = 0,
    created: ?f64 = null,
    finished: ?f64 = null,
    first_suspend: ?format.AddrList = null,
    spawn_stack: ?format.AddrList = null,
    name: []const u8 = "",
    runs: std.ArrayList(f64) = .empty,
    run_total_ns: f64 = 0,
    wakes: std.ArrayList(f64) = .empty,
    pending_wake: ?struct { ns: f64, thread: u64 } = null,
};
pub const Samples = struct {
    values: std.ArrayList(f64) = .empty,
    pub fn add(self: *Samples, a: std.mem.Allocator, value: f64) !void {
        if (value >= 0) try self.values.append(a, value);
    }
};
pub const Zone = struct {
    name: []const u8 = "unknown zone",
    samples: Samples = .{},
    run_samples: Samples = .{},
    location: ?format.Payload(.srcloc) = null,
};
pub const Plot = struct { count: u64 = 0, min: i64 = std.math.maxInt(i64), max: i64 = std.math.minInt(i64), total: f64 = 0 };
const PendingIo = struct { ns: f64, kind: u64 };
const PendingWork = struct { queued: ?f64 = null, begin: ?struct { ns: f64, thread: u64 } = null };
const ZoneOwner = struct { task: bool, id: u64 };
const OpenZone = struct { srcloc: u64, ns: f64, thread: u64, run_ns: ?f64 };
pub const ZoneEvent = struct {
    thread: u64,
    ns: f64,
    task: u64,
    srcloc: u64,
    begin: bool,
};
pub const WorkSpan = struct {
    work: u64,
    begin_thread: u64,
    end_thread: u64,
    start: f64,
    end: f64,
    canceled: bool,
    physical: bool,
};
pub const IoStats = [std.enums.values(format.IoResult).len]Samples;
pub const Model = struct {
    session: session_mod.Session,
    threads: std.ArrayList(Thread) = .empty,
    thread_indices: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    tasks: std.AutoHashMapUnmanaged(u64, Task) = .empty,
    slices: std.ArrayList(Slice) = .empty,
    flows: std.ArrayList(Flow) = .empty,
    io_stats: std.AutoHashMapUnmanaged(u64, IoStats) = .empty,
    zones: std.AutoHashMapUnmanaged(u64, Zone) = .empty,
    zone_stacks: std.AutoHashMapUnmanaged(ZoneOwner, std.ArrayList(OpenZone)) = .empty,
    zone_events: std.ArrayList(ZoneEvent) = .empty,
    plots: std.StringHashMapUnmanaged(Plot) = .empty,
    work_wait: Samples = .{},
    work_run: Samples = .{},
    work_spans: std.ArrayList(WorkSpan) = .empty,
    missing_threads: usize = 0,
    pending_io: usize = 0,
    io_pair_errors: usize = 0,
    incomplete_slices: usize = 0,
    task_pair_errors: usize = 0,

    pub fn thread(self: *const Model, id: u64) ?*const Thread {
        return &self.threads.items[self.thread_indices.get(id) orelse return null];
    }

    pub fn build(a: std.mem.Allocator, session: session_mod.Session) !Model {
        var self: Model = .{ .session = session };
        var threads = session.threads.valueIterator();
        while (threads.next()) |info| try self.threads.append(a, .{
            .info = info.*,
            .classes = session.classMask(),
        });
        for (self.threads.items, 0..) |t, i| try self.thread_indices.put(a, t.info.thread, i);
        for (session.events.items) |event| {
            if (self.thread_indices.contains(event.thread)) continue;
            try self.thread_indices.put(a, event.thread, self.threads.items.len);
            try self.threads.append(a, .{
                .info = .{
                    .thread = event.thread,
                    .os_tid = 0,
                    .kind = .other,
                    .executor = format.no_executor,
                    .name = "",
                },
                .metadata_known = false,
                .classes = session.classMask(),
            });
            self.missing_threads += 1;
        }
        std.mem.sort(Thread, self.threads.items, {}, threadLess);
        for (self.threads.items, 0..) |t, i| try self.thread_indices.put(a, t.info.thread, i);
        // Lifecycle markers take precedence even if a damaged file has events outside them.
        // Older traces retain first/last-event bounds independently for each missing marker.
        for (session.events.items) |event| {
            const index = self.thread_indices.get(event.thread).?;
            const t = &self.threads.items[index];
            if (t.first == null) t.first = event.ns;
            if (event.event == .thread_begin and !t.has_thread_begin) {
                t.first = event.ns;
                t.has_thread_begin = true;
            }
            if (!t.has_thread_end or event.event == .thread_end) t.last = event.ns;
            if (event.event == .thread_end) t.has_thread_end = true;
        }
        var pending_io: std.AutoHashMapUnmanaged(u64, PendingIo) = .empty;
        var pending_work: std.AutoHashMapUnmanaged(u64, PendingWork) = .empty;
        for (session.events.items) |event| {
            const index = self.thread_indices.get(event.thread).?;
            const t = &self.threads.items[index];
            const now = event.ns;
            const previous = t.cursor_ns orelse now;
            const interval_start = @max(previous, t.first.?);
            const interval_end = @min(now, t.last);
            if (interval_end > interval_start and (t.info.kind != .other or !t.metadata_known)) {
                const state = t.state();
                t.durations[@backingInt(state)] += interval_end - interval_start;
                var merged = false;
                if (t.state_slice) |slice_index| {
                    const slice = &self.slices.items[slice_index];
                    if (slice.state == state and slice.end == interval_start) {
                        slice.end = interval_end;
                        merged = true;
                    }
                }
                if (!merged) {
                    t.state_slice = self.slices.items.len;
                    try self.slices.append(a, .{
                        .thread = event.thread,
                        .start = interval_start,
                        .end = interval_end,
                        .kind = .state,
                        .state = state,
                    });
                }
            }
            t.cursor_ns = now;
            if (format.classOf(std.meta.activeTag(event.event))) |class| {
                if (!session.hasClass(class)) continue;
            }
            switch (event.event) {
                .task_create => |v| {
                    const task = try self.getTask(a, v.task);
                    task.entry = v.entry;
                    task.executor = v.executor;
                    task.created = now;
                },
                .task_func => |v| (try self.getTask(a, v.task)).func = v.func,
                .task_stack => |v| {
                    const task = try self.getTask(a, v.task);
                    switch (v.kind) {
                        .first_suspend => task.first_suspend = v.frames,
                        .spawn => task.spawn_stack = v.frames,
                    }
                },
                .task_begin => |v| {
                    if (t.task != null) self.incomplete_slices += 1;
                    t.task = v.task;
                    t.task_start = now;
                    const task = try self.getTask(a, v.task);
                    if (task.pending_wake) |wake| {
                        if (now >= wake.ns) {
                            try task.wakes.append(a, now - wake.ns);
                            try self.flows.append(a, .{ .task = v.task, .source_thread = wake.thread, .target_thread = event.thread, .start = wake.ns, .end = now });
                        }
                        task.pending_wake = null;
                    }
                },
                .task_end => |v| {
                    if (t.task) |id| {
                        const task = try self.getTask(a, id);
                        try task.runs.append(a, now - t.task_start);
                        task.run_total_ns += now - t.task_start;
                        try self.slices.append(a, .{
                            .thread = event.thread,
                            .start = t.task_start,
                            .end = now,
                            .kind = .task,
                            .id = id,
                        });
                        t.task = null;
                        if (v.reason == .finish) task.finished = now;
                    } else {
                        self.task_pair_errors += 1;
                    }
                },
                .task_wake => |v| {
                    const task = try self.getTask(a, v.task);
                    // Duplicate notifications do not restart an already pending wake.
                    if (task.pending_wake == null) task.pending_wake = .{ .ns = now, .thread = event.thread };
                },
                .poll_begin => |v| t.poll = if (v.timeout_ns == 0) .poll_check else .poll_wait,
                .poll_end => t.poll = null,
                .flush_begin => t.flush = true,
                .flush_end => t.flush = false,
                .park_begin => {
                    t.parks += 1;
                    t.park_start = now;
                },
                .park_end => {
                    if (t.park_start) |start| try self.slices.append(a, .{ .thread = event.thread, .start = start, .end = now, .kind = .park });
                    t.park_start = null;
                },
                .steal => |v| t.steals += v.count,
                .io_submit => |v| {
                    const pending = try pending_io.getOrPut(a, v.op);
                    if (pending.found_existing) self.io_pair_errors += 1;
                    pending.value_ptr.* = .{ .ns = now, .kind = v.kind };
                },
                .io_complete => |v| {
                    if (pending_io.fetchRemove(v.op)) |pending| {
                        const stats = try self.io_stats.getOrPut(a, pending.value.kind);
                        if (!stats.found_existing) stats.value_ptr.* = @splat(.{});
                        try stats.value_ptr[@backingInt(v.result)].add(a, now - pending.value.ns);
                    } else self.io_pair_errors += 1;
                },
                .work_queue => |v| try pending_work.put(a, v.work, .{ .queued = now }),
                .work_begin => |v| {
                    if (t.metadata_known and t.info.kind == .blocking) t.work_depth += 1;
                    const pending = try pending_work.getOrPut(a, v.work);
                    if (!pending.found_existing) pending.value_ptr.* = .{};
                    pending.value_ptr.begin = .{ .ns = now, .thread = event.thread };
                    if (pending.value_ptr.queued) |queued| try self.work_wait.add(a, now - queued);
                },
                .work_end => |v| {
                    if (pending_work.fetchRemove(v.work)) |pending| if (pending.value.begin) |begin| {
                        const worker = &self.threads.items[self.thread_indices.get(begin.thread).?];
                        const physical = worker.metadata_known and worker.info.kind == .blocking and
                            begin.thread == event.thread;
                        if (worker.metadata_known and worker.info.kind == .blocking)
                            worker.work_depth -|= 1;
                        try self.work_run.add(a, now - begin.ns);
                        try self.work_spans.append(a, .{
                            .work = v.work,
                            .begin_thread = begin.thread,
                            .end_thread = event.thread,
                            .start = begin.ns,
                            .end = now,
                            .canceled = v.canceled,
                            .physical = physical,
                        });
                    };
                },
                .srcloc => |v| {
                    const zone = try self.getZone(a, v.srcloc);
                    zone.name = if (v.name.len > 0) v.name else v.function;
                    zone.location = v;
                },
                .zone_begin => |v| {
                    if (!session.hasClass(.sched)) continue;
                    const owner: ZoneOwner = .{
                        .task = t.task != null,
                        .id = t.task orelse event.thread,
                    };
                    const stack = try self.zone_stacks.getOrPut(a, owner);
                    if (!stack.found_existing) stack.value_ptr.* = .empty;
                    _ = try self.getZone(a, v.srcloc);
                    try stack.value_ptr.append(a, .{
                        .srcloc = v.srcloc,
                        .ns = now,
                        .thread = event.thread,
                        .run_ns = if (t.task) |id|
                            (try self.getTask(a, id)).run_total_ns + now - t.task_start
                        else
                            null,
                    });
                    if (owner.task) try self.zone_events.append(a, .{
                        .thread = event.thread,
                        .ns = now,
                        .task = owner.id,
                        .srcloc = v.srcloc,
                        .begin = true,
                    });
                },
                .zone_end => |v| {
                    if (!session.hasClass(.sched)) continue;
                    const owner: ZoneOwner = .{
                        .task = t.task != null,
                        .id = t.task orelse event.thread,
                    };
                    if (self.zone_stacks.getPtr(owner)) |stack| {
                        if (stack.items.len == 0) continue;
                        const opened = stack.items[stack.items.len - 1];
                        // Bad nesting leaves the unmatched begin visible as incomplete.
                        if (opened.srcloc != v.srcloc) continue;
                        _ = stack.pop();
                        const zone = try self.getZone(a, v.srcloc);
                        try zone.samples.add(a, now - opened.ns);
                        if (opened.run_ns) |run_ns| {
                            const task = try self.getTask(a, owner.id);
                            try zone.run_samples.add(a, task.run_total_ns + now - t.task_start - run_ns);
                        }
                        if (owner.task) {
                            try self.zone_events.append(a, .{
                                .thread = event.thread,
                                .ns = now,
                                .task = owner.id,
                                .srcloc = v.srcloc,
                                .begin = false,
                            });
                        } else {
                            try self.slices.append(a, .{
                                .thread = opened.thread,
                                .start = opened.ns,
                                .end = now,
                                .kind = .zone,
                                .id = v.srcloc,
                            });
                        }
                    }
                },
                .plot => |v| {
                    const plot = try self.plots.getOrPut(a, v.name);
                    if (!plot.found_existing) plot.value_ptr.* = .{};
                    plot.value_ptr.count += 1;
                    plot.value_ptr.min = @min(plot.value_ptr.min, v.value);
                    plot.value_ptr.max = @max(plot.value_ptr.max, v.value);
                    plot.value_ptr.total += @floatFromInt(v.value);
                },
                else => {},
            }
        }
        for (self.threads.items) |t| {
            if (t.task != null) self.incomplete_slices += 1;
            if (t.poll != null) self.incomplete_slices += 1;
            if (t.flush) self.incomplete_slices += 1;
            if (t.park_start != null) self.incomplete_slices += 1;
        }
        self.pending_io = pending_io.count();
        self.incomplete_slices += pending_work.count();
        var stacks = self.zone_stacks.valueIterator();
        while (stacks.next()) |stack| self.incomplete_slices += stack.items.len;
        return self;
    }

    fn getTask(self: *Model, a: std.mem.Allocator, id: u64) !*Task {
        const entry = try self.tasks.getOrPut(a, id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = id };
        return entry.value_ptr;
    }
    fn getZone(self: *Model, a: std.mem.Allocator, key: u64) !*Zone {
        const entry = try self.zones.getOrPut(a, key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }
    fn threadLess(_: void, lhs: Thread, rhs: Thread) bool {
        return lhs.info.thread < rhs.info.thread;
    }
};
