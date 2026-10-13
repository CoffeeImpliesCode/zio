const std = @import("std");
const format = @import("zio_trace_format");
const Session = @import("session.zig").Session;
const Model = @import("timeline.zig").Model;
const all_recorded: format.record.Process = .{
    .exe_path = "",
    .anchor_addr = 0,
    .classes = format.all_classes,
};

const Encoder = struct {
    bytes: [8192]u8 = undefined,
    len: usize = 0,
    fn init() Encoder {
        var result: Encoder = .{};
        const header: format.FileHeader = .{ .clock = .tsc, .ticks_per_second = 500_000_000, .pid = 42, .start_realtime_ns = 0 };
        @memcpy(result.bytes[0..@sizeOf(format.FileHeader)], std.mem.asBytes(&header));
        result.len = @sizeOf(format.FileHeader);
        return result;
    }
    fn record(self: *Encoder, comptime kind: format.RecordKind, value: format.RecordPayload(kind)) void {
        self.len += format.writeRecordHeader(self.bytes[self.len..], kind, format.fieldsLen(value));
        self.len += format.writeFields(self.bytes[self.len..], value);
    }
    fn chunk(self: *Encoder, thread: u64, seq: u64, base: u64, events: []const u8) void {
        const value: format.record.Chunk = .{ .thread = thread, .seq = seq, .base_ticks = base };
        self.len += format.writeRecordHeader(self.bytes[self.len..], .chunk, format.fieldsLen(value) + events.len);
        self.len += format.writeFields(self.bytes[self.len..], value);
        @memcpy(self.bytes[self.len..][0..events.len], events);
        self.len += events.len;
    }
};

test "synthetic session calibration, reordered chunks, states and wake latency" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ = try std.testing.environ.createMap(a);
    const scratch = environ.get("TMPDIR") orelse return error.MissingScratchDirectory;
    var random: [8]u8 = undefined;
    io.random(&random);
    const path = try a.print("{s}/zio-trace-test-{s}", .{ scratch, std.fmt.bytesToHex(&random, .lower) });
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } });
    defer dir.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var process = Encoder.init();
    process.record(.process, all_recorded);
    process.record(.calibration, .{ .ticks = 100, .monotonic_ns = 1000 });
    process.record(.calibration, .{ .ticks = 200, .monotonic_ns = 1200 });
    process.record(.end, .{ .dropped = 3 });
    process.len += format.writeRecordHeader(process.bytes[process.len..], @fromBackingInt(200), 0);
    try dir.writeFile(io, .{ .sub_path = "process.dump", .data = process.bytes[0..process.len] });
    var executor = Encoder.init();
    executor.record(.thread, .{ .thread = 0, .os_tid = 77, .kind = .executor, .executor = 2, .name = "" });
    var events: [2048]u8 = undefined;
    var n: usize = 0;
    n += format.writeEvent(events[n..], .task_begin, 0, .{ .task = 1 });
    n += format.writeEvent(events[n..], .srcloc, 0, .{ .srcloc = 5, .name = "zone \"quoted\"", .function = "user", .file = "user.zig", .line = 1 });
    n += format.writeEvent(events[n..], .zone_begin, 0, .{ .srcloc = 5 });
    n += format.writeEvent(events[n..], .io_submit, 0, .{ .op = 7, .kind = 4 });
    n += format.writeEvent(events[n..], .plot, 0, .{ .name = "plot\nescaped", .value = -4 });
    n += format.writeEvent(events[n..], .zone_end, 10, .{ .srcloc = 5 });
    n += format.writeEvent(events[n..], .task_end, 0, .{ .reason = .finish });
    n += format.writeEvent(events[n..], .io_complete, 0, .{ .op = 7, .result = .ok });
    n += format.writeEvent(events[n..], .poll_begin, 0, .{ .timeout_ns = 0 });
    n += format.writeEvent(events[n..], .poll_end, 5, .{ .timed_out = false });
    n += format.writeEvent(events[n..], .flush_begin, 0, .{});
    n += format.writeEvent(events[n..], .flush_end, 5, .{});
    executor.chunk(0, 1, 140, events[0..n]);
    n = 0;
    n += format.writeEvent(events[n..], .task_create, 0, .{ .task = 1, .entry = 123, .executor = 2, .parent = 0, .group = 0 });
    n += format.writeEvent(events[n..], .task_begin, 0, .{ .task = 1 });
    n += format.writeEvent(events[n..], .task_end, 10, .{ .reason = .wait });
    n += format.writeEvent(events[n..], .poll_begin, 0, .{ .timeout_ns = 100 });
    n += format.writeEvent(events[n..], .poll_end, 20, .{ .timed_out = true });
    n += format.writeEvent(events[n..], .plot, 0, .{ .name = "plot\nescaped", .value = 6 });
    executor.chunk(0, 0, 100, events[0..n]);
    executor.bytes[executor.len] = @backingInt(format.RecordKind.chunk);
    executor.len += 1; // A crash in a record header must not discard earlier chunks.
    try dir.writeFile(io, .{ .sub_path = "77-0.dump", .data = executor.bytes[0..executor.len] });
    var worker = Encoder.init();
    worker.record(.thread, .{ .thread = 1, .os_tid = 88, .kind = .blocking, .executor = format.no_executor, .name = "" });
    n = 0;
    n += format.writeEvent(events[n..], .work_queue, 0, .{ .work = 9 });
    n += format.writeEvent(events[n..], .work_begin, 5, .{ .work = 9 });
    n += format.writeEvent(events[n..], .task_wake, 30, .{ .task = 1 });
    n += format.writeEvent(events[n..], .work_end, 15, .{ .work = 9, .canceled = false });
    worker.chunk(1, 0, 100, events[0..n]);
    try dir.writeFile(io, .{ .sub_path = "88-1.dump", .data = worker.bytes[0..worker.len] });
    const session = try Session.load(a, io, path);
    try std.testing.expectEqual(@as(usize, 1), session.decode_errors);
    try std.testing.expectEqual(@as(u64, 3), session.dropped);
    try std.testing.expectApproxEqAbs(@as(f64, 1080), session.clock.ns(140), 0.001);
    const model = try Model.build(a, session);
    const thread = model.thread(0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 40), thread.durations[@backingInt(@import("timeline.zig").State.task)], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 40), thread.durations[@backingInt(@import("timeline.zig").State.poll_wait)], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0 * 70.0 / 120.0), thread.busyPercent().?, 0.001);
    const task = model.tasks.get(1).?;
    try std.testing.expectEqual(@as(usize, 2), task.runs.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 10), task.wakes.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 90), model.thread(1).?.durations[@backingInt(@import("timeline.zig").State.work)], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 90), model.thread(1).?.busyPercent().?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20), task.runs.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), task.finished.? - task.created.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20), thread.durations[@backingInt(@import("timeline.zig").State.scheduler)], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), thread.durations[@backingInt(@import("timeline.zig").State.poll_check)], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), thread.durations[@backingInt(@import("timeline.zig").State.flush)], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), model.work_wait.values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 90), model.work_run.values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20), model.io_stats.get(4).?[@backingInt(format.IoResult.ok)].values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20), model.zones.get(5).?.samples.values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), model.plots.get("plot\nescaped").?.total / 2, 0.001);
    var json: std.Io.Writer.Allocating = .init(a);
    try @import("perfetto.zig").write(a, &json.writer, &model, true);
    _ = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
    var svg: std.Io.Writer.Allocating = .init(a);
    try @import("svg.zig").write(a, &svg.writer, &model, 12);
}

