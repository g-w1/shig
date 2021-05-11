const std = @import("std");
const ChildProcess = std.ChildProcess;

// would something like this make sense?
const CdFlags = enum { L, P };

const Argv = std.ArrayList([]const u8);
const Flags = std.ArrayList(CdFlags);

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
        const exit = cp.spawnAndWait() catch |e| {
            switch (e) {
                error.FileNotFound => try shigError("{s}: file not found", .{argv.items[0]}),
                error.AccessDenied => try shigError("{s}: Permission denied", .{argv.items[0]}),
                else => return e,
            }
            continue;
        };
    }
}

fn printPrompt(ally: *std.mem.Allocator) !void {
    const stdout = std.io.getStdOut();
    try stdout.writer().writeAll("(shig)> ");
}

/// true if it used a builtin, false if not
fn handleBuiltin(argv: [][]const u8, ally: *std.mem.Allocator) !bool {
    const stdout = std.io.getStdOut().writer();
    if (std.mem.eql(u8, argv[0], "exit")) {
        if (argv.len > 2) {
            try stdout.writeAll("exit: too many arguments\n");
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
        var operands = try Argv.initCapacity(ally, 1);
        defer operands.deinit();
        var flags = Flags.init(ally);
        defer flags.deinit();
        for (argv[1..]) |a| {
            if (a[0] != '-') { // without a dash it's an operand
                try operands.append(a);
            } else { // TODO: handle path starting with '/', '.' or neither(CDPATH) explicitely
                if (a.len == 1) { // singular dash means go back to previous directory
                    const newdir = try std.process.getEnvVarOwned(ally, "OLDPWD");
                    defer ally.free(newdir);
                    try stdout.print("{s}\n", .{newdir});
                    try cd(ally, newdir);
                    return true;
                } else { // Otherwise it's a flag
                    for (a[1..]) |flag| {
                        switch (flag) {
                            'L' => try flags.append(.L),
                            'P' => try flags.append(.P),
                            else => {
                                try shigError("cd: Illegal option -{c}", .{flag});
                                return true;
                            },
                        }
                    }
                    // TODO: make the flags do sth
                }
            }
        }

        if (operands.items.len > 1) {
            try stdout.writeAll("cd: too many arguments\n");
            return true;
        } else if (operands.items.len == 0) {
            const home = std.process.getEnvVarOwned(ally, "HOME") catch |e| {
                switch (e) {
                    error.EnvironmentVariableNotFound => {
                        try shigError("cd: HOME not set", .{});
                    },
                    else => try shigError("cd: {s}: TODO", .{@errorName(e)}),
                }
                return true;
            };
            defer ally.free(home);
            try cd(ally, home);
            return true;
        } else {
            std.debug.assert(operands.items.len == 1);
            try cd(ally, operands.items[0]);
            return true;
        }
    }

    if (std.mem.eql(u8, argv[0], "export")) {
        if (argv.len == 1) {
            for (std.os.environ) |envvar| {
                try stdout.print("{s}\n", .{envvar});
            }
        } else {
            const eql_position = std.mem.indexOf(u8, argv[1], "=");
            if (eql_position) |pos| {
                const name = argv[1][0..pos];
                const word = argv[1][pos + 1 ..];
                try envExport(ally, name, word);
            } else {
                try shigError("export: TODO export existing variables", .{});
            }
        }
        return true;
    }
    return false;
}

// TODO: The builtins should probably be in separate files

fn envExport(ally: *std.mem.Allocator, name: []const u8, word: []const u8) !void {
    for (std.os.environ) |*envvar| {
        var line_i: usize = 0;
        while (envvar.*[line_i] != 0 and envvar.*[line_i] != '=') : (line_i += 1) {}
        const this_key = envvar.*[0..line_i];
        if (!std.mem.eql(u8, name, this_key)) continue;

        var end_i: usize = line_i;
        while (envvar.*[end_i] != 0) : (end_i += 1) {}
        // This may be a memory leak
        envvar.* = try std.fmt.allocPrintZ(ally, "{s}={s}", .{ name, word });
    }
    // TODO: export not yet existing env variable
}

fn cd(ally: *std.mem.Allocator, p: []const u8) !void {
    var buffer = [_:0]u8{0} ** 100;
    try envExport(ally, "OLDPWD", try std.os.getcwd(&buffer));
    std.process.changeCurDir(p) catch |e| switch (e) {
        error.AccessDenied => try shigError("cd: {s}: Permission denied", .{p}),
        error.FileNotFound => try shigError("cd: {s}: No such file or directory", .{p}),
        error.NotDir => try shigError("cd: {s}: Not a directory", .{p}),
        // TODO
        // error.FileSystem => {},
        // error.SymLinkLoop => {},
        // error.NameTooLong => {},
        // error.SystemResources => {},
        // error.BadPathName => {},
        else => try shigError("cd: {s}: TODO", .{@errorName(e)}),
    };
}

fn shigError(
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(fmt, args);
    try stdout.writeByte('\n');
}
