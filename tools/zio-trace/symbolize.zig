// SPDX-FileCopyrightText: 2026 zio contributors
// SPDX-License-Identifier: MIT

//! Offline ELF/DWARF address lookup. The caller subtracts one from return addresses.
const std = @import("std");
const builtin = @import("builtin");
const format = @import("zio_trace_format");
const Dwarf = std.debug.Dwarf;
const DW = std.dwarf;

pub const Location = struct {
    function: []const u8,
    file: ?[]const u8,
    line: u32,
    column: u32,
    /// Declaration/origin source used for filtering, not an observed call site.
    provenance_file: ?[]const u8 = null,
};

pub const Symbolizer = struct {
    gpa: std.mem.Allocator,
    elf: ?std.debug.ElfFile = null,
    load_bias: ?u64 = null,
    executable_ranges: std.ArrayList(Range) = .empty,
    cache: std.AutoHashMapUnmanaged(u64, Cached) = .empty,
    units: std.AutoHashMapUnmanaged(u64, ?*UnitIndex) = .empty,
    text: std.heap.ArenaAllocator.State = .{},

    const Range = struct { start: u64, end: u64 };
    const Cached = struct { location: ?Location, frames: ?[]const Location = null };

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
        var units = self.units.valueIterator();
        while (units.next()) |entry| if (entry.*) |index| {
            index.deinit(self.gpa);
            self.gpa.destroy(index);
        };
        self.units.deinit(self.gpa);
        var text = self.text.promote(self.gpa);
        text.deinit();
        self.* = undefined;
    }

    /// Function entries are used as-is. Subtract one from a return PC before calling.
    /// Both successful lookups and misses are cached; all strings live until deinit.
    pub fn lookup(self: *Symbolizer, addr: u64) ?Location {
        const entry = self.cache.getOrPut(self.gpa, addr) catch return null;
        if (!entry.found_existing) entry.value_ptr.* = .{ .location = self.lookupUncached(addr) };
        return entry.value_ptr.location;
    }

    /// Resolve each inline context in one physical frame, innermost first.
    /// The caller adjusts return PCs as for lookup. An empty slice is a cached miss.
    /// Slices and strings remain valid until deinit, including across later lookups.
    pub fn lookupFrames(self: *Symbolizer, addr: u64) []const Location {
        const location = self.lookup(addr) orelse return &.{};
        const cached = self.cache.getPtr(addr).?;
        if (cached.frames) |frames| return frames;
        var text = self.text.promote(self.gpa);
        defer self.text = text.state;
        const a = text.allocator();
        cached.frames = self.inlineFrames(a, addr, location) catch blk: {
            // Incomplete debug information still permits the ordinary symbol fallback.
            const frames = a.alloc(Location, 1) catch break :blk &.{};
            frames[0] = location;
            break :blk frames;
        };
        return cached.frames.?;
    }

    fn inlineFrames(self: *Symbolizer, a: std.mem.Allocator, addr: u64, inner: Location) ![]const Location {
        const elf = if (self.elf) |*elf| elf else return error.MissingDebugInfo;
        const dwarf = if (elf.dwarf) |*dwarf| dwarf else return error.MissingDebugInfo;
        const address = try std.math.sub(u64, addr, self.load_bias.?);
        const unit = try dwarf.findCompileUnit(elf.endian, address);
        const index = try self.unitIndex(unit);
        var deepest: ?usize = null;
        for (index.nodes, 0..) |node, i| {
            if (!node.is_function or !rangeMatches(index.ranges[node.ranges_start..][0..node.ranges_len], address)) continue;
            if (deepest == null or node.depth >= index.nodes[deepest.?].depth) deepest = i;
        }
        var current = deepest orelse return error.MissingDebugInfo;
        var frames: std.ArrayList(Location) = .empty;
        defer frames.deinit(self.gpa);
        var child: ?usize = null;
        while (true) {
            const node = &index.nodes[current];
            if (node.is_function and rangeMatches(index.ranges[node.ranges_start..][0..node.ranges_len], address)) {
                const resolved = try self.resolveNode(a, index, current);
                var location: Location = .{
                    .function = resolved.name orelse if (frames.items.len == 0) inner.function else "??",
                    .file = null,
                    .line = 0,
                    .column = 0,
                    .provenance_file = resolved.file,
                };
                if (child) |callee_index| {
                    const callee = index.nodes[callee_index];
                    if (callee.call_line) |line| {
                        if (callee.call_file) |file| {
                            location.file = try sourceFile(self.gpa, a, dwarf, unit, elf.endian, file);
                        } else if (resolved.zig_file) {
                            // Zig omits call_file when it is the enclosing declaration's
                            // file, identified through ZIG_parent. A real call_line is
                            // still required; declaration lines are never spawn PCs.
                            location.file = resolved.file;
                        }
                        location.line = std.math.cast(u32, line) orelse 0;
                        location.column = std.math.cast(u32, callee.call_column orelse 0) orelse 0;
                    }
                } else {
                    // The PC line-table row belongs to the innermost context even if
                    // our origin traversal resolves a name the std name cache missed.
                    location.file = inner.file;
                    location.line = inner.line;
                    location.column = inner.column;
                }
                try frames.append(self.gpa, location);
                child = current;
            }
            current = node.parent orelse break;
        }
        return a.dupe(Location, frames.items);
    }

    fn unitIndex(self: *Symbolizer, unit: *Dwarf.CompileUnit) ScanError!*UnitIndex {
        const entry = try self.units.getOrPut(self.gpa, unit.offset);
        if (entry.found_existing) return entry.value_ptr.* orelse error.MissingDebugInfo;
        // Cache unsupported/malformed units too, without retrying their full scan.
        entry.value_ptr.* = null;
        const elf = &self.elf.?;
        const index = try buildUnitIndex(self.gpa, &elf.dwarf.?, unit, elf.endian);
        entry.value_ptr.* = index;
        return index;
    }

    fn referencedNode(self: *Symbolizer, offset: u64) ScanError!NodeRef {
        const dwarf = &self.elf.?.dwarf.?;
        for (dwarf.compile_unit_list.items) |*unit| {
            if (offset < unit.offset or offset - unit.offset >= unit.size) continue;
            const index = try self.unitIndex(unit);
            return .{ .index = index, .node = index.find(offset) orelse return error.InvalidDebugInfo };
        }
        return error.InvalidDebugInfo;
    }

    fn resolveNode(self: *Symbolizer, a: std.mem.Allocator, index: *UnitIndex, node_index: usize) ScanError!ResolvedNode {
        const initial = &index.nodes[node_index];
        if (initial.resolved) |resolved| return resolved;
        var visited: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer visited.deinit(self.gpa);
        var current: NodeRef = .{ .index = index, .node = node_index };
        var name: ?[]const u8 = null;
        while (true) {
            const node = current.index.nodes[current.node];
            const seen = try visited.getOrPut(self.gpa, node.offset);
            if (seen.found_existing) return error.InvalidDebugInfo;
            if (node.name) |found| {
                name = found;
                break;
            }
            current = try self.referencedNode(node.origin orelse node.specification orelse break);
        }
        visited.clearRetainingCapacity();
        var pending: std.ArrayList(NodeRef) = .empty;
        defer pending.deinit(self.gpa);
        try pending.append(self.gpa, .{ .index = index, .node = node_index });
        var file: ?[]const u8 = null;
        var zig_file = false;
        while (pending.pop()) |reference| {
            const node = reference.index.nodes[reference.node];
            const seen = try visited.getOrPut(self.gpa, node.offset);
            if (seen.found_existing) continue;
            if (node.decl_file) |decl_file| {
                const elf = &self.elf.?;
                file = try sourceFile(self.gpa, a, &elf.dwarf.?, reference.index.unit, elf.endian, decl_file);
                break;
            }
            if (node.parent) |parent| try pending.append(self.gpa, .{ .index = reference.index, .node = parent });
            if (node.zig_parent) |parent| {
                zig_file = true;
                try pending.append(self.gpa, try self.referencedNode(parent));
            }
            if (node.specification) |specification| try pending.append(self.gpa, try self.referencedNode(specification));
            if (node.origin) |origin| try pending.append(self.gpa, try self.referencedNode(origin));
        }
        const resolved: ResolvedNode = .{ .name = name, .file = file, .zig_file = zig_file };
        initial.resolved = resolved;
        return resolved;
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

// The standard DWARF function cache discards DIE ancestry and inline call sites.
// Read those attributes from its already-opened units and abbreviation tables.
const DieAttr = std.meta.Elem(@TypeOf(@as(Dwarf.Die, undefined).attrs));
const ScanError = Dwarf.ScanError;

const ResolvedNode = struct {
    name: ?[]const u8,
    file: ?[]const u8,
    zig_file: bool,
};
const InlineNode = struct {
    offset: u64,
    parent: ?usize,
    depth: usize,
    is_function: bool,
    name: ?[]const u8,
    origin: ?u64,
    specification: ?u64,
    zig_parent: ?u64,
    decl_file: ?u64,
    call_file: ?u64,
    call_line: ?u64,
    call_column: ?u64,
    ranges_start: usize,
    ranges_len: usize,
    resolved: ?ResolvedNode = null,
};
const UnitIndex = struct {
    unit: *Dwarf.CompileUnit,
    nodes: []InlineNode,
    ranges: []Symbolizer.Range,

    fn deinit(self: *UnitIndex, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.ranges);
    }

    fn find(self: *const UnitIndex, offset: u64) ?usize {
        const i = std.sort.lowerBound(InlineNode, self.nodes, offset, struct {
            fn order(target: u64, node: InlineNode) std.math.Order {
                return std.math.order(target, node.offset);
            }
        }.order);
        return if (i < self.nodes.len and self.nodes[i].offset == offset) i else null;
    }
};
const NodeRef = struct { index: *UnitIndex, node: usize };

