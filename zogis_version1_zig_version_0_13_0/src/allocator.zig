const std = @import("std");
const Allocator = std.mem.Allocator;
pub const BumpAllocator = struct {
    buffer: []u8,
    offset: usize,

    pub fn init(buffer: []u8) BumpAllocator {
        return .{ .buffer = buffer, .offset = 0 };
    }

    pub fn allocator(self: *BumpAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, _: usize) ?[*]u8 {
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
        const alignment = @as(usize, 1) << @as(u6, @intCast(log2_align));
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);

        if (aligned_offset + n > self.buffer.len) return null;

        const ptr = self.buffer[aligned_offset .. aligned_offset + n].ptr;
        self.offset = aligned_offset + n;
        return ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}

    pub fn reset(self: *BumpAllocator) void {
        self.offset = 0;
    }

    pub fn used(self: *const BumpAllocator) usize {
        return self.offset;
    }

    pub fn remaining(self: *const BumpAllocator) usize {
        return self.buffer.len - self.offset;
    }
};

pub const ArenaAllocator = struct {
    backing: Allocator,
    chunks: std.ArrayList([]u8),
    current: []u8,
    offset: usize,
    chunk_size: usize,

    const DEFAULT_CHUNK_SIZE = 4096;

    pub fn init(backing: Allocator, chunk_size: usize) !ArenaAllocator {
        const size = if (chunk_size == 0) DEFAULT_CHUNK_SIZE else chunk_size;
        const first_chunk = try backing.alloc(u8, size);
        var chunks = std.ArrayList([]u8).init(backing);
        try chunks.append(first_chunk);
        return .{
            .backing = backing,
            .chunks = chunks,
            .current = first_chunk,
            .offset = 0,
            .chunk_size = size,
        };
    }

    pub fn deinit(self: *ArenaAllocator) void {
        for (self.chunks.items) |chunk| {
            self.backing.free(chunk);
        }
        self.chunks.deinit();
    }

    pub fn allocator(self: *ArenaAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        const alignment = @as(usize, 1) << @as(u6, @intCast(log2_align));
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);

        if (aligned_offset + n <= self.current.len) {
            const ptr = self.current[aligned_offset .. aligned_offset + n].ptr;
            self.offset = aligned_offset + n;
            return ptr;
        }

        const new_size = @max(self.chunk_size, n + alignment);
        const new_chunk = self.backing.alloc(u8, new_size) catch return null;
        self.chunks.append(new_chunk) catch {
            self.backing.free(new_chunk);
            return null;
        };
        self.current = new_chunk;
        self.offset = 0;

        return alloc(ctx, n, log2_align, ret_addr);
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}

    pub fn reset(self: *ArenaAllocator) void {
        while (self.chunks.items.len > 1) {
            const chunk = self.chunks.pop();
            self.backing.free(chunk);
        }
        self.current = self.chunks.items[0];
        self.offset = 0;
    }
};

pub const DebugAllocator = struct {
    backing: Allocator,
    stats: Stats,

    pub const Stats = struct {
        total_allocated: usize = 0,
        total_freed: usize = 0,
        active_allocations: usize = 0,
        peak_allocated: usize = 0,
        alloc_count: usize = 0,
        free_count: usize = 0,
    };

    pub fn init(backing: Allocator) DebugAllocator {
        return .{ .backing = backing, .stats = .{} };
    }

    pub fn allocator(self: *DebugAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(n, log2_align, ret_addr) orelse return null;

        self.stats.total_allocated += n;
        self.stats.active_allocations += n;
        self.stats.alloc_count += 1;
        if (self.stats.active_allocations > self.stats.peak_allocated) {
            self.stats.peak_allocated = self.stats.active_allocations;
        }
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(buf, log2_align, new_len, ret_addr)) return false;

        if (new_len > buf.len) {
            const delta = new_len - buf.len;
            self.stats.total_allocated += delta;
            self.stats.active_allocations += delta;
        } else {
            const delta = buf.len - new_len;
            self.stats.total_freed += delta;
            self.stats.active_allocations -= delta;
        }
        return true;
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, log2_align, ret_addr);
        self.stats.total_freed += buf.len;
        self.stats.active_allocations -= buf.len;
        self.stats.free_count += 1;
    }

    pub fn report(self: *const DebugAllocator, writer: anytype) !void {
        try writer.print(
            \\
            \\=== Zogis Memory Report ===
            \\  Total allocated : {} bytes
            \\  Total freed     : {} bytes
            \\  Active (live)   : {} bytes
            \\  Peak usage      : {} bytes
            \\  Alloc calls     : {}
            \\  Free calls      : {}
            \\===========================
            \\
        , .{
            self.stats.total_allocated,
            self.stats.total_freed,
            self.stats.active_allocations,
            self.stats.peak_allocated,
            self.stats.alloc_count,
            self.stats.free_count,
        });
    }

    pub fn hasLeaks(self: *const DebugAllocator) bool {
        return self.stats.active_allocations > 0;
    }
};

test "BumpAllocator: basic alloc and reset" {
    var buf: [1024]u8 = undefined;
    var bump = BumpAllocator.init(&buf);
    const a = bump.allocator();

    const s1 = try a.alloc(u8, 100);
    const s2 = try a.alloc(u8, 200);
    try std.testing.expect(s1.len == 100);
    try std.testing.expect(s2.len == 200);
    try std.testing.expect(bump.used() >= 300);

    bump.reset();
    try std.testing.expect(bump.used() == 0);
}

test "BumpAllocator: out of memory" {
    var buf: [64]u8 = undefined;
    var bump = BumpAllocator.init(&buf);
    const a = bump.allocator();

    _ = try a.alloc(u8, 32);
    const result = a.alloc(u8, 64);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "ArenaAllocator: alloc and deinit" {
    var arena = try ArenaAllocator.init(std.testing.allocator, 256);
    defer arena.deinit();
    const a = arena.allocator();

    const s1 = try a.alloc(u8, 100);
    const s2 = try a.alloc(u8, 100);
    try std.testing.expect(s1.len == 100);
    try std.testing.expect(s2.len == 100);
}

test "ArenaAllocator: spans multiple chunks" {
    var arena = try ArenaAllocator.init(std.testing.allocator, 64);
    defer arena.deinit();
    const a = arena.allocator();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try a.alloc(u8, 32);
    }
    try std.testing.expect(arena.chunks.items.len > 1);
}

test "DebugAllocator: tracks allocations" {
    var debug = DebugAllocator.init(std.testing.allocator);
    const a = debug.allocator();

    const s = try a.alloc(u8, 128);
    try std.testing.expect(debug.stats.total_allocated == 128);
    try std.testing.expect(debug.stats.active_allocations == 128);
    try std.testing.expect(debug.hasLeaks());

    a.free(s);
    try std.testing.expect(debug.stats.total_freed == 128);
    try std.testing.expect(!debug.hasLeaks());
}
