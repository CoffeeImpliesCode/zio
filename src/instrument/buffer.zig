const std = @import("std");
const format = @import("format.zig");

test "instrument buffer rollover remains independently decodable and contiguous" {
    var buffer: Buffer = .{};
    var seq: u64 = 0;
    var decoded: usize = 0;
    for (0..100000) |i| {
        const payload: format.Payload(.task_begin) = .{ .task = i + 1 };
        if (!buffer.append(.task_begin, i * 100, payload)) {
            const bytes = buffer.seal(7, seq);
            const chunk = try format.parseChunk(bytes);
            try std.testing.expectEqual(seq, chunk.header.seq);
            var it = chunk.iterator();
            while (try it.next()) |event| {
                decoded += 1;
                try std.testing.expectEqual(decoded, event.event.task_begin.task);
            }
            seq += 1;
            buffer.reset();
            try std.testing.expect(buffer.append(.task_begin, i * 100, payload));
        }
    }
    const chunk = try format.parseChunk(buffer.seal(7, seq));
    var it = chunk.iterator();
    while (try it.next()) |_| decoded += 1;
    try std.testing.expectEqual(100000, decoded);
    try std.testing.expect(seq > 0);
}

pub const Buffer = struct {
    pub const capacity = 64 * 1024;
    const reserve = 3 * format.max_uleb_len;
    bytes: [capacity]u8 = undefined,
    len: usize = reserve,
    base: u64 = 0,
    last: u64 = 0,
    start: usize = reserve,

    pub fn append(self: *Buffer, comptime tag: format.EventTag, ticks: u64, payload: format.Payload(tag)) bool {
        const dt = if (self.len == reserve) 0 else ticks -% self.last;
        const maximum = comptime format.eventMaxLen(tag);
        const needed = if (comptime maximum != null) maximum.? else format.eventLen(tag, dt, payload);
        const priority = tag == .flush_begin or tag == .flush_end or tag == .thread_end;
        const limit = if (priority) capacity else capacity - 64;
        if (needed > limit -| self.len) return false;
        if (self.len == reserve) self.base = ticks;
        self.len += format.writeEvent(self.bytes[self.len..], tag, dt, payload);
        self.last = ticks;
        return true;
    }

    pub fn seal(self: *Buffer, thread: u64, seq: u64) []const u8 {
        const header: format.record.Chunk = .{ .thread = thread, .seq = seq, .base_ticks = self.base };
        self.start = reserve - format.fieldsLen(header);
        _ = format.writeFields(self.bytes[self.start..reserve], header);
        return self.bytes[self.start..self.len];
    }

    pub fn empty(self: *const Buffer) bool {
        return self.len == reserve;
    }

    pub fn reset(self: *Buffer) void {
        self.len = reserve;
        self.start = reserve;
    }
};
