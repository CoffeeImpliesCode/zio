// SPDX-FileCopyrightText: 2026 zio contributors
// SPDX-License-Identifier: MIT

//! On-disk format of a zio trace. Shared by the runtime writer
//! (`src/instrument/`) and the offline analyzer (`tools/zio-trace/`); it
//! depends on `std` only.
//!
//! A traced run (built with `-Dinstrument=true`, started with
//! `ZIO_PROFILE=1`) writes one session directory under the working
//! directory:
//!
//!     .zio/<start_realtime_ns>/process.dump         process, name, calibration, end records
//!     .zio/<start_realtime_ns>/<os_tid>-<thread>.dump  one thread's thread record and chunks
//!
//! `<thread>` is the trace-local thread index (`record.Thread.thread`), so
//! files stay unique when the OS reuses a thread id. If the directory
//! already exists, `-<pid>` is appended to its name.
//!
//! Every dump file is a `FileHeader` followed by records until end of file:
//!
//!     record  := kind:u8  len:uleb128  payload[len]
//!
//! Record payloads (except `chunk`) and event payloads are sequences of
//! fields in declaration order of their payload struct:
//!
//!     u64, enum(uN)  -> uleb128
//!     i64            -> zigzag, then uleb128
//!     bool           -> one byte, 0 or 1
//!     []const u8     -> uleb128 length, then the bytes
//!     AddrList       -> uleb128 count, then count uleb128 addresses
//!
//! A `chunk` record carries a run of one thread's events:
//!
//!     chunk   := thread:uleb128  seq:uleb128  base_ticks:uleb128  event*
//!     event   := tag:u8  dt:uleb128  fields
//!
//! `dt` is the tick delta from the previous event in the same chunk, or from
//! `base_ticks` for the first one, so every chunk decodes on its own. A
//! thread's chunks carry consecutive `seq` numbers starting at 0.
//!
//! Ticks convert to nanoseconds through the `calibration` records, which pair
//! a tick reading with a CLOCK_MONOTONIC reading. With two or more, fit a
//! line; with one, use `FileHeader.ticks_per_second`.
//!
//! Readers must skip records of unknown kind (the length makes this possible)
//! and stop decoding a chunk at the first unknown event tag. A file cut short
//! by a crash is valid up to its last complete record.
const std = @import("std");

pub const magic = "ZIOTRACE".*;
pub const version: u16 = 1;

/// Name of the exported function whose run-time address the `process` record
/// carries. The analyzer looks the symbol up in the executable to compute
/// the load bias of a position-independent executable.
pub const anchor_symbol = "zio_trace_anchor";

pub const ClockKind = enum(u8) {
    /// x86 RDTSC; invariant TSC assumed.
    tsc = 0,
    /// AArch64 CNTVCT_EL0.
    cntvct = 1,
    /// CLOCK_MONOTONIC nanoseconds; ticks are nanoseconds.
    monotonic_ns = 2,
};

pub const FileHeader = extern struct {
    magic: [8]u8 = magic,
    version: u16 = version,
    header_size: u16 = @sizeOf(FileHeader),
    clock: ClockKind,
    pointer_size: u8 = @sizeOf(usize),
    reserved: [2]u8 = @splat(0),
    /// Nominal tick frequency; 0 when unknown (derive it from calibration).
    ticks_per_second: u64,
    pid: u64,
    /// CLOCK_REALTIME at session start, for display only.
    start_realtime_ns: i64,

    comptime {
        std.debug.assert(@sizeOf(FileHeader) == 40);
    }
};

pub const RecordKind = enum(u8) {
    process = 1,
    thread = 2,
    calibration = 3,
    name = 4,
    chunk = 5,
    end = 6,
    _,
};

/// Which flavour of thread a `thread` record describes.
pub const ThreadKind = enum(u8) {
    /// Runs an `Executor` (the runtime's own thread included).
    executor = 0,
    /// A blocking thread pool worker.
    blocking = 1,
    /// Any other thread that emitted events (e.g. one that woke a task).
    other = 2,
};

/// Name tables give names to small integers used by events.
pub const NameTable = enum(u8) {
    /// `io_submit.kind`: the event loop operation type.
    io_op = 0,
    _,
};

