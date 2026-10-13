// SPDX-License-Identifier: MIT
const std = @import("std");
const zio = @import("zio");
pub const std_options_debug_io = zio.debug_io;

noinline fn primeSearch(seed: u64) !void {
    const span = zio.instrument.zone(@src());
    defer span.end();
    var result = seed;
    for (0..120) |batch| {
        for (0..20000) |i| result = (result ^ @as(u64, i)) *% 6364136223846793005 +% 1;
        std.mem.doNotOptimizeAway(result);
        zio.instrument.plot("cpu batch", @intCast(batch));
        try zio.yield();
    }
}
noinline fn hashSearch(seed: u64) !void {
    const span = zio.instrument.zone(@src());
    defer span.end();
    var result = seed;
    for (0..100) |_| {
        for (0..15000) |_| result = std.hash.Wyhash.hash(result, "zio tracing workload");
        std.mem.doNotOptimizeAway(result);
        try zio.yield();
    }
}
fn producer(channel: *zio.Channel(i64)) !void {
    for (0..15) |i| {
        try zio.sleep(.fromMilliseconds(100));
        try channel.send(@intCast(i));
    }
}
fn consumer(channel: *zio.Channel(i64)) !void {
    for (0..15) |_| zio.instrument.plot("received", try channel.receive());
}
fn mutexWait(mutex: *zio.Mutex) !void {
    for (0..10) |_| {
        try mutex.lock();
        defer mutex.unlock();
        try zio.sleep(.fromMilliseconds(5));
    }
}
fn pipeWrite(file: zio.File) !void {
    try zio.sleep(.fromMilliseconds(50));
    var buffer: [128]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.writeAll("a traced pipe wake\n");
    try writer.interface.flush();
}
fn pipeRead(file: zio.File) !void {
    var buffer: [128]u8 = undefined;
    var reader = file.reader(&buffer);
    _ = try reader.interface.takeDelimiterInclusive('\n');
}
fn blockingWork() u64 {
    const span = zio.instrument.zone(@src());
    defer span.end();
    var value: u64 = 1;
    for (0..2_000_000) |i| value = value *% 33 +% i;
    return value;
}
noinline fn standardSleep(io: std.Io, value: u64) u64 {
    io.sleep(.fromMilliseconds(75), .awake) catch {};
    return value * 2;
}
noinline fn standardGroupSleep(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(25), .awake);
}
pub fn main(init: std.process.Init) !void {
    const runtime = try zio.Runtime.init(init.gpa, .{ .executors = .exact(4) });
    defer runtime.deinit();
    zio.instrument.message("trace demo starts");
    var channel = zio.Channel(i64).init(&.{});
    var mutex: zio.Mutex = .init;
    const fds = try zio.os.fs.pipe();
    const pipes: zio.PipePair = .{
        .read = .{ .fd = fds[0], .pollable = true },
        .write = .{ .fd = fds[1], .pollable = true },
    };
    defer pipes.close();
    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(primeSearch, .{@as(u64, 7)});
    try group.spawn(hashSearch, .{@as(u64, 13)});
    try group.spawn(producer, .{&channel});
    try group.spawn(consumer, .{&channel});
    try group.spawn(mutexWait, .{&mutex});
    try group.spawn(mutexWait, .{&mutex});
    try group.spawn(pipeWrite, .{pipes.write});
    try group.spawn(pipeRead, .{pipes.read});
    var blocking = try runtime.spawnBlocking(blockingWork, .{});
    const io = runtime.io();
    var async_task = io.async(standardSleep, .{ io, @as(u64, 21) });
    var concurrent_task = try io.concurrent(standardSleep, .{ io, @as(u64, 22) });
    var standard_group: std.Io.Group = .init;
    standard_group.async(io, standardGroupSleep, .{io});
    zio.instrument.plot("async answer", @intCast(async_task.await(io)));
    zio.instrument.plot("concurrent answer", @intCast(concurrent_task.await(io)));
    zio.instrument.plot("blocking answer", @bitCast(blocking.join()));
    try standard_group.await(io);
    try group.wait();
    zio.instrument.message("trace demo ends");
}
