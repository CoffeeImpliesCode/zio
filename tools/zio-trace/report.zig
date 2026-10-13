const std = @import("std");
const timeline = @import("timeline.zig");
const Model = timeline.Model;
const Session = @import("session.zig").Session;
const Writer = std.Io.Writer;

pub fn info(w: *Writer, model: *const Model) !void {
    const session = model.session;
    try w.print("Session: {s}\nProcess: {d}\nClock: {s}; {d} calibration points; {d:.6} ns/tick\nDuration: {d:.3} ms\nFiles: {d}; events: {d}; drops: {d}; decode errors: {d}; incomplete slices: {d}\n", .{ session.path, session.header.pid, @tagName(session.header.clock), session.calibrations.items.len, session.clock.slope, (session.end_ns - session.start_ns) / 1e6, session.files, session.events.items.len, session.dropped, session.decode_errors, model.incomplete_slices });
    try w.print("Chunk sequence errors: {d}; task pairing errors: {d}\n", .{ session.sequence_errors, model.task_pair_errors });
    if (session.process) |process| try w.print("Executable: {s}\n", .{process.exe_path});
    try threadTable(w, model);
}

pub fn threadTable(w: *Writer, model: *const Model) !void {
    try w.writeAll("\nThread  kind       executor  tid       wall ms    busy %\n");
    for (model.threads.items) |thread| {
        try w.print("{d:<7} {s:<10} ", .{ thread.info.thread, @tagName(thread.info.kind) });
        if (thread.info.executor == @import("zio_trace_format").no_executor) try w.writeAll("-         ") else try w.print("{d:<9} ", .{thread.info.executor});
        try w.print("{d:<9} {d:>9.3} ", .{ thread.info.os_tid, (thread.last - (thread.first orelse thread.last)) / 1e6 });
        if (thread.info.kind == .other) try w.writeAll("       n/a (point events)\n") else try w.print("{d:>9.2}\n", .{thread.busyPercent()});
    }
}

const Group = struct {
    spawned: usize = 0,
    runs: timeline.Samples = .{},
    wakes: timeline.Samples = .{},
    lifetimes: timeline.Samples = .{},
};

pub fn stats(a: std.mem.Allocator, w: *Writer, model: *Model) !void {
    try info(w, model);
    try w.writeAll("\nThread states (ms; within observed thread lifetime):\n");
    for (model.threads.items) |thread| {
        try w.print("  thread {d}: ", .{thread.info.thread});
        inline for (@typeInfo(timeline.State).@"enum".field_names, 0..) |name, i| try w.print("{s}={d:.3} ", .{ name, thread.durations[i] / 1e6 });
        try w.print("steals={d} parks={d}\n", .{ thread.steals, thread.parks });
    }
    var groups: std.StringHashMapUnmanaged(Group) = .empty;
    var tasks = model.tasks.valueIterator();
    while (tasks.next()) |task| {
        const group = try groups.getOrPut(a, task.name);
        if (!group.found_existing) group.value_ptr.* = .{};
        group.value_ptr.spawned += @intFromBool(task.created != null);
        try group.value_ptr.runs.values.appendSlice(a, task.runs.items);
        try group.value_ptr.wakes.values.appendSlice(a, task.wakes.items);
        if (task.created) |created| if (task.finished) |finished| try group.value_ptr.lifetimes.add(a, finished - created);
    }
    try w.writeAll("\nTasks by name (all durations in microseconds):\n");
    var names: std.ArrayList([]const u8) = .empty;
    var keys = groups.keyIterator();
    while (keys.next()) |key| try names.append(a, key.*);
    std.mem.sort([]const u8, names.items, {}, nameLess);
    for (names.items) |name| {
        const group = groups.getPtr(name).?;
        try w.print("  {s}: spawned={d}\n", .{ name, group.spawned });
        try distribution(w, "slices / run", &group.runs);
        try distribution(w, "wake->run", &group.wakes);
        try distribution(w, "completed lifetime", &group.lifetimes);
    }
    try w.writeAll("\nI/O submit->complete by operation (us):\n");
    var ops = model.io_stats.iterator();
    while (ops.next()) |op| {
        try w.print("  {s} (kind {d})\n", .{ model.session.names.get(op.key_ptr.*) orelse "unknown", op.key_ptr.* });
        try distribution(w, "latency", op.value_ptr);
    }
    try w.writeAll("\nBlocking pool (us):\n");
    try distribution(w, "queue wait", &model.work_wait);
    try distribution(w, "run", &model.work_run);
    try w.writeAll("\nZones (us):\n");
    var zones = model.zones.iterator();
    while (zones.next()) |zone| {
        try w.print("  {s} (srcloc 0x{x})\n", .{ zone.value_ptr.name, zone.key_ptr.* });
        try distribution(w, "wall duration (includes suspension)", &zone.value_ptr.samples);
        try distribution(w, "task on-CPU duration", &zone.value_ptr.cpu_samples);
    }
    try w.writeAll("\nPlots:\n");
    var plots = model.plots.iterator();
    while (plots.next()) |plot| try w.print("  {s}: count={d} min={d} max={d} mean={d:.3}\n", .{ plot.key_ptr.*, plot.value_ptr.count, plot.value_ptr.min, plot.value_ptr.max, plot.value_ptr.total / @as(f64, @floatFromInt(plot.value_ptr.count)) });
}

pub fn distribution(w: *Writer, label: []const u8, samples: *timeline.Samples) !void {
    const values = samples.values.items;
    if (values.len == 0) {
        try w.print("    {s}: count=0\n", .{label});
        return;
    }
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    var total: f64 = 0;
    for (values) |value| total += value;
    try w.print("    {s}: count={d} total={d:.3} mean={d:.3} p50={d:.3} p95={d:.3} p99={d:.3} max={d:.3}\n", .{ label, values.len, total / 1000, total / @as(f64, @floatFromInt(values.len)) / 1000, percentile(values, 50) / 1000, percentile(values, 95) / 1000, percentile(values, 99) / 1000, values[values.len - 1] / 1000 });
}

pub fn percentile(sorted: []const f64, percent: usize) f64 {
    const rank = (sorted.len * percent + 99) / 100;
    return sorted[@min(sorted.len - 1, rank -| 1)];
}
fn nameLess(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

test "percentiles use nearest rank, not median for p95" {
    const values = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(f64, 5), percentile(&values, 50));
    try std.testing.expectEqual(@as(f64, 10), percentile(&values, 95));
}
