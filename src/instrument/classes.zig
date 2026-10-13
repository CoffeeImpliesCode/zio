const std = @import("std");
const format = @import("format.zig");

pub const Result = struct { mask: u64 = 0, unknown: usize = 0 };
pub fn classForName(name: []const u8) ?format.EventClass {
    return std.meta.stringToEnum(format.EventClass, name);
}

pub fn parse(text: []const u8) Result {
    if (std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "1")) return .{ .mask = format.all_classes };
    var result: Result = .{};
    var tokens = std.mem.splitScalar(u8, text, ',');
    while (tokens.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len == 0) continue;
        if (classForName(name)) |class| {
            result.mask |= class.mask();
        } else {
            result.unknown += 1;
        }
    }
    return result;
}

test "instrument profile classes parse independently of session setup" {
    try std.testing.expectEqual(format.all_classes, parse("1").mask);
    try std.testing.expectEqual(format.EventClass.sched.mask() | format.EventClass.loop.mask(), parse("sched,loop").mask);
    try std.testing.expectEqual(format.EventClass.work.mask() | format.EventClass.user.mask(), parse(" work, user,work ").mask);
    try std.testing.expectEqual(0, parse("").mask);
    try std.testing.expectEqual(0, parse("unknown").mask);
    try std.testing.expectEqual(1, parse("unknown").unknown);
    try std.testing.expectEqual(format.EventClass.stacks.mask(), parse("bad,stacks,,wrong").mask);
    try std.testing.expectEqual(2, parse("bad,stacks,,wrong").unknown);
}
