const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BumpAllocator = struct {
    buffer: []u8,
    offset: usize,

    pub fn init(buffer: []u8) BumpAllocator {
        return .{ .buffer = buffer, .offset = 0 };
    }

    pub fn allocator(self: *BumpAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, _: usize) ?[*]u8 {
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
        const alignment = @as(usize, 1) << @as(u6, @intCast(log2_align));
        const start = std.mem.alignForward(usize, self.offset, alignment);
        if (start + n > self.buffer.len) return null;
        const ptr = self.buffer[start .. start + n].ptr;
        self.offset = start + n;
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
        const first = try backing.alloc(u8, size);
        var chunks = std.ArrayList([]u8).init(backing);
        try chunks.append(first);
        return .{ .backing = backing, .chunks = chunks, .current = first, .offset = 0, .chunk_size = size };
    }

    pub fn deinit(self: *ArenaAllocator) void {
        for (self.chunks.items) |c| self.backing.free(c);
        self.chunks.deinit();
    }

    pub fn allocator(self: *ArenaAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        const alignment = @as(usize, 1) << @as(u6, @intCast(log2_align));
        const start = std.mem.alignForward(usize, self.offset, alignment);
        if (start + n <= self.current.len) {
            const ptr = self.current[start .. start + n].ptr;
            self.offset = start + n;
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
            const c = self.chunks.pop();
            self.backing.free(c);
        }
        self.current = self.chunks.items[0];
        self.offset = 0;
    }

    pub fn bytesUsed(self: *const ArenaAllocator) usize {
        var total: usize = 0;
        for (self.chunks.items) |c| total += c.len;
        return total;
    }
};

pub const PoolAllocator = struct {
    buffer: []u8,
    slot_size: usize,
    free_head: ?[*]u8,
    capacity: usize,
    in_use: usize,

    pub fn init(buffer: []u8, slot_size: usize) PoolAllocator {
        const real_slot = @max(slot_size, @sizeOf(usize));
        const n_slots = buffer.len / real_slot;

        var head: ?[*]u8 = null;
        var i = n_slots;
        while (i > 0) {
            i -= 1;
            const slot_ptr = buffer[i * real_slot ..].ptr;
            const next_ptr: *?[*]u8 = @ptrCast(@alignCast(slot_ptr));
            next_ptr.* = head;
            head = slot_ptr;
        }

        return .{
            .buffer = buffer,
            .slot_size = real_slot,
            .free_head = head,
            .capacity = n_slots,
            .in_use = 0,
        };
    }

    pub fn allocator(self: *PoolAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, n: usize, _: u8, _: usize) ?[*]u8 {
        const self: *PoolAllocator = @ptrCast(@alignCast(ctx));
        if (n > self.slot_size) return null;
        const head = self.free_head orelse return null;
        const next_ptr: *?[*]u8 = @ptrCast(@alignCast(head));
        self.free_head = next_ptr.*;
        self.in_use += 1;
        return head;
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, _: u8, _: usize) void {
        const self: *PoolAllocator = @ptrCast(@alignCast(ctx));
        const next_ptr: *?[*]u8 = @ptrCast(@alignCast(buf.ptr));
        next_ptr.* = self.free_head;
        self.free_head = buf.ptr;
        self.in_use -= 1;
    }

    pub fn available(self: *const PoolAllocator) usize {
        return self.capacity - self.in_use;
    }
    pub fn utilization(self: *const PoolAllocator) f64 {
        if (self.capacity == 0) return 0.0;
        return @as(f64, @floatFromInt(self.in_use)) / @as(f64, @floatFromInt(self.capacity));
    }
};

