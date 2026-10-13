const std = @import("std");
const timeline = @import("timeline.zig");
const format = @import("zio_trace_format");
const Writer = std.Io.Writer;

const Lane = enum(u3) {
    execution,
    states,
    parks,
    work,
    wakes,

    fn mask(self: Lane) u8 {
        return @as(u8, 1) << @intCast(@backingInt(self));
    }
};
const lane_count = std.enums.values(Lane).len;
const Anchor = struct { flow: usize, out: bool };

pub fn write(a: std.mem.Allocator, w: *Writer, model: *const timeline.Model, flows: bool) !void {
    const pid = model.session.header.pid;
    const lanes = try a.alloc(u8, model.threads.items.len);
    defer a.free(lanes);
    @memset(lanes, Lane.execution.mask());
    for (model.slices.items) |*slice| {
        const lane = sliceLane(slice) orelse continue;
        lanes[model.thread_indices.get(slice.thread).?] |= lane.mask();
    }
    for (model.work_spans.items) |span| {
        if (span.physical) lanes[model.thread_indices.get(span.begin_thread).?] |= Lane.work.mask();
    }
    if (flows) for (model.flows.items) |flow| {
        lanes[model.thread_indices.get(flow.source_thread).?] |= Lane.wakes.mask();
        lanes[model.thread_indices.get(flow.target_thread).?] |= Lane.wakes.mask();
    };
    try w.writeAll("{\"displayTimeUnit\":\"ms\",\"zioTrace\":{\"sessionPath\":");
    try json(w, model.session.path);
    try w.writeAll(",\"recordedClasses\":");
    if (model.session.classMask()) |mask| {
        try w.writeAll("[");
        var separator: []const u8 = "";
        inline for (std.enums.values(format.EventClass)) |class| {
            if (mask & class.mask() != 0) {
                try w.writeAll(separator);
                try json(w, @tagName(class));
                separator = ",";
            }
        }
        try w.writeAll("]");
    } else try w.writeAll("null");
    try w.writeAll(",\"diagnostics\":");
    try diagnostics(w, model);
    try w.writeAll(",\"note\":\"Unrecorded classes are unavailable, not zero. " ++
        "Executor utilization requires sched+loop; blocking utilization requires work. " ++
        "Migration-safe task zones require sched+user. " ++
        "Unfinalized dropped counts are lower bounds, not final totals. " ++
        "Pending I/O is excluded from latency statistics. " ++
        "Blocking work spans show wall time, not CPU time. " ++
        "Lanes are derived views of a physical thread; display tids are not OS tids. " ++
        "Wake/run anchors have zero duration and retain the recorded endpoint timestamps.\"}," ++
        "\"traceEvents\":[\n");
    try w.print("{{\"ph\":\"M\",\"name\":\"process_name\",\"pid\":{d},\"args\":{{\"name\":", .{pid});
    try json(w, if (model.session.process) |process|
        if (process.exe_path.len != 0) std.fs.path.basename(process.exe_path) else "unknown executable"
    else
        "unknown executable");
    try w.writeAll("}}");
    if (damaged(model)) {
        try w.print(",\n{{\"ph\":\"i\",\"s\":\"g\",\"pid\":{d},\"tid\":0,\"ts\":0," ++
            "\"cat\":\"diagnostics\",\"name\":", .{pid});
        try json(w, if (!model.session.finalized)
            "Recording unfinalized: dropped count is a lower bound; statistics may be incomplete"
        else
            "Recording loss or damage: statistics may be incomplete");
        try w.writeAll(",\"args\":");
        try diagnostics(w, model);
        try w.writeAll("}");
    }
    for (model.threads.items, lanes) |thread, used| {
        inline for (std.enums.values(Lane)) |lane| {
            if (used & lane.mask() != 0) {
                var label_buffer: [256]u8 = undefined;
                var label: Writer = .fixed(&label_buffer);
                try label.print("{s} thread {d} · {s}", .{
                    thread.kindName(), thread.info.thread, @tagName(lane),
                });
                if (thread.metadata_known) {
                    if (thread.info.executor != format.no_executor)
                        try label.print(" executor {d}", .{thread.info.executor});
                    try label.print(" tid {d}", .{thread.info.os_tid});
                }
                if (thread.unavailableReason()) |reason|
                    try label.print(" (busy n/a: {s})", .{reason});
                try w.print(",\n{{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":{d},\"tid\":{d},\"args\":{{\"traceThread\":{d},\"lane\":\"{s}\",\"name\":", .{
                    pid, trackId(model, thread.info.thread, lane), thread.info.thread, @tagName(lane),
                });
                try json(w, label.buffered());
                try w.writeAll("}}");
            }
        }
    }
    for (model.slices.items) |*slice| {
        const lane = sliceLane(slice) orelse continue;
        const name: []const u8 = switch (slice.kind) {
            .task => if (model.tasks.get(slice.id)) |task| task.name else "unknown task",
            .state => switch (slice.state) {
                .poll_check, .poll_wait, .flush => @tagName(slice.state),
                .unknown => if (model.thread(slice.thread)) |thread|
                    if (!thread.metadata_known)
                        "unclassified time (thread metadata missing)"
                    else if (thread.classes == null)
                        "unclassified time (recorded classes unknown)"
                    else
                        "unclassified time (required classes not recorded)"
                else
                    "unclassified time",
                else => unreachable,
            },
            .park => "park",
            .zone => if (model.zones.get(slice.id)) |zone| zone.name else "unknown zone",
        };
        const tid = trackId(model, slice.thread, lane);
        // State intervals partition a timeline. Serialize their common endpoints
        // rather than independently rounding ts+dur into overlapping X events.
        if (slice.kind == .state) {
            try w.print(",\n{{\"ph\":\"B\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3},\"cat\":\"state\",\"name\":", .{
                pid, tid, (slice.start - model.session.start_ns) / 1000,
            });
            try json(w, name);
            try w.print(",\"args\":{{\"traceThread\":{d}}}}}", .{slice.thread});
            try w.print(",\n{{\"ph\":\"E\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3},\"cat\":\"state\"}}", .{
                pid, tid, (slice.end - model.session.start_ns) / 1000,
            });
        } else {
            try w.print(",\n{{\"ph\":\"X\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3},\"dur\":{d:.3},\"cat\":", .{
                pid, tid, (slice.start - model.session.start_ns) / 1000, (slice.end - slice.start) / 1000,
            });
            try json(w, @tagName(slice.kind));
            try w.writeAll(",\"name\":");
            try json(w, name);
            try w.print(",\"args\":{{\"id\":\"0x{x}\",\"traceThread\":{d}}}}}", .{ slice.id, slice.thread });
        }
    }
    for (model.work_spans.items) |*span| {
        if (span.physical) {
            try w.print(
                ",\n{{\"ph\":\"X\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3},\"dur\":{d:.3}," ++
                    "\"cat\":\"work\",\"name\":\"blocking work (wall time)\",\"args\":{{" ++
                    "\"id\":\"0x{x}\",\"beginThread\":{d},\"endThread\":{d}," ++
                    "\"canceled\":{s},\"physical\":true,\"includesSuspension\":true}}}}",
                .{
                    pid,                                          trackId(model, span.begin_thread, .work),
                    (span.start - model.session.start_ns) / 1000, (span.end - span.start) / 1000,
                    span.work,                                    span.begin_thread,
                    span.end_thread,                              if (span.canceled) "true" else "false",
                },
            );
        } else {
            inline for (.{ true, false }) |begin| {
                const thread = if (begin) span.begin_thread else span.end_thread;
                try w.print(
                    ",\n{{\"ph\":\"{s}\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3}," ++
                        "\"cat\":\"work\",\"id2\":{{\"local\":\"{d}:0x{x}\"}}," ++
                        "\"name\":\"blocking work (wall time; includes suspension)\"," ++
                        "\"args\":{{\"beginThread\":{d},\"endThread\":{d}," ++
                        "\"canceled\":{s},\"physical\":false,\"includesSuspension\":true}}}}",
                    .{
                        if (begin) "b" else "e",                                                 pid,                                    trackId(model, thread, .execution),
                        ((if (begin) span.start else span.end) - model.session.start_ns) / 1000, model.session.header.start_realtime_ns, span.work,
                        span.begin_thread,                                                       span.end_thread,                        if (span.canceled) "true" else "false",
                    },
                );
            }
        }
    }
    // These endpoints retain source order, including nested zones at equal timestamps.
    for (model.zone_events.items) |event| {
        try w.print(
            ",\n{{\"ph\":\"{s}\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3}," ++
                "\"cat\":\"zone\",\"id2\":{{\"local\":\"{d}:0x{x}\"}},\"name\":",
            .{
                if (event.begin) "b" else "e",              pid,                                    trackId(model, event.thread, .execution),
                (event.ns - model.session.start_ns) / 1000, model.session.header.start_realtime_ns, event.task,
            },
        );
        const zone = model.zones.get(event.srcloc).?;
        try json(w, zone.name);
        try w.print(",\"args\":{{\"srcloc\":\"0x{x}\",\"task\":{d},\"traceThread\":{d}}}}}", .{
            event.srcloc, event.task, event.thread,
        });
    }
    for (model.session.events.items) |event| {
        if (!model.session.hasClass(.user)) continue;
        switch (event.event) {
            .plot => |plot| {
                try w.print(",\n{{\"ph\":\"C\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3},\"name\":", .{
                    pid, trackId(model, event.thread, .execution), (event.ns - model.session.start_ns) / 1000,
                });
                try json(w, plot.name);
                try w.print(",\"args\":{{\"value\":{d}}}}}", .{plot.value});
            },
            .message => |message| {
                try w.print(",\n{{\"ph\":\"i\",\"s\":\"t\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3},\"name\":", .{
                    pid, trackId(model, event.thread, .execution), (event.ns - model.session.start_ns) / 1000,
                });
                try json(w, message.text);
                try w.writeAll("}");
            },
            else => {},
        }
    }
    if (flows and model.flows.items.len != 0) try writeFlows(a, w, model);
    try w.writeAll("\n]}\n");
}