test "single calibration uses nominal frequency" {
    const clock = @import("session.zig").Clock.fit(&.{.{ .ticks = 100, .monotonic_ns = 1000 }}, 500_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 1020), clock.ns(110), 0.001);
}

test "chunk sequence order survives equal timestamps and unknown events" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ = try std.testing.environ.createMap(a);
    const scratch = environ.get("TMPDIR") orelse return error.MissingScratchDirectory;
    var random: [8]u8 = undefined;
    io.random(&random);
    const path = try a.print("{s}/zio-trace-order-{s}", .{ scratch, std.fmt.bytesToHex(&random, .lower) });
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } });
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer dir.close(io);
    var file = Encoder.init();
    file.record(.process, all_recorded);
    file.record(.thread, .{ .thread = 0, .os_tid = 7, .kind = .executor, .executor = 1, .name = "" });
    var bytes: [128]u8 = undefined;
    var n = format.writeEvent(&bytes, .task_end, 0, .{ .reason = .finish });
    file.chunk(0, 2, 100, bytes[0..n]);
    n = format.writeEvent(&bytes, .task_begin, 0, .{ .task = 1 });
    bytes[n] = 255;
    n += 1;
    file.chunk(0, 1, 100, bytes[0..n]);
    n = format.writeEvent(&bytes, .task_create, 0, .{ .task = 1, .entry = 9, .executor = 1, .parent = 0, .group = 0 });
    file.chunk(0, 0, 100, bytes[0..n]);
    try dir.writeFile(io, .{ .sub_path = "thread.dump", .data = file.bytes[0..file.len] });
    try dir.writeFile(io, .{ .sub_path = "short.dump", .data = "ZIOTRACE" });
    const session = try Session.load(a, io, path);
    try std.testing.expectEqual(@as(usize, 2), session.decode_errors);
    try std.testing.expectEqual(@as(usize, 0), session.sequence_errors);
    try std.testing.expect(session.events.items[0].event == .task_create);
    try std.testing.expect(session.events.items[1].event == .task_begin);
    try std.testing.expect(session.events.items[2].event == .task_end);
    const model = try Model.build(a, session);
    try std.testing.expectEqual(@as(usize, 0), model.task_pair_errors);
    try std.testing.expectEqual(@as(usize, 1), model.tasks.get(1).?.runs.items.len);
}

test "task zones follow migration and retain global source names" {
    const trace = @import("session.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{
        .path = "migration",
        .start_ns = 0,
        .end_ns = 100,
        .process = all_recorded,
    };
    for (0..2) |id| {
        try session.threads.put(a, id, .{
            .thread = id,
            .os_tid = 100 + id,
            .kind = .executor,
            .executor = id,
            .name = "",
        });
    }
    const events = [_]trace.Event{
        .{ .thread = 0, .ticks = 0, .ns = 0, .event = .{ .task_begin = .{ .task = 1 } } },
        .{ .thread = 0, .ticks = 10, .ns = 10, .event = .{ .srcloc = .{
            .srcloc = 5,
            .name = "migrated",
            .function = "user",
            .file = "user.zig",
            .line = 1,
        } } },
        .{ .thread = 0, .ticks = 10, .ns = 10, .event = .{ .zone_begin = .{ .srcloc = 5 } } },
        .{ .thread = 0, .ticks = 20, .ns = 20, .event = .{ .task_end = .{
            .reason = .wait,
        } } },
        .{ .thread = 1, .ticks = 80, .ns = 80, .event = .{ .task_begin = .{ .task = 1 } } },
        .{ .thread = 1, .ticks = 90, .ns = 90, .event = .{ .zone_end = .{ .srcloc = 5 } } },
        .{ .thread = 1, .ticks = 100, .ns = 100, .event = .{ .task_end = .{
            .reason = .finish,
        } } },
    };
    try session.events.appendSlice(a, &events);
    const model = try Model.build(a, session);
    try std.testing.expectEqual(@as(usize, 0), model.incomplete_slices);
    try std.testing.expectEqual(@as(usize, 1), model.zones.count());
    const zone = model.zones.get(5).?;
    try std.testing.expectEqualStrings("migrated", zone.name);
    try std.testing.expectApproxEqAbs(@as(f64, 80), zone.samples.values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20), zone.run_samples.values.items[0], 0.001);
    var json: std.Io.Writer.Allocating = .init(a);
    try @import("perfetto.zig").write(a, &json.writer, &model, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
    var begins: usize = 0;
    var ends: usize = 0;
    for (parsed.value.object.get("traceEvents").?.array.items) |event| {
        const object = event.object;
        const phase = object.get("ph").?.string;
        if (std.mem.eql(u8, phase, "b")) {
            begins += 1;
            try std.testing.expectEqual(@as(i64, 0), object.get("args").?.object.get("traceThread").?.integer);
            try std.testing.expectEqual(@as(i64, 1), object.get("args").?.object.get("task").?.integer);
            try std.testing.expectEqualStrings("migrated", object.get("name").?.string);
        }
        if (std.mem.eql(u8, phase, "e")) {
            ends += 1;
            try std.testing.expectEqual(@as(i64, 1), object.get("args").?.object.get("traceThread").?.integer);
            try std.testing.expectEqual(@as(i64, 1), object.get("args").?.object.get("task").?.integer);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), begins);
    try std.testing.expectEqual(@as(usize, 1), ends);
}

