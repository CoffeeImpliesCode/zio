const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");
const clock = @import("clock.zig");
const Buffer = @import("buffer.zig").Buffer;
const allocator = std.heap.page_allocator;
const stack = @import("stack.zig");
const os_thread = @import("../os/thread.zig");
const classes = @import("classes.zig");

pub var class_mask: std.atomic.Value(u64) = .init(0);
var lifecycle: @import("../os/thread.zig").Mutex = .init();
var registry: @import("../os/thread.zig").Mutex = .init();
var refs: usize = 0;
var generation: std.atomic.Value(u64) = .init(0);
var next_task_id: std.atomic.Value(u64) = .init(1);
const task_id_block = 1024;
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
    kind: format.ThreadKind = .other,
    executor: u64 = format.no_executor,
    seq: u64 = 0,
    id_next: u64 = 0,
    id_end: u64 = 0,
    current: u64 = 0,
    spawn_func: u64 = 0,
    buffers: [2]Buffer = .{ .{}, .{} },
    front: u1 = 0,
    // Threads are heap-owned and never moved; cache the producer buffer address.
    buffer: *Buffer = undefined,
    pending: std.atomic.Value(u32) = .init(0),
    stack_bounds: stack.Bounds = .{},
    classes: u64 = format.all_classes,
    sources: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn init(self: *Thread, fd: std.c.fd_t, index: u64, bounds: stack.Bounds) void {
        self.* = .{ .fd = fd, .index = index, .stack_bounds = bounds };
        self.buffer = &self.buffers[0];
    }

    pub inline fn nextTaskId(self: *Thread) u64 {
        if (self.id_next == self.id_end) {
            self.id_next = next_task_id.fetchAdd(task_id_block, .monotonic);
            self.id_end = self.id_next + task_id_block;
        }
        const id = self.id_next;
        self.id_next += 1;
        return id;
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

fn begin(selected: u64) !void {
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
    writeRecord(process_fd, .process, .{ .exe_path = if (exe_len > 0) exe[0..@intCast(exe_len)] else "", .anchor_addr = @intFromPtr(&anchor), .classes = selected });
    inline for (@typeInfo(@import("../ev/completion.zig").Op).@"enum".field_names, 0..) |op_name, i| {
        writeRecord(process_fd, .name, .{ .table = .io_op, .value = i, .name = op_name });
    }
    dropped.store(0, .monotonic);
    next_task_id.store(1, .monotonic);
    calibration();
    stop.store(false, .release);
    if (!builtin.single_threaded) writer = try std.Thread.spawn(.{}, writerMain, .{});
    _ = generation.fetchAdd(1, .monotonic);
    class_mask.store(selected, .release);
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
        const text = std.mem.span(value);
        const selection = classes.parse(text);
        if (selection.unknown != 0) {
            var tokens = std.mem.splitScalar(u8, text, ',');
            while (tokens.next()) |raw| {
                const name = std.mem.trim(u8, raw, " \t\r\n");
                if (name.len != 0 and classes.classForName(name) == null)
                    std.log.warn("unknown ZIO_PROFILE class '{s}'; ignoring it", .{name});
            }
        }
        if (selection.mask == 0) return;
        begin(selection.mask) catch |err| {
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
    if (class_mask.load(.monotonic) == 0) return;
    class_mask.store(0, .release);
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
    if (class_mask.load(.acquire) == 0) return null;
    const current_generation = generation.load(.monotonic);
    if (local_generation == current_generation) if (local) |thread| return thread;
    return registerThread(kind, executor, current_generation);
}

/// Preserve identity when a creator cannot allocate or open its trace producer.
pub noinline fn unrecordedTaskId() u64 {
    _ = dropped.fetchAdd(1, .monotonic);
    return next_task_id.fetchAdd(1, .monotonic);
}

/// Register an explicit runtime role on the calling native thread.
/// A changed role or executor identity closes the old trace-local lifetime first;
/// repeated registration and generic emitters keep the current producer.
pub noinline fn enterThread(kind: format.ThreadKind, executor: u64) ?*Thread {
    const thread = getThread(kind, executor) orelse return null;
    if (kind == .other) return thread;
    if (thread.kind == kind and thread.executor == executor) return thread;
    // Draining needs the writer, which acquires registry. Never hold it here.
    local = null;
    finishThread(thread);
    return registerThread(kind, executor, local_generation);
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
    thread.classes = class_mask.load(.monotonic);
    thread.kind = kind;
    thread.executor = executor;
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
    try std.testing.expectEqual(0, class_mask.load(.monotonic));
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

test "instrument task ids remain nonzero and unique across thread block rollovers" {
    next_task_id.store(1, .monotonic);
    defer next_task_id.store(1, .monotonic);
    const a = try std.testing.allocator.create(Thread);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Thread);
    defer std.testing.allocator.destroy(b);
    a.init(-1, 1, .{});
    b.init(-1, 2, .{});
    var ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer ids.deinit(std.testing.allocator);
    for (0..task_id_block * 2 + 1) |_| {
        for ([_]*Thread{ a, b }) |thread| {
            const id = thread.nextTaskId();
            try std.testing.expect(id != 0);
            const entry = try ids.getOrPut(std.testing.allocator, id);
            try std.testing.expect(!entry.found_existing);
        }
    }
}

const RoleTest = struct {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
        extern "c" fn fchdir(fd: std.c.fd_t) c_int;
    };

    fn openReader(fd: std.c.fd_t) !std.c.fd_t {
        var name: [64]u8 = undefined;
        const file = try std.mem.printSentinel(&name, "/proc/self/fd/{d}", .{fd}, 0);
        const readable = std.c.open(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        if (readable < 0) return error.TraceReadOpenFailed;
        return readable;
    }

    fn readThread(fd: std.c.fd_t, kind: format.ThreadKind, executor: u64, plots: usize, tasks: usize) !u64 {
        const bytes = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        const len = std.c.pread(fd, bytes.ptr, bytes.len, 0);
        try std.testing.expect(len > 0);
        var reader = try format.FileReader.init(bytes[0..@intCast(len)]);
        const record = (try reader.next()) orelse return error.MissingThreadRecord;
        try std.testing.expectEqual(format.RecordKind.thread, record.kind);
        const metadata = try format.parseRecord(.thread, record.payload);
        try std.testing.expectEqual(kind, metadata.kind);
        try std.testing.expectEqual(executor, metadata.executor);
        try std.testing.expectEqual(@as(u64, @intCast(std.Thread.getCurrentId())), metadata.os_tid);
        var seq: u64 = 0;
        var plot_count: usize = 0;
        var task_count: usize = 0;
        var began = false;
        var ended = false;
        while (try reader.next()) |raw| {
            try std.testing.expectEqual(format.RecordKind.chunk, raw.kind);
            const chunk = try format.parseChunk(raw.payload);
            try std.testing.expectEqual(metadata.thread, chunk.header.thread);
            try std.testing.expectEqual(seq, chunk.header.seq);
            seq += 1;
            var events = chunk.iterator();
            while (try events.next()) |event| {
                try std.testing.expect(!ended);
                switch (event.event) {
                    .thread_begin => {
                        try std.testing.expect(!began);
                        began = true;
                    },
                    .thread_end => {
                        try std.testing.expect(began);
                        ended = true;
                    },
                    .plot => |plot| {
                        try std.testing.expect(began);
                        try std.testing.expectEqualStrings("before registration", plot.name);
                        try std.testing.expectEqual(@as(i64, @intCast(plot_count)), plot.value);
                        plot_count += 1;
                    },
                    .task_begin => {
                        try std.testing.expect(began);
                        task_count += 1;
                    },
                    .executor_info => |info| {
                        try std.testing.expectEqual(format.ThreadKind.executor, kind);
                        try std.testing.expectEqual(executor, info.executor);
                    },
                    .flush_begin, .flush_end, .task_end => try std.testing.expect(began),
                    else => return error.UnexpectedEvent,
                }
            }
        }
        try std.testing.expect(began and ended);
        try std.testing.expectEqual(plots, plot_count);
        try std.testing.expectEqual(tasks, task_count);
        return metadata.thread;
    }

    fn promote(comptime kind: format.ThreadKind) !void {
        if (builtin.os.tag != .linux) return error.SkipZigTest;
        try std.testing.expectEqual(0, refs);
        var scratch = std.testing.tmpDir(.{});
        defer scratch.cleanup();
        const cwd_fd = std.c.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, @as(std.c.mode_t, 0));
        try std.testing.expect(cwd_fd >= 0);
        defer _ = std.c.close(cwd_fd);
        try std.testing.expectEqual(0, c.fchdir(scratch.dir.handle));
        defer std.debug.assert(c.fchdir(cwd_fd) == 0);
        const previous = if (std.c.getenv("ZIO_PROFILE")) |value|
            try std.testing.allocator.dupeSentinel(u8, std.mem.span(value), 0)
        else
            null;
        defer {
            if (previous) |value| {
                std.debug.assert(c.setenv("ZIO_PROFILE", value, 1) == 0);
                std.testing.allocator.free(value);
            } else {
                std.debug.assert(c.unsetenv("ZIO_PROFILE") == 0);
            }
        }
        try std.testing.expectEqual(0, c.setenv("ZIO_PROFILE", "1", 1));
        acquire();
        defer release();
        const before = getThread(.other, format.no_executor) orelse return error.MissingTraceThread;
        const before_fd = try openReader(before.fd);
        defer _ = std.c.close(before_fd);
        for (0..10000) |i| {
            before.emit(.plot, .{ .name = "before registration", .value = @intCast(i) });
        }
        const previous_id = before.nextTaskId();
        const hooks = @import("hooks.zig");
        var executor: struct {
            id: u64,
            instr: struct { thread: ?*Thread = null } = .{},
        } = .{ .id = 17 };
        const active = if (kind == .executor) blk: {
            hooks.executorRegister(&executor);
            break :blk executor.instr.thread orelse return error.MissingTraceThread;
        } else blk: {
            hooks.threadInit();
            break :blk getThread(.other, format.no_executor) orelse return error.MissingTraceThread;
        };
        const active_fd = try openReader(active.fd);
        defer _ = std.c.close(active_fd);
        try std.testing.expectEqual(active, getThread(.other, format.no_executor).?);
        try std.testing.expectEqual(active, enterThread(.other, format.no_executor).?);
        if (kind == .executor) {
            hooks.executorRegister(&executor);
            try std.testing.expectEqual(active, executor.instr.thread.?);
        } else {
            hooks.threadInit();
            try std.testing.expectEqual(active, getThread(.other, format.no_executor).?);
        }
        const task = active.nextTaskId();
        try std.testing.expect(previous_id != task);
        if (kind == .executor) {
            active.emit(.executor_info, .{ .executor = executor.id, .loop = 99 });
        }
        active.emit(.task_begin, .{ .task = task });
        active.emit(.task_end, .{ .reason = .finish });
        const replacement = enterThread(.executor, 18) orelse return error.MissingTraceThread;
        try std.testing.expect(replacement != active);
        const replacement_fd = try openReader(replacement.fd);
        defer _ = std.c.close(replacement_fd);
        const replacement_task = replacement.nextTaskId();
        try std.testing.expect(previous_id != replacement_task and task != replacement_task);
        replacement.emit(.task_begin, .{ .task = replacement_task });
        replacement.emit(.task_end, .{ .reason = .finish });
        exitThread();
        const before_index = try readThread(before_fd, .other, format.no_executor, 10000, 0);
        const active_index = try readThread(
            active_fd,
            kind,
            if (kind == .executor) executor.id else format.no_executor,
            0,
            1,
        );
        try std.testing.expect(before_index != active_index);
        const replacement_index = try readThread(replacement_fd, .executor, 18, 0, 1);
        try std.testing.expect(replacement_index != active_index);
        const after_exit = getThread(.other, format.no_executor) orelse return error.MissingTraceThread;
        try std.testing.expect(after_exit != replacement);
        const after_exit_fd = try openReader(after_exit.fd);
        defer _ = std.c.close(after_exit_fd);
        const after_exit_task = after_exit.nextTaskId();
        try std.testing.expect(after_exit_task != previous_id);
        try std.testing.expect(after_exit_task != task);
        try std.testing.expect(after_exit_task != replacement_task);
        exitThread();
        const after_exit_index = try readThread(after_exit_fd, .other, format.no_executor, 0, 0);
        try std.testing.expect(after_exit_index != replacement_index);
    }
};

test "instrument marker thread becomes a distinct executor lifetime" {
    // Decode real files to preserve pre-registration markers without executor attribution.
    try RoleTest.promote(.executor);
    try RoleTest.promote(.executor);
}

test "instrument marker thread becomes a distinct blocking lifetime" {
    // Explicit blocking registration must replace generic TLS, then survive generic emission.
    try RoleTest.promote(.blocking);
    try RoleTest.promote(.blocking);
}

const RegistrationFailureTest = struct {
    const Context = struct {
        runtime: *@import("../runtime.zig").Runtime,
        completed: std.atomic.Value(u32) = .init(0),
        failure: ?anyerror = null,
    };

    fn taskBody(context: *Context) void {
        _ = context.completed.fetchAdd(1, .monotonic);
    }

    fn foreignSpawn(context: *Context) void {
        var handle = context.runtime.spawn(taskBody, .{context}) catch |err| {
            context.failure = err;
            return;
        };
        handle.join();
        handle.cancel();
    }
};

// A creator can lose its trace file while an already-registered executor works.
test "instrument failed creator registration preserves workload and task identity" {
    if (builtin.os.tag != .linux or builtin.single_threaded or
        !@import("root.zig").enabled) return error.SkipZigTest;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const cwd_fd = std.c.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, @as(std.c.mode_t, 0));
    try std.testing.expect(cwd_fd >= 0);
    defer _ = std.c.close(cwd_fd);
    try std.testing.expectEqual(0, RoleTest.c.fchdir(scratch.dir.handle));
    defer std.debug.assert(RoleTest.c.fchdir(cwd_fd) == 0);
    const runtime = try @import("../runtime.zig").Runtime.init(std.testing.allocator, .{
        .executors = .exact(1),
        .enable_main_executor = false,
    });
    var initialized = true;
    defer if (initialized) runtime.deinit();
    if (class_mask.load(.monotonic) & format.EventClass.sched.mask() == 0)
        return error.SkipZigTest;
    const worker = runtime.executors.items[0].instr.thread.?;
    const worker_fd = try RoleTest.openReader(worker.fd);
    defer _ = std.c.close(worker_fd);
    const process_reader = try RoleTest.openReader(process_fd);
    defer _ = std.c.close(process_reader);
    var context: RegistrationFailureTest.Context = .{ .runtime = runtime };
    {
        var original: std.c.rlimit = undefined;
        try std.testing.expectEqual(0, std.c.getrlimit(.NOFILE, &original));
        const limited: std.c.rlimit = .{ .cur = @min(original.cur, 96), .max = original.max };
        try std.testing.expectEqual(0, std.c.setrlimit(.NOFILE, &limited));
        defer std.debug.assert(std.c.setrlimit(.NOFILE, &original) == 0);
        var descriptors: [96]std.c.fd_t = undefined;
        var count: usize = 0;
        defer for (descriptors[0..count]) |fd| {
            std.debug.assert(std.c.close(fd) == 0);
        };
        while (count < descriptors.len) {
            const fd = std.c.dup(process_fd);
            if (fd < 0) {
                try std.testing.expectEqual(std.posix.E.MFILE, std.posix.errno(fd));
                break;
            }
            descriptors[count] = fd;
            count += 1;
        }
        try std.testing.expect(count < descriptors.len);
        const foreign = try std.Thread.spawn(.{}, RegistrationFailureTest.foreignSpawn, .{&context});
        foreign.join();
    }
    if (context.failure) |err| return err;
    try std.testing.expectEqual(@as(u32, 1), context.completed.load(.monotonic));
    runtime.deinit();
    initialized = false;
    var bytes: [65536]u8 = undefined;
    const length = std.c.pread(worker_fd, &bytes, bytes.len, 0);
    try std.testing.expect(length > 0);
    var reader = try format.FileReader.init(bytes[0..@intCast(length)]);
    var current: u64 = 0;
    var finishes: usize = 0;
    while (try reader.next()) |record| {
        if (record.kind != .chunk) continue;
        var events = (try format.parseChunk(record.payload)).iterator();
        while (try events.next()) |event| switch (event.event) {
            .task_begin => |v| {
                try std.testing.expect(v.task != 0);
                try std.testing.expectEqual(@as(u64, 0), current);
                current = v.task;
            },
            .task_end => |v| {
                try std.testing.expect(current != 0);
                if (v.reason == .finish) finishes += 1;
                current = 0;
            },
            else => {},
        };
    }
    try std.testing.expectEqual(@as(u64, 0), current);
    try std.testing.expectEqual(@as(usize, 1), finishes);
    const process_length = std.c.pread(process_reader, &bytes, bytes.len, 0);
    try std.testing.expect(process_length > 0);
    reader = try format.FileReader.init(bytes[0..@intCast(process_length)]);
    var losses: ?u64 = null;
    while (try reader.next()) |record| {
        if (record.kind == .end) losses = (try format.parseRecord(.end, record.payload)).dropped;
    }
    try std.testing.expect(losses.? > 0);
}

