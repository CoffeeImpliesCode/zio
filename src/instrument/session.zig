const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");
const clock = @import("clock.zig");
const Buffer = @import("buffer.zig").Buffer;
const allocator = std.heap.page_allocator;
const stack = @import("stack.zig");
const os_thread = @import("../os/thread.zig");

pub var running: std.atomic.Value(bool) = .init(false);
var lifecycle: @import("../os/thread.zig").Mutex = .init();
var registry: @import("../os/thread.zig").Mutex = .init();
var refs: usize = 0;
var generation: std.atomic.Value(u64) = .init(0);
var threads: std.ArrayList(*Thread) = .empty;
var writer: ?std.Thread = null;
var stop: std.atomic.Value(bool) = .init(false);
var writer_signal: std.atomic.Value(u32) = .init(0);
var process_fd: std.c.fd_t = -1;
var path_buf: [256]u8 = undefined;
var path: []const u8 = &.{};
var header: format.FileHeader = undefined;
var dropped: std.atomic.Value(u64) = .init(0);
threadlocal var local: ?*Thread = null;
threadlocal var local_generation: u64 = 0;

pub const Thread = struct {
    fd: std.c.fd_t,
    index: u64,
    seq: u64 = 0,
    counter: u32 = 0,
    current: u64 = 0,
    spawn_func: u64 = 0,
    buffers: [2]Buffer = .{ .{}, .{} },
    front: u1 = 0,
    // Threads are heap-owned and never moved; cache the producer buffer address.
    buffer: *Buffer = undefined,
    pending: std.atomic.Value(u32) = .init(0),
    stack_bounds: stack.Bounds = .{},
    sources: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn init(self: *Thread, fd: std.c.fd_t, index: u64, bounds: stack.Bounds) void {
        self.* = .{ .fd = fd, .index = index, .stack_bounds = bounds };
        self.buffer = &self.buffers[0];
    }

    pub inline fn emit(self: *Thread, comptime tag: format.EventTag, payload: format.Payload(tag)) void {
        if (!self.buffer.append(tag, clock.ticks(), payload)) {
            @branchHint(.unlikely);
            self.emitRollover(tag, payload);
        }
    }

    noinline fn emitRollover(self: *Thread, comptime tag: format.EventTag, payload: format.Payload(tag)) void {
        @branchHint(.cold);
        self.flush();
        if (!self.buffer.append(tag, clock.ticks(), payload)) {
            _ = dropped.fetchAdd(1, .monotonic);
        }
    }

    pub fn defineSource(self: *Thread, id: u64, source: std.builtin.SourceLocation) bool {
        if (self.sources.contains(id)) return true;
        self.sources.put(allocator, id, {}) catch {
            _ = dropped.fetchAdd(1, .monotonic);
            return false;
        };
        self.emit(.srcloc, .{
            .srcloc = id,
            .name = source.fn_name,
            .function = source.fn_name,
            .file = source.file,
            .line = source.line,
        });
        return true;
    }

    pub fn freeSources(self: *Thread) void {
        self.sources.deinit(allocator);
    }

    pub noinline fn flush(self: *Thread) void {
        @branchHint(.cold);
        if (self.buffers[self.front].empty()) return;
        if (builtin.single_threaded) {
            _ = self.buffers[self.front].append(.flush_begin, clock.ticks(), .{});
            writeChunk(self, self.front);
            self.buffers[self.front].reset();
            _ = self.buffers[self.front].append(.flush_end, clock.ticks(), .{});
            return;
        }
        self.waitForSpare(true);
        _ = self.buffers[self.front].seal(self.index, self.seq);
        self.seq += 1;
        self.pending.store(@as(u32, self.front) + 1, .release);
        self.front ^= 1;
        self.buffers[self.front].reset();
        self.buffer = &self.buffers[self.front];
        wakeWriter();
    }

    fn waitForSpare(self: *Thread, traced: bool) void {
        var pending = self.pending.load(.acquire);
        if (pending == 0) return;
        if (traced) _ = self.buffers[self.front].append(.flush_begin, clock.ticks(), .{});
        while (pending != 0) {
            os_thread.Futex.wait(&self.pending, pending);
            pending = self.pending.load(.acquire);
        }
        if (traced) _ = self.buffers[self.front].append(.flush_end, clock.ticks(), .{});
    }
};

