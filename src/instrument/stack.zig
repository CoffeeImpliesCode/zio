const std = @import("std");
const builtin = @import("builtin");

pub const Bounds = struct { low: usize = 0, high: usize = 0 };

pub fn walk(bounds: Bounds, first_frame: usize, output: []usize) usize {
    if (bounds.high < bounds.low or bounds.high - bounds.low < 2 * @sizeOf(usize)) return 0;
    var frame = first_frame;
    var count: usize = 0;
    while (count < output.len and frame >= bounds.low and
        frame <= bounds.high - 2 * @sizeOf(usize) and frame % @alignOf(usize) == 0)
    {
        const words: *const [2]usize = @ptrFromInt(frame);
        if (words[1] == 0) break;
        output[count] = words[1];
        count += 1;
        const next = words[0];
        if (next <= frame) break;
        frame = next;
    }
    return count;
}

const linux = struct {
    extern "c" fn pthread_getattr_np(std.c.pthread_t, *std.c.pthread_attr_t) c_int;
    extern "c" fn pthread_attr_getstack(*const std.c.pthread_attr_t, *?*anyopaque, *usize) c_int;
};
const darwin = struct {
    extern "c" fn pthread_get_stackaddr_np(std.c.pthread_t) ?*anyopaque;
    extern "c" fn pthread_get_stacksize_np(std.c.pthread_t) usize;
};

pub fn threadBounds() Bounds {
    switch (builtin.os.tag) {
        .linux => {
            var attributes: std.c.pthread_attr_t = undefined;
            if (linux.pthread_getattr_np(std.c.pthread_self(), &attributes) != 0) return .{};
            defer _ = std.c.pthread_attr_destroy(&attributes);
            var address: ?*anyopaque = null;
            var size: usize = 0;
            if (linux.pthread_attr_getstack(&attributes, &address, &size) != 0) return .{};
            const low = @intFromPtr(address orelse return .{});
            return .{ .low = low, .high = std.math.add(usize, low, size) catch return .{} };
        },
        else => |tag| {
            if (!tag.isDarwin()) return .{};
            const address = darwin.pthread_get_stackaddr_np(std.c.pthread_self()) orelse return .{};
            const high = @intFromPtr(address);
            const size = darwin.pthread_get_stacksize_np(std.c.pthread_self());
            if (size > high) return .{};
            return .{ .low = high - size, .high = high };
        },
    }
}

pub fn currentBounds(native: Bounds) Bounds {
    const runtime = @import("../runtime.zig");
    if (runtime.getCurrentExecutorOrNull()) |executor| {
        if (executor.current_task) |task| {
            if (task != &executor.main_task) {
                const info = task.coro.context.stack_info;
                return .{ .low = info.limit, .high = info.base };
            }
        }
    }
    return native;
}

pub noinline fn capture(native: Bounds, output: []usize) usize {
    switch (builtin.cpu.arch) {
        .x86_64, .x86, .aarch64 => {},
        else => return 0,
    }
    var bounds = currentBounds(native);
    const first = @frameAddress();
    // Linux's main-stack attributes include reservation below mapped pages.
    // Starting at a live frame and moving strictly upwards never visits it.
    bounds.low = @max(bounds.low, first);
    return walk(bounds, first, output);
}

test "instrument bounded frames reject invalid and unaligned chains" {
    var frames: [3][2]usize = undefined;
    const bounds: Bounds = .{ .low = @intFromPtr(&frames), .high = @intFromPtr(&frames) + @sizeOf(@TypeOf(frames)) };
    frames[0] = .{ @intFromPtr(&frames[1]), 100 };
    frames[1] = .{ bounds.high + 16, 200 };
    frames[2] = .{ 0, 300 };
    var output: [8]usize = undefined;
    try std.testing.expectEqual(2, walk(bounds, @intFromPtr(&frames[0]), &output));
    try std.testing.expectEqualSlices(usize, &.{ 100, 200 }, output[0..2]);
    try std.testing.expectEqual(0, walk(bounds, bounds.high, &output));
    try std.testing.expectEqual(0, walk(bounds, bounds.low + 1, &output));
    frames[0][0] = bounds.low;
    try std.testing.expectEqual(1, walk(bounds, bounds.low, &output));
}

test "instrument native bounds contain a live frame" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const bounds = threadBounds();
    const frame = @frameAddress();
    try std.testing.expect(frame >= bounds.low and frame < bounds.high);
    var frames: [8]usize = undefined;
    try std.testing.expect(capture(bounds, &frames) > 0);
}
