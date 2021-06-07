const std = @import("std");
const main = @import("main.zig");
const builtin = std.builtin;
const executeLine = main.executeLine;
const shigError = main.shigError;

const BuiltinType = enum {
    cd,
    @"export",
    exit,
    type,
};

fn builtinCd(ally: *std.mem.Allocator, argv: [][]const u8) !void {
    const stdout = std.io.getStdOut().writer();
    std.debug.assert(std.mem.eql(u8, "cd", argv[0])); // cd was called wrong
    var operand: []const u8 = undefined;
    for (argv[1..]) |a| {
        if (a[0] != '-') { // without a dash it's an operand
            operand = a;
        } else if (std.mem.eql(u8, a, "-")) { // singular dash means go back to previous directory
            const newdir = main.env_map.get("OLDPWD");
            if (newdir) |nd| {
                const d = try std.mem.dupe(ally, u8, nd);
                defer ally.free(d);

                try stdout.print("{s}\n", .{d});

                try cd(ally, d);
            } else {
                try shigError("cd: OLDPWD not set", .{});
            }
            return;
        } else { // Otherwise it's a flag
            try shigError("cd: TODO illegal option {s} (flags are not supported yet)", .{a});
            return;
        }
    }
    if (argv.len == 1) {
        const home = std.process.getEnvVarOwned(ally, "HOME") catch |e| {
            switch (e) {
                error.EnvironmentVariableNotFound => try shigError("cd: HOME not set", .{}),
                else => try shigError("cd: {s}: TODO", .{@errorName(e)}),
            }
            return;
        };
        defer ally.free(home);
        try cd(ally, home);
        return;
    }

    std.debug.assert(argv.len >= 2); // we have already handled the case where we cd home
    if (argv.len != 2) {
        try shigError("cd: too many arguments", .{});
    } else {
        try cd(ally, operand);
    }
}
fn cd(ally: *std.mem.Allocator, p: []const u8) !void {
    const cwd = try std.process.getCwdAlloc(ally);
    defer ally.free(cwd);
    try main.env_map.put("OLDPWD", cwd);
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

fn builtinExit(argv: [][]const u8) !void {
    std.debug.assert(std.mem.eql(u8, "exit", argv[0])); // exit was called wrong
    const stdout = std.io.getStdOut().writer();
    if (argv.len > 2) {
        try shigError("exit: too many arguments", .{});
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
fn builtinExport(ally: *std.mem.Allocator, argv: [][]const u8) !void {
    std.debug.assert(std.mem.eql(u8, "export", argv[0])); // export was called wrong
    const stdout = std.io.getStdOut().writer();
    if (argv.len == 1) {
        var env_iter = main.env_map.iterator();
        while (env_iter.next()) |envvar| {
            try stdout.print("{s}={s}\n", .{ envvar.key_ptr.*, envvar.value_ptr.* });
        }
    } else {
        for (argv[1..]) |a| {
            const eql_position = std.mem.indexOf(u8, a, "=");
            if (eql_position) |pos| {
                const name = a[0..pos];
                const word = a[pos + 1 ..];
                try main.env_map.put(name, word);
            } else {
                try shigError("export: TODO export existing variables", .{});
            }
        }
    }
}
fn builtinType(ally: *std.mem.Allocator, argv: [][]const u8) !void {
    std.debug.assert(std.mem.eql(u8, "type", argv[0])); // type was called wrong
    const stdout = std.io.getStdOut().writer();
    if (argv.len == 1) {
        return;
    } else {
        for (argv[1..]) |a| {
            // TODO aliases first
            if (std.meta.stringToEnum(BuiltinType, a) != null) {
                try stdout.print("{s} is a shell builtin\n", .{a});
                continue;
            }
            if (try main.getProgFromPath(ally, a)) |p| {
                try stdout.print("{s} is {s}\n", .{ a, p });
                ally.free(p);
                continue;
            }
            try shigError("{s}: not found", .{a}); // TODO functions
        }
    }
}

/// true if it used a builtin, false if not
pub fn handleBuiltin(argv: [][]const u8, ally: *std.mem.Allocator) !bool {
    std.debug.assert(argv.len > 0);
    const stdout = std.io.getStdOut().writer();
    switch (std.meta.stringToEnum(BuiltinType, argv[0]) orelse return false) {
        .cd => try builtinCd(ally, argv),
        .@"export" => try builtinExport(ally, argv),
        .exit => try builtinExit(argv),
        .type => try builtinType(ally, argv),
    }
    return true;
}

test "cd" {
    const ally = std.testing.allocator;
    try main.init(ally);
    defer main.deinit();

    const old_cwd = try std.process.getCwdAlloc(ally);
    defer ally.free(old_cwd);

    try executeLine(ally, "cd");
    try executeLine(ally, "cd -");
    try executeLine(ally, "cd /tmp");
    try executeLine(ally, "cd -");

    const new_cwd = try std.process.getCwdAlloc(ally);
    defer ally.free(new_cwd);

    try std.testing.expectEqualStrings(new_cwd, old_cwd);
}

test "export" {
    const ally = std.testing.allocator;
    try main.init(ally);
    defer main.deinit();

    try std.testing.expect(main.env_map.get("SHIG_TEST_ENV_VAR") == null);

    try executeLine(ally, "export SHIG_TEST_ENV_VAR=shig_sucess");

    try std.testing.expectEqualStrings(main.env_map.get("SHIG_TEST_ENV_VAR").?, "shig_sucess");
}
