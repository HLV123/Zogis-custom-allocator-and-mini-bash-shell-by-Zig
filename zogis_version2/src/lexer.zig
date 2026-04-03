const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const TokenKind = enum {
    word,
    pipe,
    and_and,
    or_or,
    redirect_out,
    redirect_append,
    redirect_in,
    background,
    semicolon,
    string,
    cmd_sub,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
};

pub const LexError = error{
    UnterminatedString,
    UnterminatedCmdSub,
    OutOfMemory,
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    allocator: Allocator,
    env: ?*std.StringHashMap([]const u8),

    pub fn init(input: []const u8, allocator: Allocator) Lexer {
        return .{ .input = input, .pos = 0, .allocator = allocator, .env = null };
    }

    pub fn initWithEnv(input: []const u8, allocator: Allocator, env: *std.StringHashMap([]const u8)) Lexer {
        return .{ .input = input, .pos = 0, .allocator = allocator, .env = env };
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
                    if (self.peek1() == '|') {
                        try tokens.append(.{ .kind = .or_or, .value = "||" });
                        self.pos += 2;
                    } else {
                        try tokens.append(.{ .kind = .pipe, .value = "|" });
                        self.pos += 1;
                    }
                },
                '&' => {
                    if (self.peek1() == '&') {
                        try tokens.append(.{ .kind = .and_and, .value = "&&" });
                        self.pos += 2;
                    } else {
                        try tokens.append(.{ .kind = .background, .value = "&" });
                        self.pos += 1;
                    }
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
                    if (self.peek1() == '>') {
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
                '$' => {
                    if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '(') {
                        const tok = try self.readCmdSub();
                        try tokens.append(tok);
                    } else {
                        const tok = try self.readWord();
                        try tokens.append(tok);
                    }
                },
                else => {
                    const tok = try self.readWord();
                    try tokens.append(tok);
                },
            }
        }
        return tokens.toOwnedSlice();
    }

    fn peek1(self: *Lexer) u8 {
        if (self.pos + 1 < self.input.len) return self.input[self.pos + 1];
        return 0;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len and
            (self.input[self.pos] == ' ' or self.input[self.pos] == '\t'))
            self.pos += 1;
    }

    fn readWord(self: *Lexer) LexError!Token {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        const start = self.pos;
        var expanded = false;

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '|' or ch == '&' or
                ch == ';' or ch == '<' or ch == '>' or ch == '"' or ch == '\'')
                break;

            if (ch == '~' and self.pos == start and buf.items.len == 0) {
                expanded = true;
                self.pos += 1;
                const home = getHome(self.allocator) catch ".";
                defer self.allocator.free(home);
                try buf.appendSlice(home);
                continue;
            }

            if (ch == '$') {
                expanded = true;
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '(') {
                    self.pos += 1;
                    const inner_start = self.pos;
                    var depth: usize = 1;
                    while (self.pos < self.input.len) {
                        if (self.input[self.pos] == '(') depth += 1;
                        if (self.input[self.pos] == ')') {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                        self.pos += 1;
                    }
                    const inner = self.input[inner_start..self.pos];
                    if (self.pos < self.input.len) self.pos += 1;
                    try buf.appendSlice("\x00$");
                    try buf.appendSlice(inner);
                } else if (self.pos < self.input.len and self.input[self.pos] == '{') {
                    self.pos += 1;
                    const var_start = self.pos;
                    while (self.pos < self.input.len and self.input[self.pos] != '}')
                        self.pos += 1;
                    const var_name = self.input[var_start..self.pos];
                    if (self.pos < self.input.len) self.pos += 1;
                    try buf.appendSlice(self.expandVar(var_name));
                } else {
                    const var_start = self.pos;
                    while (self.pos < self.input.len) {
                        const vc = self.input[self.pos];
                        if (!std.ascii.isAlphanumeric(vc) and vc != '_') break;
                        self.pos += 1;
                    }
                    const var_name = self.input[var_start..self.pos];
                    try buf.appendSlice(self.expandVar(var_name));
                }
                continue;
            }

            try buf.append(ch);
            self.pos += 1;
        }

        if (expanded) {
            return .{ .kind = .word, .value = try buf.toOwnedSlice() };
        } else {
            buf.deinit();
            return .{ .kind = .word, .value = self.input[start..self.pos] };
        }
    }

    fn expandVar(self: *Lexer, name: []const u8) []const u8 {
        if (self.env) |env| {
            if (env.get(name)) |val| return val;
        }
        const val = std.process.getEnvVarOwned(self.allocator, name) catch return "";
        return val;
    }

    fn readString(self: *Lexer, quote: u8) LexError!Token {
        self.pos += 1;
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            const ch = self.input[self.pos];
            if (quote == '"' and ch == '$' and self.pos + 1 < self.input.len) {
                self.pos += 1;
                const var_start = self.pos;
                while (self.pos < self.input.len) {
                    const vc = self.input[self.pos];
                    if (!std.ascii.isAlphanumeric(vc) and vc != '_') break;
                    self.pos += 1;
                }
                const var_name = self.input[var_start..self.pos];
                try buf.appendSlice(self.expandVar(var_name));
                continue;
            }
            try buf.append(ch);
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return LexError.UnterminatedString;
        self.pos += 1;
        return .{ .kind = .string, .value = try buf.toOwnedSlice() };
    }

    fn readCmdSub(self: *Lexer) LexError!Token {
        self.pos += 2;
        const start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '(') depth += 1;
            if (self.input[self.pos] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return LexError.UnterminatedCmdSub;
        const inner = self.input[start..self.pos];
        self.pos += 1;
        return .{ .kind = .cmd_sub, .value = inner };
    }
};

fn getHome(allocator: Allocator) ![]u8 {
    const key = if (comptime builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    return std.process.getEnvVarOwned(allocator, key);
}

test "Lexer: simple command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lexer = Lexer.init("echo hello world", a);
    const tokens = try lexer.tokenize();
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
    try std.testing.expectEqual(TokenKind.pipe, tokens[1].kind);
}

test "Lexer: && and ||" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l1 = Lexer.init("echo a && echo b", a);
    const t1 = try l1.tokenize();
    try std.testing.expectEqual(TokenKind.and_and, t1[2].kind);

    var l2 = Lexer.init("echo a || echo b", a);
    const t2 = try l2.tokenize();
    try std.testing.expectEqual(TokenKind.or_or, t2[2].kind);
}

test "Lexer: quoted string with $VAR expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.StringHashMap([]const u8).init(a);
    try env.put("NAME", "Zogis");
    var lexer = Lexer.initWithEnv("echo \"hello $NAME\"", a, &env);
    const tokens = try lexer.tokenize();
    try std.testing.expectEqualStrings("hello Zogis", tokens[1].value);
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
    try std.testing.expectError(LexError.UnterminatedString, lexer.tokenize());
}

test "Lexer: cmd substitution token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lexer = Lexer.init("echo $(pwd)", a);
    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenKind.cmd_sub, tokens[1].kind);
    try std.testing.expectEqualStrings("pwd", tokens[1].value);
}
