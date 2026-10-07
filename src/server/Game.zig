const Game = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const IpAddress = std.Io.net.IpAddress;

const grace = @import("grace");
const rsa = grace.rsa;
const process = grace.process;
const protocol = grace.protocol;
const protobuf = grace.protobuf;

const Configuration = @import("Game/Configuration.zig");

pub const log = std.log.scoped(.@"grace-game-server");
pub const main = process.main;

const default_listen_address = "127.0.0.1:20501";
const default_concurrency: u32 = 16;
const default_config_path = "game.zon";

pub const Args = struct {
    @"--listen-address": []const u8 = default_listen_address,
    @"--concurrency": u32 = default_concurrency,
    @"--config-path": ?[]const u8 = null,
};

pub const usage = std.fmt.comptimePrint(
    \\Usage: grace-game-server [options]
    \\
    \\Options:
    \\  --help, -h            Print this help and exit
    \\  --listen-address      TCP listen address; default is {q}
    \\  --concurrency         Amount of connections to be processed concurrently; default is {d}
    \\  --config-path         Configuration file path; default is {q}
    \\
, .{
    default_listen_address,
    default_concurrency,
    default_config_path,
});

const recv_buffer_size: usize = 16384;
const send_buffer_size: usize = 16384;

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

    const conf: Configuration = .build(.{ .zon = &config_zon });

    if (args.@"--concurrency" == 0)
        process.fatal(log, "--concurrency must be greater than zero", .{});

    const per_client_buffer_size = recv_buffer_size + send_buffer_size;
    const client_buffers = gpa.alloc(
        u8,
        per_client_buffer_size * args.@"--concurrency",
    ) catch |err| switch (err) {
        error.OutOfMemory => process.fatal(log,
            \\failed to allocate memory for {d} clients
            \\likely cause: --concurrency is higher than system can process
        , .{args.@"--concurrency"}),
    };
    defer gpa.free(client_buffers);

    // TODO: bundle `clients` and `client_buffers` into single alignedAlloc
    const clients = gpa.alloc(Client, args.@"--concurrency") catch |err| switch (err) {
        error.OutOfMemory => process.fatal(log,
            \\failed to allocate memory for {d} clients
            \\likely cause: --concurrency is higher than system can process
        , .{args.@"--concurrency"}),
    };
    defer gpa.free(clients);

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

    var client_task_group: Io.Group = .init;
    defer client_task_group.cancel(io);

    const game: Game = .{ .conf = &conf };

    if (!process.have_concurrency) @compileError("TODO");

    var task_index: u32 = 0;
    while (task_index < args.@"--concurrency") : (task_index += 1) {
        const buffer =
            client_buffers[per_client_buffer_size * task_index ..][0..per_client_buffer_size];

        const task: Task = .{
            .game = &game,
            .net_server = &net_server,
            .recv_buffer = buffer[0..recv_buffer_size],
            .send_buffer = buffer[recv_buffer_size..][0..send_buffer_size],
            .client = &clients[task_index],
        };

        client_task_group.concurrent(io, runClientTask, .{ io, task }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => process.fatal(log,
                \\failed to allocate concurrency for {d} clients
                \\likely cause: --concurrency is higher than system can process
            , .{args.@"--concurrency"}),
        };
    }

    static_allocator.setBehavior(.@"unreachable");
    defer static_allocator.setBehavior(.allow_dealloc);

    log.info("waiting for clients at tcp://{f}", .{net_server.socket.address});
    defer log.info("shutting down...", .{});

    try process.Shutdown.wait(io);
}

const Task = struct {
    game: *const Game,
    net_server: *Io.net.Server,
    recv_buffer: []u8,
    send_buffer: []u8,
    client: *Client,
};

const Client = struct {
    player_uid: u32,
    packet_id_counter: u32,
    xorpad: protocol.Xorpad,
};

fn runClientTask(io: Io, task: Task) Io.Cancelable!void {
    while (true) {
        const stream = task.net_server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };
        defer stream.close(io);

        log.info("new client from {f}", .{stream.socket.address});
        defer log.info("client from {f} disconnected", .{stream.socket.address});

        serveStream(io, stream, &task) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => |e| log.debug(
                "failed to serve client from {f}: {t}",
                .{ stream.socket.address, e },
            ),
        };
    }
}