test "nested zone stacks isolate suspended tasks and outside-thread markers" {
    const E = struct {
        fn at(thread: u64, ns: u64, event: format.Event) @import("session.zig").Event {
            return .{ .thread = thread, .ticks = ns, .ns = @floatFromInt(ns), .event = event };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{ .path = "nested", .process = all_recorded };
    for (0..2) |id| try session.threads.put(a, id, .{
        .thread = id,
        .os_tid = 100 + id,
        .kind = .executor,
        .executor = id,
        .name = "",
    });
    const events = [_]@import("session.zig").Event{
        E.at(0, 0, .{ .task_begin = .{ .task = 1 } }),
        E.at(0, 5, .{ .zone_begin = .{ .srcloc = 5 } }),
        E.at(0, 6, .{ .zone_begin = .{ .srcloc = 6 } }),
        E.at(0, 10, .{ .task_end = .{ .reason = .wait } }),
        E.at(0, 12, .{ .task_begin = .{ .task = 2 } }),
        E.at(0, 14, .{ .zone_begin = .{ .srcloc = 5 } }),
        E.at(0, 16, .{ .zone_end = .{ .srcloc = 5 } }),
        E.at(0, 20, .{ .task_end = .{ .reason = .finish } }),
        E.at(0, 21, .{ .zone_begin = .{ .srcloc = 5 } }),
        E.at(0, 23, .{ .zone_end = .{ .srcloc = 5 } }),
        E.at(1, 30, .{ .task_begin = .{ .task = 1 } }),
        E.at(1, 31, .{ .zone_end = .{ .srcloc = 6 } }),
        E.at(1, 32, .{ .zone_end = .{ .srcloc = 5 } }),
        E.at(1, 40, .{ .task_end = .{ .reason = .finish } }),
    };
    try session.events.appendSlice(a, &events);
    const model = try Model.build(a, session);
    try std.testing.expectEqual(@as(usize, 0), model.incomplete_slices);
    const outer = model.zones.get(5).?;
    try std.testing.expectEqual(@as(usize, 3), outer.samples.values.items.len);
    try std.testing.expectEqual(@as(usize, 2), outer.run_samples.values.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 27), outer.samples.values.items[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 7), outer.run_samples.values.items[1], 0.001);
    const inner = model.zones.get(6).?;
    try std.testing.expectApproxEqAbs(@as(f64, 25), inner.samples.values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 5), inner.run_samples.values.items[0], 0.001);
    const tasks = [_]u64{ 1, 1, 2, 2, 1, 1 };
    const sources = [_]u64{ 5, 6, 5, 5, 6, 5 };
    try std.testing.expectEqual(@as(usize, 6), model.zone_events.items.len);
    for (model.zone_events.items, tasks, sources, 0..) |event, task, srcloc, i| {
        try std.testing.expectEqual(task, event.task);
        try std.testing.expectEqual(srcloc, event.srcloc);
        try std.testing.expectEqual(i < 3, event.begin);
    }
    var thread_zones: usize = 0;
    for (model.slices.items) |slice| if (slice.kind == .zone) {
        thread_zones += 1;
        try std.testing.expectApproxEqAbs(@as(f64, 2), slice.end - slice.start, 0.001);
    };
    try std.testing.expectEqual(@as(usize, 1), thread_zones);
}

test "thread lifetime markers bound idle time" {
    const E = struct {
        fn at(thread: u64, ns: u64, event: format.Event) @import("session.zig").Event {
            return .{ .thread = thread, .ticks = ns, .ns = @floatFromInt(ns), .event = event };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{ .path = "lifetime", .start_ns = 0, .end_ns = 1000 };
    for (0..4) |id| try session.threads.put(a, id, .{
        .thread = id,
        .os_tid = 100 + id,
        .kind = .blocking,
        .executor = format.no_executor,
        .name = "",
    });
    const events = [_]@import("session.zig").Event{
        E.at(0, 0, .{ .message = .{ .text = "outside lifetime" } }),
        E.at(3, 0, .{ .message = .{ .text = "before begin-only marker" } }),
        E.at(2, 50, .{ .message = .{ .text = "end-only first event" } }),
        E.at(0, 100, .{ .thread_begin = .{} }),
        E.at(3, 150, .{ .thread_begin = .{} }),
        E.at(1, 200, .{ .message = .{ .text = "legacy first event" } }),
        E.at(1, 220, .{ .work_begin = .{ .work = 2 } }),
        E.at(1, 260, .{ .work_end = .{ .work = 2, .canceled = false } }),
        E.at(0, 300, .{ .work_begin = .{ .work = 1 } }),
        E.at(1, 400, .{ .message = .{ .text = "legacy last event" } }),
        E.at(0, 500, .{ .work_end = .{ .work = 1, .canceled = false } }),
        E.at(3, 850, .{ .message = .{ .text = "begin-only last event" } }),
        E.at(0, 900, .{ .thread_end = .{} }),
        E.at(2, 950, .{ .thread_end = .{} }),
        E.at(2, 975, .{ .message = .{ .text = "after end-only marker" } }),
        E.at(0, 1000, .{ .message = .{ .text = "outside lifetime" } }),
    };
    try session.events.appendSlice(a, &events);
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(a);
    const scratch = environ.get("TMPDIR") orelse return error.MissingScratchDirectory;
    var random: [8]u8 = undefined;
    io.random(&random);
    const path = try a.print("{s}/zio-trace-lifetime-{s}", .{ scratch, std.fmt.bytesToHex(&random, .lower) });
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } });
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer dir.close(io);
    var process = Encoder.init();
    process.record(.process, all_recorded);
    process.record(.calibration, .{ .ticks = 0, .monotonic_ns = 0 });
    process.record(.calibration, .{ .ticks = 1000, .monotonic_ns = 1000 });
    try dir.writeFile(io, .{
        .sub_path = "process.dump",
        .data = process.bytes[0..process.len],
    });
    var infos = session.threads.valueIterator();
    while (infos.next()) |info| {
        var file = Encoder.init();
        file.record(.thread, info.*);
        var bytes: [2048]u8 = undefined;
        var n: usize = 0;
        var previous: u64 = 0;
        for (events) |event| {
            if (event.thread != info.thread) continue;
            switch (event.event) {
                inline else => |payload, tag| {
                    n += format.writeEvent(bytes[n..], tag, event.ticks - previous, payload);
                },
            }
            previous = event.ticks;
        }
        file.chunk(info.thread, 0, 0, bytes[0..n]);
        try dir.writeFile(io, .{
            .sub_path = try a.print("{d}.dump", .{info.thread}),
            .data = file.bytes[0..file.len],
        });
    }
    const model = try Model.build(a, try Session.load(a, io, path));
    const worker = model.thread(0).?;
    try std.testing.expectEqual(@as(f64, 100), worker.first.?);
    try std.testing.expectEqual(@as(f64, 900), worker.last);
    try std.testing.expectEqual(@as(f64, 200), worker.durations[@backingInt(@import("timeline.zig").State.work)]);
    try std.testing.expectEqual(@as(f64, 600), worker.durations[@backingInt(@import("timeline.zig").State.idle)]);
    try std.testing.expectEqual(@as(f64, 25), worker.busyPercent().?);
    const legacy = model.thread(1).?;
    try std.testing.expectEqual(@as(f64, 200), legacy.first.?);
    try std.testing.expectEqual(@as(f64, 400), legacy.last);
    try std.testing.expectEqual(@as(f64, 20), legacy.busyPercent().?);
    try std.testing.expectEqual(@as(f64, 50), model.thread(2).?.first.?);
    try std.testing.expectEqual(@as(f64, 950), model.thread(2).?.last);
    try std.testing.expectEqual(@as(f64, 150), model.thread(3).?.first.?);
    try std.testing.expectEqual(@as(f64, 850), model.thread(3).?.last);
}