pub const record = struct {
    pub const Process = struct {
        /// Executable path as seen by the traced process (/proc/self/exe).
        exe_path: []const u8,
        /// Run-time address of `anchor_symbol`.
        anchor_addr: u64,
    };

    pub const Thread = struct {
        /// Trace-local thread index; matches `Chunk.thread`.
        thread: u64,
        os_tid: u64,
        kind: ThreadKind,
        /// Executor id, or `no_executor`.
        executor: u64,
        name: []const u8,
    };

    pub const Calibration = struct {
        ticks: u64,
        monotonic_ns: u64,
    };

    pub const Name = struct {
        table: NameTable,
        value: u64,
        name: []const u8,
    };

    /// Header fields of a `chunk` record; the event bytes follow them.
    pub const Chunk = struct {
        thread: u64,
        seq: u64,
        base_ticks: u64,
    };

    pub const End = struct {
        /// Events dropped across all threads (buffer limit reached).
        dropped: u64,
    };
};

pub const no_executor = std.math.maxInt(u64);
/// `poll_begin.timeout_ns` for an unbounded wait.
pub const infinite_timeout = std.math.maxInt(u64);

pub const TaskEndReason = enum(u8) {
    /// Still runnable: rescheduled (yield, time slice, migration).
    yield = 0,
    /// Waiting for a wake (I/O, timer, lock, channel, join, ...).
    wait = 1,
    /// The task body returned.
    finish = 2,
};

pub const ParkKind = enum(u8) {
    /// Non-blocking probe of the loop before a real park.
    probe = 0,
    /// Indefinite park.
    full = 1,
    /// Park capped at the rescue baton tick.
    baton = 2,
};

pub const StackKind = enum(u8) {
    /// Captured inside the task just before it first switched away.
    first_suspend = 0,
    /// Captured on the spawning side when the task was created.
    spawn = 1,
};

pub const IoResult = enum(u8) {
    ok = 0,
    err = 1,
    canceled = 2,
};

/// Return addresses, innermost first.
pub const AddrList = struct {
    /// Encoding side: the addresses.
    items: []const usize = &.{},
    /// Decoding side: element count and the encoded elements.
    count: usize = 0,
    encoded: []const u8 = &.{},

    pub fn iterator(self: AddrList) Iterator {
        return .{ .bytes = self.encoded, .left = self.count };
    }

    pub const Iterator = struct {
        bytes: []const u8,
        pos: usize = 0,
        left: usize,

        pub fn next(it: *Iterator) DecodeError!?u64 {
            if (it.left == 0) return null;
            it.left -= 1;
            return try readUleb(it.bytes, &it.pos);
        }
    };
};

