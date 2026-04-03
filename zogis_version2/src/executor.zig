const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ParsedInput = @import("parser.zig").ParsedInput;
const PipelineNode = @import("parser.zig").PipelineNode;
const Pipeline = @import("parser.zig").Pipeline;
const Command = @import("parser.zig").Command;
const Connector = @import("parser.zig").Connector;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const DebugAllocator = @import("allocator.zig").DebugAllocator;
const SlabAllocator = @import("allocator.zig").SlabAllocator;

pub const ExecContext = struct {
    allocator: Allocator,
    debug_alloc: *DebugAllocator,
    slab: *SlabAllocator,
    history: *std.ArrayList([]const u8),
    env: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    prev_dir: ?[]u8,
    last_exit: u8,
    cwd_buf: [std.fs.max_path_bytes]u8,
    should_exit: bool,

    pub fn init(
        allocator: Allocator,
        debug_alloc: *DebugAllocator,
        slab: *SlabAllocator,
        history: *std.ArrayList([]const u8),
    ) ExecContext {
        return .{
            .allocator = allocator,
            .debug_alloc = debug_alloc,
            .slab = slab,
            .history = history,
            .env = std.StringHashMap([]const u8).init(allocator),
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .prev_dir = null,
            .last_exit = 0,
            .cwd_buf = undefined,
            .should_exit = false,
        };
    }

    pub fn deinit(self: *ExecContext) void {
        var it = self.env.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.env.deinit();
        var ait = self.aliases.iterator();
        while (ait.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.aliases.deinit();
        if (self.prev_dir) |d| self.allocator.free(d);
    }
};

pub fn execute(ctx: *ExecContext, input: ParsedInput) ExecError!void {
    for (input.nodes, 0..) |node, i| {
        try executePipeline(ctx, node.pipeline);
        if (ctx.should_exit) return;
        if (i + 1 < input.nodes.len) {
            switch (node.connector) {
                .and_and => if (ctx.last_exit != 0) return,
                .or_or => if (ctx.last_exit == 0) return,
                .semicolon => {},
            }
        }
    }
}

const ExecError = anyerror;

fn executePipeline(ctx: *ExecContext, pipeline: Pipeline) ExecError!void {
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

fn tempBatPath(allocator: Allocator) ![]u8 {
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
    return std.fmt.allocPrint(allocator, "{s}{c}zogis_cmd_{d}.bat", .{
        tmp_dir, std.fs.path.sep, S.counter,
    });
}

fn runCmdSub(ctx: *ExecContext, inner_cmd: []const u8) ExecError![]u8 {
    const tmp_out = try tempFilePath(ctx.allocator, "zogis_sub");
    defer {
        std.fs.cwd().deleteFile(tmp_out) catch {};
        ctx.allocator.free(tmp_out);
    }

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = Lexer.initWithEnv(inner_cmd, a, &ctx.env);
    const toks = lexer.tokenize() catch return ctx.allocator.dupe(u8, "");
    var parser = Parser.init(toks, a);
    const parsed = parser.parse() catch return ctx.allocator.dupe(u8, "");

    for (parsed.nodes) |node| {
        for (node.pipeline.commands) |cmd| {
            try executeCommand(ctx, cmd, null, tmp_out);
        }
    }

    const f = std.fs.cwd().openFile(tmp_out, .{}) catch
        return try ctx.allocator.dupe(u8, "");
    defer f.close();
    var buf = std.ArrayList(u8).init(ctx.allocator);
    try f.reader().readAllArrayList(&buf, 1024 * 1024);
    while (buf.items.len > 0 and
        (buf.items[buf.items.len - 1] == '\n' or
        buf.items[buf.items.len - 1] == '\r'))
        _ = buf.pop();
    return try buf.toOwnedSlice();
}

fn expandGlob(allocator: Allocator, pattern: []const u8) ![][]const u8 {
    if (std.mem.indexOfAny(u8, pattern, "*?") == null) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = pattern;
        return result;
    }
    var matches = std.ArrayList([]const u8).init(allocator);
    const sep = std.fs.path.sep;
    const last_sep = std.mem.lastIndexOfScalar(u8, pattern, sep);
    const dir_path = if (last_sep) |i| pattern[0..i] else ".";
    const file_pat = if (last_sep) |i| pattern[i + 1 ..] else pattern;

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = pattern;
        return result;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (matchGlob(file_pat, entry.name)) {
            const full = if (last_sep != null)
                try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir_path, sep, entry.name })
            else
                try allocator.dupe(u8, entry.name);
            try matches.append(full);
        }
    }
    if (matches.items.len == 0) {
        matches.deinit();
        const result = try allocator.alloc([]const u8, 1);
        result[0] = pattern;
        return result;
    }
    std.mem.sort([]const u8, matches.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return matches.toOwnedSlice();
}

