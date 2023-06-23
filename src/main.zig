const std = @import("std");
const ChildProcess = std.ChildProcess;
const builtin = std.builtin;

const builtins = @import("builtins.zig");

const Argv = std.ArrayList([]const u8);

pub var env_map: std.process.EnvMap = undefined;
pub var lastexitcode: u32 = 0;

pub fn init(ally: std.mem.Allocator) !void {
    env_map = try std.process.getEnvMap(ally);
}
pub fn deinit() void {
    env_map.deinit();
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var ally = gpa.allocator();

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
        // execute the command
        try executeLine(ally, line);
    }
}

pub fn executeLine(ally: std.mem.Allocator, line: []const u8) !void {
    // tokenization of line
    var argv = try Argv.initCapacity(ally, 1);
    defer argv.deinit();
    var tokenized = std.mem.tokenizeAny(u8, line, " ");
    while (tokenized.next()) |arg| {
        try argv.append(arg);
    }
    // parse the args / handle builtin funcs
    if (argv.items.len < 1 or try builtins.handleBuiltin(argv.items, ally)) return;

    // from zig docs:
    // // The POSIX standard does not allow malloc() between fork() and execve(),
    // // and `self.allocator` may be a libc allocator.
    // // I have personally observed the child process deadlocking when it tries
    // // to call malloc() due to a heap allocation between fork() and execve(),
    // // in musl v1.1.24.
    // // Additionally, we want to reduce the number of possible ways things
    // // can fail between fork() and execve().
    // // Therefore, we do all the allocation for the execve() before the fork().
    // // This means we must do the null-termination of argv and env vars here.

    const pid_result = try std.os.fork();
    if (pid_result == 0) {
        // child
        switch (std.process.execv(ally, argv.items)) {
            error.FileNotFound => try shigError("{s}: file not found", .{argv.items[0]}),
            error.AccessDenied => try shigError("{s}: Permission denied", .{argv.items[0]}),
            else => |e| try shigError("{s}: TODO handle more errors", .{@errorName(e)}),
        }
    } else {
        // parent
        const waitpid_results = std.os.waitpid(pid_result, 0);
        lastexitcode = waitpid_results.status;
    }
}

fn printPrompt(ally: std.mem.Allocator) !void {
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

test "exec" {
    try init(std.testing.allocator);
    defer deinit();

    // relative paths in $PATH
    try executeLine(std.testing.allocator, "ls");

    // Absolute path
    var cmd = try std.mem.concat(std.testing.allocator, u8, &.{ std.testing.zig_exe_path, " --help" });
    defer std.testing.allocator.free(cmd);
    try executeLine(std.testing.allocator, cmd);
}

/// returns an owned slice
pub fn getProgFromPath(allocator: std.mem.Allocator, prog: []const u8) !?[:0]const u8 {
    if (std.mem.indexOfScalar(u8, prog, '/') != null) {
        std.os.access(prog, std.os.system.X_OK) catch return null;
        return @as(?[:0]const u8, try allocator.dupeZ(u8, prog));
    }

    const PATH = std.os.getenvZ("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
    var it = std.mem.tokenizeAny(u8, PATH, ":");
    while (it.next()) |directory| {
        const path = try std.fs.path.joinZ(allocator, &.{ directory, prog });
        std.os.access(path, std.os.system.X_OK) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }
    return null;
}