fn sliceLane(slice: *const timeline.Slice) ?Lane {
    return switch (slice.kind) {
        .task, .zone => .execution,
        .park => .parks,
        .state => switch (slice.state) {
            .poll_check, .poll_wait, .flush, .unknown => .states,
            else => null,
        },
    };
}

fn trackId(model: *const timeline.Model, thread: u64, lane: Lane) usize {
    return model.thread_indices.get(thread).? * lane_count + @backingInt(lane) + 1;
}

fn anchorTime(model: *const timeline.Model, anchor: Anchor) f64 {
    const flow = &model.flows.items[anchor.flow];
    return if (anchor.out) flow.start else flow.end;
}

fn anchorLess(model: *const timeline.Model, lhs: Anchor, rhs: Anchor) bool {
    const left = anchorTime(model, lhs);
    const right = anchorTime(model, rhs);
    if (left != right) return left < right;
    if (lhs.flow != rhs.flow) return lhs.flow < rhs.flow;
    return lhs.out and !rhs.out;
}

fn writeFlows(a: std.mem.Allocator, w: *Writer, model: *const timeline.Model) !void {
    const anchors = try a.alloc(Anchor, model.flows.items.len * 2);
    defer a.free(anchors);
    const ids = try a.alloc(u64, model.flows.items.len);
    defer a.free(ids);
    const seed = std.hash.Wyhash.hash(model.session.header.pid, std.mem.asBytes(&model.session.header.start_realtime_ns));
    for (ids, 0..) |*id, index| {
        const ordinal: u64 = @intCast(index);
        id.* = std.hash.Wyhash.hash(seed, std.mem.asBytes(&ordinal));
        anchors[index * 2] = .{ .flow = index, .out = true };
        anchors[index * 2 + 1] = .{ .flow = index, .out = false };
    }
    std.mem.sort(Anchor, anchors, model, anchorLess);
    for (anchors) |anchor| {
        const flow = &model.flows.items[anchor.flow];
        const thread = if (anchor.out) flow.source_thread else flow.target_thread;
        const tid = trackId(model, thread, .wakes);
        const ns = (anchorTime(model, anchor) - model.session.start_ns) / 1000;
        // A complete zero-duration slice binds at the recorded wake/run point.
        // Equal-timestamp B/E pairs are reordered by the importer and stay open.
        try w.print(",\n{{\"ph\":\"X\",\"dur\":0,\"cat\":\"wake\",\"name\":\"{s}\",\"pid\":{d},\"tid\":{d},\"ts\":{d:.3},\"bind_id\":\"0x{x}\",\"flow_{s}\":true,\"args\":{{\"task\":{d},\"traceThread\":{d}}}}}", .{
            if (anchor.out) "wake" else "run", model.session.header.pid,        tid,       ns,
            ids[anchor.flow],                  if (anchor.out) "out" else "in", flow.task, thread,
        });
    }
}

fn damaged(model: *const timeline.Model) bool {
    return !model.session.finalized or model.session.dropped != 0 or
        model.session.decode_errors != 0 or model.session.sequence_errors != 0 or
        model.session.header_mismatches != 0 or model.missing_threads != 0 or
        model.incomplete_slices != 0 or model.task_pair_errors != 0 or
        model.io_pair_errors != 0;
}

fn diagnostics(w: *Writer, model: *const timeline.Model) !void {
    try std.json.Stringify.value(.{
        .finalized = model.session.finalized,
        .dropped = model.session.dropped,
        .decodeErrors = model.session.decode_errors,
        .sequenceErrors = model.session.sequence_errors,
        .headerMismatches = model.session.header_mismatches,
        .missingThreads = model.missing_threads,
        .incompleteSlices = model.incomplete_slices,
        .taskPairErrors = model.task_pair_errors,
        .pendingIo = model.pending_io,
        .ioPairErrors = model.io_pair_errors,
    }, .{}, w);
}

fn json(w: *Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, w);
}
