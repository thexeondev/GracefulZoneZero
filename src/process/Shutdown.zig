const Shutdown = @This();

const builtin = @import("builtin");
const native_os = builtin.target.os.tag;

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const assert = std.debug.assert;
const fatal = std.process.fatal;

io: Io,
event: Io.Event,

var global_shutdown: Shutdown = undefined;
var global_shutdown_initialized: std.atomic.Value(bool) = .init(false);

/// Wait until application termination is requested.
/// Arms SIGINT handler on POSIX and "console ctrl handler" on windows.
///
/// Asserts there's only one outstanding `wait`.
pub fn wait(io: Io) Io.Cancelable!void {
    assert(!global_shutdown_initialized.swap(true, .seq_cst));

    global_shutdown = .{
        .io = io,
        .event = .unset,
    };

    switch (native_os) {
        .windows => initWindows(),
        else => initPosix(),
    }

    try global_shutdown.event.wait(io);
}

fn initPosix() void {
    const rc = posix.system.sigaction(.INT, &.{
        .handler = .{ .handler = sigIntHandler },
        .mask = std.mem.zeroes(@FieldType(posix.system.Sigaction, "mask")),
        .flags = 0,
    }, null);

    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| fatal(
            \\couldn't setup shutdown handler
            \\sigaction errno={t}
            \\
        , .{err}),
    }
}

fn sigIntHandler(_: posix.system.SIG) callconv(.c) void {
    global_shutdown.event.set(global_shutdown.io);
}

extern "kernel32" fn SetConsoleCtrlHandler(
    *const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
    std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

fn initWindows() void {
    const handler_set = SetConsoleCtrlHandler(consoleCtrlHandler, .TRUE);
    if (handler_set == .FALSE) fatal(
        \\couldn't setup shutdown handler
        \\SetConsoleCtrlHandler GetLastError={t}
        \\
    , .{std.os.windows.GetLastError()});
}

fn consoleCtrlHandler(_: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    global_shutdown.event.set(global_shutdown.io);
    return .TRUE;
}
