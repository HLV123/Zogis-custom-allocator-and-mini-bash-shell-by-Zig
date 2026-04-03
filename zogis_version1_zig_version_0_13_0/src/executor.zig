const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ParsedInput = @import("parser.zig").ParsedInput;
const Pipeline = @import("parser.zig").Pipeline;
const Command = @import("parser.zig").Command;
const DebugAllocator = @import("allocator.zig").DebugAllocator;

pub const ExecContext = struct {
    allocator: Allocator,
    debug_alloc: *DebugAllocator,
    history: *std.ArrayList([]const u8),
    cwd_buf: [std.fs.max_path_bytes]u8,
    should_exit: bool,

    pub fn init(
        allocator: Allocator,
        debug_alloc: *DebugAllocator,
        history: *std.ArrayList([]const u8),
    ) ExecContext {
        return .{
            .allocator = allocator,
            .debug_alloc = debug_alloc,
            .history = history,
            .cwd_buf = undefined,
            .should_exit = false,
        };
    }
};

pub fn execute(ctx: *ExecContext, input: ParsedInput) !void {
    for (input.pipelines) |pipeline| {
        try executePipeline(ctx, pipeline);
        if (ctx.should_exit) break;
    }
}

fn executePipeline(ctx: *ExecContext, pipeline: Pipeline) !void {
    const cmds = pipeline.commands;
    if (cmds.len == 1) {
        try executeCommand(ctx, cmds[0], null, null);
        return;
    }

    var prev_output = std.ArrayList(u8).init(ctx.allocator);
    defer prev_output.deinit();

    for (cmds, 0..) |cmd, i| {
        const is_last = (i == cmds.len - 1);
        if (is_last) {
            const tmp_in = try writeTempFile(ctx.allocator, prev_output.items);
            defer {
                std.fs.cwd().deleteFile(tmp_in) catch {};
                ctx.allocator.free(tmp_in);
            }
            try executeCommand(ctx, cmd, tmp_in, null);
        } else {
            const tmp_in = try writeTempFile(ctx.allocator, prev_output.items);
            defer {
                std.fs.cwd().deleteFile(tmp_in) catch {};
                ctx.allocator.free(tmp_in);
            }
            const tmp_out = try tempFilePath(ctx.allocator, "zogis_out");
            defer {
                std.fs.cwd().deleteFile(tmp_out) catch {};
                ctx.allocator.free(tmp_out);
            }
            try executeCommand(ctx, cmd, tmp_in, tmp_out);

            prev_output.clearRetainingCapacity();
            const f = std.fs.cwd().openFile(tmp_out, .{}) catch continue;
            defer f.close();
            try f.reader().readAllArrayList(&prev_output, 10 * 1024 * 1024);
        }
    }
}

fn writeTempFile(allocator: Allocator, data: []const u8) ![]u8 {
    const path = try tempFilePath(allocator, "zogis_in");
    errdefer allocator.free(path);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
    return path;
}

fn tempFilePath(allocator: Allocator, prefix: []const u8) ![]u8 {
    const tmp_dir = if (comptime builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "TEMP") catch
            std.process.getEnvVarOwned(allocator, "TMP") catch
            try allocator.dupe(u8, ".")
    else
        try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_dir);

    const S = struct {
        var counter: u32 = 0;
    };
    S.counter +%= 1;

    return std.fmt.allocPrint(allocator, "{s}{c}{s}_{d}.tmp", .{
        tmp_dir, std.fs.path.sep, prefix, S.counter,
    });
}