fn serveStream(io: Io, stream: Io.net.Stream, task: *const Task) !void {
    var stream_reader = stream.reader(io, task.recv_buffer);

    {
        var writer: Io.Writer = .fixed(task.send_buffer);
        handleFirstCommand(
            io,
            task.game,
            task.client,
            &stream_reader.interface,
            &writer,
        ) catch |err| switch (err) {
            error.Canceled => comptime unreachable, // will appear as soon as we start loading state
            error.ReadFailed => return stream_reader.err.?,
            error.WriteFailed => {
                log.warn("response to the first packet exceeded send_buffer_size", .{});
                return;
            },
            else => |e| return e,
        };

        try netWriteAll(io, &stream, writer.buffered());
    }

    while (protocol.Command.decode(&stream_reader.interface)) |command| {
        protocol.xor(command.body, &task.client.xorpad);

        log.info(
            "received command with id {d}, head: {X}, body: {X}",
            .{ command.id, command.head, command.body },
        );

        const head = try protobuf.decode(protobuf.gen.PacketHead.Decoded, command.head);
        var session: grace.Session = .{
            .time = .now(io, .real),
            .command = command,
            .sink = .{
                .packet_id_counter = &task.client.packet_id_counter,
                .ack_packet_id = head.packet_id,
                .fixed_writer = .fixed(task.send_buffer),
                .xorpad = &task.client.xorpad,
            },
            .player_uid = task.client.player_uid,
        };

        grace.commands.execute(&session) catch |err| switch (err) {
            error.CommandUnhandled => log.warn("unhandled command with id {d}", .{command.id}),
            else => |e| return e,
        };

        try netWriteAll(io, &stream, session.sink.fixed_writer.buffered());
    } else |err| switch (err) {
        error.ReadFailed => return stream_reader.err.?,
        error.MagicNumberMismatch,
        error.StreamTooLong,
        => |e| return e,
        error.EndOfStream => return,
    }
}

fn netWriteAll(
    io: Io,
    stream: *const Io.net.Stream,
    data: []const u8,
) (Io.Cancelable || Io.Operation.NetWrite.Error)!void {
    var remaining = data;
    while (remaining.len != 0) {
        var vec: [1][]const u8 = .{remaining};
        const written = try (try io.operate(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &vec,
        } })).net_write;

        remaining = remaining[written..];
    }
}

fn handleFirstCommand(
    io: Io,
    game: *const Game,
    client: *Client,
    reader: *Io.Reader,
    writer: *Io.Writer,
) !void {
    const command: protocol.Command = try .decode(reader);

    if (command.id != protobuf.gen.PlayerGetTokenCsReq.cmd_id)
        return error.UnexpectedFirstCmdId;

    protocol.xor(command.body, &game.conf.xorpad);

    const request = try protobuf.decode(protobuf.gen.PlayerGetTokenCsReq.Decoded, command.body);
    log.info(
        "PlayerGetToken:" ++
            " channel_id={d}" ++
            ", platform_type={d}" ++
            ", rsa_ver={d}" ++
            ", account_type={d}" ++
            ", account_uid={q}" ++
            ", device={q}" ++
            ", token={q}",
        .{
            request.channel_id,
            request.platform_type,
            request.rsa_ver,
            request.account_type,
            request.account_uid,
            request.device,
            request.token,
        },
    );

    const get_token: PlayerGetToken = .{ .writer = writer, .xorpad = &game.conf.xorpad };
    if (request.rsa_ver != rsa.version) {
        log.debug(
            "rsa version mismatch (expected: {d}, received: {d})",
            .{ rsa.version, request.rsa_ver },
        );
        return get_token.fail(&.{ .retcode = 1 });
    }

    // TODO: make compile-proto.zig emit []u8 for `string`/`bytes` in `Decoded` variants
    // to avoid this @constCast
    const client_rand_key = rsa.decryptString(@constCast(request.client_rand_key)) orelse {
        log.debug("client_rand_key decryption failed, string: {q}", .{request.client_rand_key});
        return get_token.fail(&.{ .retcode = 1 });
    };

    if (client_rand_key.len != @sizeOf(u64)) {
        log.debug("client_rand_key length mismatch (got {d} bytes)", .{client_rand_key.len});
        return get_token.fail(&.{ .retcode = 1 });
    }

    var server_rand_key: [@sizeOf(u64)]u8 = undefined;
    io.random(&server_rand_key);

    var server_rand_key_encrypt_buffer: rsa.EncryptAndSignBuffer = undefined;
    rsa.encryptAndSign(&server_rand_key_encrypt_buffer, &server_rand_key);

    const player_uid: u32 = 1337;

    try get_token.finish(&.{
        .retcode = 0,
        .uid = player_uid,
        .server_rand_key = &server_rand_key_encrypt_buffer.ciphertext,
        .sign = &server_rand_key_encrypt_buffer.sign,
    });

    const rand_key =
        mem.readInt(u64, server_rand_key[0..8], .little) ^
        mem.readInt(u64, client_rand_key[0..8], .little);

    client.player_uid = player_uid;
    client.packet_id_counter = 0;
    grace.random.fillArray(client.xorpad.len, &client.xorpad, rand_key);
}

const PlayerGetToken = struct {
    writer: *Io.Writer,
    xorpad: *const protocol.Xorpad,

    pub fn finish(
        get_token: *const PlayerGetToken,
        rsp: *const protobuf.gen.PlayerGetTokenScRsp,
    ) protocol.Command.EncodeError!void {
        try protocol.Command.encode(protobuf.gen.PlayerGetTokenScRsp, rsp, .{
            .head = &.{},
            .writer = get_token.writer,
            .xorpad = get_token.xorpad,
        });
    }

    pub fn fail(
        get_token: *const PlayerGetToken,
        rsp: *const protobuf.gen.PlayerGetTokenScRsp,
    ) (protocol.Command.EncodeError || error{PlayerGetTokenFailed}) {
        try get_token.finish(rsp);
        return error.PlayerGetTokenFailed;
    }
};