fn writeAll(fd: std.c.fd_t, bytes: []const u8) bool {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + pos, bytes.len - pos);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return false;
        }
        if (n == 0) return false;
        pos += @intCast(n);
    }
    return true;
}

fn writeRecord(fd: std.c.fd_t, comptime tag: format.RecordKind, payload: format.RecordPayload(tag)) void {
    var bytes: [8192]u8 = undefined;
    const size = format.fieldsLen(payload);
    if (size + format.max_record_header_len > bytes.len) return;
    var len = format.writeRecordHeader(&bytes, tag, size);
    len += format.writeFields(bytes[len..], payload);
    if (!writeAll(fd, bytes[0..len])) _ = dropped.fetchAdd(1, .monotonic);
}

fn writeChunk(thread: *Thread, index: u1) void {
    const buffer = &thread.buffers[index];
    const bytes = if (builtin.single_threaded) buffer.seal(thread.index, thread.seq) else buffer.bytes[buffer.start..buffer.len];
    var record_header: [format.max_record_header_len]u8 = undefined;
    const len = format.writeRecordHeader(&record_header, .chunk, bytes.len);
    if (!writeAll(thread.fd, record_header[0..len]) or !writeAll(thread.fd, bytes)) {
        _ = dropped.fetchAdd(1, .monotonic);
    }
    if (builtin.single_threaded) thread.seq += 1;
}

fn calibration() void {
    const before = clock.ticks();
    const ns = clock.monotonic();
    const after = clock.ticks();
    writeRecord(process_fd, .calibration, .{ .ticks = before + (after -% before) / 2, .monotonic_ns = ns });
}

fn wakeWriter() void {
    _ = writer_signal.fetchAdd(1, .monotonic);
    os_thread.Futex.wake(&writer_signal, .one);
}

fn writerMain() void {
    var last = clock.monotonic();
    while (true) {
        const observed = writer_signal.load(.acquire);
        registry.lock();
        for (threads.items) |thread| {
            const pending = thread.pending.load(.acquire);
            if (pending != 0) {
                writeChunk(thread, @intCast(pending - 1));
                thread.pending.store(0, .release);
                os_thread.Futex.wake(&thread.pending, .one);
            }
        }
        registry.unlock();
        const now = clock.monotonic();
        if (now - last >= std.time.ns_per_s) {
            calibration();
            last = now;
        }
        if (stop.load(.acquire)) break;
        const until_calibration = std.time.ns_per_s - @min(now - last, std.time.ns_per_s);
        os_thread.Futex.timedWait(&writer_signal, observed, .fromNanoseconds(until_calibration)) catch {};
    }
}

fn openFile(name: [:0]const u8) !std.c.fd_t {
    const fd = std.c.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.TraceOpenFailed;
    if (!writeAll(fd, std.mem.asBytes(&header))) {
        _ = std.c.close(fd);
        return error.TraceWriteFailed;
    }
    return fd;
}

fn begin() !void {
    const start = clock.realtime();
    const pid: u64 = @intCast(std.c.getpid());
    header = .{ .clock = clock.kind, .ticks_per_second = if (clock.kind == .monotonic_ns) std.time.ns_per_s else 0, .pid = pid, .start_realtime_ns = start };
    if (std.c.mkdir(".zio", 0o700) != 0 and std.posix.errno(-1) != .EXIST) return error.TraceDirectoryFailed;
    var directory = try std.mem.printSentinel(&path_buf, ".zio/{d}", .{start}, 0);
    if (std.c.mkdir(directory, 0o700) != 0) {
        if (std.posix.errno(-1) != .EXIST) return error.TraceDirectoryFailed;
        directory = try std.mem.printSentinel(&path_buf, ".zio/{d}-{d}", .{ start, pid }, 0);
        if (std.c.mkdir(directory, 0o700) != 0) return error.TraceDirectoryFailed;
    }
    path = directory;
    var name: [320]u8 = undefined;
    process_fd = try openFile(try std.mem.printSentinel(&name, "{s}/process.dump", .{path}, 0));
    errdefer _ = std.c.close(process_fd);
    var exe: [4096]u8 = undefined;
    const exe_len = if (builtin.os.tag == .linux) std.c.readlink("/proc/self/exe", &exe, exe.len) else -1;
    writeRecord(process_fd, .process, .{ .exe_path = if (exe_len > 0) exe[0..@intCast(exe_len)] else "", .anchor_addr = @intFromPtr(&anchor) });
    inline for (@typeInfo(@import("../ev/completion.zig").Op).@"enum".field_names, 0..) |op_name, i| {
        writeRecord(process_fd, .name, .{ .table = .io_op, .value = i, .name = op_name });
    }
    dropped.store(0, .monotonic);
    calibration();
    stop.store(false, .release);
    if (!builtin.single_threaded) writer = try std.Thread.spawn(.{}, writerMain, .{});
    _ = generation.fetchAdd(1, .monotonic);
    running.store(true, .release);
}