fn buildUnitIndex(
    gpa: std.mem.Allocator,
    dwarf: *Dwarf,
    unit: *Dwarf.CompileUnit,
    endian: std.builtin.Endian,
) ScanError!*UnitIndex {
    const info = dwarf.section(.debug_info) orelse return error.MissingDebugInfo;
    const end = try std.math.add(u64, unit.offset, unit.size);
    if (end > info.len) return error.InvalidDebugInfo;
    var reader: std.Io.Reader = .fixed(info[0..@intCast(end)]);
    reader.seek = @intCast(unit.offset);
    const header = try Dwarf.readUnitHeader(&reader, endian);
    if (header.format != unit.format or
        try std.math.add(u64, header.header_length, header.unit_length) != unit.size)
        return error.InvalidDebugInfo;
    const version = try reader.takeInt(u16, endian);
    if (version != unit.version or version < 2 or version > 5) return error.InvalidDebugInfo;
    const address_size, const abbrev_offset = if (version == 5) blk: {
        if (try reader.takeByte() != DW.UT.compile) return error.InvalidDebugInfo;
        const size = try reader.takeByte();
        break :blk .{ size, try readOffset(&reader, unit, endian) };
    } else blk: {
        const offset = try readOffset(&reader, unit, endian);
        break :blk .{ try reader.takeByte(), offset };
    };
    if (address_size != unit.addr_size_bytes or abbrev_offset != unit.abbrev_offset)
        return error.InvalidDebugInfo;
    if (address_size != 1 and address_size != 2 and address_size != 4 and address_size != 8)
        return error.InvalidDebugInfo;
    const table = for (dwarf.abbrev_table_list.items) |table| {
        if (table.offset == unit.abbrev_offset) break table;
    } else return error.MissingDebugInfo;
    var max_attrs: usize = 0;
    var padding: ?u7 = null;
    for (table.abbrevs) |abbrev| {
        max_attrs = @max(max_attrs, abbrev.attrs.len);
        if (abbrev.tag_id == DW.TAG.ZIG_padding and !abbrev.has_children and abbrev.attrs.len == 0)
            padding = std.math.cast(u7, abbrev.code);
    }
    const attrs = try gpa.alloc(DieAttr, max_attrs);
    defer gpa.free(attrs);
    var nodes: std.ArrayList(InlineNode) = .empty;
    defer nodes.deinit(gpa);
    var ranges: std.ArrayList(Symbolizer.Range) = .empty;
    defer ranges.deinit(gpa);
    var depths: std.ArrayList(?usize) = .empty;
    defer depths.deinit(gpa);
    var parent: ?usize = null;
    while (reader.seek < reader.buffer.len) {
        if (reader.buffer[reader.seek] == 0) {
            const next = std.mem.findNonePos(u8, reader.buffer, reader.seek, &.{0}) orelse reader.buffer.len;
            var count = next - reader.seek;
            while (count != 0 and depths.items.len != 0) : (count -= 1) parent = depths.pop().?;
            reader.seek = next;
            continue;
        }
        if (padding) |code| {
            if (reader.buffer[reader.seek] == code) {
                reader.seek = std.mem.findNonePos(u8, reader.buffer, reader.seek, &.{code}) orelse reader.buffer.len;
                continue;
            }
        }
        const offset = reader.seek;
        const die = (try readDie(dwarf, unit, endian, &reader, attrs)) orelse return error.InvalidDebugInfo;
        const previous_parent = parent;
        const is_function = die.tag_id == DW.TAG.subprogram or die.tag_id == DW.TAG.inlined_subroutine or
            die.tag_id == DW.TAG.subroutine or die.tag_id == DW.TAG.entry_point;
        // Keep referenced declarations/file owners, not unrelated variables/type leaves.
        if (is_function or die.tag_id == DW.TAG.compile_unit or die.tag_id == DW.TAG.namespace or
            die.tag_id == DW.TAG.structure_type or die.tag_id == DW.TAG.class_type or
            die.tag_id == DW.TAG.union_type or getAttr(die, DW.AT.decl_file) != null or
            getAttr(die, DW.AT.ZIG_parent) != null)
        {
            const ranges_start = ranges.items.len;
            if (is_function) try collectRanges(gpa, dwarf, unit, endian, die, &ranges);
            const node: InlineNode = .{
                .offset = offset,
                .parent = parent,
                .depth = depths.items.len,
                .is_function = is_function,
                .name = if (is_function and getAttr(die, DW.AT.name) != null)
                    try die.getAttrString(dwarf, endian, DW.AT.name, dwarf.section(.debug_str), unit)
                else
                    null,
                .origin = try referenceOffset(die, DW.AT.abstract_origin, unit),
                .specification = try referenceOffset(die, DW.AT.specification, unit),
                .zig_parent = try referenceOffset(die, DW.AT.ZIG_parent, unit),
                .decl_file = attrUInt(die, DW.AT.decl_file),
                .call_file = attrUInt(die, DW.AT.call_file),
                .call_line = attrUInt(die, DW.AT.call_line),
                .call_column = attrUInt(die, DW.AT.call_column),
                .ranges_start = ranges_start,
                .ranges_len = ranges.items.len - ranges_start,
            };
            parent = nodes.items.len;
            try nodes.append(gpa, node);
        }
        if (die.has_children) {
            try depths.append(gpa, previous_parent);
        } else {
            parent = previous_parent;
        }
    }
    const index = try gpa.create(UnitIndex);
    errdefer gpa.destroy(index);
    const owned_nodes = try nodes.toOwnedSlice(gpa);
    errdefer gpa.free(owned_nodes);
    index.* = .{ .unit = unit, .nodes = owned_nodes, .ranges = try ranges.toOwnedSlice(gpa) };
    return index;
}

