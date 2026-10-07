const Dispatch = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const IpAddress = std.Io.net.IpAddress;

const grace = @import("grace");
const http = grace.http;
const process = grace.process;

const Configuration = @import("Dispatch/Configuration.zig");

pub const main = process.main;

pub const log = std.log.scoped(.@"grace-dispatch-server");

pub const usage = std.fmt.comptimePrint(
    \\Usage: grace-dispatch-server [options]
    \\
    \\Options:
    \\  --help            Print this help and exit
    \\  --listen-address  TCP listen address; default is {q}
    \\  --outer-url       Outer URL prefix of this server; default is {q}
    \\  --config-path     Path to configuration file; default is {q}
    \\  --concurrency     Amount of clients to be handled simultaneously; default is {d}
    \\
, .{
    default_listen_address,
    default_outer_url,
    default_config_path,
    default_concurrency,
});

const default_listen_address = "127.0.0.1:12401";
const default_outer_url = "http://127.0.0.1:12401";
const default_config_path = "dispatch.zon";
const default_concurrency: u32 = 16;

pub const Args = struct {
    @"--listen-address": []const u8 = default_listen_address,
    @"--outer-url": []const u8 = default_outer_url,
    @"--config-path": ?[]const u8 = null,
    @"--concurrency": u32 = default_concurrency,
};

conf: *const Configuration,

pub fn start(init: process.Init, args: Args) !void {
    const static_allocator = init.static_allocator;
    const gpa = static_allocator.allocator();
    const io = init.io;

    const should_exit_if_config_not_found = args.@"--config-path" != null;
    const config_path = args.@"--config-path" orelse default_config_path;

    var config_zon_arena: std.heap.ArenaAllocator = .init(gpa);
    defer config_zon_arena.deinit();

    var config_zon: Configuration.Zon = .defaults;

    if (Io.Dir.cwd().readFileAllocOptions(
        io,
        config_path,
        config_zon_arena.allocator(),
        .unlimited,
        .@"1",
        0,
    )) |content| {
        var diag: std.zon.parse.Diagnostics = undefined;
        std.zon.parse.updateFromSlice(Configuration.Zon, &config_zon, .{
            .gpa = gpa,
            .arena = config_zon_arena.allocator(),
            .source = content,
            .diagnostics = &diag,
        }) catch |err| switch (err) {
            error.OutOfMemory => process.fatal(
                log,
                "ran out of memory while parsing config file {q}",
                .{config_path},
            ),
            error.ParseZon => process.fatal(log, "{f}", .{diag.fmt(config_path)}),
        };
    } else |err| switch (err) {
        error.FileNotFound => if (should_exit_if_config_not_found)
            process.fatal(log, "config file {q} doesn't exist", .{config_path}),
        else => |e| process.fatal(log, "failed to read config file {q}: {t}", .{ config_path, e }),
    }

    var conf: Configuration = try .build(gpa, .{
        .zon = &config_zon,
        .outer_url = args.@"--outer-url",
    });
    defer conf.deinit();

    const listen_address = IpAddress.parseLiteral(args.@"--listen-address") catch
        process.fatal(log, "bad --listen-address {q}", .{args.@"--listen-address"});

    var net_server = listen_address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 64,
    }) catch |err| switch (err) {
        error.AddressInUse => process.fatal(log,
            \\address {qf} is already in use
            \\likely cause: another instance of this server is already running
        , .{listen_address}),
        else => |e| return e,
    };
    defer net_server.deinit(io);

    var connections_buffer = http.Server.Connection.Buffer.init(gpa, .{
        .connection_capacity = args.@"--concurrency",
        .recv_buffer_size = 8192,
        .send_buffer_size = 8192,
    }) catch |err| switch (err) {
        error.OutOfMemory => process.fatal(log,
            \\failed to allocate memory for {d} clients
            \\likely cause: --concurrency is higher than system can process
        , .{args.@"--concurrency"}),
    };
    defer connections_buffer.deinit(gpa);

    var http_server: http.Server = .{
        .net_server = &net_server,
        .concurrent = process.have_concurrency,
        .connections_buffer = connections_buffer,
    };
    defer http_server.deinit(io);

    const dispatch: Dispatch = .{ .conf = &conf };

    http_server.start(io, &dispatch) catch |err| switch (err) {
        error.ConcurrencyUnavailable => process.fatal(log,
            \\failed to allocate concurrency for {d} clients
            \\likely cause: --concurrency is higher than system can process
        , .{args.@"--concurrency"}),
        error.Canceled => |e| return e,
    };

    static_allocator.setBehavior(.@"unreachable");
    defer static_allocator.setBehavior(.allow_dealloc);

    if (!process.have_concurrency) return; // `start` should have blocked indefinitely.

    log.info("waiting for requests at http://{f}", .{net_server.socket.address});
    try process.Shutdown.wait(io);
    log.info("shutting down...", .{});
}

pub fn handle(dispatch: *const Dispatch, client: http.Server.Client) http.Server.HandleError!void {
    if (mem.eql(u8, client.request.line.path, "/query_dispatch")) {
        const query = http.query.parseFromSlice(struct {
            version: []const u8,
        }, client.request.line.query) orelse
            return try client.respondString(.bad_request, "");

        const rsp = dispatch.conf.query_dispatch_by_version.get(query.version) orelse fallback: {
            log.debug("no configuration for requested version {q}", .{query.version});
            break :fallback dispatch.conf.query_dispatch_fallback_response;
        };

        try client.respondString(.ok, rsp);
    } else if (mem.cutPrefix(u8, client.request.line.path, "/query_gateway/")) |server_name| {
        const query = http.query.parseFromSlice(struct {
            version: []const u8,
        }, client.request.line.query) orelse
            return try client.respondString(.bad_request, "");

        const rsp = rsp: {
            const gateway = dispatch.conf.query_gateway_by_server.get(server_name) orelse
                break :rsp dispatch.conf.query_gateway_fallback_response;

            if (!mem.eql(u8, gateway.client_version, query.version))
                break :rsp dispatch.conf.query_gateway_fallback_response;

            break :rsp gateway.response;
        };

        try client.respondString(.ok, rsp);
    } else {
        try client.respondString(.service_unavailable, "599 Service Unavailable");
    }
}