test "sched-only recording pairs implicit task ends without claiming utilization" {
    const E = struct {
        fn at(ns: u64, event: format.Event) @import("session.zig").Event {
            return .{ .thread = 0, .ticks = ns, .ns = @floatFromInt(ns), .event = event };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{
        .path = "sched-only",
        .start_ns = 0,
        .end_ns = 100,
        .process = .{
            .exe_path = "",
            .anchor_addr = 0,
            .classes = format.EventClass.sched.mask(),
        },
    };
    for (0..2) |id| try session.threads.put(a, id, .{
        .thread = id,
        .os_tid = id,
        .executor = id,
        .name = "",
        .kind = if (id == 0) .executor else .blocking,
    });
    const events = [_]@import("session.zig").Event{
        E.at(0, .{ .thread_begin = .{} }),
        E.at(5, .{ .task_create = .{
            .task = 1,
            .entry = 0x111,
            .executor = 0,
            .parent = 0,
            .group = 0,
        } }),
        E.at(5, .{ .task_func = .{ .task = 1, .func = 0xabc } }),
        E.at(6, .{ .task_create = .{
            .task = 2,
            .entry = 0x222,
            .executor = 0,
            .parent = 0,
            .group = 0,
        } }),
        E.at(10, .{ .task_begin = .{ .task = 1 } }),
        E.at(20, .{ .task_end = .{ .reason = .wait } }),
        E.at(30, .{ .task_begin = .{ .task = 2 } }),
        E.at(50, .{ .task_end = .{ .reason = .finish } }),
        E.at(60, .{ .task_begin = .{ .task = 1 } }),
        E.at(80, .{ .task_end = .{ .reason = .finish } }),
        E.at(100, .{ .thread_end = .{} }),
    };
    try session.events.appendSlice(a, &events);
    var model = try Model.build(a, session);
    try std.testing.expectEqual(@as(usize, 0), model.task_pair_errors);
    try std.testing.expectEqual(@as(usize, 0), model.incomplete_slices);
    try std.testing.expectEqualSlices(f64, &.{ 10, 20 }, model.tasks.get(1).?.runs.items);
    try std.testing.expectEqualSlices(f64, &.{20}, model.tasks.get(2).?.runs.items);
    try std.testing.expect(model.thread(0).?.busyPercent() == null);
    try std.testing.expect(model.thread(1).?.busyPercent() == null);
    try std.testing.expectEqual(@as(f64, 50), model.thread(0).?.durations[@backingInt(@import("timeline.zig").State.unknown)]);
    try @import("naming.zig").resolve(a, &model, null);
    try std.testing.expectEqualStrings("0xabc", model.tasks.get(1).?.name);
    try std.testing.expectEqualStrings("0x222", model.tasks.get(2).?.name);
    var report: std.Io.Writer.Allocating = .init(a);
    try @import("report.zig").stats(a, &report.writer, &model);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "Recorded classes: sched") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "loop not recorded") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "I/O: not recorded") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "Zones: not recorded") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "Plots: not recorded") != null);
    var svg: std.Io.Writer.Allocating = .init(a);
    try @import("svg.zig").write(a, &svg.writer, &model, 10);
    try std.testing.expect(std.mem.indexOf(u8, svg.written(), "mean busy n/a") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg.written(), "loop not recorded") != null);
    var json: std.Io.Writer.Allocating = .init(a);
    try @import("perfetto.zig").write(a, &json.writer, &model, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
    const classes = parsed.value.object.get("zioTrace").?.object.get("recordedClasses").?.array;
    try std.testing.expectEqual(@as(usize, 1), classes.items.len);
    try std.testing.expectEqualStrings("sched", classes.items[0].string);
    try session.events.append(a, E.at(110, .{ .task_end = .{ .reason = .finish } }));
    const unmatched = try Model.build(a, session);
    try std.testing.expectEqual(@as(usize, 1), unmatched.task_pair_errors);
}

test "user-only and missing metadata recordings do not infer scheduler diagnostics" {
    const E = struct {
        fn at(ns: u64, event: format.Event) @import("session.zig").Event {
            return .{ .thread = 0, .ticks = ns, .ns = @floatFromInt(ns), .event = event };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{
        .path = "user-only",
        .start_ns = 0,
        .end_ns = 100,
        .process = .{
            .exe_path = "",
            .anchor_addr = 0,
            .classes = format.EventClass.user.mask(),
        },
    };
    try session.threads.put(a, 0, .{
        .thread = 0,
        .os_tid = 10,
        .executor = 0,
        .name = "",
        .kind = .executor,
    });
    const events = [_]@import("session.zig").Event{
        E.at(0, .{ .thread_begin = .{} }),
        // Off-class events must never manufacture a task pairing failure.
        E.at(1, .{ .task_end = .{ .reason = .finish } }),
        E.at(2, .{ .zone_begin = .{ .srcloc = 5 } }),
        E.at(3, .{ .plot = .{ .name = "recorded plot", .value = 7 } }),
        E.at(4, .{ .zone_end = .{ .srcloc = 5 } }),
        E.at(100, .{ .thread_end = .{} }),
    };
    try session.events.appendSlice(a, &events);
    var model = try Model.build(a, session);
    try std.testing.expectEqual(@as(usize, 0), model.task_pair_errors);
    try std.testing.expectEqual(@as(usize, 0), model.incomplete_slices);
    try std.testing.expectEqual(@as(u32, 0), model.tasks.count());
    try std.testing.expect(model.thread(0).?.busyPercent() == null);
    try std.testing.expectEqual(@as(u64, 1), model.plots.get("recorded plot").?.count);
    var report: std.Io.Writer.Allocating = .init(a);
    try @import("report.zig").stats(a, &report.writer, &model);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "Tasks: not recorded") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "Zones: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "recorded plot: count=1") != null);
    session.process = null;
    var unknown = try Model.build(a, session);
    try std.testing.expect(unknown.thread(0).?.busyPercent() == null);
    try std.testing.expectEqual(@as(usize, 0), unknown.task_pair_errors);
    var unknown_report: std.Io.Writer.Allocating = .init(a);
    try @import("report.zig").stats(a, &unknown_report.writer, &unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown_report.written(), "Recorded classes: unknown (missing process record)") != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown_report.written(), "Plots: not recorded (recorded classes unknown)") != null);
    var json: std.Io.Writer.Allocating = .init(a);
    try @import("perfetto.zig").write(a, &json.writer, &unknown, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
    try std.testing.expect(parsed.value.object.get("zioTrace").?.object.get("recordedClasses").? == .null);
}

