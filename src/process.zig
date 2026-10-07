const builtin = @import("builtin");
const optimize = builtin.optimize;
const native_os = builtin.target.os.tag;

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const grace = @import("grace.zig");
const StaticAllocator = grace.StaticAllocator;

pub const args = @import("process/args.zig");
pub const Shutdown = @import("process/Shutdown.zig");

var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
const use_safe_allocator = switch (optimize) {
    .debug, .safe => true,
    .small, .fast => false,
};

pub const Init = struct {
    io: Io,
    static_allocator: *StaticAllocator,
};

/// Indicates whether task-level concurrency is available,
/// including via `std.Io` instance passed in `Init`.
pub const have_concurrency = switch (native_os) {
    .wasi => false,
    else => true,
};

/// Applications can take advantage of this entry point by re-exporting it in their
/// root source files.
///
/// The root must also provide:
/// * `start` function taking `Init` and an instance of custom `Args` type
/// * `log` declaration, exposing same API as result of `std.log.scoped`
/// * `usage` declaration of type coercible to `[]const u8`
pub fn main(init: std.process.Init.Minimal) !void {
    const backing_gpa = if (use_safe_allocator)
        safe_allocator.allocator()
    else
        std.heap.smp_allocator;

    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };

    var static_allocator: StaticAllocator = .init(backing_gpa);

    var threaded: std.Io.Threaded = .init(static_allocator.allocator(), .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var args_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer args_arena.deinit();
    const args_slice = try init.args.toSlice(args_arena.allocator());

    try parseArgsAndCallStart(@import("root"), args_slice, .{
        .io = io,
        .static_allocator = &static_allocator,
    });
}

fn parseArgsAndCallStart(comptime root: type, args_slice: []const []const u8, init: Init) !void {
    const params = @typeInfo(@TypeOf(root.start)).@"fn".param_types;
    comptime {
        assert(params.len == 2);
        assert(params[0].? == Init);
        assert(@typeInfo(params[1].?) == .@"struct");
    }

    const Args = params[1].?;
    const args_parsed = args.parse(Args, root.log, args_slice) orelse {
        Io.File.stdout().writeStreamingAll(init.io, root.usage) catch {};
        std.process.exit(0);
    };

    try root.start(init, args_parsed);
}

/// Logs an error to the `log` and then terminates the process with exit code 1.
pub fn fatal(comptime log: type, comptime fmt: []const u8, fmt_args: anytype) noreturn {
    log.err(fmt, fmt_args);
    std.process.exit(1);
}