/// Every event and its payload. Ids: `task` values are nonzero, unique for
/// the session and assigned by the runtime; `op`/`work`/`loop`/`srcloc` are
/// addresses, unique only while the object is alive.
pub const Event = union(enum(u8)) {
    /// `count` events were lost on this thread before this point.
    dropped: struct { count: u64 } = 0,
    /// This thread runs executor `executor`, whose event loop lives at `loop`.
    executor_info: struct { executor: u64, loop: u64 } = 1,

    /// A task was created. `entry` is the type-erased start function (0 for
    /// an executor's main task); `parent` the creating task (0 for none);
    /// `group` the address of its `Group` (0 for none).
    task_create: struct { task: u64, entry: u64, executor: u64, parent: u64, group: u64 } = 2,
    /// The user function behind `task`, when the spawn API knew it.
    task_func: struct { task: u64, func: u64 } = 3,
    task_stack: struct { task: u64, kind: StackKind, frames: AddrList } = 4,
    /// `task` starts or resumes running on this thread.
    task_begin: struct { task: u64 } = 5,
    /// `task` stops running on this thread.
    task_end: struct { task: u64, reason: TaskEndReason } = 6,
    /// This thread made `task` runnable.
    task_wake: struct { task: u64 } = 7,

    /// This executor took `count` tasks from executor `victim`.
    steal: struct { victim: u64, count: u64 } = 8,
    park_begin: struct { kind: ParkKind } = 9,
    park_end: struct {} = 10,

    /// The event loop backend is about to wait for at most `timeout_ns`
    /// (`infinite_timeout`, or 0 for a non-blocking check).
    poll_begin: struct { timeout_ns: u64 } = 11,
    poll_end: struct { timed_out: bool } = 12,
    /// This thread issued a wake-up to the event loop at `loop`.
    loop_wake: struct { loop: u64 } = 13,

    /// Completion `op` of name-table kind `kind` was submitted to this
    /// thread's loop.
    io_submit: struct { op: u64, kind: u64 } = 14,
    io_complete: struct { op: u64, result: IoResult } = 15,

    /// Blocking pool work item `work` was queued / started / finished.
    work_queue: struct { work: u64 } = 16,
    work_begin: struct { work: u64 } = 17,
    work_end: struct { work: u64, canceled: bool } = 18,

    /// User zones. `srcloc` identifies a source location described by an
    /// earlier `srcloc` event on the same thread.
    zone_begin: struct { srcloc: u64 } = 19,
    zone_end: struct { srcloc: u64 } = 20,
    srcloc: struct { srcloc: u64, name: []const u8, function: []const u8, file: []const u8, line: u64 } = 21,
    message: struct { text: []const u8 } = 22,
    plot: struct { name: []const u8, value: i64 } = 23,

    /// This thread is blocked writing trace data, from the event's
    /// timestamp until `flush_end`. Analysis should count it as tracing
    /// overhead, not as runtime work.
    flush_begin: struct {} = 24,
    flush_end: struct {} = 25,

    /// First event of a registered thread (emitted right after its `thread`
    /// record) and its last event before the thread exits or the session
    /// ends. They bound the thread's observed lifetime, idle time included.
    thread_begin: struct {} = 26,
    thread_end: struct {} = 27,
};

pub const EventTag = @typeInfo(Event).@"union".tag_type.?;

pub fn Payload(comptime tag: EventTag) type {
    return @FieldType(Event, @tagName(tag));
}

// ---------------------------------------------------------------------------
// Primitive codec

pub const DecodeError = error{ Truncated, Overflow, InvalidValue };

/// Largest uleb128 encoding of a u64.
pub const max_uleb_len = 10;

pub inline fn writeUleb(buf: []u8, value: u64) usize {
    var v = value;
    var i: usize = 0;
    while (v >= 0x80) : (i += 1) {
        buf[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
    }
    buf[i] = @truncate(v);
    return i + 1;
}

pub fn ulebLen(value: u64) usize {
    var v = value;
    var n: usize = 1;
    while (v >= 0x80) : (n += 1) v >>= 7;
    return n;
}

pub fn readUleb(bytes: []const u8, pos: *usize) DecodeError!u64 {
    var result: u64 = 0;
    var shift: u32 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.Truncated;
        const byte = bytes[pos.*];
        pos.* += 1;
        if (shift == 63 and byte > 1) return error.Overflow;
        result |= @as(u64, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) return result;
        shift += 7;
        if (shift > 63) return error.Overflow;
    }
}

pub inline fn zigzag(value: i64) u64 {
    return @bitCast((value << 1) ^ (value >> 63));
}

pub inline fn unzigzag(value: u64) i64 {
    return @as(i64, @bitCast(value >> 1)) ^ -@as(i64, @bitCast(value & 1));
}

// ---------------------------------------------------------------------------
// Field-sequence codec, shared by event and record payloads

fn fieldMaxLen(comptime T: type) ?usize {
    return switch (T) {
        u64, i64 => max_uleb_len,
        bool => 1,
        []const u8, AddrList => null,
        else => switch (@typeInfo(T)) {
            .@"enum" => ulebLen(std.math.maxInt(@typeInfo(T).@"enum".tag_type)),
            else => @compileError("unsupported trace field type " ++ @typeName(T)),
        },
    };
}

/// Upper bound on the encoded size of `P`, or null if it holds slices.
pub fn fieldsMaxLen(comptime P: type) ?usize {
    const info = @typeInfo(P).@"struct";
    var total: usize = 0;
    inline for (info.field_types) |T| total += fieldMaxLen(T) orelse return null;
    return total;
}