pub const SlabAllocator = struct {
    const NUM_CLASSES = 6;
    const SIZE_CLASSES = [NUM_CLASSES]usize{ 8, 16, 32, 64, 128, 256 };
    const SLOTS_PER_CLASS = 128;

    pools: [NUM_CLASSES]PoolAllocator,
    buffers: [NUM_CLASSES][]u8,
    backing: Allocator,

    pub fn init(backing: Allocator) !SlabAllocator {
        var self: SlabAllocator = undefined;
        self.backing = backing;
        for (SIZE_CLASSES, 0..) |sz, i| {
            const buf = try backing.alloc(u8, sz * SLOTS_PER_CLASS);
            self.buffers[i] = buf;
            self.pools[i] = PoolAllocator.init(buf, sz);
        }
        return self;
    }

    pub fn deinit(self: *SlabAllocator) void {
        for (self.buffers) |buf| self.backing.free(buf);
    }

    pub fn allocator(self: *SlabAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        } };
    }

    fn classFor(n: usize) ?usize {
        for (SIZE_CLASSES, 0..) |sz, i| {
            if (n <= sz) return i;
        }
        return null;
    }

    fn owningClass(self: *SlabAllocator, ptr: [*]u8) ?usize {
        const addr = @intFromPtr(ptr);
        for (self.buffers, 0..) |buf, i| {
            const start = @intFromPtr(buf.ptr);
            if (addr >= start and addr < start + buf.len) return i;
        }
        return null;
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
        if (classFor(n)) |i| {
            const pool_ptr: *anyopaque = &self.pools[i];
            return PoolAllocator.alloc(pool_ptr, n, log2_align, ret_addr);
        }
        return self.backing.rawAlloc(n, log2_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
        if (self.owningClass(buf.ptr) != null) return false;
        return self.backing.rawResize(buf, log2_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
        const self: *SlabAllocator = @ptrCast(@alignCast(ctx));
        if (self.owningClass(buf.ptr)) |i| {
            const pool_ptr: *anyopaque = &self.pools[i];
            PoolAllocator.free(pool_ptr, buf, log2_align, ret_addr);
            return;
        }
        self.backing.rawFree(buf, log2_align, ret_addr);
    }

    pub fn report(self: *const SlabAllocator, writer: anytype) !void {
        try writer.print("\n=== Slab Allocator Report ===\n", .{});
        try writer.print("  {s:<12} {s:>8} {s:>8} {s:>8} {s:>10}\n", .{ "Class", "SlotSize", "InUse", "Free", "Utilization" });
        try writer.print("  ------------ -------- -------- -------- ----------\n", .{});
        for (SIZE_CLASSES, 0..) |sz, i| {
            const pool = &self.pools[i];
            const pct = pool.utilization() * 100.0;
            try writer.print("  {d:<12} {d:>8} {d:>8} {d:>8} {d:>9.1}%\n", .{
                sz, pool.slot_size, pool.in_use, pool.available(), pct,
            });
        }
        try writer.print("=============================\n\n", .{});
    }
};

pub const DebugAllocator = struct {
    backing: Allocator,
    stats: Stats,
    live_allocs: std.AutoHashMap(usize, AllocRecord),

    const GUARD_SIZE: usize = 8;
    const GUARD_BYTE: u8 = 0xAB;

    pub const Stats = struct {
        total_allocated: usize = 0,
        total_freed: usize = 0,
        active_bytes: usize = 0,
        peak_bytes: usize = 0,
        alloc_count: usize = 0,
        free_count: usize = 0,
        overflow_detected: usize = 0,
    };

    pub const AllocRecord = struct {
        size: usize,
        ret_addr: usize,
    };

    pub fn init(backing: Allocator) DebugAllocator {
        return .{
            .backing = backing,
            .stats = .{},
            .live_allocs = std.AutoHashMap(usize, AllocRecord).init(backing),
        };
    }

    pub fn deinit(self: *DebugAllocator) void {
        self.live_allocs.deinit();
    }

    pub fn allocator(self: *DebugAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        } };
    }

    fn totalSize(n: usize) usize {
        return GUARD_SIZE + n + GUARD_SIZE;
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const raw = self.backing.rawAlloc(totalSize(n), log2_align, ret_addr) orelse return null;
        @memset(raw[0..GUARD_SIZE], GUARD_BYTE);
        @memset(raw[GUARD_SIZE + n .. GUARD_SIZE + n + GUARD_SIZE], GUARD_BYTE);
        const user_ptr = raw + GUARD_SIZE;
        self.live_allocs.put(@intFromPtr(user_ptr), .{
            .size = n,
            .ret_addr = ret_addr,
        }) catch {};

        self.stats.total_allocated += n;
        self.stats.active_bytes += n;
        self.stats.alloc_count += 1;
        if (self.stats.active_bytes > self.stats.peak_bytes)
            self.stats.peak_bytes = self.stats.active_bytes;

        return user_ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const raw_ptr = buf.ptr - GUARD_SIZE;
        const raw_len = totalSize(buf.len);
        const raw_slice = raw_ptr[0..raw_len];
        if (!self.backing.rawResize(raw_slice, log2_align, totalSize(new_len), ret_addr))
            return false;
        @memset(raw_ptr[GUARD_SIZE + new_len .. GUARD_SIZE + new_len + GUARD_SIZE], GUARD_BYTE);
        if (new_len > buf.len) {
            const delta = new_len - buf.len;
            self.stats.total_allocated += delta;
            self.stats.active_bytes += delta;
        } else {
            const delta = buf.len - new_len;
            self.stats.total_freed += delta;
            self.stats.active_bytes -= delta;
        }
        if (self.live_allocs.getPtr(@intFromPtr(buf.ptr))) |rec| rec.size = new_len;
        return true;
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const raw_ptr = buf.ptr - GUARD_SIZE;
        const raw_len = totalSize(buf.len);
        const head = raw_ptr[0..GUARD_SIZE];
        for (head) |b| {
            if (b != GUARD_BYTE) {
                self.stats.overflow_detected += 1;
                break;
            }
        }
        const tail = raw_ptr[GUARD_SIZE + buf.len .. GUARD_SIZE + buf.len + GUARD_SIZE];
        for (tail) |b| {
            if (b != GUARD_BYTE) {
                self.stats.overflow_detected += 1;
                break;
            }
        }

        self.backing.rawFree(raw_ptr[0..raw_len], log2_align, ret_addr);
        _ = self.live_allocs.remove(@intFromPtr(buf.ptr));

        self.stats.total_freed += buf.len;
        self.stats.active_bytes -= buf.len;
        self.stats.free_count += 1;
    }

    pub fn hasLeaks(self: *const DebugAllocator) bool {
        return self.live_allocs.count() > 0;
    }

    pub fn report(self: *const DebugAllocator, writer: anytype) !void {
        try writer.print(
            \\
            \\=== Zogis Memory Report ===
            \\  Total allocated  : {d} bytes
            \\  Total freed      : {d} bytes
            \\  Active (live)    : {d} bytes
            \\  Peak usage       : {d} bytes
            \\  Alloc calls      : {d}
            \\  Free calls       : {d}
            \\  Overflows found  : {d}
            \\  Live allocations : {d}
            \\
        , .{
            self.stats.total_allocated,
            self.stats.total_freed,
            self.stats.active_bytes,
            self.stats.peak_bytes,
            self.stats.alloc_count,
            self.stats.free_count,
            self.stats.overflow_detected,
            self.live_allocs.count(),
        });

        if (self.live_allocs.count() > 0) {
            try writer.print("  [LEAK REPORT]\n", .{});
            var it = self.live_allocs.iterator();
            var idx: usize = 1;
            while (it.next()) |entry| {
                try writer.print("  #{d}: {d} bytes  (alloc site: 0x{x})\n", .{
                    idx,
                    entry.value_ptr.size,
                    entry.value_ptr.ret_addr,
                });
                idx += 1;
            }
        } else {
            try writer.print("  [OK] No leaks detected.\n", .{});
        }
        try writer.print("===========================\n\n", .{});
    }

    pub fn benchmark(
        self: *DebugAllocator,
        writer: anytype,
        alloc_size: usize,
        iterations: usize,
    ) !void {
        const a = self.allocator();
        const t0 = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const buf = a.alloc(u8, alloc_size) catch continue;
            a.free(buf);
        }
        const t1 = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(t1 - t0);
        const elapsed_ms = elapsed_ns / 1_000_000;
        const ops_per_sec = if (elapsed_ns > 0)
            @as(u64, iterations) * 1_000_000_000 / elapsed_ns
        else
            0;

        try writer.print(
            \\
            \\=== Benchmark: alloc+free {d} bytes x {d} ===
            \\  Elapsed : {d} ms
            \\  Ops/sec : {d}
            \\==============================================
            \\
        , .{ alloc_size, iterations, elapsed_ms, ops_per_sec });
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
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 64));
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
    while (i < 10) : (i += 1) _ = try a.alloc(u8, 32);
    try std.testing.expect(arena.chunks.items.len > 1);
}

