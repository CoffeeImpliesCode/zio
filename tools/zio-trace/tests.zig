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
    try std.testing.expectApproxEqAbs(@as(f64, 20), model.io_stats.get(4).?.values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20), model.zones.get(5).?.samples.values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), model.plots.get("plot\nescaped").?.total / 2, 0.001);
    var json: std.Io.Writer.Allocating = .init(a);
    try @import("perfetto.zig").write(a, &json.writer, &model, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json.written(), .{});
    try std.testing.expect(parsed.value.object.get("traceEvents").?.array.items.len > 5);
    var svg: std.Io.Writer.Allocating = .init(a);
    try @import("svg.zig").write(a, &svg.writer, &model, 12);
    try std.testing.expect(std.mem.indexOf(u8, svg.written(), "mean busy 58.3%") != null);
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
    try std.testing.expectApproxEqAbs(@as(f64, 20), zone.cpu_samples.values.items[0], 0.001);
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
            try std.testing.expectEqual(@as(i64, 0), object.get("tid").?.integer);
            try std.testing.expectEqualStrings("1", object.get("id").?.string);
            try std.testing.expectEqualStrings("migrated", object.get("name").?.string);
        }
        if (std.mem.eql(u8, phase, "e")) {
            ends += 1;
            try std.testing.expectEqual(@as(i64, 1), object.get("tid").?.integer);
            try std.testing.expectEqualStrings("1", object.get("id").?.string);
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
    try std.testing.expectEqual(@as(usize, 2), outer.cpu_samples.values.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 27), outer.samples.values.items[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 7), outer.cpu_samples.values.items[1], 0.001);
    const inner = model.zones.get(6).?;
    try std.testing.expectApproxEqAbs(@as(f64, 25), inner.samples.values.items[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 5), inner.cpu_samples.values.items[0], 0.001);
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

test "thread lifetime markers bound idle time and SVG observed background" {
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
    var svg: std.Io.Writer.Allocating = .init(a);
    try @import("svg.zig").write(a, &svg.writer, &model, 10);
    try std.testing.expect(std.mem.indexOf(u8, svg.written(), "<rect class=\"observed-interval\" x=\"387.000\" y=\"82.000\"" ++
        " width=\"696.000\" height=\"44\" fill=\"#fafafa\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg.written(), "mean busy 25.0%") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "Blocking pool: not recorded") != null);
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