fn referenceOffset(die: Dwarf.Die, id: u64, unit: *const Dwarf.CompileUnit) ScanError!?u64 {
    const value = getAttr(die, id) orelse return null;
    return switch (value) {
        .ref => |offset| if (offset < unit.size)
            try std.math.add(u64, unit.offset, offset)
        else
            error.InvalidDebugInfo,
        .ref_addr => |offset| offset,
        else => error.InvalidDebugInfo,
    };
}

fn rangeMatches(ranges: []const Symbolizer.Range, address: u64) bool {
    for (ranges) |range| if (address >= range.start and address < range.end) return true;
    return false;
}

fn readDie(
    dwarf: *Dwarf,
    unit: *const Dwarf.CompileUnit,
    endian: std.builtin.Endian,
    reader: *std.Io.Reader,
    attrs: []DieAttr,
) ScanError!?Dwarf.Die {
    const code = try reader.takeLeb128(u64);
    if (code == 0) return null;
    const table = for (dwarf.abbrev_table_list.items) |table| {
        if (table.offset == unit.abbrev_offset) break table;
    } else return error.MissingDebugInfo;
    const abbrev = for (table.abbrevs) |abbrev| {
        if (abbrev.code == code) break abbrev;
    } else return error.InvalidDebugInfo;
    if (abbrev.attrs.len > attrs.len) return error.InvalidDebugInfo;
    for (attrs[0..abbrev.attrs.len], abbrev.attrs) |*result, attr| result.* = .{
        .id = attr.id,
        .value = try readForm(reader, unit, endian, attr.form_id, attr.payload),
    };
    return .{
        .tag_id = abbrev.tag_id,
        .has_children = abbrev.has_children,
        .attrs = attrs[0..abbrev.attrs.len],
    };
}