fn matchGlob(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: usize = std.math.maxInt(usize);
    var star_ni: usize = 0;
    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (star_pi != std.math.maxInt(usize)) {
            star_ni += 1;
            ni = star_ni;
            pi = star_pi + 1;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

const ExpandedArgs = struct {
    argv: [][]const u8,
    is_quoted: []bool,
};

fn expandArgv(ctx: *ExecContext, cmd: Command) !ExpandedArgs {
    var result = std.ArrayList([]const u8).init(ctx.allocator);
    var quoted = std.ArrayList(bool).init(ctx.allocator);

    for (cmd.argv, 0..) |arg, i| {
        const is_sub = i < cmd.is_cmd_sub.len and cmd.is_cmd_sub[i];
        const is_q = i < cmd.is_quoted.len and cmd.is_quoted[i];

        if (is_sub) {
            const output = try runCmdSub(ctx, arg);
            defer ctx.allocator.free(output);
            var it = std.mem.tokenizeAny(u8, output, " \t\n\r");
            while (it.next()) |word| {
                const owned = try ctx.allocator.dupe(u8, word);
                if (std.mem.indexOfAny(u8, owned, "*?") != null) {
                    const matches = try expandGlob(ctx.allocator, owned);
                    ctx.allocator.free(owned);
                    defer ctx.allocator.free(matches);
                    for (matches) |m| {
                        try result.append(m);
                        try quoted.append(false);
                    }
                } else {
                    try result.append(owned);
                    try quoted.append(false);
                }
            }
            continue;
        }

        if (std.mem.indexOf(u8, arg, "\x00$") != null) {
            const resolved = try resolveInlineCmdSub(ctx, arg);
            try result.append(resolved);
            try quoted.append(false);
            continue;
        }

        if (std.mem.indexOfAny(u8, arg, "*?") != null) {
            const matches = try expandGlob(ctx.allocator, arg);
            defer ctx.allocator.free(matches);
            for (matches) |m| {
                if (m.ptr == arg.ptr) {
                    try result.append(arg);
                } else {
                    try result.append(m);
                }
                try quoted.append(false);
            }
        } else {
            try result.append(arg);
            try quoted.append(is_q);
        }
    }

    return .{ .argv = try result.toOwnedSlice(), .is_quoted = try quoted.toOwnedSlice() };
}

fn resolveInlineCmdSub(ctx: *ExecContext, arg: []const u8) ExecError![]u8 {
    var buf = std.ArrayList(u8).init(ctx.allocator);
    var i: usize = 0;
    while (i < arg.len) {
        if (i + 1 < arg.len and arg[i] == '\x00' and arg[i + 1] == '$') {
            i += 2;
            const inner_start = i;
            while (i < arg.len and !(arg[i] == '\x00' and i + 1 < arg.len and arg[i + 1] == '$'))
                i += 1;
            const inner = arg[inner_start..i];
            const output = try runCmdSub(ctx, inner);
            defer ctx.allocator.free(output);
            const trimmed = std.mem.trim(u8, output, "\n\r");
            try buf.appendSlice(trimmed);
        } else {
            try buf.append(arg[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice();
}

fn executeCommand(
    ctx: *ExecContext,
    cmd: Command,
    stdin_override: ?[]const u8,
    stdout_override: ?[]const u8,
) ExecError!void {
    const stdout_w = std.io.getStdOut().writer();
    const name0 = cmd.argv[0];
    if (ctx.aliases.get(name0)) |expansion| {
        var full_cmd = std.ArrayList(u8).init(ctx.allocator);
        defer full_cmd.deinit();
        try full_cmd.appendSlice(expansion);
        for (cmd.argv[1..]) |a| {
            try full_cmd.append(' ');
            try full_cmd.appendSlice(a);
        }
        var lexer = Lexer.initWithEnv(full_cmd.items, ctx.allocator, &ctx.env);
        const toks = lexer.tokenize() catch return;
        var parser = Parser.init(toks, ctx.allocator);
        const parsed = parser.parse() catch return;
        for (parsed.nodes) |node| {
            try executePipeline(ctx, node.pipeline);
        }
        return;
    }

    const expanded = try expandArgv(ctx, cmd);
    const argv = expanded.argv;
    defer ctx.allocator.free(argv);
    defer ctx.allocator.free(expanded.is_quoted);
    if (argv.len == 0) return;
    const name = argv[0];
    const builtin_out_path = stdout_override orelse cmd.redirect_out;
    var builtin_out_file: ?std.fs.File = null;
    defer if (builtin_out_file) |f| f.close();

    var is_builtin_cmd = false;
    for ([_][]const u8{
        "exit",      "quit",  "help",  "clear",   "echo",    "pwd",     "cd",
        "export",    "unset", "alias", "unalias", "history", "meminfo", "slabinfo",
        "benchmark",
    }) |b| {
        if (std.mem.eql(u8, name, b)) {
            is_builtin_cmd = true;
            break;
        }
    }

    if (is_builtin_cmd and builtin_out_path != null) {
        const path = builtin_out_path.?;
        const appending = if (stdout_override != null) false else cmd.redirect_append;
        const flags: std.fs.File.CreateFlags = .{ .truncate = !appending };
        builtin_out_file = std.fs.cwd().createFile(path, flags) catch |err| {
            try stdout_w.print("redirect: cannot create '{s}': {}\n", .{ path, err });
            return;
        };
        if (appending) {
            const end = builtin_out_file.?.getEndPos() catch 0;
            builtin_out_file.?.seekTo(end) catch {};
        }
    }
    const out_w = if (builtin_out_file) |f| f.writer() else stdout_w;

    if (std.mem.eql(u8, name, "exit") or std.mem.eql(u8, name, "quit")) {
        ctx.should_exit = true;
        try out_w.print("Goodbye!\n", .{});
        return;
    }
    if (std.mem.eql(u8, name, "help")) {
        try printHelp(out_w);
        return;
    }
    if (std.mem.eql(u8, name, "clear")) {
        try out_w.print("\x1b[2J\x1b[H", .{});
        return;
    }

    if (std.mem.eql(u8, name, "echo")) {
        for (argv[1..], 0..) |arg, i| {
            if (i > 0) try out_w.writeByte(' ');
            try out_w.writeAll(arg);
        }
        try out_w.writeByte('\n');
        ctx.last_exit = 0;
        return;
    }

    if (std.mem.eql(u8, name, "pwd")) {
        const cwd = try std.fs.cwd().realpath(".", &ctx.cwd_buf);
        try out_w.print("{s}\n", .{cwd});
        ctx.last_exit = 0;
        return;
    }

    if (std.mem.eql(u8, name, "cd")) {
        try builtinCd(ctx, argv, out_w);
        return;
    }

    if (std.mem.eql(u8, name, "export")) {
        for (argv[1..]) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                const k = try ctx.allocator.dupe(u8, arg[0..eq]);
                const v = try ctx.allocator.dupe(u8, arg[eq + 1 ..]);
                if (ctx.env.fetchRemove(k)) |old| {
                    ctx.allocator.free(old.key);
                    ctx.allocator.free(old.value);
                }
                try ctx.env.put(k, v);
            } else {
                const v = std.process.getEnvVarOwned(ctx.allocator, arg) catch continue;
                const k = try ctx.allocator.dupe(u8, arg);
                if (ctx.env.fetchRemove(k)) |old| {
                    ctx.allocator.free(old.key);
                    ctx.allocator.free(old.value);
                }
                try ctx.env.put(k, v);
            }
        }
        ctx.last_exit = 0;
        return;
    }

    if (std.mem.eql(u8, name, "unset")) {
        for (argv[1..]) |arg| {
            if (ctx.env.fetchRemove(arg)) |old| {
                ctx.allocator.free(old.key);
                ctx.allocator.free(old.value);
            }
        }
        ctx.last_exit = 0;
        return;
    }

    if (std.mem.eql(u8, name, "alias")) {
        if (cmd.argv.len == 1) {
            var it = ctx.aliases.iterator();
            while (it.next()) |e|
                try out_w.print("alias {s}='{s}'\n", .{ e.key_ptr.*, e.value_ptr.* });
            return;
        }
        var joined = std.ArrayList(u8).init(ctx.allocator);
        defer joined.deinit();
        for (cmd.argv[1..], 0..) |raw_arg, i| {
            if (i > 0) try joined.append(' ');
            try joined.appendSlice(raw_arg);
        }
        const full = joined.items;
        if (std.mem.indexOfScalar(u8, full, '=')) |eq| {
            const k = try ctx.allocator.dupe(u8, full[0..eq]);
            const v_raw = full[eq + 1 ..];
            const v = try ctx.allocator.dupe(u8, std.mem.trimLeft(u8, v_raw, " \t"));
            if (ctx.aliases.fetchRemove(k)) |old| {
                ctx.allocator.free(old.key);
                ctx.allocator.free(old.value);
            }
            try ctx.aliases.put(k, v);
        } else {
            if (ctx.aliases.get(full)) |val|
                try out_w.print("alias {s}='{s}'\n", .{ full, val });
        }
        ctx.last_exit = 0;
        return;
    }

    if (std.mem.eql(u8, name, "unalias")) {
        for (argv[1..]) |arg| {
            if (ctx.aliases.fetchRemove(arg)) |old| {
                ctx.allocator.free(old.key);
                ctx.allocator.free(old.value);
            }
        }
        return;
    }

    if (std.mem.eql(u8, name, "history")) {
        for (ctx.history.items, 1..) |entry, idx|
            try out_w.print("  {d:3}  {s}\n", .{ idx, entry });
        return;
    }
    if (std.mem.eql(u8, name, "meminfo")) {
        try ctx.debug_alloc.report(out_w);
        return;
    }
    if (std.mem.eql(u8, name, "slabinfo")) {
        try ctx.slab.report(out_w);
        return;
    }
    if (std.mem.eql(u8, name, "benchmark")) {
        const sz = if (argv.len > 1) std.fmt.parseInt(usize, argv[1], 10) catch 32 else 32;
        const iters = if (argv.len > 2) std.fmt.parseInt(usize, argv[2], 10) catch 100_000 else 100_000;
        try ctx.debug_alloc.benchmark(out_w, sz, iters);
        return;
    }

    if (builtin_out_file) |f| {
        f.close();
        builtin_out_file = null;
    }

    var final_argv: []const []const u8 = argv;
    var wrapped: ?[][]const u8 = null;
    defer if (wrapped) |w| ctx.allocator.free(w);
    var bat_cleanup: ?[]u8 = null;
    defer if (bat_cleanup) |p| {
        std.fs.deleteFileAbsolute(p) catch {};
        std.heap.page_allocator.free(p);
    };

    if (comptime builtin.os.tag == .windows) {
        const win_builtins = [_][]const u8{
            "dir",    "type", "copy",    "del", "move", "ren", "rename",
            "mkdir",  "md",   "rmdir",   "rd",  "cls",  "set", "where",
            "attrib", "find", "findstr",
        };
        for (win_builtins) |wb| {
            if (std.ascii.eqlIgnoreCase(name, wb)) {
                const bat_path = try tempBatPath(std.heap.page_allocator);
                bat_cleanup = bat_path;
                {
                    const bf = std.fs.createFileAbsolute(bat_path, .{ .truncate = true }) catch |err| {
                        try stdout_w.print("internal: cannot create temp bat: {}\n", .{err});
                        return;
                    };
                    defer bf.close();
                    const fw = bf.writer();
                    try fw.writeAll("@");
                    for (argv, 0..) |a, idx| {
                        if (idx > 0) try fw.writeByte(' ');
                        const q = idx < expanded.is_quoted.len and expanded.is_quoted[idx];
                        if (q) try fw.writeByte('"');
                        try fw.writeAll(a);
                        if (q) try fw.writeByte('"');
                    }
                    try fw.writeAll("\r\n");
                }

                const w = try ctx.allocator.alloc([]const u8, 3);
                w[0] = "cmd.exe";
                w[1] = "/c";
                w[2] = bat_path;
                wrapped = w;
                final_argv = w;
                break;
            }
        }
    }

    var child = std.process.Child.init(final_argv, ctx.allocator);

    const effective_stdin = stdin_override orelse cmd.redirect_in;
    const effective_stdout_path = stdout_override orelse cmd.redirect_out;

    var stdin_file: ?std.fs.File = null;
    if (effective_stdin) |path| {
        stdin_file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try stdout_w.print("redirect: cannot open '{s}' for reading: {}\n", .{ path, err });
            return;
        };
        child.stdin_behavior = .Pipe;
    }
    defer if (stdin_file) |f| f.close();

    var out_file: ?std.fs.File = null;
    if (effective_stdout_path) |path| {
        const flags: std.fs.File.CreateFlags = .{ .truncate = !cmd.redirect_append };
        out_file = std.fs.cwd().createFile(path, flags) catch |err| {
            try stdout_w.print("redirect: cannot open '{s}' for writing: {}\n", .{ path, err });
            return;
        };
        if (cmd.redirect_append) {
            if (out_file) |f| {
                const end = f.getEndPos() catch 0;
                f.seekTo(end) catch {};
            }
        }
        child.stdout_behavior = .Pipe;
    }
    defer if (out_file) |f| f.close();

    child.spawn() catch |err| {
        try stdout_w.print("{s}: command not found ({s})\n", .{ name, @errorName(err) });
        ctx.last_exit = 127;
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

    if (out_file) |sf| {
        if (child.stdout) |pipe_stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = pipe_stdout.read(&buf) catch break;
                if (n == 0) break;
                sf.writeAll(buf[0..n]) catch break;
            }
        }
    }

    const term = try child.wait();
    ctx.last_exit = switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn builtinCd(ctx: *ExecContext, argv: [][]const u8, writer: anytype) ExecError!void {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;

    const target: []const u8 = if (argv.len > 1) blk: {
        const arg = argv[1];
        if (std.mem.eql(u8, arg, "-")) {
            if (ctx.prev_dir) |prev| {
                try writer.print("{s}\n", .{prev});
                break :blk prev;
            } else {
                try writer.print("cd: no previous directory\n", .{});
                return;
            }
        }
        break :blk arg;
    } else blk: {
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

    var prev_buf: [std.fs.max_path_bytes]u8 = undefined;
    const current = std.fs.cwd().realpath(".", &prev_buf) catch null;

    var dir = std.fs.cwd().openDir(target, .{}) catch |err| {
        try writer.print("cd: {s}: {}\n", .{ target, err });
        return;
    };
    defer dir.close();
    dir.setAsCwd() catch |err| {
        try writer.print("cd: {s}: {}\n", .{ target, err });
        return;
    };

    if (current) |c| {
        if (ctx.prev_dir) |old| ctx.allocator.free(old);
        ctx.prev_dir = try ctx.allocator.dupe(u8, c);
    }
    ctx.last_exit = 0;
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\
        \\Zogis Shell - Built-in commands:
        \\  help                Show this help
        \\  exit / quit         Exit the shell
        \\  clear               Clear the screen
        \\  echo [args]         Print arguments
        \\  pwd                 Print working directory
        \\  cd [dir|-]          Change directory (- = previous, no arg = home)
        \\  history             Show command history
        \\  export NAME=VAL     Set environment variable
        \\  export NAME         Import from process environment
        \\  unset NAME          Remove environment variable
        \\  alias NAME=CMD      Create command alias
        \\  alias               List all aliases
        \\  unalias NAME        Remove alias
        \\
        \\Memory commands:
        \\  meminfo             DebugAllocator: leak report + stats
        \\  slabinfo            SlabAllocator: size-class utilization
        \\  benchmark [sz] [n]  Measure alloc+free throughput
        \\
        \\Operators:
        \\  cmd1 | cmd2         Pipe stdout of cmd1 to stdin of cmd2
        \\  cmd1 && cmd2        Run cmd2 only if cmd1 succeeded (exit 0)
        \\  cmd1 || cmd2        Run cmd2 only if cmd1 failed (exit != 0)
        \\  cmd > file          Redirect stdout to file (overwrite)
        \\  cmd >> file         Redirect stdout to file (append)
        \\  cmd < file          Read stdin from file
        \\  cmd1 ; cmd2         Run cmd1 then cmd2 unconditionally
        \\
        \\Expansions:
        \\  $VAR / ${{VAR}}     Environment variable expansion
        \\  ~                   Home directory
        \\  *.ext / ?           Glob patterns
        \\  $(cmd)              Command substitution
        \\
    , .{});
}