fn anchor() callconv(.c) void {}
comptime {
    if (@import("../options.zig").options.instrument) @export(&anchor, .{ .name = format.anchor_symbol });
}

pub noinline fn acquire() void {
    lifecycle.lock();
    defer lifecycle.unlock();
    refs += 1;
    if (refs == 1) {
        const value = std.c.getenv("ZIO_PROFILE") orelse return;
        if (!std.mem.eql(u8, std.mem.span(value), "1")) return;
        begin() catch |err| {
            std.log.err("zio trace setup failed: {s}", .{@errorName(err)});
            return;
        };
    }
}

pub noinline fn release() void {
    lifecycle.lock();
    defer lifecycle.unlock();
    if (refs == 0) return;
    refs -= 1;
    if (refs != 0) return;
    if (!running.load(.monotonic)) return;
    running.store(false, .release);
    // Runtime workers have been joined; external event emitters must be quiescent.
    for (threads.items) |thread| finishThread(thread);
    stop.store(true, .release);
    wakeWriter();
    if (writer) |t| t.join();
    writer = null;
    calibration();
    writeRecord(process_fd, .end, .{ .dropped = dropped.load(.monotonic) });
    _ = std.c.close(process_fd);
    for (threads.items) |thread| {
        allocator.destroy(thread);
    }
    threads.deinit(allocator);
    threads = .empty;
    local = null;
}

pub inline fn getThread(kind: format.ThreadKind, executor: u64) ?*Thread {
    if (!running.load(.acquire)) return null;
    const current_generation = generation.load(.monotonic);
    if (local_generation == current_generation) if (local) |thread| return thread;
    return registerThread(kind, executor, current_generation);
}

noinline fn registerThread(kind: format.ThreadKind, executor: u64, current_generation: u64) ?*Thread {
    registry.lock();
    defer registry.unlock();
    const index = threads.items.len + 1;
    var name: [320]u8 = undefined;
    const tid: u64 = @intCast(std.Thread.getCurrentId());
    const fd = openFile(std.mem.printSentinel(&name, "{s}/{d}-{d}.dump", .{ path, tid, index }, 0) catch return null) catch return null;
    const thread = allocator.create(Thread) catch {
        _ = std.c.close(fd);
        return null;
    };
    thread.init(fd, index, stack.threadBounds());
    threads.append(allocator, thread) catch {
        allocator.destroy(thread);
        _ = std.c.close(fd);
        return null;
    };
    writeRecord(fd, .thread, .{ .thread = index, .os_tid = tid, .kind = kind, .executor = executor, .name = @tagName(kind) });
    thread.emit(.thread_begin, .{});
    local = thread;
    local_generation = current_generation;
    return thread;
}

fn finishThread(thread: *Thread) void {
    if (thread.fd < 0) return;
    if (builtin.single_threaded) {
        thread.emit(.thread_end, .{});
        writeChunk(thread, thread.front);
        thread.buffers[thread.front].reset();
    } else {
        thread.waitForSpare(true);
        if (!thread.buffers[thread.front].append(.thread_end, clock.ticks(), .{})) {
            thread.flush();
            thread.waitForSpare(true);
            const appended = thread.buffers[thread.front].append(.thread_end, clock.ticks(), .{});
            std.debug.assert(appended);
        }
        thread.flush();
        thread.waitForSpare(false);
    }
    _ = std.c.close(thread.fd);
    thread.fd = -1;
    thread.freeSources();
}