fn readOffset(reader: *std.Io.Reader, unit: *const Dwarf.CompileUnit, endian: std.builtin.Endian) ScanError!u64 {
    return switch (unit.format) {
        .@"32" => try reader.takeInt(u32, endian),
        .@"64" => try reader.takeInt(u64, endian),
    };
}

fn readAddress(reader: *std.Io.Reader, size: u8, endian: std.builtin.Endian) ScanError!u64 {
    return switch (size) {
        1 => try reader.takeByte(),
        2 => try reader.takeInt(u16, endian),
        4 => try reader.takeInt(u32, endian),
        8 => try reader.takeInt(u64, endian),
        else => error.InvalidDebugInfo,
    };
}

fn readForm(
    r: *std.Io.Reader,
    unit: *const Dwarf.CompileUnit,
    endian: std.builtin.Endian,
    initial_form: u64,
    implicit: i64,
) ScanError!Dwarf.FormValue {
    const F = DW.FORM;
    var form = initial_form;
    // Indirect forms consume bytes, so the remaining section bounds the traversal.
    while (form == F.indirect) form = try r.takeLeb128(u64);
    return switch (form) {
        F.addr => .{ .addr = try readAddress(r, unit.addr_size_bytes, endian) },
        F.addrx => .{ .addrx = try r.takeLeb128(u64) },
        F.addrx1 => .{ .addrx = try r.takeByte() },
        F.addrx2 => .{ .addrx = try r.takeInt(u16, endian) },
        F.addrx3 => .{ .addrx = try r.takeInt(u24, endian) },
        F.addrx4 => .{ .addrx = try r.takeInt(u32, endian) },
        F.block1 => .{ .block = try r.take(try r.takeByte()) },
        F.block2 => .{ .block = try r.take(try r.takeInt(u16, endian)) },
        F.block4 => .{ .block = try r.take(try r.takeInt(u32, endian)) },
        F.block => .{ .block = try r.take(try r.takeLeb128(usize)) },
        F.data1 => .{ .udata = try r.takeByte() },
        F.data2 => .{ .udata = try r.takeInt(u16, endian) },
        F.data4 => .{ .udata = try r.takeInt(u32, endian) },
        F.data8 => .{ .udata = try r.takeInt(u64, endian) },
        F.data16 => .{ .data16 = try r.takeArray(16) },
        F.udata => .{ .udata = try r.takeLeb128(u64) },
        F.sdata => .{ .sdata = try r.takeLeb128(i64) },
        F.exprloc => .{ .exprloc = try r.take(try r.takeLeb128(usize)) },
        F.flag => .{ .flag = (try r.takeByte()) != 0 },
        F.flag_present => .{ .flag = true },
        F.sec_offset => .{ .sec_offset = try readOffset(r, unit, endian) },
        F.ref1 => .{ .ref = try r.takeByte() },
        F.ref2 => .{ .ref = try r.takeInt(u16, endian) },
        F.ref4 => .{ .ref = try r.takeInt(u32, endian) },
        F.ref8, F.ref_sig8 => .{ .ref = try r.takeInt(u64, endian) },
        F.ref_udata => .{ .ref = try r.takeLeb128(u64) },
        F.ref_addr => .{ .ref_addr = if (unit.version == 2)
            try readAddress(r, unit.addr_size_bytes, endian)
        else
            try readOffset(r, unit, endian) },
        F.string => .{ .string = try r.takeSentinel(0) },
        F.strp => .{ .strp = try readOffset(r, unit, endian) },
        F.strx => .{ .strx = try r.takeLeb128(u64) },
        F.strx1 => .{ .strx = try r.takeByte() },
        F.strx2 => .{ .strx = try r.takeInt(u16, endian) },
        F.strx3 => .{ .strx = try r.takeInt(u24, endian) },
        F.strx4 => .{ .strx = try r.takeInt(u32, endian) },
        F.line_strp => .{ .line_strp = try readOffset(r, unit, endian) },
        F.implicit_const => .{ .sdata = implicit },
        F.loclistx => .{ .loclistx = try r.takeLeb128(u64) },
        F.rnglistx => .{ .rnglistx = try r.takeLeb128(u64) },
        else => error.InvalidDebugInfo,
    };
}

