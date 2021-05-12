const std = @import("std");
const ChildProcess = std.ChildProcess;
const builtin = std.builtin;

const builtins = @import("builtins.zig");

const Argv = std.ArrayList([]const u8);

pub var env_map: std.BufMap = undefined;

pub fn init(ally: *std.mem.Allocator) !void {
    env_map = try std.process.getEnvMap(ally);
}
pub fn deinit() void {
    env_map.deinit();
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const ally = &gpa.allocator;
    defer _ = gpa.deinit();

    try init(ally);
    defer deinit();

    const stdout = std.io.getStdOut().writer();

    while (true) {
        // the prompt
        try printPrompt(ally);

        // reading the line
        const stdin = std.io.getStdIn();
        const line = (stdin.reader().readUntilDelimiterAlloc(ally, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => {
                try stdout.writeByte('\n');
                break;
            },
            else => return e,
        });
        defer ally.free(line);
        if (line.len < 1) continue;
        try executeLine(ally, line);
    }
}

pub fn executeLine(ally: *std.mem.Allocator, line: []const u8) !void {
    // tokenization of line
    var argv = try Argv.initCapacity(ally, 1);
    defer argv.deinit();
    var tokenized = std.mem.tokenize(line, " ");
    while (tokenized.next()) |arg| {
        try argv.append(arg);
    }
    // parse the args / handle builtin funcs
    if (argv.items.len < 1 or try builtins.handleBuiltin(argv.items, ally)) return;
    var cp = try ChildProcess.init(argv.items, ally);
    defer cp.deinit();
    const exit = cp.spawnAndWait() catch |e| {
        switch (e) {
            error.FileNotFound => try shigError("{s}: file not found", .{argv.items[0]}),
            error.AccessDenied => try shigError("{s}: Permission denied", .{argv.items[0]}),
            else => try shigError("{s}: TODO handle more errors", .{@errorName(e)}),
        }
        return;
    };
}

fn printPrompt(ally: *std.mem.Allocator) !void {
    const stdout = std.io.getStdOut();
    const cwd = try std.process.getCwdAlloc(ally);
    defer ally.free(cwd);
    try stdout.writer().print("\x1b[34;1m{s} \x1b[32;1m(shig)>\x1b[0m ", .{cwd});
}

pub fn shigError(
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("shig: " ++ fmt ++ "\n", args);
}

test "builtins" {
    _ = @import("builtins.zig");
}

/// returns an owned slice
pub fn getProgFromPath(allocator: *std.mem.Allocator, prog: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, prog, '/') != null) {
        std.os.access(prog, std.os.system.X_OK) catch return null;
        return prog;
    }

    const PATH = std.os.getenvZ("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
    var it = std.mem.tokenize(PATH, ":");
    while (it.next()) |directory| {
        const path = try std.fs.path.join(allocator, &.{ directory, prog });
        std.os.access(path, std.os.system.X_OK) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }
    return null;
}