test "PoolAllocator: alloc and free" {
    var buf: [1024]u8 = undefined;
    var pool = PoolAllocator.init(&buf, 32);
    const a = pool.allocator();
    const p1 = try a.alloc(u8, 32);
    const p2 = try a.alloc(u8, 16);
    try std.testing.expect(p1.len == 32);
    try std.testing.expect(p2.len == 16);
    try std.testing.expect(pool.in_use == 2);
    a.free(p1);
    try std.testing.expect(pool.in_use == 1);
    const p3 = try a.alloc(u8, 32);
    try std.testing.expect(p3.ptr == p1.ptr);
}

test "PoolAllocator: exhaustion" {
    var buf: [64]u8 = undefined;
    var pool = PoolAllocator.init(&buf, 32);
    const a = pool.allocator();
    _ = try a.alloc(u8, 32);
    _ = try a.alloc(u8, 32);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 32));
}

test "SlabAllocator: routes to correct size class" {
    var slab = try SlabAllocator.init(std.testing.allocator);
    defer slab.deinit();
    const a = slab.allocator();
    const s8 = try a.alloc(u8, 8);
    const s16 = try a.alloc(u8, 16);
    const s32 = try a.alloc(u8, 32);
    try std.testing.expect(s8.len == 8);
    try std.testing.expect(s16.len == 16);
    try std.testing.expect(s32.len == 32);
    a.free(s8);
    a.free(s16);
    a.free(s32);
}

