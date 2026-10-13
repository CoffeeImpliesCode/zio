const std = @import("std");
const timeline = @import("timeline.zig");
const Writer = std.Io.Writer;
const colors = [_][]const u8{
    "#2563eb", "#60a5fa", "#22c55e", "#cbd5e1",
    "#f97316", "#7c3aed", "#f1f5f9", "#94a3b8",
};

pub fn write(a: std.mem.Allocator, w: *Writer, model: *const timeline.Model, bins: usize) !void {
    const width: f64 = 870;
    const left: f64 = 300;
    const height = 145 + model.threads.items.len * 74;
    const duration = @max(1, model.session.end_ns - model.session.start_ns);
    const bin_ns = duration / @as(f64, @floatFromInt(bins));
    const bin_width = width / @as(f64, @floatFromInt(bins));
    try w.print("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"{d}\" viewBox=\"0 0 1200 {d}\"><style>text{{font-family:system-ui,sans-serif;fill:#0f172a;font-size:12px}}.title{{font-size:20px;font-weight:600}}.minor{{fill:#475569;font-size:11px}}</style><rect width=\"1200\" height=\"{d}\" fill=\"white\"/><text x=\"20\" y=\"28\" class=\"title\">zio thread utilization</text>\n", .{ height, height, height });
    inline for (@typeInfo(timeline.State).@"enum".field_names, colors, 0..) |name, color, i| {
        try w.print("<rect x=\"{d}\" y=\"45\" width=\"12\" height=\"12\"" ++
            " fill=\"{s}\"/><text x=\"{d}\" y=\"56\">{s}</text>\n", .{ 20 + i * 145, color, 38 + i * 145, name });
    }
    const fractions = try a.alloc([timeline.state_count]f64, bins);
    for (model.threads.items, 0..) |thread, row| {
        @memset(fractions, @splat(0));
        for (model.slices.items) |slice| {
            if (slice.kind != .state or slice.thread != thread.info.thread) continue;
            const start = @max(0, slice.start - model.session.start_ns);
            const end = @min(duration, slice.end - model.session.start_ns);
            if (end <= start) continue;
            const first = @min(bins - 1, @as(usize, @intFromFloat(@floor(start / bin_ns))));
            const last = @min(bins - 1, @as(usize, @intFromFloat(@floor(end / bin_ns))));
            for (first..last + 1) |bin| {
                const lo = @as(f64, @floatFromInt(bin)) * bin_ns;
                fractions[bin][@backingInt(slice.state)] += @max(0, @min(end, lo + bin_ns) - @max(start, lo)) / bin_ns;
            }
        }
        const y: f64 = @floatFromInt(82 + row * 74);
        try w.print("<text x=\"20\" y=\"{d:.2}\">thread {d} · {s} · tid {d}</text>\n", .{ y + 15, thread.info.thread, @tagName(thread.info.kind), thread.info.os_tid });
        try w.print("<text x=\"20\" y=\"{d:.2}\" class=\"minor\">executor ", .{y + 34});
        if (thread.info.executor == @import("zio_trace_format").no_executor) try w.writeAll("—") else try w.print("{d}", .{thread.info.executor});
        if (thread.busyPercent()) |busy| {
            try w.print(" · mean busy {d:.1}%</text>\n", .{busy});
        } else {
            try w.writeAll(" · mean busy n/a</text>\n");
            const reason = thread.unavailableReason().?;
            try w.print("<text x=\"20\" y=\"{d:.2}\" class=\"minor\">{s}</text>\n", .{ y + 51, reason });
        }
        try w.print(
            "<rect x=\"300\" y=\"{d:.2}\" width=\"870\" height=\"44\"" ++
                " fill=\"none\" stroke=\"#e2e8f0\"/>\n",
            .{y},
        );
        const interval_start = std.math.clamp((thread.first orelse model.session.start_ns) - model.session.start_ns, 0, duration);
        const interval_end = std.math.clamp(thread.last - model.session.start_ns, interval_start, duration);
        const interval_x = left + interval_start / duration * width;
        const interval_width = (interval_end - interval_start) / duration * width;
        try w.print(
            "<rect class=\"observed-interval\" x=\"{d:.3}\" y=\"{d:.3}\"" ++
                " width=\"{d:.3}\" height=\"44\" fill=\"#fafafa\"/>\n",
            .{ interval_x, y, interval_width },
        );
        try w.print(
            "<clipPath id=\"observed-{d}\"><rect x=\"{d:.3}\" y=\"{d:.3}\"" ++
                " width=\"{d:.3}\" height=\"44\"/></clipPath>" ++
                "<g clip-path=\"url(#observed-{d})\">\n",
            .{ thread.info.thread, interval_x, y, interval_width, thread.info.thread },
        );
        for (fractions, 0..) |fraction, bin| {
            var offset: f64 = 0;
            for (fraction, colors) |value, color| {
                if (value <= 0) continue;
                const h = 44 * value;
                try w.print("<rect x=\"{d:.3}\" y=\"{d:.3}\" width=\"{d:.3}\" height=\"{d:.3}\" fill=\"{s}\"/>\n", .{ left + @as(f64, @floatFromInt(bin)) * bin_width, y + 44 - offset - h, bin_width + 0.02, h, color });
                offset += h;
            }
        }
        if (thread.info.kind == .other) {
            for (model.session.events.items) |event| {
                if (event.thread != thread.info.thread) continue;
                try w.print("<path d=\"M {d:.3} {d:.3} v 12\" stroke=\"#64748b\"/>\n", .{ left + (event.ns - model.session.start_ns) / duration * width, y + 16 });
            }
        }
        try w.writeAll("</g>\n");
    }
    const axis_y = 82 + model.threads.items.len * 74;
    for (0..7) |tick| {
        const fraction = @as(f64, @floatFromInt(tick)) / 6;
        try w.print("<path d=\"M {d:.2} {d} v 5\" stroke=\"#64748b\"/><text x=\"{d:.2}\" y=\"{d}\" text-anchor=\"middle\">{d:.2} ms</text>\n", .{ left + width * fraction, axis_y, left + width * fraction, axis_y + 21, duration * fraction / 1e6 });
    }
    try w.print("<text x=\"300\" y=\"{d}\" class=\"minor\">" ++
        "Relative to first event; bars show fractions of each time bin. " ++
        "Blank time is outside a thread's observed interval.</text>\n", .{axis_y + 43});
    try w.print("<text x=\"300\" y=\"{d}\" class=\"minor\">" ++
        "Unknown = unclassified time. Executor utilization requires sched+loop; " ++
        "blocking utilization requires work.</text></svg>\n", .{axis_y + 58});
}
