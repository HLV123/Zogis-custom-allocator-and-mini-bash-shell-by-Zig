const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("lexer.zig").Token;
const TokenKind = @import("lexer.zig").TokenKind;

pub const Command = struct {
    argv: [][]const u8,
    redirect_in: ?[]const u8,
    redirect_out: ?[]const u8,
    redirect_append: bool,
    background: bool,
};

pub const Pipeline = struct {
    commands: []Command,
    background: bool,
};

pub const ParsedInput = struct {
    pipelines: []Pipeline,
};

pub const ParseError = error{
    UnexpectedToken,
    EmptyCommand,
    OutOfMemory,
    MissingRedirectTarget,
};

pub const Parser = struct {
    tokens: []const Token,
    pos: usize,
    allocator: Allocator,

    pub fn init(tokens: []const Token, allocator: Allocator) Parser {
        return .{ .tokens = tokens, .pos = 0, .allocator = allocator };
    }

    pub fn parse(self: *Parser) ParseError!ParsedInput {
        var pipelines = std.ArrayList(Pipeline).init(self.allocator);

        while (self.peek().kind != .eof) {
            const pipeline = try self.parsePipeline();
            try pipelines.append(pipeline);

            if (self.peek().kind == .semicolon) {
                self.advance();
            } else {
                break;
            }
        }

        return .{ .pipelines = try pipelines.toOwnedSlice() };
    }

    fn parsePipeline(self: *Parser) ParseError!Pipeline {
        var commands = std.ArrayList(Command).init(self.allocator);
        var bg = false;

        const first = try self.parseCommand();
        try commands.append(first);

        while (self.peek().kind == .pipe) {
            self.advance();
            const cmd = try self.parseCommand();
            try commands.append(cmd);
        }

        if (self.peek().kind == .background) {
            bg = true;
            self.advance();
        }

        return .{
            .commands = try commands.toOwnedSlice(),
            .background = bg,
        };
    }

    fn parseCommand(self: *Parser) ParseError!Command {
        var argv = std.ArrayList([]const u8).init(self.allocator);
        var redirect_in: ?[]const u8 = null;
        var redirect_out: ?[]const u8 = null;
        var redirect_append: bool = false;
        var background: bool = false;

        loop: while (true) {
            const tok = self.peek();
            switch (tok.kind) {
                .word, .string => {
                    try argv.append(tok.value);
                    self.advance();
                },
                .redirect_in => {
                    self.advance();
                    const target = self.peek();
                    if (target.kind != .word and target.kind != .string)
                        return ParseError.MissingRedirectTarget;
                    redirect_in = target.value;
                    self.advance();
                },
                .redirect_out => {
                    self.advance();
                    const target = self.peek();
                    if (target.kind != .word and target.kind != .string)
                        return ParseError.MissingRedirectTarget;
                    redirect_out = target.value;
                    redirect_append = false;
                    self.advance();
                },
                .redirect_append => {
                    self.advance();
                    const target = self.peek();
                    if (target.kind != .word and target.kind != .string)
                        return ParseError.MissingRedirectTarget;
                    redirect_out = target.value;
                    redirect_append = true;
                    self.advance();
                },
                .background => {
                    background = true;
                    self.advance();
                    break :loop;
                },
                else => break :loop,
            }
        }

        if (argv.items.len == 0) return ParseError.EmptyCommand;

        return .{
            .argv = try argv.toOwnedSlice(),
            .redirect_in = redirect_in,
            .redirect_out = redirect_out,
            .redirect_append = redirect_append,
            .background = background,
        };
    }

    fn peek(self: *Parser) Token {
        if (self.pos >= self.tokens.len) return .{ .kind = .eof, .value = "" };
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) self.pos += 1;
    }
};

const Lexer = @import("lexer.zig").Lexer;

fn parseInput(input: []const u8, allocator: Allocator) !ParsedInput {
    var lexer = Lexer.init(input, allocator);
    const tokens = try lexer.tokenize();
    var parser = Parser.init(tokens, allocator);
    return parser.parse();
}

test "Parser: single command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parseInput("echo hello", a);
    try std.testing.expect(result.pipelines.len == 1);
    const cmd = result.pipelines[0].commands[0];
    try std.testing.expectEqualStrings("echo", cmd.argv[0]);
    try std.testing.expectEqualStrings("hello", cmd.argv[1]);
}

test "Parser: pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parseInput("ls | grep foo", a);
    try std.testing.expect(result.pipelines[0].commands.len == 2);
    try std.testing.expectEqualStrings("ls", result.pipelines[0].commands[0].argv[0]);
    try std.testing.expectEqualStrings("grep", result.pipelines[0].commands[1].argv[0]);
}

test "Parser: redirect out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parseInput("echo hi > out.txt", a);
    const cmd = result.pipelines[0].commands[0];
    try std.testing.expectEqualStrings("out.txt", cmd.redirect_out.?);
    try std.testing.expect(!cmd.redirect_append);
}

test "Parser: semicolon separates pipelines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parseInput("echo a ; echo b", a);
    try std.testing.expect(result.pipelines.len == 2);
}

test "Parser: empty command errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = parseInput("echo |", a);
    try std.testing.expectError(ParseError.EmptyCommand, result);
}
