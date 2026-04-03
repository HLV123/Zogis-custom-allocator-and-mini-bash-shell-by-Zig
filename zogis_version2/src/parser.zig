const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("lexer.zig").Token;
const TokenKind = @import("lexer.zig").TokenKind;

pub const Command = struct {
    argv: [][]const u8,
    is_cmd_sub: []bool,
    is_quoted: []bool,
    redirect_in: ?[]const u8,
    redirect_out: ?[]const u8,
    redirect_append: bool,
    background: bool,
};

pub const Pipeline = struct {
    commands: []Command,
    background: bool,
};

pub const Connector = enum {
    semicolon,
    and_and,
    or_or,
};

pub const PipelineNode = struct {
    pipeline: Pipeline,
    connector: Connector,
};

pub const ParsedInput = struct {
    nodes: []PipelineNode,
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
        var nodes = std.ArrayList(PipelineNode).init(self.allocator);

        while (self.peek().kind != .eof) {
            const pipeline = try self.parsePipeline();
            const connector: Connector = switch (self.peek().kind) {
                .semicolon => blk: {
                    self.advance();
                    break :blk .semicolon;
                },
                .and_and => blk: {
                    self.advance();
                    break :blk .and_and;
                },
                .or_or => blk: {
                    self.advance();
                    break :blk .or_or;
                },
                else => .semicolon,
            };
            try nodes.append(.{ .pipeline = pipeline, .connector = connector });
            if (connector == .semicolon and self.peek().kind == .eof) break;
            if (self.peek().kind == .eof) break;
        }

        return .{ .nodes = try nodes.toOwnedSlice() };
    }

    fn parsePipeline(self: *Parser) ParseError!Pipeline {
        var commands = std.ArrayList(Command).init(self.allocator);
        var bg = false;

        try commands.append(try self.parseCommand());
        while (self.peek().kind == .pipe) {
            self.advance();
            try commands.append(try self.parseCommand());
        }
        if (self.peek().kind == .background) {
            bg = true;
            self.advance();
        }

        return .{ .commands = try commands.toOwnedSlice(), .background = bg };
    }

    fn parseCommand(self: *Parser) ParseError!Command {
        var argv = std.ArrayList([]const u8).init(self.allocator);
        var cmd_subs = std.ArrayList(bool).init(self.allocator);
        var quoted = std.ArrayList(bool).init(self.allocator);
        var redirect_in: ?[]const u8 = null;
        var redirect_out: ?[]const u8 = null;
        var redirect_append: bool = false;
        var background: bool = false;

        loop: while (true) {
            const tok = self.peek();
            switch (tok.kind) {
                .word, .string => {
                    try argv.append(tok.value);
                    try cmd_subs.append(false);
                    try quoted.append(tok.kind == .string);
                    self.advance();
                },
                .cmd_sub => {
                    try argv.append(tok.value);
                    try cmd_subs.append(true);
                    try quoted.append(false);
                    self.advance();
                },
                .redirect_in => {
                    self.advance();
                    const t = self.peek();
                    if (t.kind != .word and t.kind != .string) return ParseError.MissingRedirectTarget;
                    redirect_in = t.value;
                    self.advance();
                },
                .redirect_out => {
                    self.advance();
                    const t = self.peek();
                    if (t.kind != .word and t.kind != .string) return ParseError.MissingRedirectTarget;
                    redirect_out = t.value;
                    redirect_append = false;
                    self.advance();
                },
                .redirect_append => {
                    self.advance();
                    const t = self.peek();
                    if (t.kind != .word and t.kind != .string) return ParseError.MissingRedirectTarget;
                    redirect_out = t.value;
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
            .is_cmd_sub = try cmd_subs.toOwnedSlice(),
            .is_quoted = try quoted.toOwnedSlice(),
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
    const toks = try lexer.tokenize();
    var parser = Parser.init(toks, allocator);
    return parser.parse();
}

test "Parser: single command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseInput("echo hello", a);
    try std.testing.expectEqualStrings("echo", r.nodes[0].pipeline.commands[0].argv[0]);
    try std.testing.expectEqualStrings("hello", r.nodes[0].pipeline.commands[0].argv[1]);
}

test "Parser: pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseInput("ls | grep foo", a);
    try std.testing.expect(r.nodes[0].pipeline.commands.len == 2);
}

test "Parser: && connector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseInput("echo a && echo b", a);
    try std.testing.expect(r.nodes.len == 2);
    try std.testing.expectEqual(Connector.and_and, r.nodes[0].connector);
}

test "Parser: || connector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseInput("false || echo fallback", a);
    try std.testing.expectEqual(Connector.or_or, r.nodes[0].connector);
}

test "Parser: semicolon separates pipelines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseInput("echo a ; echo b", a);
    try std.testing.expect(r.nodes.len == 2);
}

test "Parser: redirect out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseInput("echo hi > out.txt", a);
    const cmd = r.nodes[0].pipeline.commands[0];
    try std.testing.expectEqualStrings("out.txt", cmd.redirect_out.?);
    try std.testing.expect(!cmd.redirect_append);
}

test "Parser: empty command errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(ParseError.EmptyCommand, parseInput("echo |", a));
}