pub fn fieldsLen(payload: anytype) usize {
    const P = @TypeOf(payload);
    const info = @typeInfo(P).@"struct";
    var total: usize = 0;
    inline for (info.field_names, info.field_types) |name, T| {
        const value = @field(payload, name);
        total += switch (T) {
            u64 => ulebLen(value),
            i64 => ulebLen(zigzag(value)),
            bool => 1,
            []const u8 => ulebLen(value.len) + value.len,
            AddrList => blk: {
                var n = ulebLen(value.items.len);
                for (value.items) |addr| n += ulebLen(addr);
                break :blk n;
            },
            else => ulebLen(@backingInt(value)),
        };
    }
    return total;
}

/// Encode `payload` into `buf`, which must hold `fieldsLen(payload)` bytes.
pub inline fn writeFields(buf: []u8, payload: anytype) usize {
    const P = @TypeOf(payload);
    const info = @typeInfo(P).@"struct";
    var i: usize = 0;
    inline for (info.field_names, info.field_types) |name, T| {
        const value = @field(payload, name);
        switch (T) {
            u64 => i += writeUleb(buf[i..], value),
            i64 => i += writeUleb(buf[i..], zigzag(value)),
            bool => {
                buf[i] = @intFromBool(value);
                i += 1;
            },
            []const u8 => {
                i += writeUleb(buf[i..], value.len);
                @memcpy(buf[i..][0..value.len], value);
                i += value.len;
            },
            AddrList => {
                i += writeUleb(buf[i..], value.items.len);
                for (value.items) |addr| i += writeUleb(buf[i..], addr);
            },
            else => i += writeUleb(buf[i..], @backingInt(value)),
        }
    }
    return i;
}

/// Decode a `P` from `bytes` at `pos`. Slices point into `bytes`.
pub fn readFields(comptime P: type, bytes: []const u8, pos: *usize) DecodeError!P {
    const info = @typeInfo(P).@"struct";
    var result: P = undefined;
    inline for (info.field_names, info.field_types) |name, T| {
        @field(result, name) = switch (T) {
            u64 => try readUleb(bytes, pos),
            i64 => unzigzag(try readUleb(bytes, pos)),
            bool => blk: {
                if (pos.* >= bytes.len) return error.Truncated;
                const byte = bytes[pos.*];
                pos.* += 1;
                break :blk switch (byte) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidValue,
                };
            },
            []const u8 => blk: {
                const len = try readUleb(bytes, pos);
                if (len > bytes.len - pos.*) return error.Truncated;
                const start = pos.*;
                pos.* += @intCast(len);
                break :blk bytes[start..pos.*];
            },
            AddrList => blk: {
                const count = try readUleb(bytes, pos);
                const start = pos.*;
                var n: u64 = 0;
                while (n < count) : (n += 1) _ = try readUleb(bytes, pos);
                break :blk .{ .count = @intCast(count), .encoded = bytes[start..pos.*] };
            },
            else => blk: {
                const Tag = @typeInfo(T).@"enum".tag_type;
                const raw = try readUleb(bytes, pos);
                const narrow = std.math.cast(Tag, raw) orelse return error.InvalidValue;
                break :blk std.enums.fromInt(T, narrow) orelse return error.InvalidValue;
            },
        };
    }
    return result;
}

// ---------------------------------------------------------------------------
// Events

/// Upper bound on the encoded size of an event without slice fields, or null.
pub fn eventMaxLen(comptime tag: EventTag) ?usize {
    return 1 + max_uleb_len + (fieldsMaxLen(Payload(tag)) orelse return null);
}

pub fn eventLen(comptime tag: EventTag, dt: u64, payload: Payload(tag)) usize {
    return 1 + ulebLen(dt) + fieldsLen(payload);
}

/// Encode one event into `buf`, which must hold `eventLen(...)` bytes (or
/// `eventMaxLen(tag)` for slice-free events). Returns the bytes written.
pub inline fn writeEvent(buf: []u8, comptime tag: EventTag, dt: u64, payload: Payload(tag)) usize {
    buf[0] = @backingInt(tag);
    var i: usize = 1;
    i += writeUleb(buf[i..], dt);
    i += writeFields(buf[i..], payload);
    return i;
}