fn executeCommand(
    ctx: *ExecContext,
    cmd: Command,
    stdin_override: ?[]const u8,
    stdout_override: ?[]const u8,
) !void {
    const name = cmd.argv[0];
    const stdout = std.io.getStdOut().writer();

    if (std.mem.eql(u8, name, "exit") or std.mem.eql(u8, name, "quit")) {
        ctx.should_exit = true;
        try stdout.print("Goodbye!\n", .{});
        return;
    }
    if (std.mem.eql(u8, name, "help")) {
        try printHelp(stdout);
        return;
    }
    if (std.mem.eql(u8, name, "clear")) {
        try stdout.print("\x1b[2J\x1b[H", .{});
        return;
    }
    if (std.mem.eql(u8, name, "echo")) {
        for (cmd.argv[1..], 0..) |arg, i| {
            if (i > 0) try stdout.print(" ", .{});
            try stdout.print("{s}", .{arg});
        }
        try stdout.print("\n", .{});
        return;
    }
    if (std.mem.eql(u8, name, "pwd")) {
        const cwd = try std.fs.cwd().realpath(".", &ctx.cwd_buf);
        try stdout.print("{s}\n", .{cwd});
        return;
    }
    if (std.mem.eql(u8, name, "cd")) {
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target: []const u8 = if (cmd.argv.len > 1) cmd.argv[1] else blk: {
            const home = std.process.getEnvVarOwned(
                ctx.allocator,
                if (comptime builtin.os.tag == .windows) "USERPROFILE" else "HOME",
            ) catch null;
            if (home) |h| {
                const len = @min(h.len, home_buf.len);
                @memcpy(home_buf[0..len], h[0..len]);
                ctx.allocator.free(h);
                break :blk home_buf[0..len];
            }
            break :blk ".";
        };
        var dir = std.fs.cwd().openDir(target, .{}) catch |err| {
            try stdout.print("cd: {s}: {}\n", .{ target, err });
            return;
        };
        defer dir.close();
        dir.setAsCwd() catch |err| {
            try stdout.print("cd: {s}: {}\n", .{ target, err });
        };
        return;
    }
    if (std.mem.eql(u8, name, "meminfo")) {
        try ctx.debug_alloc.report(stdout);
        return;
    }
    if (std.mem.eql(u8, name, "history")) {
        for (ctx.history.items, 1..) |entry, idx| {
            try stdout.print("  {d:3}  {s}\n", .{ idx, entry });
        }
        return;
    }

    var child = std.process.Child.init(cmd.argv, ctx.allocator);

    const effective_stdin: ?[]const u8 = stdin_override orelse cmd.redirect_in;
    const effective_stdout_path: ?[]const u8 = stdout_override orelse cmd.redirect_out;

    var stdin_file: ?std.fs.File = null;
    if (effective_stdin) |path| {
        stdin_file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try stdout.print("redirect: cannot open '{s}' for reading: {}\n", .{ path, err });
            return;
        };
        child.stdin_behavior = .Pipe;
    }
    defer if (stdin_file) |f| f.close();

    var stdout_file: ?std.fs.File = null;
    if (effective_stdout_path) |path| {
        const flags: std.fs.File.CreateFlags = .{ .truncate = !cmd.redirect_append };
        stdout_file = std.fs.cwd().createFile(path, flags) catch |err| {
            try stdout.print("redirect: cannot open '{s}' for writing: {}\n", .{ path, err });
            return;
        };
        child.stdout_behavior = .Pipe;
    }
    defer if (stdout_file) |f| f.close();

    child.spawn() catch |err| {
        try stdout.print("{s}: command not found ({s})\n", .{ name, @errorName(err) });
        return;
    };

    if (stdin_file) |sf| {
        if (child.stdin) |pipe_stdin| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = sf.read(&buf) catch break;
                if (n == 0) break;
                pipe_stdin.writeAll(buf[0..n]) catch break;
            }
            pipe_stdin.close();
            child.stdin = null;
        }
    }

    if (stdout_file) |sf| {
        if (child.stdout) |pipe_stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = pipe_stdout.read(&buf) catch break;
                if (n == 0) break;
                sf.writeAll(buf[0..n]) catch break;
            }
        }
    }

    _ = try child.wait();
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\
        \\Zogis Shell - Built-in commands:
        \\  help          Show this help
        \\  exit / quit   Exit the shell
        \\  clear         Clear the screen
        \\  echo [args]   Print arguments
        \\  pwd           Print working directory
        \\  cd [dir]      Change directory (no arg = home)
        \\  meminfo       Show memory allocator stats
        \\  history       Show command history
        \\
        \\Operators:
        \\  cmd1 | cmd2   Pipe output of cmd1 to cmd2
        \\  cmd > file    Redirect output to file (overwrite)
        \\  cmd >> file   Redirect output to file (append)
        \\  cmd < file    Read input from file
        \\  cmd1 ; cmd2   Run cmd1 then cmd2
        \\
    , .{});
}
