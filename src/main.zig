const std = @import("std");
const ChildProcess = std.ChildProcess;

const Argv = std.ArrayList([]const u8);

pub fn main() anyerror!void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    var gpa = &alloc.allocator;
    const stdout = std.io.getStdOut().writer();
    while (true) {
        // the prompt
        try printPrompt(gpa);

        // reading the line
        const stdin = std.io.getStdIn();
        const line = (stdin.reader().readUntilDelimiterAlloc(gpa, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => {
                try stdout.writeByte('\n');
                std.process.exit(0);
            },
            else => return e,
        });
        if (line.len < 1) continue;
        defer gpa.free(line);
        // tokenization of line
        var argv = try Argv.initCapacity(gpa, 1);
        defer argv.deinit();
        var tokenized = std.mem.tokenize(line, " ");
        while (tokenized.next()) |arg| {
            try argv.append(arg);
        }
        // parse the args / handle builtin funcs
        if (argv.items.len < 1 or try handleBuiltin(argv.items, gpa)) continue;
        var cp = try ChildProcess.init(argv.items, gpa);
        defer cp.deinit();
        const exit = cp.spawnAndWait() catch |e| switch (e) {
            error.FileNotFound => {
                try shigError("{s}: file not found\n", .{argv.items[0]});
                continue;
            },
            else => return e,
        };
    }
}

fn printPrompt(ally: *std.mem.Allocator) !void {
    const stdout = std.io.getStdOut();
    try stdout.writer().print("(shig)> ", .{});
}

/// true if it used a builtin, false if not
fn handleBuiltin(argv: [][]const u8, ally: *std.mem.Allocator) !bool {
    const stdout = std.io.getStdOut().writer();
    if (std.mem.eql(u8, argv[0], "exit")) {
        if (argv.len > 2) {
            try stdout.print("exit: too many arguments\n", .{});
            return false;
        } else if (argv.len == 1) {
            std.process.exit(0);
        } else {
            const exit_num = std.fmt.parseInt(u8, argv[1], 10) catch |e| switch (e) {
                error.Overflow => std.process.exit(std.math.maxInt(u8)),
                error.InvalidCharacter => std.process.exit(0),
            };
            std.process.exit(exit_num);
        }
    }
    if (std.mem.eql(u8, argv[0], "cd")) {
        if (argv.len > 2) {
            try stdout.print("cd: too many arguments\n", .{});
            return true;
        } else if (argv.len == 1) {
            const home = std.process.getEnvVarOwned(ally, "HOME") catch |e| {
                switch (e) {
                    error.EnvironmentVariableNotFound => {
                        try shigError("cd: HOME not set\n", .{});
                        return true;
                    },
                    else => return e,
                }
            };
            try cd(home);
            return true;
        } else {
            std.debug.assert(argv.len == 2);
            try cd(argv[1]);
            return true;
        }
    }
    return false;
}

fn cd(p: []const u8) !void {
    std.process.changeCurDir(p) catch |e| switch (e) {
        error.AccessDenied => try shigError("cd: {s}: Permission denied\n", .{p}),
        error.FileNotFound => try shigError("cd: {s}: No such file or directory\n", .{p}),
        error.NotDir => try shigError("cd: {s}: Not a directory\n", .{p}),
        // TODO
        // error.FileSystem => {},
        // error.SymLinkLoop => {},
        // error.NameTooLong => {},
        // error.SystemResources => {},
        // error.BadPathName => {},
        else => return e,
    };
}

fn shigError(
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(fmt, args);
}
