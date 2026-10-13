// SPDX-FileCopyrightText: 2026 zio contributors
// SPDX-License-Identifier: MIT

//! Offline ELF/DWARF address lookup. The caller subtracts one from return addresses.
const std = @import("std");
const builtin = @import("builtin");
const format = @import("zio_trace_format");

pub const Location = struct {
    function: []const u8,
    file: ?[]const u8,
    line: u32,
    column: u32,
};

pub const Symbolizer = struct {
    gpa: std.mem.Allocator,
    elf: ?std.debug.ElfFile = null,
    load_bias: ?u64 = null,
    executable_ranges: std.ArrayList(Range) = .empty,
    cache: std.AutoHashMapUnmanaged(u64, ?Location) = .empty,
    text: std.heap.ArenaAllocator.State = .{},

    const Range = struct { start: u64, end: u64 };

    /// Missing anchors in PIE files leave the load bias unknown; lookups then return null.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        exe_path: []const u8,
        anchor_runtime_addr: u64,
    ) !Symbolizer {
        var self: Symbolizer = .{ .gpa = gpa };
        errdefer self.deinit();
        if (comptime builtin.os.tag != .linux) return self;

        const file = try std.Io.Dir.cwd().openFile(io, exe_path, .{});
        defer file.close(io);
        var magic_buffer: [64]u8 = undefined;
        var file_reader = file.reader(io, &magic_buffer);
        const magic = file_reader.interface.peek(4) catch |err| switch (err) {
            error.EndOfStream => return self,
            error.ReadFailed => return file_reader.err orelse error.Unexpected,
        };
        if (!std.mem.eql(u8, magic, std.elf.MAGIC)) return self;
        self.elf = std.debug.ElfFile.load(gpa, io, file, null, &.none) catch |err| switch (err) {
            error.InvalidElfMagic,
            error.InvalidElfClass,
            error.InvalidElfEndian,
            error.InvalidElfVersion,
            => return self,
            else => return err,
        };
        const elf = &self.elf.?;
        var reader: std.Io.Reader = .fixed(elf.mapped_file);
        const header = try std.elf.Header.read(&reader);
        var headers = header.iterateProgramHeadersBuffer(elf.mapped_file);
        while (try headers.next()) |segment| {
            if (segment.type != .LOAD or !segment.flags.X) continue;
            try self.executable_ranges.append(gpa, .{
                .start = segment.vaddr,
                .end = try std.math.add(u64, segment.vaddr, segment.memsz),
            });
        }

        const anchor = try findAnchor(elf);
        if (anchor) |value| {
            if (anchor_runtime_addr != 0) {
                self.load_bias = std.math.sub(u64, anchor_runtime_addr, value) catch null;
            }
        }
        if (self.load_bias == null and header.type == .EXEC) self.load_bias = 0;

        if (elf.dwarf) |*dwarf| {
            dwarf.open(gpa, elf.endian) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    // A malformed or unsupported DWARF section must not hide usable symbols.
                    dwarf.deinit(gpa);
                    elf.dwarf = null;
                },
            };
        }
        return self;
    }

    pub fn deinit(self: *Symbolizer) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.elf) |*elf| elf.deinit(self.gpa);
        }
        self.executable_ranges.deinit(self.gpa);
        self.cache.deinit(self.gpa);
        var text = self.text.promote(self.gpa);
        text.deinit();
        self.* = undefined;
    }

    /// Function entries are used as-is. Subtract one from a return PC before calling.
    /// Both successful lookups and misses are cached; all strings live until deinit.
    pub fn lookup(self: *Symbolizer, addr: u64) ?Location {
        const entry = self.cache.getOrPut(self.gpa, addr) catch return null;
        if (!entry.found_existing) entry.value_ptr.* = self.lookupUncached(addr);
        return entry.value_ptr.*;
    }

    fn lookupUncached(self: *Symbolizer, addr: u64) ?Location {
        const bias = self.load_bias orelse return null;
        const address = std.math.sub(u64, addr, bias) catch return null;
        const mapped = for (self.executable_ranges.items) |range| {
            if (address >= range.start and address < range.end) break true;
        } else false;
        if (!mapped) return null;

        const elf = if (self.elf) |*elf| elf else return null;
        const symbol = elf.searchSymtab(self.gpa, address) catch std.debug.Symbol.unknown;
        var location: Location = .{
            .function = symbol.name orelse "??",
            .file = null,
            .line = 0,
            .column = 0,
        };
        if (elf.dwarf) |*dwarf| {
            if (dwarf.getSymbolName(address)) |name| location.function = name;
            const unit = dwarf.findCompileUnit(elf.endian, address) catch
                return if (symbol.name != null) location else null;
            var text = self.text.promote(self.gpa);
            defer self.text = text.state;
            const source = dwarf.getLineNumberInfo(
                self.gpa,
                text.allocator(),
                elf.endian,
                unit,
                address,
            ) catch return if (symbol.name != null or
                !std.mem.eql(u8, location.function, "??")) location else null;
            location.file = source.file_name;
            location.line = std.math.cast(u32, source.line) orelse 0;
            location.column = std.math.cast(u32, source.column) orelse 0;
            return location;
        }
        return if (symbol.name != null) location else null;
    }

    fn findAnchor(elf: *std.debug.ElfFile) !?u64 {
        const symtab = elf.symtab orelse return null;
        const strtab = elf.strtab orelse return null;
        switch (elf.is_64) {
            inline true, false => |is_64| {
                const Sym = if (is_64) std.elf.Elf64_Sym else std.elf.Elf32_Sym;
                if (symtab.entry_size != @sizeOf(Sym) or
                    symtab.bytes.len % @sizeOf(Sym) != 0) return error.BadSymtab;
                var reader: std.Io.Reader = .fixed(symtab.bytes);
                var anchor: ?u64 = null;
                for (0..symtab.bytes.len / @sizeOf(Sym)) |_| {
                    const symbol = try reader.takeStruct(Sym, elf.endian);
                    if (symbol.st_name >= strtab.len) return error.BadSymtab;
                    const name = std.mem.sliceTo(strtab[symbol.st_name..], 0);
                    _ = try std.math.add(u64, symbol.st_value, symbol.st_size);
                    if (symbol.st_shndx != std.elf.SHN_UNDEF and
                        std.mem.eql(u8, name, format.anchor_symbol)) anchor = symbol.st_value;
                }
                return anchor;
            },
        }
    }
};

