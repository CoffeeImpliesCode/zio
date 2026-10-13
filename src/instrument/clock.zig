const builtin = @import("builtin");
const format = @import("format.zig");

pub const kind: format.ClockKind = switch (builtin.cpu.arch) {
    .x86_64 => .tsc,
    .aarch64 => .cntvct,
    else => .monotonic_ns,
};

pub inline fn ticks() u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            var high: u32 = undefined;
            var low: u32 = undefined;
            asm volatile ("rdtsc"
                : [low] "={eax}" (low),
                  [high] "={edx}" (high),
            );
            break :blk (@as(u64, high) << 32) | low;
        },
        .aarch64 => asm volatile ("mrs %[value], cntvct_el0"
            : [value] "=r" (-> u64),
        ),
        else => monotonic(),
    };
}

pub fn monotonic() u64 {
    return @intCast(@import("../os/time.zig").now(.awake).value);
}

pub fn realtime() i64 {
    return @intCast(@import("../os/time.zig").now(.real).value);
}