fn getAttr(die: Dwarf.Die, id: u64) ?Dwarf.FormValue {
    for (die.attrs) |attr| if (attr.id == id) return attr.value;
    return null;
}

fn attrUInt(die: Dwarf.Die, id: u64) ?u64 {
    const value = getAttr(die, id) orelse return null;
    return switch (value) {
        .udata, .sec_offset => |n| n,
        .sdata => |n| std.math.cast(u64, n),
        else => null,
    };
}

fn resolveAddress(
    dwarf: *Dwarf,
    unit: *const Dwarf.CompileUnit,
    endian: std.builtin.Endian,
    value: Dwarf.FormValue,
) ScanError!u64 {
    return switch (value) {
        .addr => |address| address,
        .addrx => |index| blk: {
            const bytes = dwarf.section(.debug_addr) orelse return error.MissingDebugInfo;
            const offset = try std.math.add(u64, unit.addr_base, try std.math.mul(u64, index, unit.addr_size_bytes));
            if (offset > bytes.len) return error.InvalidDebugInfo;
            var reader: std.Io.Reader = .fixed(bytes);
            reader.seek = @intCast(offset);
            break :blk try readAddress(&reader, unit.addr_size_bytes, endian);
        },
        else => error.InvalidDebugInfo,
    };
}