const TimerTraceTest = struct {
    const Loop = @import("../ev/loop.zig").Loop;
    const Timer = @import("../ev/completion.zig").Timer;
    const cycles = 64;
    const Context = struct {
        loop: *Loop,
        tid: u64 = 0,
        reader: std.c.fd_t = -1,
        failure: ?anyerror = null,
    };

    fn run(context: *Context) void {
        exercise(context) catch |err| {
            context.failure = err;
        };
    }

    fn exercise(context: *Context) !void {
        context.tid = @intCast(std.Thread.getCurrentId());
        const producer = getThread(.other, format.no_executor) orelse return error.MissingTraceThread;
        defer exitThread();
        context.reader = try RoleTest.openReader(producer.fd);
        var timer: Timer = .init(.{ .duration = .fromSeconds(60) });
        for (0..cycles) |_| {
            context.loop.setTimer(&timer, .{ .duration = .fromSeconds(60) });
            context.loop.setTimer(&timer, .{ .duration = .fromSeconds(30) });
            if (!context.loop.clearTimer(&timer)) return error.TimerNotDisarmed;
            // Clearing an already-disarmed timer must not emit a second terminal event.
            if (!context.loop.clearTimer(&timer)) return error.TimerNotReusable;
        }
    }

    fn verify(context: Context) !void {
        var bytes: [65536]u8 = undefined;
        const length = std.c.pread(context.reader, &bytes, bytes.len, 0);
        try std.testing.expect(length > 0);
        var reader = try format.FileReader.init(bytes[0..@intCast(length)]);
        const metadata = try format.parseRecord(.thread, (try reader.next()).?.payload);
        try std.testing.expectEqual(context.tid, metadata.os_tid);
        var submits: usize = 0;
        var completes: usize = 0;
        while (try reader.next()) |record| {
            if (record.kind != .chunk) continue;
            var events = (try format.parseChunk(record.payload)).iterator();
            while (try events.next()) |event| switch (event.event) {
                .io_submit => |value| {
                    try std.testing.expectEqual(@as(u64, @backingInt(@import("../ev/completion.zig").Op.timer)), value.kind);
                    submits += 1;
                },
                .io_complete => |value| {
                    try std.testing.expectEqual(format.IoResult.canceled, value.result);
                    completes += 1;
                },
                else => {},
            };
        }
        try std.testing.expectEqual(@as(usize, cycles), submits);
        try std.testing.expectEqual(@as(usize, cycles), completes);
    }

    fn verifyRetired(fd: std.c.fd_t) !void {
        var bytes: [65536]u8 = undefined;
        const length = std.c.pread(fd, &bytes, bytes.len, 0);
        try std.testing.expect(length > 0);
        var reader = try format.FileReader.init(bytes[0..@intCast(length)]);
        var pending: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer pending.deinit(std.testing.allocator);
        while (try reader.next()) |record| {
            if (record.kind != .chunk) continue;
            var events = (try format.parseChunk(record.payload)).iterator();
            while (try events.next()) |event| switch (event.event) {
                .io_submit => |value| {
                    try std.testing.expect(!pending.contains(value.op));
                    try pending.put(std.testing.allocator, value.op, {});
                },
                .io_complete => |value| try std.testing.expect(pending.remove(value.op)),
                else => {},
            };
        }
        try std.testing.expectEqual(@as(usize, 0), pending.count());
    }
};

