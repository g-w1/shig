const std = @import("std");

const Tokens = std.ArrayList([]const u8);

pub fn Parser() type {
    return struct {
        const Self = @This();

        allocator: *std.mem.Allocator,
        tokens: Tokens,
        position: usize,

        pub fn init(allocator: *std.mem.Allocator, input: []const u8) !Self {
            return Self{
                .allocator = allocator,
                .tokens = blk: {
                    var tokens = Tokens.init(allocator);
                    var tokenized = std.mem.tokenize(input, " ");
                    while (tokenized.next()) |t| {
                        try tokens.append(t);
                    }
                    break :blk tokens;
                },
                .position = 0,
            };
        }

        pub fn deinit(self: Self) void {
            self.tokens.deinit();
        }
    };
}