fn collectRanges(
    gpa: std.mem.Allocator,
    dwarf: *Dwarf,
    unit: *const Dwarf.CompileUnit,
    endian: std.builtin.Endian,
    die: Dwarf.Die,
    output: *std.ArrayList(Symbolizer.Range),
) ScanError!void {
    if (getAttr(die, DW.AT.low_pc)) |low| {
        if (getAttr(die, DW.AT.high_pc)) |high| {
            const start = try resolveAddress(dwarf, unit, endian, low);
            const end = switch (high) {
                .addr, .addrx => try resolveAddress(dwarf, unit, endian, high),
                .udata => |length| try std.math.add(u64, start, length),
                else => return error.InvalidDebugInfo,
            };
            try output.append(gpa, .{ .start = start, .end = end });
        }
    }
    const ranges = getAttr(die, DW.AT.ranges) orelse return;
    const bytes = dwarf.section(if (unit.version >= 5) .debug_rnglists else .debug_ranges) orelse
        return error.MissingDebugInfo;
    const offset = switch (ranges) {
        .sec_offset, .udata => |offset| offset,
        .rnglistx => |index| blk: {
            const size: u64 = if (unit.format == .@"32") 4 else 8;
            const pos = try std.math.add(u64, unit.rnglists_base, try std.math.mul(u64, index, size));
            if (pos > bytes.len) return error.InvalidDebugInfo;
            var offsets: std.Io.Reader = .fixed(bytes);
            offsets.seek = @intCast(pos);
            break :blk try std.math.add(u64, unit.rnglists_base, try readOffset(&offsets, unit, endian));
        },
        else => return error.InvalidDebugInfo,
    };
    if (offset > bytes.len) return error.InvalidDebugInfo;
    var reader: std.Io.Reader = .fixed(bytes);
    reader.seek = @intCast(offset);
    var base: u64 = if (getAttr(unit.die, DW.AT.low_pc)) |low|
        try resolveAddress(dwarf, unit, endian, low)
    else
        0;
    while (reader.seek < bytes.len) {
        var start: u64 = undefined;
        var end: u64 = undefined;
        if (unit.version < 5) {
            start = try readAddress(&reader, unit.addr_size_bytes, endian);
            end = try readAddress(&reader, unit.addr_size_bytes, endian);
            if (start == 0 and end == 0) return;
            const max_address = @as(u64, std.math.maxInt(u64)) >> @intCast(64 - @as(u16, unit.addr_size_bytes) * 8);
            if (start == max_address) {
                base = end;
                continue;
            }
            start = try std.math.add(u64, base, start);
            end = try std.math.add(u64, base, end);
        } else switch (try reader.takeByte()) {
            DW.RLE.end_of_list => return,
            DW.RLE.base_address => {
                base = try readAddress(&reader, unit.addr_size_bytes, endian);
                continue;
            },
            DW.RLE.base_addressx => {
                base = try resolveAddress(dwarf, unit, endian, .{ .addrx = try reader.takeLeb128(u64) });
                continue;
            },
            DW.RLE.start_end => {
                start = try readAddress(&reader, unit.addr_size_bytes, endian);
                end = try readAddress(&reader, unit.addr_size_bytes, endian);
            },
            DW.RLE.start_length => {
                start = try readAddress(&reader, unit.addr_size_bytes, endian);
                end = try std.math.add(u64, start, try reader.takeLeb128(u64));
            },
            DW.RLE.startx_endx => {
                start = try resolveAddress(dwarf, unit, endian, .{ .addrx = try reader.takeLeb128(u64) });
                end = try resolveAddress(dwarf, unit, endian, .{ .addrx = try reader.takeLeb128(u64) });
            },
            DW.RLE.startx_length => {
                start = try resolveAddress(dwarf, unit, endian, .{ .addrx = try reader.takeLeb128(u64) });
                end = try std.math.add(u64, start, try reader.takeLeb128(u64));
            },
            DW.RLE.offset_pair => {
                start = try std.math.add(u64, base, try reader.takeLeb128(u64));
                end = try std.math.add(u64, base, try reader.takeLeb128(u64));
            },
            else => return error.InvalidDebugInfo,
        }
        try output.append(gpa, .{ .start = start, .end = end });
    }
    return error.InvalidDebugInfo;
}

fn sourceFile(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    dwarf: *Dwarf,
    unit: *Dwarf.CompileUnit,
    endian: std.builtin.Endian,
    file: u64,
) !?[]const u8 {
    try dwarf.populateSrcLocCache(gpa, endian, unit);
    const cache = &unit.src_loc_cache.?;
    const index = std.math.sub(u64, file, @intFromBool(cache.version < 5)) catch return null;
    if (index >= cache.files.len) return null;
    const entry = cache.files[@intCast(index)];
    if (entry.dir_index >= cache.directories.len) return null;
    return try std.fs.path.join(a, &.{ cache.directories[entry.dir_index].path, entry.path });
}

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

inline fn inlineCapturedCaller() usize {
    return someFn();
}

noinline fn captureInlineCaller() usize {
    const address = inlineCapturedCaller();
    std.mem.doNotOptimizeAway(address);
    return address;
}

test "inline contexts preserve PC coordinates when name caches disagree" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var symbols = try Symbolizer.init(std.testing.allocator, std.testing.io, "/proc/self/exe", @intFromPtr(&testAnchor));
    defer symbols.deinit();
    const caller = captureCaller();
    const address = caller.address - 1 - symbols.load_bias.?;
    const dwarf = &symbols.elf.?.dwarf.?;
    const other = dwarf.getSymbolName(@intFromPtr(&someFn) - symbols.load_bias.?).?;
    // Alter the standard library's lossy name cache, not executable DIEs or source rows.
    for (dwarf.func_list.items) |*func| {
        if (func.pc_range) |range| if (address >= range.start and address < range.end) {
            func.name = other;
        };
    }
    const inner = symbols.lookup(caller.address - 1).?;
    const contexts = symbols.lookupFrames(caller.address - 1);
    try std.testing.expect(std.mem.endsWith(u8, contexts[0].function, "captureCaller"));
    try std.testing.expect(contexts[0].file != null);
    try std.testing.expectEqualStrings(inner.file.?, contexts[0].file.?);
    try std.testing.expectEqual(caller.line, contexts[0].line);
    try std.testing.expectEqual(inner.column, contexts[0].column);
}