comptime {
    if (builtin.is_test) @export(&testAnchor, .{ .name = format.anchor_symbol });
}

fn testAnchor() callconv(.c) void {
    asm volatile ("" ::: .{ .memory = true });
}

noinline fn someFn() usize {
    return @returnAddress();
}

const Caller = struct { address: usize, line: u32 };

noinline fn captureCaller() Caller {
    const line = @src().line + 1;
    return .{ .address = someFn(), .line = line };
}

// Resolve the running executable rather than fabricated addresses, including PIE relocation.
test "symbolizer resolves real function entries and cached source locations" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&testAnchor),
    );
    defer symbols.deinit();

    const location = symbols.lookup(@intFromPtr(&someFn)) orelse
        return error.FunctionNotResolved;
    try std.testing.expect(std.mem.endsWith(u8, location.function, "someFn"));
    try std.testing.expect(std.mem.endsWith(u8, location.file.?, "symbolize.zig"));
    try std.testing.expect(location.line > 0 and location.line < @src().line);
    const again = symbols.lookup(@intFromPtr(&someFn)).?;
    try std.testing.expectEqual(location.function.ptr, again.function.ptr);
    try std.testing.expectEqual(location.file.?.ptr, again.file.?.ptr);
    try std.testing.expectEqual(null, symbols.lookup(0));
    try std.testing.expectEqual(null, symbols.lookup(std.math.maxInt(u64)));
    for (1..128) |offset| _ = symbols.lookup(@intFromPtr(&someFn) + offset);
    const retained = symbols.lookup(@intFromPtr(&someFn)).?;
    try std.testing.expectEqual(location.file.?.ptr, retained.file.?.ptr);
    try std.testing.expectEqualStrings(location.file.?, retained.file.?);
    try std.testing.expect(symbols.cache.count() >= 130);
}

// A return PC identifies the instruction after the call; the analyzer adjusts it by one.
test "symbolizer resolves a return address to the calling line" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&testAnchor),
    );
    defer symbols.deinit();
    const caller = captureCaller();
    const location = symbols.lookup(caller.address - 1) orelse
        return error.CallerNotResolved;
    try std.testing.expect(std.mem.endsWith(u8, location.function, "captureCaller"));
    try std.testing.expect(std.mem.endsWith(u8, location.file.?, "symbolize.zig"));
    try std.testing.expectEqual(caller.line, location.line);
    try std.testing.expect(location.column > 0);
}

// DWARF-less ELF files retain the same symbol-table address/name mapping.
test "symbolizer falls back to symtab names without DWARF" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&testAnchor),
    );
    defer symbols.deinit();
    symbols.elf.?.dwarf.?.deinit(std.testing.allocator);
    symbols.elf.?.dwarf = null;
    const location = symbols.lookup(@intFromPtr(&someFn)) orelse
        return error.FunctionNotResolved;
    try std.testing.expect(std.mem.endsWith(u8, location.function, "someFn"));
    try std.testing.expectEqual(null, location.file);
    try std.testing.expectEqual(0, location.line);
    try std.testing.expectEqual(0, location.column);
}

test "symbolizer resolves DWARF without a symbol table" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&testAnchor),
    );
    defer symbols.deinit();
    symbols.elf.?.symtab = null;
    const location = symbols.lookup(@intFromPtr(&someFn)) orelse
        return error.FunctionNotResolved;
    try std.testing.expect(std.mem.endsWith(u8, location.function, "someFn"));
    try std.testing.expect(std.mem.endsWith(u8, location.file.?, "symbolize.zig"));
}

test "symbolizer requires relocation information only for PIE" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        0,
    );
    defer symbols.deinit();
    var reader: std.Io.Reader = .fixed(symbols.elf.?.mapped_file);
    const header = try std.elf.Header.read(&reader);
    if (header.type == .DYN) {
        try std.testing.expectEqual(null, symbols.lookup(@intFromPtr(&someFn)));
        try std.testing.expectEqual(null, symbols.load_bias);
    } else {
        try std.testing.expectEqual(0, symbols.load_bias.?);
        try std.testing.expect(symbols.lookup(@intFromPtr(&someFn)) != null);
    }
}

test "symbolizer treats non ELF formats as unmapped" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const root = std.testing.environ.getPosix("TMPDIR") orelse return error.SkipZigTest;
    var random: [8]u8 = undefined;
    std.testing.io.random(&random);
    const path = try std.testing.allocator.print("{s}/zio-symbolizer-{x}.bin", .{ root, &random });
    defer std.testing.allocator.free(path);
    const dir = std.Io.Dir.cwd();
    const data = "MZ";
    try dir.writeFile(std.testing.io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .exclusive = true },
    });
    defer dir.deleteFile(std.testing.io, path) catch @panic("test fixture cleanup failed");
    var symbols = try Symbolizer.init(std.testing.allocator, std.testing.io, path, 0);
    defer symbols.deinit();
    try std.testing.expectEqual(null, symbols.lookup(@intFromPtr(&someFn)));
}