test "SlabAllocator: large fallback to backing" {
    var slab = try SlabAllocator.init(std.testing.allocator);
    defer slab.deinit();
    const a = slab.allocator();
    const big = try a.alloc(u8, 512);
    try std.testing.expect(big.len == 512);
    a.free(big);
}

test "DebugAllocator: tracks allocations" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const a = debug.allocator();
    const s = try a.alloc(u8, 128);
    try std.testing.expect(debug.stats.total_allocated == 128);
    try std.testing.expect(debug.stats.active_bytes == 128);
    try std.testing.expect(debug.hasLeaks());
    a.free(s);
    try std.testing.expect(debug.stats.total_freed == 128);
    try std.testing.expect(!debug.hasLeaks());
}

test "DebugAllocator: leak detection" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const a = debug.allocator();
    _ = try a.alloc(u8, 64);
    try std.testing.expect(debug.hasLeaks());
    try std.testing.expect(debug.live_allocs.count() == 1);
    var it = debug.live_allocs.iterator();
    while (it.next()) |entry| {
        const ptr: [*]u8 = @ptrFromInt(entry.key_ptr.*);
        a.free(ptr[0..entry.value_ptr.size]);
    }
}

test "DebugAllocator: guard byte overflow detection" {
    var debug = DebugAllocator.init(std.testing.allocator);
    defer debug.deinit();
    const a = debug.allocator();
    const s = try a.alloc(u8, 16);
    const raw: [*]u8 = s.ptr - DebugAllocator.GUARD_SIZE;
    raw[DebugAllocator.GUARD_SIZE + 16] = 0xFF;
    a.free(s);
    try std.testing.expect(debug.stats.overflow_detected > 0);
}