// Corrupt only one real inline DIE's origin reference. A focused subprocess timeout
// can distinguish prompt cycle rejection from section-sized repeated traversal.
test "inline origin cycles reject a real executable DIE" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var symbols = try Symbolizer.init(std.testing.allocator, std.testing.io, "/proc/self/exe", @intFromPtr(&testAnchor));
    defer symbols.deinit();
    const address = captureInlineCaller() - 1 - symbols.load_bias.?;
    const elf = &symbols.elf.?;
    const dwarf = &elf.dwarf.?;
    const unit = try dwarf.findCompileUnit(elf.endian, address);
    const table = for (dwarf.abbrev_table_list.items) |table| {
        if (table.offset == unit.abbrev_offset) break table;
    } else return error.MissingDebugInfo;
    var max_attrs: usize = 0;
    for (table.abbrevs) |abbrev| max_attrs = @max(max_attrs, abbrev.attrs.len);
    const attrs = try std.testing.allocator.alloc(DieAttr, max_attrs);
    defer std.testing.allocator.free(attrs);
    var section = &dwarf.sections[@backingInt(Dwarf.Section.Id.debug_info)].?;
    const bytes = try std.testing.allocator.dupe(u8, section.data);
    section.data = bytes;
    section.owned = true;
    var reader: std.Io.Reader = .fixed(bytes);
    reader.seek = @intCast(unit.offset);
    _ = try Dwarf.readUnitHeader(&reader, elf.endian);
    _ = try reader.takeInt(u16, elf.endian);
    if (unit.version >= 5) {
        _ = try reader.takeByte();
        _ = try reader.takeByte();
        _ = try readOffset(&reader, unit, elf.endian);
    } else {
        _ = try readOffset(&reader, unit, elf.endian);
        _ = try reader.takeByte();
    }
    while (reader.seek < unit.offset + unit.size) {
        const offset = reader.seek;
        const die = try readDie(dwarf, unit, elf.endian, &reader, attrs) orelse continue;
        if (die.tag_id != DW.TAG.inlined_subroutine) continue;
        var ranges: std.ArrayList(Symbolizer.Range) = .empty;
        defer ranges.deinit(std.testing.allocator);
        try collectRanges(std.testing.allocator, dwarf, unit, elf.endian, die, &ranges);
        if (!rangeMatches(ranges.items, address)) continue;
        var fields: std.Io.Reader = .fixed(bytes);
        fields.seek = offset;
        const code = try fields.takeLeb128(u64);
        const abbrev = for (table.abbrevs) |abbrev| {
            if (abbrev.code == code) break abbrev;
        } else return error.InvalidDebugInfo;
        for (abbrev.attrs) |attr| {
            const field_offset = fields.seek;
            _ = try readForm(&fields, unit, elf.endian, attr.form_id, attr.payload);
            if (attr.id != DW.AT.abstract_origin) continue;
            const reference = if (attr.form_id == DW.FORM.ref_addr) offset else offset - unit.offset;
            const target = bytes[field_offset..fields.seek];
            switch (attr.form_id) {
                DW.FORM.ref1 => std.mem.writeInt(u8, target[0..1], @intCast(reference), elf.endian),
                DW.FORM.ref2 => std.mem.writeInt(u16, target[0..2], @intCast(reference), elf.endian),
                DW.FORM.ref4 => std.mem.writeInt(u32, target[0..4], @intCast(reference), elf.endian),
                DW.FORM.ref8 => std.mem.writeInt(u64, target[0..8], reference, elf.endian),
                DW.FORM.ref_addr => switch (target.len) {
                    4 => std.mem.writeInt(u32, target[0..4], @intCast(reference), elf.endian),
                    8 => std.mem.writeInt(u64, target[0..8], reference, elf.endian),
                    else => return error.UnsupportedFixtureReference,
                },
                DW.FORM.ref_udata => {
                    var value = reference;
                    for (target, 0..) |*byte, i| {
                        byte.* = @as(u8, @truncate(value & 0x7f)) |
                            (if (i + 1 < target.len) @as(u8, 0x80) else 0);
                        value >>= 7;
                    }
                    try std.testing.expectEqual(@as(u64, 0), value);
                },
                else => return error.UnsupportedFixtureReference,
            }
            // Exercise the public fallback after corrupting the actual executable metadata.
            const runtime_address = address + symbols.load_bias.?;
            const ordinary = symbols.lookup(runtime_address).?;
            const contexts = symbols.lookupFrames(runtime_address);
            try std.testing.expectEqual(@as(usize, 1), contexts.len);
            try std.testing.expectEqualStrings(ordinary.function, contexts[0].function);
            try std.testing.expectEqualStrings(ordinary.file.?, contexts[0].file.?);
            return;
        }
    }
    return error.InlineFixtureNotResolved;
}

