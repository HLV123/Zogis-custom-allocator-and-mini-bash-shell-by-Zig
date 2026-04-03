const std = @import("std");
const ArenaAllocator = @import("allocator.zig").ArenaAllocator;
const DebugAllocator = @import("allocator.zig").DebugAllocator;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const executor = @import("executor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    var debug_alloc = DebugAllocator.init(backing);
    const tracked = debug_alloc.allocator();

    var history = std.ArrayList([]const u8).init(tracked);
    defer {
        for (history.items) |entry| tracked.free(entry);
        history.deinit();
    }

    var ctx = executor.ExecContext.init(tracked, &debug_alloc, &history);

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    try stdout.print(
        \\
        \\  ______   ____    _____   _____   _____
        \\ |___  /  / __ \  / ____| |_   _| / ____|
        \\    / /  | |  | || |  __    | |  | (___
        \\   / /   | |  | || | |_ |   | |   \___ \
        \\  / /__  | |__| || |__| |  _| |_  ____) |
        \\ /_____|  \____/  \_____| |_____| |_____|
        \\
        \\  ==========================================
        \\    Zogis Shell  -  type 'help' for commands
        \\  ==========================================
        \\
    , .{});

    var line_buf: [4096]u8 = undefined;

    while (!ctx.should_exit) {
        const cwd = std.fs.cwd().realpath(".", &ctx.cwd_buf) catch ".";
        try stdout.print("\x1b[32mzogis\x1b[0m:\x1b[34m{s}\x1b[0m$ ", .{cwd});
        const line_raw = stdin.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| {
            try stdout.print("read error: {}\n", .{err});
            continue;
        } orelse break;

        const line = std.mem.trimRight(u8, line_raw, "\r\n ");
        if (line.len == 0) continue;

        const history_entry = try tracked.dupe(u8, line);
        try history.append(history_entry);

        var arena = ArenaAllocator.init(tracked, 4096) catch |err| {
            try stdout.print("arena init failed: {}\n", .{err});
            continue;
        };
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var lexer = Lexer.init(line, arena_alloc);
        const tokens = lexer.tokenize() catch |err| {
            try stdout.print("lex error: {}\n", .{err});
            continue;
        };

        var parser = Parser.init(tokens, arena_alloc);
        const parsed = parser.parse() catch |err| {
            try stdout.print("parse error: {}\n", .{err});
            continue;
        };

        executor.execute(&ctx, parsed) catch |err| {
            try stdout.print("exec error: {}\n", .{err});
        };
    }

    try stdout.print("\n", .{});
    try debug_alloc.report(stdout);

    if (debug_alloc.hasLeaks()) {
        try stdout.print("[warn] memory leaks detected above\n", .{});
    }
}

test {
    _ = @import("allocator.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
}