pub const DecodedEvent = struct {
    /// Absolute tick of the event.
    ticks: u64,
    event: Event,
};

/// Iterates the events of one chunk.
pub const EventIterator = struct {
    bytes: []const u8,
    pos: usize = 0,
    ticks: u64,

    pub fn init(events: []const u8, base_ticks: u64) EventIterator {
        return .{ .bytes = events, .ticks = base_ticks };
    }

    /// Returns null at the end of the chunk. `error.InvalidValue` for an
    /// unknown tag: the rest of the chunk can't be decoded.
    pub fn next(it: *EventIterator) DecodeError!?DecodedEvent {
        if (it.pos >= it.bytes.len) return null;
        const raw_tag = it.bytes[it.pos];
        it.pos += 1;
        const tag = std.enums.fromInt(EventTag, raw_tag) orelse return error.InvalidValue;
        it.ticks +%= try readUleb(it.bytes, &it.pos);
        const event: Event = switch (tag) {
            inline else => |t| @unionInit(Event, @tagName(t), try readFields(Payload(t), it.bytes, &it.pos)),
        };
        return .{ .ticks = it.ticks, .event = event };
    }
};

// ---------------------------------------------------------------------------
// Records

pub fn RecordPayload(comptime kind: RecordKind) type {
    return switch (kind) {
        .process => record.Process,
        .thread => record.Thread,
        .calibration => record.Calibration,
        .name => record.Name,
        .chunk => record.Chunk,
        .end => record.End,
        _ => unreachable,
    };
}

/// Upper bound on a record header: kind byte plus a uleb128 length.
pub const max_record_header_len = 1 + max_uleb_len;

pub fn writeRecordHeader(buf: []u8, kind: RecordKind, payload_len: u64) usize {
    buf[0] = @backingInt(kind);
    return 1 + writeUleb(buf[1..], payload_len);
}

pub const RawRecord = struct {
    kind: RecordKind,
    payload: []const u8,
};

/// A decoded chunk record: its header and its event bytes.
pub const ChunkView = struct {
    header: record.Chunk,
    events: []const u8,

    pub fn iterator(self: ChunkView) EventIterator {
        return .init(self.events, self.header.base_ticks);
    }
};

pub fn parseChunk(payload: []const u8) DecodeError!ChunkView {
    var pos: usize = 0;
    const header = try readFields(record.Chunk, payload, &pos);
    return .{ .header = header, .events = payload[pos..] };
}

/// Parse a non-chunk record payload.
pub fn parseRecord(comptime kind: RecordKind, payload: []const u8) DecodeError!RecordPayload(kind) {
    var pos: usize = 0;
    return readFields(RecordPayload(kind), payload, &pos);
}

/// Iterates the records of a whole trace held in memory.
pub const FileReader = struct {
    header: FileHeader,
    bytes: []const u8,
    pos: usize,

    pub const Error = DecodeError || error{ BadMagic, UnsupportedVersion };

    pub fn init(bytes: []const u8) Error!FileReader {
        if (bytes.len < @sizeOf(FileHeader)) return error.Truncated;
        var header: FileHeader = undefined;
        @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(FileHeader)]);
        if (!std.mem.eql(u8, &header.magic, &magic)) return error.BadMagic;
        if (header.version != version) return error.UnsupportedVersion;
        if (header.header_size < @sizeOf(FileHeader) or header.header_size > bytes.len) return error.Truncated;
        return .{ .header = header, .bytes = bytes, .pos = header.header_size };
    }

    /// Returns null at end of file. A record cut off by a crash or a short
    /// write returns `error.Truncated`; everything before it is valid.
    pub fn next(self: *FileReader) DecodeError!?RawRecord {
        if (self.pos >= self.bytes.len) return null;
        const kind: RecordKind = @fromBackingInt(self.bytes[self.pos]);
        var pos = self.pos + 1;
        const len = try readUleb(self.bytes, &pos);
        if (len > self.bytes.len - pos) return error.Truncated;
        const payload = self.bytes[pos..][0..@intCast(len)];
        self.pos = pos + payload.len;
        return .{ .kind = kind, .payload = payload };
    }
};