extern fn zio_trace_anchor() callconv(.c) void;

const SleepCaller = struct { address: u64 = 0, line: u32 = 0 };

fn decodedFrames(a: std.mem.Allocator, addresses: []const u64) !format.AddrList {
    const bytes = try a.alloc(u8, addresses.len * format.max_varint_len);
    var len: usize = 0;
    for (addresses) |address| len += format.writeVarint(bytes[len..], address);
    const frames: format.AddrList = .{ .count = addresses.len, .encoded = bytes[0..len] };
    var iterator = frames.iterator();
    for (addresses) |address| try std.testing.expectEqual(address, (try iterator.next()).?);
    try std.testing.expectEqual(null, try iterator.next());
    return frames;
}

noinline fn captureSleep(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
    const caller: *SleepCaller = @ptrCast(@alignCast(userdata.?));
    caller.address = @returnAddress();
}

noinline fn physicalSleeper() !SleepCaller {
    var caller: SleepCaller = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.sleep = captureSleep;
    const io: std.Io = .{ .userdata = &caller, .vtable = &vtable };
    caller.line = @src().line + 1;
    try @call(.always_inline, std.Io.sleep, .{ io, std.Io.Duration.fromNanoseconds(1), .awake });
    std.mem.doNotOptimizeAway(&caller);
    return caller;
}

inline fn enclosingInlineSleeper(io: std.Io, caller: *SleepCaller) !void {
    caller.line = @src().line + 1;
    try @call(.always_inline, std.Io.sleep, .{ io, std.Io.Duration.fromNanoseconds(2), .awake });
    std.mem.doNotOptimizeAway(caller);
}

noinline fn inlineSleeperHost() !SleepCaller {
    var caller: SleepCaller = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.sleep = captureSleep;
    const io: std.Io = .{ .userdata = &caller, .vtable = &vtable };
    try enclosingInlineSleeper(io, &caller);
    std.mem.doNotOptimizeAway(&caller);
    return caller;
}

// Force the real std.Io.sleep wrapper inline even in Debug. Its callback records a
// physical return PC, not a fabricated symbol, just as the runtime stack capture does.
test "task naming recovers physical and enclosing inline users behind runtime DWARF" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const naming = @import("naming.zig");
    const Symbolizer = @import("symbolize.zig").Symbolizer;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&zio_trace_anchor),
    );
    defer symbols.deinit();
    const physical = try physicalSleeper();
    const inlined = try inlineSleeperHost();
    // Verify the fixture reaches the reported bug instead of an ordinary user PC.
    try std.testing.expect(naming.runtimeFrame(symbols.lookup(physical.address - 1).?));
    try std.testing.expect(naming.runtimeFrame(symbols.lookup(inlined.address - 1).?));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model: Model = .{ .session = .{ .path = "inline-dwarf" } };
    const physical_frames = try decodedFrames(a, &.{ 0, physical.address });
    const inline_frames = try decodedFrames(a, &.{inlined.address});
    try model.tasks.put(a, 1, .{
        .id = 1,
        .entry = @intFromPtr(&inlineSleeperHost),
        .first_suspend = physical_frames,
        .spawn_stack = inline_frames,
    });
    try model.tasks.put(a, 2, .{
        .id = 2,
        .entry = @intFromPtr(&inlineSleeperHost),
        .first_suspend = inline_frames,
        .spawn_stack = inline_frames,
    });
    try model.tasks.put(a, 3, .{
        .id = 3,
        .func = @intFromPtr(&physicalSleeper),
        .first_suspend = inline_frames,
    });
    try naming.resolve(a, &model, &symbols);
    try std.testing.expect(std.mem.endsWith(u8, model.tasks.get(1).?.name, "physicalSleeper"));
    try std.testing.expect(std.mem.endsWith(u8, model.tasks.get(2).?.name, "enclosingInlineSleeper"));
    try std.testing.expect(std.mem.endsWith(u8, model.tasks.get(3).?.name, "physicalSleeper"));
    try std.testing.expect(!std.mem.eql(u8, model.tasks.get(1).?.name, model.tasks.get(2).?.name));
    const contexts = symbols.lookupFrames(inlined.address - 1);
    const user = for (contexts) |context| {
        if (!naming.runtimeFrame(context)) break context;
    } else return error.InlineUserNotResolved;
    try std.testing.expect(std.mem.endsWith(u8, user.function, "enclosingInlineSleeper"));
    try std.testing.expect(std.mem.endsWith(u8, user.file.?, "tests.zig"));
    try std.testing.expectEqual(inlined.line, user.line);
    try std.testing.expect(user.column > 0);
    try std.testing.expectEqual(@as(usize, 0), symbols.lookupFrames(0).len);
    try std.testing.expectEqual(@as(usize, 0), symbols.lookupFrames(std.math.maxInt(u64)).len);
    // DWARF-only files must not silently lose enclosing user attribution.
    symbols.elf.?.symtab = null;
    symbols.cache.clearRetainingCapacity();
    try naming.resolve(a, &model, &symbols);
    try std.testing.expect(std.mem.endsWith(u8, model.tasks.get(1).?.name, "physicalSleeper"));
    try std.testing.expect(std.mem.endsWith(u8, model.tasks.get(2).?.name, "enclosingInlineSleeper"));
    // Previously borrowed contexts survive later cache growth and re-resolution.
    const resolved = symbols.lookupFrames(inlined.address - 1);
    const retained_user = for (resolved) |context| {
        if (!naming.runtimeFrame(context)) break context;
    } else return error.InlineUserNotResolved;
    try std.testing.expectEqualStrings(user.function, retained_user.function);
    try std.testing.expectEqualStrings(user.file.?, retained_user.file.?);
    try std.testing.expectEqual(user.line, retained_user.line);
    try std.testing.expectEqual(user.column, retained_user.column);
}

