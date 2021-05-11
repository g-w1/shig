const std = @import("std");
const ChildProcess = std.ChildProcess;
const builtin = std.builtin;

const Argv = std.ArrayList([]const u8);

var env_map: std.BufMap = undefined;

pub fn main() anyerror!void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    var gpa = &alloc.allocator;
    defer _ = alloc.deinit();
    env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();
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
        defer gpa.free(line);
        if (line.len < 1) continue;
        try executeLine(gpa, line);
    }
}

fn executeLine(ally: *std.mem.Allocator, line: []const u8) !void {
    // tokenization of line
    var argv = try Argv.initCapacity(ally, 1);
    defer argv.deinit();
    var tokenized = std.mem.tokenize(line, " ");
    while (tokenized.next()) |arg| {
        try argv.append(arg);
    }
    // parse the args / handle builtin funcs
    if (argv.items.len < 1 or try handleBuiltin(argv.items, ally)) return;
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

test "cd" {
    const ally = std.testing.allocator;
    env_map = try std.process.getEnvMap(ally);
    defer env_map.deinit();

    const old_cwd = try std.process.getCwdAlloc(ally);
    defer ally.free(old_cwd);

    try executeLine(ally, "cd");
    try executeLine(ally, "cd -");

    const new_cwd = try std.process.getCwdAlloc(ally);
    defer ally.free(new_cwd);

    try std.testing.expectEqualStrings(new_cwd, old_cwd);
}

test "export" {
    const ally = std.testing.allocator;
    env_map = try std.process.getEnvMap(ally);
    defer env_map.deinit();

    try std.testing.expect(env_map.get("SHIG_TEST_ENV_VAR") == null);

    try executeLine(ally, "export SHIG_TEST_ENV_VAR=shig_sucess");

    try std.testing.expectEqualStrings(env_map.get("SHIG_TEST_ENV_VAR").?, "shig_sucess");
}

fn printPrompt(ally: *std.mem.Allocator) !void {
    const stdout = std.io.getStdOut();
    const cwd = try std.process.getCwdAlloc(ally);
    defer ally.free(cwd);
    try stdout.writer().print("\x1b[34;1m{s} \x1b[32;1m(shig)>\x1b[0m ", .{cwd});
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
        for (argv[1..]) |a| {
            if (a[0] != '-') { // without a dash it's an operand
                try operands.append(a);
            } else if (std.mem.eql(u8, a, "-")) { // singular dash means go back to previous directory
                const newdir = env_map.get("OLDPWD");
                if (newdir) |nd| {
                    const d = try std.mem.dupe(ally, u8, nd);
                    defer ally.free(d);

                    if (!builtin.is_test)
                        try stdout.print("{s}\n", .{d});

                    try cd(ally, d);
                } else {
                    try shigError("cd: OLDPWD not set", .{});
                }
                return true;
            } else { // Otherwise it's a flag
                try shigError("cd: TODO illegal option {s} (flags are not supported yet)", .{a});
                return true;
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
            var env_iter = env_map.iterator();
            while (env_iter.next()) |envvar| {
                if (!builtin.is_test)
                    try stdout.print("{s}={s}\n", .{ envvar.key, envvar.value });
            }
        } else {
            for (argv[1..]) |a| {
                const eql_position = std.mem.indexOf(u8, a, "=");
                if (eql_position) |pos| {
                    const name = a[0..pos];
                    const word = a[pos + 1 ..];
                    try env_map.set(name, word);
                } else {
                    try shigError("export: TODO export existing variables", .{});
                }
            }
        }
        return true;
    }
    return false;
}

// TODO: The builtins should probably be in separate files

fn cd(ally: *std.mem.Allocator, p: []const u8) !void {
    const cwd = try std.process.getCwdAlloc(ally);
    defer ally.free(cwd);
    try env_map.set("OLDPWD", cwd);
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
    const stderr = std.io.getStdErr().writer();
    try stderr.print(fmt, args);
    try stderr.writeByte('\n');
}