test "instrument cross-thread timer disarms retain producer ownership and terminal events" {
    if (builtin.os.tag != .linux or builtin.single_threaded or
        !@import("root.zig").enabled) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const scratch = std.mem.span(std.c.getenv("TMPDIR") orelse return error.MissingScratchDirectory);
    var random: [8]u8 = undefined;
    io.random(&random);
    const directory = try a.print("{s}/zio-trace-timers-{s}", .{ scratch, std.fmt.bytesToHex(&random, .lower) });
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, directory, .{});
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer dir.close(io);
    const cwd_fd = std.c.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, @as(std.c.mode_t, 0));
    try std.testing.expect(cwd_fd >= 0);
    defer _ = std.c.close(cwd_fd);
    try std.testing.expectEqual(0, RoleTest.c.fchdir(dir.handle));
    defer std.debug.assert(RoleTest.c.fchdir(cwd_fd) == 0);
    const previous = if (std.c.getenv("ZIO_PROFILE")) |value| try a.dupeSentinel(u8, std.mem.span(value), 0) else null;
    defer {
        if (previous) |value| {
            std.debug.assert(RoleTest.c.setenv("ZIO_PROFILE", value, 1) == 0);
        } else std.debug.assert(RoleTest.c.unsetenv("ZIO_PROFILE") == 0);
    }
    try std.testing.expectEqual(0, RoleTest.c.setenv("ZIO_PROFILE", "io", 1));
    const runtime = try @import("../runtime.zig").Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    var initialized = true;
    defer if (initialized) runtime.deinit();
    const main_reader = try RoleTest.openReader(runtime.executors.items[0].instr.thread.?.fd);
    defer _ = std.c.close(main_reader);
    var contexts = [_]TimerTraceTest.Context{
        .{ .loop = &runtime.executors.items[0].loop },
        .{ .loop = &runtime.executors.items[0].loop },
    };
    defer for (contexts) |context| {
        if (context.reader >= 0) _ = std.c.close(context.reader);
    };
    var workers: [2]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (workers[0..spawned]) |worker| worker.join();
    for (&contexts) |*context| {
        workers[spawned] = try std.Thread.spawn(.{}, TimerTraceTest.run, .{context});
        spawned += 1;
    }
    for (workers) |worker| worker.join();
    spawned = 0;
    for (contexts) |context| {
        if (context.failure) |err| return err;
        try TimerTraceTest.verify(context);
    }
    runtime.deinit();
    initialized = false;
    try TimerTraceTest.verifyRetired(main_reader);
}