// A generic task that never suspended has only a spawn PC; preserve the enclosing
// user's call site, rather than reporting std.Io.sleep's library source line.
test "spawn fallback preserves enclosing inline user call site" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Symbolizer = @import("symbolize.zig").Symbolizer;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&zio_trace_anchor),
    );
    defer symbols.deinit();
    const caller = try inlineSleeperHost();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = try decodedFrames(a, &.{caller.address});
    var model: Model = .{ .session = .{ .path = "inline-spawn" } };
    try model.tasks.put(a, 1, .{
        .id = 1,
        .entry = @intFromPtr(&inlineSleeperHost),
        .spawn_stack = frames,
    });
    try @import("naming.zig").resolve(a, &model, &symbols);
    const name = model.tasks.get(1).?.name;
    try std.testing.expect(std.mem.startsWith(u8, name, "spawned at "));
    const suffix = try a.print("tests.zig:{d}", .{caller.line});
    try std.testing.expect(std.mem.endsWith(u8, name, suffix));
}

test "task naming preserves symtab-only and no-symbol fallbacks" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Symbolizer = @import("symbolize.zig").Symbolizer;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&zio_trace_anchor),
    );
    defer symbols.deinit();
    symbols.elf.?.dwarf.?.deinit(std.testing.allocator);
    symbols.elf.?.dwarf = null;
    const caller = try physicalSleeper();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = try decodedFrames(a, &.{caller.address});
    var model: Model = .{ .session = .{ .path = "stripped" } };
    try model.tasks.put(a, 1, .{
        .id = 1,
        .entry = @intFromPtr(&physicalSleeper),
        .first_suspend = frames,
    });
    try @import("naming.zig").resolve(a, &model, &symbols);
    try std.testing.expect(std.mem.endsWith(u8, model.tasks.get(1).?.name, "physicalSleeper"));
    symbols.elf.?.symtab = null;
    symbols.cache.clearRetainingCapacity();
    try @import("naming.zig").resolve(a, &model, &symbols);
    const fallback = try a.print("0x{x}", .{@intFromPtr(&physicalSleeper)});
    try std.testing.expectEqualStrings(fallback, model.tasks.get(1).?.name);
}

noinline fn captureSort(caller: *SleepCaller, lhs: u64, rhs: u64) bool {
    caller.address = @returnAddress();
    return lhs < rhs;
}

noinline fn sortCaller() SleepCaller {
    var values = [_]u64{ 4, 1, 3, 2 };
    var caller: SleepCaller = .{};
    @call(.always_inline, std.mem.sort, .{ u64, values[0..], &caller, captureSort });
    std.mem.doNotOptimizeAway(&values);
    return caller;
}

fn removeInlineCallSites(symbols: *@import("symbolize.zig").Symbolizer) void {
    for (symbols.elf.?.dwarf.?.abbrev_table_list.items) |table| {
        for (table.abbrevs) |abbrev| {
            for (abbrev.attrs) |*attr| {
                if (attr.id == std.dwarf.AT.call_file or attr.id == std.dwarf.AT.call_line or
                    attr.id == std.dwarf.AT.call_column)
                {
                    // Keep the real DIE byte layout, but make these coordinates absent.
                    attr.id = std.dwarf.AT.description;
                }
            }
        }
    }
    symbols.cache.clearRetainingCapacity();
}

test "runtime inline contexts retain provenance without call sites" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Symbolizer = @import("symbolize.zig").Symbolizer;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&zio_trace_anchor),
    );
    defer symbols.deinit();
    const caller = sortCaller();
    removeInlineCallSites(&symbols);
    const contexts = symbols.lookupFrames(caller.address - 1);
    try std.testing.expect(contexts.len != 0);
    for (contexts) |context| {
        // Every context in this captured library comparator call, except its
        // possible physical user host, is genuinely std sorting implementation.
        if (std.mem.endsWith(u8, context.function, "sortCaller")) continue;
        try std.testing.expect(@import("naming.zig").runtimeFrame(context));
    }
}

test "missing inline call sites do not fabricate spawn source coordinates" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Symbolizer = @import("symbolize.zig").Symbolizer;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&zio_trace_anchor),
    );
    defer symbols.deinit();
    const caller = try inlineSleeperHost();
    removeInlineCallSites(&symbols);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frames = try decodedFrames(a, &.{caller.address});
    var model: Model = .{ .session = .{ .path = "missing-callsites" } };
    try model.tasks.put(a, 1, .{
        .id = 1,
        .entry = @intFromPtr(&inlineSleeperHost),
        .spawn_stack = frames,
    });
    try @import("naming.zig").resolve(a, &model, &symbols);
    try std.testing.expect(std.mem.endsWith(u8, model.tasks.get(1).?.name, "inlineSleeperHost"));
    try std.testing.expect(!std.mem.startsWith(u8, model.tasks.get(1).?.name, "spawned at "));
}

