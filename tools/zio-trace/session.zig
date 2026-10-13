const std = @import("std");
pub const format = @import("zio_trace_format");

pub const Clock = struct {
    origin_ticks: u64 = 0,
    origin_ns: f64 = 0,
    slope: f64 = 1,

    pub fn fit(points: []const format.record.Calibration, frequency: u64) Clock {
        var result: Clock = .{ .slope = if (frequency > 0) 1e9 / @as(f64, @floatFromInt(frequency)) else 1 };
        if (points.len == 0) return result;
        result.origin_ticks = points[0].ticks;
        result.origin_ns = @floatFromInt(points[0].monotonic_ns);
        if (points.len == 1) return result;
        var mean_x: f64 = 0;
        var mean_y: f64 = 0;
        for (points) |p| {
            mean_x += delta(p.ticks, result.origin_ticks);
            mean_y += delta(p.monotonic_ns, points[0].monotonic_ns);
        }
        const count: f64 = @floatFromInt(points.len);
        mean_x /= count;
        mean_y /= count;
        var covariance: f64 = 0;
        var variance: f64 = 0;
        for (points) |p| {
            const x = delta(p.ticks, result.origin_ticks) - mean_x;
            covariance += x * (delta(p.monotonic_ns, points[0].monotonic_ns) - mean_y);
            variance += x * x;
        }
        if (variance > 0 and covariance > 0) result.slope = covariance / variance;
        result.origin_ns += mean_y - result.slope * mean_x;
        return result;
    }

    pub fn ns(self: Clock, ticks: u64) f64 {
        return self.origin_ns + self.slope * delta(ticks, self.origin_ticks);
    }

    fn delta(value: u64, origin: u64) f64 {
        return if (value >= origin) @floatFromInt(value - origin) else -@as(f64, @floatFromInt(origin - value));
    }
};

pub const Event = struct { thread: u64, ticks: u64, ns: f64 = 0, event: format.Event };
const Chunk = struct { view: format.ChunkView };

/// All allocations (including decoded strings) live in the caller's session arena.
pub const Session = struct {
    path: []const u8,
    header: format.FileHeader = .{ .clock = .monotonic_ns, .ticks_per_second = 1_000_000_000, .pid = 0, .start_realtime_ns = 0 },
    process: ?format.record.Process = null,
    threads: std.AutoHashMapUnmanaged(u64, format.record.Thread) = .empty,
    names: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    calibrations: std.ArrayList(format.record.Calibration) = .empty,
    chunks: std.ArrayList(Chunk) = .empty,
    events: std.ArrayList(Event) = .empty,
    clock: Clock = .{},
    dropped: u64 = 0,
    decode_errors: usize = 0,
    sequence_errors: usize = 0,
    files: usize = 0,
    start_ns: f64 = 0,
    end_ns: f64 = 0,

    pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Session {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var self: Session = .{ .path = path };
        var header_set = false;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".dump")) continue;
            const bytes = try dir.readFileAlloc(io, entry.name, a, .unlimited);
            self.files += 1;
            var reader = format.FileReader.init(bytes) catch {
                self.decode_errors += 1;
                continue;
            };
            if (!header_set or std.mem.eql(u8, entry.name, "process.dump")) {
                self.header = reader.header;
                header_set = true;
            }
            while (true) {
                const record = (reader.next() catch {
                    self.decode_errors += 1;
                    break;
                }) orelse break;
                self.decodeRecord(a, record) catch |err| switch (err) {
                    error.Truncated, error.Overflow, error.InvalidValue => self.decode_errors += 1,
                    else => return err,
                };
            }
        }
        if (self.files == 0) return error.NoDumpFiles;
        if (self.header.clock != .monotonic_ns and self.header.ticks_per_second == 0 and self.calibrations.items.len < 2) return error.UncalibratedClock;
        self.clock = Clock.fit(self.calibrations.items, self.header.ticks_per_second);
        std.mem.sort(Chunk, self.chunks.items, {}, chunkLess);
        var event_drops: u64 = 0;
        var previous_chunk: ?format.record.Chunk = null;
        for (self.chunks.items) |chunk| {
            const header = chunk.view.header;
            const expected = if (previous_chunk) |previous|
                if (previous.thread == header.thread) previous.seq +| 1 else 0
            else
                0;
            if (header.seq != expected) self.sequence_errors += 1;
            previous_chunk = header;
            var events = chunk.view.iterator();
            while (true) {
                const event = (events.next() catch {
                    self.decode_errors += 1;
                    break;
                }) orelse break;
                if (event.event == .dropped) event_drops +|= event.event.dropped.count;
                try self.events.append(a, .{ .thread = chunk.view.header.thread, .ticks = event.ticks, .ns = self.clock.ns(event.ticks), .event = event.event });
            }
        }
        // The end record is the session total, not an additional loss report.
        self.dropped = @max(self.dropped, event_drops);
        std.mem.sort(Event, self.events.items, {}, eventLess);
        if (self.events.items.len > 0) {
            self.start_ns = self.events.items[0].ns;
            self.end_ns = self.events.items[self.events.items.len - 1].ns;
        }
        return self;
    }

    fn decodeRecord(self: *Session, a: std.mem.Allocator, raw: format.RawRecord) !void {
        switch (raw.kind) {
            .process => self.process = try format.parseRecord(.process, raw.payload),
            .thread => {
                const thread = try format.parseRecord(.thread, raw.payload);
                try self.threads.put(a, thread.thread, thread);
            },
            .calibration => try self.calibrations.append(a, try format.parseRecord(.calibration, raw.payload)),
            .name => {
                const name = try format.parseRecord(.name, raw.payload);
                if (name.table == .io_op) try self.names.put(a, name.value, name.name);
            },
            .chunk => try self.chunks.append(a, .{ .view = try format.parseChunk(raw.payload) }),
            .end => self.dropped +|= (try format.parseRecord(.end, raw.payload)).dropped,
            _ => {},
        }
    }

    fn chunkLess(_: void, lhs: Chunk, rhs: Chunk) bool {
        return if (lhs.view.header.thread == rhs.view.header.thread) lhs.view.header.seq < rhs.view.header.seq else lhs.view.header.thread < rhs.view.header.thread;
    }
    fn eventLess(_: void, lhs: Event, rhs: Event) bool {
        return lhs.ns < rhs.ns;
    }
};

pub fn newest(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, ".zio", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var best: ?[]const u8 = null;
    var stamp: u64 = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const end = std.mem.indexOfScalar(u8, entry.name, '-') orelse entry.name.len;
        const value = std.fmt.parseInt(u64, entry.name[0..end], 10) catch continue;
        if (best == null or value > stamp or (value == stamp and std.mem.order(u8, entry.name, best.?) == .gt)) {
            best = try a.dupe(u8, entry.name);
            stamp = value;
        }
    }
    return a.print(".zio/{s}", .{best orelse return error.NoTraceSessions});
}
