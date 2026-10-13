const std = @import("std");
const timeline = @import("timeline.zig");
const format = @import("zio_trace_format");
const Writer = std.Io.Writer;

pub fn write(a: std.mem.Allocator, w: *Writer, model: *const timeline.Model, flows: bool) !void {
    try w.writeAll("{\"displayTimeUnit\":\"ms\",\"zioTrace\":{\"recordedClasses\":");
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
    try w.writeAll(",\"note\":\"Unrecorded classes are unavailable, not zero. " ++
        "Executor utilization requires sched+loop; blocking utilization requires work. " ++
        "Migration-safe task zones require sched+user.\"},\"traceEvents\":[\n");
    try w.writeAll("{\"ph\":\"M\",\"name\":\"process_name\",\"pid\":1,\"args\":{\"name\":");
    try json(w, model.session.path);
    try w.writeAll("}}");
    for (model.threads.items) |thread| {
        const label = if (thread.unavailableReason()) |reason|
            try a.print("{s} executor {d} tid {d} (busy n/a: {s})", .{ @tagName(thread.info.kind), thread.info.executor, thread.info.os_tid, reason })
        else
            try a.print("{s} executor {d} tid {d}", .{ @tagName(thread.info.kind), thread.info.executor, thread.info.os_tid });
        try w.print(",\n{{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":1,\"tid\":{d},\"args\":{{\"name\":", .{thread.info.thread});
        try json(w, label);
        try w.writeAll("}}");
    }
    for (model.slices.items) |slice| {
        const name: []const u8 = switch (slice.kind) {
            .task => if (model.tasks.get(slice.id)) |task| task.name else "unknown task",
            .state => switch (slice.state) {
                .poll_check, .poll_wait, .flush => @tagName(slice.state),
                .unknown => "unclassified time (required classes not recorded)",
                else => continue,
            },
            .park => "park",
            .work => "blocking work",
            .zone => if (model.zones.get(slice.id)) |zone| zone.name else "unknown zone",
        };
        try w.print(",\n{{\"ph\":\"X\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"dur\":{d:.3},\"cat\":", .{ slice.thread, (slice.start - model.session.start_ns) / 1000, (slice.end - slice.start) / 1000 });
        try json(w, @tagName(slice.kind));
        try w.writeAll(",\"name\":");
        try json(w, name);
        try w.print(",\"args\":{{\"id\":\"0x{x}\"}}}}", .{slice.id});
    }
    // These endpoints retain source order, including nested zones at equal timestamps.
    for (model.zone_events.items) |event| {
        try w.print(
            ",\n{{\"ph\":\"{s}\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3}," ++
                "\"cat\":\"zone\",\"scope\":\"zio.task.zone\",\"id\":\"{d}\",\"name\":",
            .{ if (event.begin) "b" else "e", event.thread, (event.ns - model.session.start_ns) / 1000, event.task },
        );
        const zone = model.zones.get(event.srcloc).?;
        try json(w, zone.name);
        try w.print(",\"args\":{{\"srcloc\":\"0x{x}\"}}}}", .{event.srcloc});
    }
    for (model.session.events.items) |event| {
        if (!model.session.hasClass(.user)) continue;
        switch (event.event) {
            .plot => |plot| {
                try w.print(",\n{{\"ph\":\"C\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"name\":", .{ event.thread, (event.ns - model.session.start_ns) / 1000 });
                try json(w, plot.name);
                try w.print(",\"args\":{{\"value\":{d}}}}}", .{plot.value});
            },
            .message => |message| {
                try w.print(",\n{{\"ph\":\"i\",\"s\":\"t\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"name\":", .{ event.thread, (event.ns - model.session.start_ns) / 1000 });
                try json(w, message.text);
                try w.writeAll("}");
            },
            else => {},
        }
    }
    if (flows) for (model.flows.items, 0..) |flow, id| {
        try w.print(",\n{{\"ph\":\"s\",\"cat\":\"wake\",\"name\":\"wake->run\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"id\":{d}}}", .{ flow.source_thread, (flow.start - model.session.start_ns) / 1000, id });
        try w.print(",\n{{\"ph\":\"f\",\"bp\":\"e\",\"cat\":\"wake\",\"name\":\"wake->run\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"id\":{d}}}", .{ flow.target_thread, (flow.end - model.session.start_ns) / 1000, id });
    };
    try w.writeAll("\n]}\n");
}
fn json(w: *Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, w);
}