test "inline work can suspend and finish on another executor" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{ .path = "inline-work", .process = all_recorded };
    for (0..2) |id| try session.threads.put(a, id, .{
        .thread = id,
        .os_tid = 100 + id,
        .kind = .executor,
        .executor = id,
        .name = "",
    });
    try session.events.appendSlice(a, &.{
        .{ .thread = 0, .ticks = 0, .ns = 0, .event = .{ .task_begin = .{ .task = 1 } } },
        .{ .thread = 0, .ticks = 1, .ns = 1, .event = .{ .work_queue = .{ .work = 9 } } },
        .{ .thread = 0, .ticks = 2, .ns = 2, .event = .{ .work_begin = .{ .work = 9 } } },
        .{ .thread = 0, .ticks = 3, .ns = 3, .event = .{ .task_end = .{ .reason = .wait } } },
        .{ .thread = 1, .ticks = 8, .ns = 8, .event = .{ .task_begin = .{ .task = 1 } } },
        .{ .thread = 1, .ticks = 9, .ns = 9, .event = .{ .work_end = .{ .work = 9, .canceled = true } } },
        .{ .thread = 1, .ticks = 10, .ns = 10, .event = .{ .task_end = .{ .reason = .finish } } },
    });
    const model = try Model.build(a, session);
    try std.testing.expectEqual(@as(usize, 0), model.incomplete_slices);
    try std.testing.expectEqualSlices(f64, &.{7}, model.work_run.values.items);
    var output: std.Io.Writer.Allocating = .init(a);
    try @import("perfetto.zig").write(a, &output.writer, &model, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output.written(), .{});
    var endpoints: usize = 0;
    for (parsed.value.object.get("traceEvents").?.array.items) |event| {
        const category = event.object.get("cat") orelse continue;
        if (!std.mem.eql(u8, category.string, "work")) continue;
        try std.testing.expectEqualStrings(if (endpoints == 0) "b" else "e", event.object.get("ph").?.string);
        const trace_thread = event.object.get("args").?.object.get(if (endpoints == 0) "beginThread" else "endThread").?.integer;
        const display_thread = event.object.get("tid").?.integer;
        var resolved: ?i64 = null;
        for (parsed.value.object.get("traceEvents").?.array.items) |metadata| {
            if (!std.mem.eql(u8, metadata.object.get("name").?.string, "thread_name")) continue;
            if (metadata.object.get("tid").?.integer == display_thread)
                resolved = metadata.object.get("args").?.object.get("traceThread").?.integer;
        }
        try std.testing.expectEqual(trace_thread, resolved.?);
        try std.testing.expectEqual(@as(i64, @intCast(endpoints)), trace_thread);
        endpoints += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), endpoints);
}

test "nested pool work keeps its outer worker occupied" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{ .path = "nested-work", .process = all_recorded };
    try session.threads.put(a, 0, .{
        .thread = 0,
        .os_tid = 100,
        .kind = .blocking,
        .executor = format.no_executor,
        .name = "",
    });
    try session.events.appendSlice(a, &.{
        .{ .thread = 0, .ticks = 0, .ns = 0, .event = .{ .thread_begin = .{} } },
        .{ .thread = 0, .ticks = 10, .ns = 10, .event = .{ .work_begin = .{ .work = 1 } } },
        .{ .thread = 0, .ticks = 30, .ns = 30, .event = .{ .work_begin = .{ .work = 2 } } },
        .{ .thread = 0, .ticks = 40, .ns = 40, .event = .{ .work_end = .{ .work = 2, .canceled = false } } },
        .{ .thread = 0, .ticks = 60, .ns = 60, .event = .{ .work_end = .{ .work = 1, .canceled = false } } },
        .{ .thread = 0, .ticks = 80, .ns = 80, .event = .{ .thread_end = .{} } },
    });
    const model = try Model.build(a, session);
    try std.testing.expectEqual(@as(usize, 0), model.incomplete_slices);
    try std.testing.expectEqual(@as(f64, 50), model.thread(0).?.durations[@backingInt(@import("timeline.zig").State.work)]);
    try std.testing.expectEqual(@as(f64, 62.5), model.thread(0).?.busyPercent().?);
}

test "missing thread metadata preserves tasks zones and plots without invented utilization" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{ .path = "missing-thread", .process = all_recorded };
    try session.events.appendSlice(a, &.{
        .{ .thread = 7, .ticks = 0, .ns = 0, .event = .{ .task_begin = .{ .task = 1 } } },
        .{ .thread = 7, .ticks = 1, .ns = 1, .event = .{ .zone_begin = .{ .srcloc = 9 } } },
        .{ .thread = 7, .ticks = 2, .ns = 2, .event = .{ .plot = .{ .name = "retained", .value = -5 } } },
        .{ .thread = 7, .ticks = 4, .ns = 4, .event = .{ .zone_end = .{ .srcloc = 9 } } },
        .{ .thread = 7, .ticks = 5, .ns = 5, .event = .{ .task_end = .{ .reason = .finish } } },
    });
    const model = try Model.build(a, session);
    try std.testing.expectEqual(@as(u64, 1), (model.plots.get("retained") orelse return error.PlotDiscarded).count);
    try std.testing.expectEqualSlices(f64, &.{5}, model.tasks.get(1).?.runs.items);
    try std.testing.expectEqualSlices(f64, &.{3}, model.zones.get(9).?.samples.values.items);
    try std.testing.expect(model.thread(7).?.busyPercent() == null);
}

test "an unfinalized recording does not claim a final drop count" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ = try std.testing.environ.createMap(a);
    const scratch = environ.get("TMPDIR") orelse return error.MissingScratchDirectory;
    var random: [8]u8 = undefined;
    io.random(&random);
    const path = try a.print("{s}/zio-trace-unfinalized-{s}", .{ scratch, std.fmt.bytesToHex(&random, .lower) });
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer dir.close(io);
    var file = Encoder.init();
    file.record(.process, all_recorded);
    try dir.writeFile(io, .{ .sub_path = "process.dump", .data = file.bytes[0..file.len] });
    const model = try Model.build(a, try Session.load(a, io, path));
    var output: std.Io.Writer.Allocating = .init(a);
    try @import("perfetto.zig").write(a, &output.writer, &model, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output.written(), .{});
    const diagnostics = parsed.value.object.get("zioTrace").?.object.get("diagnostics") orelse return error.MissingLossDiagnostics;
    try std.testing.expect(!(diagnostics.object.get("finalized") orelse return error.MissingFinalization).bool);
}

test "dump files from another recording cannot pollute the session" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ = try std.testing.environ.createMap(a);
    const scratch = environ.get("TMPDIR") orelse return error.MissingScratchDirectory;
    var random: [8]u8 = undefined;
    io.random(&random);
    const path = try a.print("{s}/zio-trace-foreign-{s}", .{ scratch, std.fmt.bytesToHex(&random, .lower) });
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer dir.close(io);
    var process = Encoder.init();
    process.record(.process, all_recorded);
    process.record(.end, .{ .dropped = 0 });
    try dir.writeFile(io, .{ .sub_path = "process.dump", .data = process.bytes[0..process.len] });
    var file = Encoder.init();
    const foreign_header: format.FileHeader = .{ .clock = .tsc, .ticks_per_second = 500_000_000, .pid = 99, .start_realtime_ns = 0 };
    @memcpy(file.bytes[0..@sizeOf(format.FileHeader)], std.mem.asBytes(&foreign_header));
    var bytes: [128]u8 = undefined;
    const n = format.writeEvent(&bytes, .plot, 0, .{ .name = "foreign", .value = 42 });
    file.chunk(8, 0, 100, bytes[0..n]);
    try dir.writeFile(io, .{ .sub_path = "foreign.dump", .data = file.bytes[0..file.len] });
    const session = try Session.load(a, io, path);
    try std.testing.expectEqual(@as(usize, 0), session.events.items.len);
    try std.testing.expectEqual(@as(u64, 42), session.header.pid);
}

