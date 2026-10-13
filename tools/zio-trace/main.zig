const std = @import("std");
const Session = @import("session.zig").Session;
const Model = @import("timeline.zig").Model;
const Symbolizer = @import("symbolize.zig").Symbolizer;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    const usage =
        \\Usage: zio-trace <info|util|stats|perfetto> [options] [session-dir]
        \\  session-dir defaults to the newest .zio/<timestamp>.
        \\  --exe PATH       Override the recorded executable for symbolization.
        \\  -o PATH          Output file (required for util and perfetto).
        \\  --bins N         SVG time bins (default 300; 1..10000).
        \\  --flows          Include wake-to-run arrows in Perfetto.
        \\
    ;
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const w = &stdout.interface;
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        try w.writeAll(usage);
        try w.flush();
        return;
    }
    const command = args[1];
    if (!std.mem.eql(u8, command, "info") and !std.mem.eql(u8, command, "util") and
        !std.mem.eql(u8, command, "stats") and !std.mem.eql(u8, command, "perfetto"))
        return error.UnknownCommand;
    var path: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var exe: ?[]const u8 = null;
    var bins: usize = 300;
    var flows = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--flows")) {
            flows = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--exe") or
            std.mem.eql(u8, arg, "--bins"))
        {
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            if (std.mem.eql(u8, arg, "-o")) output = args[i] else if (std.mem.eql(u8, arg, "--exe")) exe = args[i] else {
                bins = try std.fmt.parseInt(usize, args[i], 10);
                if (bins == 0 or bins > 10000) return error.InvalidBinCount;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (path == null) {
            path = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }
    if ((std.mem.eql(u8, command, "util") or std.mem.eql(u8, command, "perfetto")) and
        output == null) return error.OutputPathRequired;
    const session = try Session.load(a, io, path orelse try @import("session.zig").newest(a, io));
    var model = try Model.build(a, session);
    var symbolizer: ?Symbolizer = null;
    defer if (symbolizer) |*symbols| symbols.deinit();
    const executable = exe orelse if (session.process) |process| process.exe_path else null;
    if (executable) |executable_path| {
        symbolizer = Symbolizer.init(init.gpa, io, executable_path, if (session.process) |process| process.anchor_addr else 0) catch |err| blk: {
            std.log.warn("cannot symbolize {s}: {s}; using recorded addresses", .{ executable_path, @errorName(err) });
            break :blk null;
        };
    }
    try @import("naming.zig").resolve(a, &model, if (symbolizer) |*symbols| symbols else null);
    if (std.mem.eql(u8, command, "info")) {
        try @import("report.zig").info(w, &model);
    } else if (std.mem.eql(u8, command, "stats")) {
        try @import("report.zig").stats(a, w, &model);
    } else {
        var file = try std.Io.Dir.cwd().createFile(io, output.?, .{});
        defer file.close(io);
        var buffer: [8192]u8 = undefined;
        var writer = file.writer(io, &buffer);
        if (std.mem.eql(u8, command, "util")) {
            try @import("svg.zig").write(a, &writer.interface, &model, bins);
            try @import("report.zig").threadTable(w, &model);
        } else {
            try @import("perfetto.zig").write(a, &writer.interface, &model, flows);
        }
        try writer.interface.flush();
        try w.print("Wrote {s}\n", .{output.?});
    }
    try w.flush();
}

test {
    _ = @import("tests.zig");
    _ = @import("naming.zig");
    _ = @import("report.zig");
    _ = @import("symbolize.zig");
}
