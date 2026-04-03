const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenKind = enum {
    word,
    pipe,
    redirect_out,
    redirect_append,
    redirect_in,
    background,
    semicolon,
    string,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
};

pub const LexError = error{
    UnterminatedString,
    OutOfMemory,
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(input: []const u8, allocator: Allocator) Lexer {
        return .{ .input = input, .pos = 0, .allocator = allocator };
    }

    pub fn tokenize(self: *Lexer) LexError![]Token {
        var tokens = std.ArrayList(Token).init(self.allocator);
        errdefer tokens.deinit();

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) {
                try tokens.append(.{ .kind = .eof, .value = "" });
                break;
            }

            const ch = self.input[self.pos];

            switch (ch) {
                '|' => {
                    try tokens.append(.{ .kind = .pipe, .value = "|" });
                    self.pos += 1;
                },
                '&' => {
                    try tokens.append(.{ .kind = .background, .value = "&" });
                    self.pos += 1;
                },
                ';' => {
                    try tokens.append(.{ .kind = .semicolon, .value = ";" });
                    self.pos += 1;
                },
                '<' => {
                    try tokens.append(.{ .kind = .redirect_in, .value = "<" });
                    self.pos += 1;
                },
                '>' => {
                    if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
                        try tokens.append(.{ .kind = .redirect_append, .value = ">>" });
                        self.pos += 2;
                    } else {
                        try tokens.append(.{ .kind = .redirect_out, .value = ">" });
                        self.pos += 1;
                    }
                },
                '"', '\'' => {
                    const tok = try self.readString(ch);
                    try tokens.append(tok);
                },
                else => {
                    const tok = self.readWord();
                    try tokens.append(tok);
                },
            }
        }

        return tokens.toOwnedSlice();
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len and
            (self.input[self.pos] == ' ' or self.input[self.pos] == '\t'))
        {
            self.pos += 1;
        }
    }

    fn readWord(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '|' or ch == '&' or
                ch == ';' or ch == '<' or ch == '>' or ch == '"' or ch == '\'')
            {
                break;
            }
            self.pos += 1;
        }
        return .{ .kind = .word, .value = self.input[start..self.pos] };
    }

    fn readString(self: *Lexer, quote: u8) LexError!Token {
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return LexError.UnterminatedString;

        const content = self.input[start..self.pos];
        self.pos += 1; // skip closing quote
        return .{ .kind = .string, .value = content };
    }
};

test "Lexer: simple command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = Lexer.init("echo hello world", a);
    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(TokenKind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("echo", tokens[0].value);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
    try std.testing.expectEqualStrings("world", tokens[2].value);
    try std.testing.expectEqual(TokenKind.eof, tokens[3].kind);
}

test "Lexer: pipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = Lexer.init("ls | grep foo", a);
    const tokens = try lexer.tokenize();

    try std.testing.expectEqualStrings("ls", tokens[0].value);
    try std.testing.expectEqual(TokenKind.pipe, tokens[1].kind);
    try std.testing.expectEqualStrings("grep", tokens[2].value);
}

test "Lexer: quoted string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = Lexer.init("echo \"hello world\"", a);
    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(TokenKind.string, tokens[1].kind);
    try std.testing.expectEqualStrings("hello world", tokens[1].value);
}

test "Lexer: redirect append" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = Lexer.init("echo hi >> out.txt", a);
    const tokens = try lexer.tokenize();

    try std.testing.expectEqual(TokenKind.redirect_append, tokens[2].kind);
}

test "Lexer: unterminated string error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = Lexer.init("echo \"oops", a);
    const result = lexer.tokenize();
    try std.testing.expectError(LexError.UnterminatedString, result);
}