test "symbolizer ignores malformed names on non-function DWARF nodes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var symbols = try Symbolizer.init(
        std.testing.allocator,
        std.testing.io,
        "/proc/self/exe",
        @intFromPtr(&testAnchor),
    );
    defer symbols.deinit();
    const caller = captureCaller();
    const runtime_address = caller.address - 1;
    const ordinary = symbols.lookup(runtime_address).?;
    const elf = &symbols.elf.?;
    const dwarf = &elf.dwarf.?;
    const address = runtime_address - symbols.load_bias.?;
    const unit = try dwarf.findCompileUnit(elf.endian, address);
    const table = for (dwarf.abbrev_table_list.items) |*candidate| {
        if (candidate.offset == unit.abbrev_offset) break candidate;
    } else return error.MissingDebugInfo;
    const root_abbrev = for (table.abbrevs) |*abbrev| {
        if (abbrev.tag_id == DW.TAG.compile_unit) break abbrev;
    } else return error.MissingDebugInfo;

    var reader: std.Io.Reader = .fixed(dwarf.section(.debug_info).?);
    reader.seek = @intCast(unit.offset);
    _ = try Dwarf.readUnitHeader(&reader, elf.endian);
    _ = try reader.takeInt(u16, elf.endian);
    if (unit.version >= 5) {
        _ = try reader.takeByte();
        _ = try reader.takeByte();
        _ = try readOffset(&reader, unit, elf.endian);
    } else {
        _ = try readOffset(&reader, unit, elf.endian);
        _ = try reader.takeByte();
    }
    const root_offset = reader.seek;
    const code = try reader.takeLeb128(u64);
    try std.testing.expectEqual(root_abbrev.code, code);
    var field_reader: std.Io.Reader = .fixed(dwarf.section(.debug_info).?);
    field_reader.seek = root_offset;
    _ = try field_reader.takeLeb128(u64);
    const name_index, const name_offset = for (root_abbrev.attrs, 0..) |attr, index| {
        const start = field_reader.seek;
        _ = try readForm(&field_reader, unit, elf.endian, attr.form_id, attr.payload);
        if (attr.id == DW.AT.name) {
            try std.testing.expectEqual(@as(usize, 4), field_reader.seek - start);
            break .{ index, start };
        }
    } else return error.MissingDebugInfo;

    const info_section_index = @backingInt(Dwarf.Section.Id.debug_info);
    const old_info = dwarf.sections[info_section_index].?;
    const new_info = try std.testing.allocator.dupe(u8, old_info.data);
    dwarf.sections[@backingInt(Dwarf.Section.Id.debug_info)] = .{ .data = new_info, .owned = true };
    defer {
        dwarf.sections[@backingInt(Dwarf.Section.Id.debug_info)] = old_info;
        std.testing.allocator.free(new_info);
    }
    @memcpy(new_info[name_offset..][0..4], &[_]u8{ 2, 2, 0, 0 });

    const offsets_section_index = @backingInt(Dwarf.Section.Id.debug_str_offsets);
    const old_offsets = dwarf.sections[offsets_section_index];
    dwarf.sections[offsets_section_index] = .{ .data = &.{}, .owned = false };
    defer dwarf.sections[offsets_section_index] = old_offsets;
    const old_base = unit.str_offsets_base;
    unit.str_offsets_base = std.math.maxInt(usize) - 7;
    defer unit.str_offsets_base = old_base;

    const old_attrs = root_abbrev.attrs;
    const new_attrs = try std.testing.allocator.alloc(@TypeOf(old_attrs[0]), old_attrs.len + 1);
    @memcpy(new_attrs[0..old_attrs.len], old_attrs);
    new_attrs[name_index].form_id = DW.FORM.strx;
    new_attrs[old_attrs.len] = .{ .id = DW.AT.producer, .form_id = DW.FORM.block1, .payload = 0 };
    root_abbrev.attrs = new_attrs;
    std.testing.allocator.free(old_attrs);

    const contexts = symbols.lookupFrames(runtime_address);
    try std.testing.expect(contexts.len > 0);
    try std.testing.expectEqualStrings(ordinary.function, contexts[0].function);
    try std.testing.expectEqualStrings(ordinary.file.?, contexts[0].file.?);
    try std.testing.expectEqual(ordinary.line, contexts[0].line);
    try std.testing.expectEqual(ordinary.column, contexts[0].column);
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
    try std.testing.expectEqualStrings(location.function, again.function);
    try std.testing.expectEqualStrings(location.file.?, again.file.?);
    try std.testing.expectEqual(null, symbols.lookup(0));
    try std.testing.expectEqual(null, symbols.lookup(std.math.maxInt(u64)));
    for (1..128) |offset| _ = symbols.lookup(@intFromPtr(&someFn) + offset);
    const retained = symbols.lookup(@intFromPtr(&someFn)).?;
    try std.testing.expectEqualStrings(location.function, retained.function);
    try std.testing.expectEqualStrings(location.file.?, retained.file.?);
    try std.testing.expectEqual(location.line, retained.line);
    try std.testing.expectEqual(location.column, retained.column);
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