// ---------------------------------------------------------------------------
// Tests

test "uleb128 and zigzag round trip" {
    var buf: [max_uleb_len]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 300, std.math.maxInt(u32), std.math.maxInt(u64) }) |v| {
        const n = writeUleb(&buf, v);
        try std.testing.expectEqual(ulebLen(v), n);
        var pos: usize = 0;
        try std.testing.expectEqual(v, try readUleb(buf[0..n], &pos));
        try std.testing.expectEqual(n, pos);
    }
    for ([_]i64{ 0, -1, 1, std.math.minInt(i64), std.math.maxInt(i64) }) |v| {
        try std.testing.expectEqual(v, unzigzag(zigzag(v)));
    }
    var pos: usize = 0;
    try std.testing.expectError(error.Truncated, readUleb(&.{0x80}, &pos));
}

test "events round trip through a chunk" {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    const frames = [_]usize{ 0x1000, 0xdead_beef, 7 };
    len += writeEvent(buf[len..], .task_create, 5, .{ .task = 1, .entry = 0x4000, .executor = 2, .parent = 0, .group = 0 });
    len += writeEvent(buf[len..], .task_end, 100, .{ .task = 1, .reason = .finish });
    len += writeEvent(buf[len..], .task_stack, 0, .{ .task = 1, .kind = .first_suspend, .frames = .{ .items = &frames } });
    len += writeEvent(buf[len..], .plot, 1, .{ .name = "queue", .value = -3 });
    len += writeEvent(buf[len..], .poll_end, 2, .{ .timed_out = true });
    try std.testing.expect(eventLen(.task_create, 5, .{ .task = 1, .entry = 0x4000, .executor = 2, .parent = 0, .group = 0 }) <= eventMaxLen(.task_create).?);

    var it: EventIterator = .init(buf[0..len], 1000);
    const a = (try it.next()).?;
    try std.testing.expectEqual(1005, a.ticks);
    try std.testing.expectEqual(0x4000, a.event.task_create.entry);
    const b = (try it.next()).?;
    try std.testing.expectEqual(1105, b.ticks);
    try std.testing.expectEqual(TaskEndReason.finish, b.event.task_end.reason);
    const c = (try it.next()).?;
    var frame_it = c.event.task_stack.frames.iterator();
    for (frames) |f| try std.testing.expectEqual(@as(u64, f), (try frame_it.next()).?);
    try std.testing.expectEqual(null, try frame_it.next());
    const d = (try it.next()).?;
    try std.testing.expectEqualStrings("queue", d.event.plot.name);
    try std.testing.expectEqual(-3, d.event.plot.value);
    const e = (try it.next()).?;
    try std.testing.expect(e.event.poll_end.timed_out);
    try std.testing.expectEqual(null, try it.next());
}

test "file reader walks records and skips unknown kinds" {
    var buf: [256]u8 = undefined;
    const header: FileHeader = .{ .clock = .monotonic_ns, .ticks_per_second = std.time.ns_per_s, .pid = 42, .start_realtime_ns = 0 };
    @memcpy(buf[0..@sizeOf(FileHeader)], std.mem.asBytes(&header));
    var len: usize = @sizeOf(FileHeader);

    const cal: record.Calibration = .{ .ticks = 10, .monotonic_ns = 20 };
    len += writeRecordHeader(buf[len..], .calibration, fieldsLen(cal));
    len += writeFields(buf[len..], cal);
    len += writeRecordHeader(buf[len..], @fromBackingInt(200), 2);
    buf[len] = 0xff;
    buf[len + 1] = 0xff;
    len += 2;

    var reader: FileReader = try .init(buf[0..len]);
    try std.testing.expectEqual(42, reader.header.pid);
    const r1 = (try reader.next()).?;
    try std.testing.expectEqual(RecordKind.calibration, r1.kind);
    try std.testing.expectEqual(20, (try parseRecord(.calibration, r1.payload)).monotonic_ns);
    const r2 = (try reader.next()).?;
    try std.testing.expectEqual(@as(u8, 200), @backingInt(r2.kind));
    try std.testing.expectEqual(null, try reader.next());
}