pub fn exitThread() void {
    if (local_generation == generation.load(.monotonic)) if (local) |thread| finishThread(thread);
    local = null;
}

test "instrument writer drains rollover with contiguous sequences" {
    if (builtin.os.tag != .linux or builtin.single_threaded) return error.SkipZigTest;
    const raw_fd = std.os.linux.memfd_create("zio-instrument-test", 0);
    try std.testing.expect(raw_fd <= std.math.maxInt(std.c.fd_t));
    const fd: std.c.fd_t = @intCast(raw_fd);
    defer _ = std.c.close(fd);
    const thread = try std.testing.allocator.create(Thread);
    defer std.testing.allocator.destroy(thread);
    const writer_fd = std.c.dup(fd);
    try std.testing.expect(writer_fd >= 0);
    thread.init(writer_fd, 1, .{});
    try threads.append(allocator, thread);
    defer {
        threads.deinit(allocator);
        threads = .empty;
    }
    const file_header: format.FileHeader = .{
        .clock = .monotonic_ns,
        .ticks_per_second = std.time.ns_per_s,
        .pid = 1,
        .start_realtime_ns = 0,
    };
    try std.testing.expect(writeAll(fd, std.mem.asBytes(&file_header)));
    stop.store(false, .release);
    const worker = try std.Thread.spawn(.{}, writerMain, .{});
    thread.emit(.thread_begin, .{});
    for (0..100000) |i| thread.emit(.task_begin, .{ .task = i + 1 });
    finishThread(thread);
    stop.store(true, .release);
    wakeWriter();
    worker.join();
    const bytes = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    const len = std.c.pread(fd, bytes.ptr, bytes.len, 0);
    try std.testing.expect(len > 0);
    var reader = try format.FileReader.init(bytes[0..@intCast(len)]);
    var seq: u64 = 0;
    var count: u64 = 0;
    var began = false;
    var ended = false;
    while (try reader.next()) |record| {
        try std.testing.expectEqual(format.RecordKind.chunk, record.kind);
        const chunk = try format.parseChunk(record.payload);
        try std.testing.expectEqual(seq, chunk.header.seq);
        seq += 1;
        var events = chunk.iterator();
        while (try events.next()) |event| switch (event.event) {
            .task_begin => |task| {
                try std.testing.expect(began and !ended);
                count += 1;
                try std.testing.expectEqual(count, task.task);
            },
            .thread_begin => {
                try std.testing.expect(!began and count == 0);
                began = true;
            },
            .thread_end => {
                try std.testing.expect(began and !ended and count == 100000);
                ended = true;
            },
            .flush_begin, .flush_end => try std.testing.expect(began and !ended),
            else => return error.UnexpectedEvent,
        };
    }
    try std.testing.expectEqual(100000, count);
    try std.testing.expect(seq > 1);
    try std.testing.expect(began and ended);
}

test "instrument inactive lifecycle balances nested runtimes without starting writer" {
    if (std.c.getenv("ZIO_PROFILE") != null) return error.SkipZigTest;
    acquire();
    acquire();
    defer {
        release();
        release();
    }
    try std.testing.expectEqual(2, refs);
    try std.testing.expect(!running.load(.monotonic));
    try std.testing.expectEqual(null, writer);
}

test "instrument source locations are defined once beyond 128 distinct locations" {
    const thread = try std.testing.allocator.create(Thread);
    defer std.testing.allocator.destroy(thread);
    thread.init(-1, 1, .{});
    defer thread.freeSources();
    for (1..257) |id| {
        try std.testing.expect(thread.defineSource(id, @src()));
        const chunk = try format.parseChunk(thread.buffers[0].seal(1, 0));
        var events = chunk.iterator();
        try std.testing.expectEqual(id, (try events.next()).?.event.srcloc.srcloc);
        try std.testing.expectEqual(null, try events.next());
        thread.buffers[0].reset();
    }
    for (1..257) |id| {
        try std.testing.expect(thread.defineSource(id, @src()));
        try std.testing.expect(thread.buffers[0].empty());
    }
}