test "report labels cannot inject terminal controls or extra report rows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var model: Model = .{ .session = .{ .path = "labels", .process = all_recorded } };
    try model.plots.put(a, "value\nforged row\x1b[2J\tλ", .{ .count = 1, .min = -5, .max = -5, .total = -5 });
    var output: std.Io.Writer.Allocating = .init(a);
    try @import("report.zig").stats(a, &output.writer, &model);
    try std.testing.expect(std.mem.indexOfScalar(u8, output.written(), 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\nforged row") == null);
}

test "separate captures from one process retain distinct wake flow identities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: [2][]const u8 = undefined;
    for (&ids, 0..) |*id, capture| {
        var session: Session = .{ .path = "captures", .process = all_recorded };
        for (1..3) |thread| try session.threads.put(a, thread, .{
            .thread = thread,
            .os_tid = thread,
            .kind = .executor,
            .executor = thread,
            .name = "",
        });
        var model = try Model.build(a, session);
        model.session.header.pid = 42;
        model.session.header.start_realtime_ns = @intCast(100 + capture);
        try model.flows.append(a, .{
            .task = 1,
            .source_thread = 1,
            .target_thread = 2,
            .start = 10,
            .end = 20,
        });
        var output: std.Io.Writer.Allocating = .init(a);
        try @import("perfetto.zig").write(a, &output.writer, &model, true);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, output.written(), .{});
        var start: ?[]const u8 = null;
        var finish: ?[]const u8 = null;
        for (parsed.value.object.get("traceEvents").?.array.items) |event| {
            const object = event.object;
            const bind = object.get("bind_id") orelse continue;
            try std.testing.expectEqual(@as(i64, 0), object.get("dur").?.integer);
            const numeric = try std.fmt.parseInt(u64, bind.string, 0);
            const flow_id = try a.print("{x}", .{numeric});
            if (object.get("flow_out")) |out| if (out.bool) {
                start = flow_id;
            };
            if (object.get("flow_in")) |in| if (in.bool) {
                finish = flow_id;
            };
        }
        try std.testing.expectEqualStrings(start orelse return error.MissingWakeAnchor, finish orelse return error.MissingRunAnchor);
        id.* = start.?;
    }
    try std.testing.expect(!std.mem.eql(u8, ids[0], ids[1]));
}

test "state intervals share exact endpoints without overlapping duration rounding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{
        .path = "rounded-states",
        .process = .{ .exe_path = "", .anchor_addr = 0, .classes = format.EventClass.user.mask() },
        .start_ns = 0,
        .end_ns = 3.7,
    };
    try session.threads.put(a, 0, .{
        .thread = 0,
        .os_tid = 100,
        .kind = .executor,
        .executor = 0,
        .name = "",
    });
    try session.events.appendSlice(a, &.{
        .{ .thread = 0, .ticks = 0, .ns = 0, .event = .{ .thread_begin = .{} } },
        .{ .thread = 0, .ticks = 1, .ns = 1.4, .event = .{ .flush_begin = .{} } },
        .{ .thread = 0, .ticks = 2, .ns = 2.6, .event = .{ .flush_end = .{} } },
        .{ .thread = 0, .ticks = 3, .ns = 3.7, .event = .{ .thread_end = .{} } },
    });
    const model = try Model.build(a, session);
    var output: std.Io.Writer.Allocating = .init(a);
    try @import("perfetto.zig").write(a, &output.writer, &model, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output.written(), .{});
    var endpoints: usize = 0;
    var previous_end: f64 = 0;
    for (parsed.value.object.get("traceEvents").?.array.items) |event| {
        const object = event.object;
        const category = object.get("cat") orelse continue;
        if (!std.mem.eql(u8, category.string, "state")) continue;
        const begins = endpoints % 2 == 0;
        try std.testing.expectEqualStrings(if (begins) "B" else "E", object.get("ph").?.string);
        const ns = object.get("ts").?.float;
        if (begins) try std.testing.expectEqual(previous_end, ns) else previous_end = ns;
        endpoints += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), endpoints);
}

test "I/O outcome latency excludes canceled failed and pending operations from success" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: Session = .{
        .path = "io-outcomes",
        .process = all_recorded,
        .start_ns = 0,
        .end_ns = 1500,
    };
    try session.threads.put(a, 0, .{
        .thread = 0,
        .os_tid = 100,
        .kind = .executor,
        .executor = 0,
        .name = "",
    });
    try session.events.appendSlice(a, &.{
        .{ .thread = 0, .ticks = 0, .ns = 0, .event = .{ .io_submit = .{ .op = 1, .kind = 4 } } },
        .{ .thread = 0, .ticks = 1, .ns = 10, .event = .{ .io_complete = .{ .op = 1, .result = .ok } } },
        .{ .thread = 0, .ticks = 2, .ns = 20, .event = .{ .io_submit = .{ .op = 1, .kind = 4 } } },
        .{ .thread = 0, .ticks = 3, .ns = 1020, .event = .{ .io_complete = .{ .op = 1, .result = .canceled } } },
        .{ .thread = 0, .ticks = 4, .ns = 1100, .event = .{ .io_submit = .{ .op = 1, .kind = 4 } } },
        .{ .thread = 0, .ticks = 5, .ns = 1140, .event = .{ .io_complete = .{ .op = 1, .result = .err } } },
        .{ .thread = 0, .ticks = 6, .ns = 1200, .event = .{ .io_submit = .{ .op = 2, .kind = 4 } } },
        .{ .thread = 0, .ticks = 7, .ns = 1300, .event = .{ .io_complete = .{ .op = 3, .result = .ok } } },
    });
    const model = try Model.build(a, session);
    const outcomes = model.io_stats.get(4).?;
    try std.testing.expectEqualSlices(f64, &.{10}, outcomes[@backingInt(format.IoResult.ok)].values.items);
    try std.testing.expectEqualSlices(f64, &.{1000}, outcomes[@backingInt(format.IoResult.canceled)].values.items);
    try std.testing.expectEqualSlices(f64, &.{40}, outcomes[@backingInt(format.IoResult.err)].values.items);
    try std.testing.expectEqual(@as(usize, 1), model.pending_io);
    try std.testing.expectEqual(@as(usize, 1), model.io_pair_errors);
}
