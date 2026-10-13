const std = @import("std");
const Symbolizer = @import("symbolize.zig").Symbolizer;
const Location = @import("symbolize.zig").Location;
const Model = @import("timeline.zig").Model;
const Task = @import("timeline.zig").Task;

pub fn resolve(a: std.mem.Allocator, model: *Model, symbolizer: ?*Symbolizer) !void {
    var tasks = model.tasks.valueIterator();
    while (tasks.next()) |task| task.name = try taskName(a, task.*, symbolizer);
}

fn taskName(a: std.mem.Allocator, task: Task, symbolizer: ?*Symbolizer) ![]const u8 {
    if (task.created != null and task.entry == 0) return a.print("main (executor {d})", .{task.executor});
    if (symbolizer) |symbols| {
        if (task.func) |func| if (symbols.lookup(func)) |loc| return loc.function;
        if (task.first_suspend) |frames| {
            var it = frames.iterator();
            while (try it.next()) |address| {
                if (address == 0) continue;
                if (symbols.lookup(address - 1)) |loc| if (!runtimeFrame(loc)) return loc.function;
            }
        }
        if (task.spawn_stack) |frames| {
            var it = frames.iterator();
            while (try it.next()) |address| {
                if (address == 0) continue;
                if (symbols.lookup(address - 1)) |loc| {
                    if (runtimeFrame(loc)) continue;
                    if (loc.file) |file| return a.print("spawned at {s}:{d}", .{ file, loc.line });
                }
            }
        }
        if (task.entry != 0) if (symbols.lookup(task.entry)) |loc| return loc.function;
    }
    return a.print("0x{x}", .{task.func orelse task.entry});
}

pub fn runtimeFrame(loc: Location) bool {
    if (std.mem.startsWith(u8, loc.function, "std.") or std.mem.startsWith(u8, loc.function, "zio.") or std.mem.startsWith(u8, loc.function, "zio::") or std.mem.startsWith(u8, loc.function, "std::")) return true;
    if (loc.file) |file| {
        if (std.mem.indexOf(u8, file, "/lib/std/") != null or std.mem.startsWith(u8, file, "lib/std/")) return true;
        if (std.mem.indexOf(u8, file, "/zio/src/") != null) return true;
        // DWARF commonly stores paths relative to the zio build root.
        if (std.mem.startsWith(u8, file, "src/")) return true;
    }
    return false;
}

test "runtime frame naming heuristic" {
    try std.testing.expect(runtimeFrame(.{ .function = "user", .file = "/a/zig/lib/std/Io.zig", .line = 1, .column = 0 }));
    try std.testing.expect(!runtimeFrame(.{ .function = "trace_demo.nativeTask", .file = "examples/trace_demo.zig", .line = 1, .column = 0 }));
}
