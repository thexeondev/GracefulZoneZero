pub const Server = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const grace = @import("../grace.zig");
const http = grace.http;

pub const Status = enum(u16) {
    ok = 200,
    bad_request = 400,
    not_found = 404,
    service_unavailable = 599,

    pub fn phrase(s: Status) []const u8 {
        return switch (s) {
            .ok => "OK",
            .bad_request => "Bad Request",
            .not_found => "Not Found",
            .service_unavailable => "Service Unavailable",
        };
    }
};

pub const Client = struct {
    request: *const http.Request,
    response_buffer: []u8,
    /// May be unbuffered.
    response_writer: *Io.Writer,

    pub const RespondError = Io.Writer.Error || error{
        ResponseBufferShort,
    };

    /// Guarantees that `string` will be passed to the underlying stream as is.
    /// Serializes response headers into `client.response_buffer`.
    pub fn respondString(
        client: *const Client,
        status: Status,
        string: []const u8,
    ) RespondError!void {
        const headers = try printResponseHeaders(client.response_buffer, status, string.len);
        var vec: [2][]const u8 = .{
            headers,
            string,
        };

        try client.response_writer.writeVecAll(&vec);
        try client.response_writer.flush();
    }

    /// Serializes `json` into `client.response_buffer` and sends it to the client.
    pub fn respondJson(client: *const Client, status: Status, json: anytype) RespondError!void {
        const body = mem.print(client.response_buffer, "{f}", .{std.json.fmt(json, .{})}) catch
            return error.ResponseBufferShort;

        const response_buffer_remaining = client.response_buffer[body.len..];
        const headers = try printResponseHeaders(response_buffer_remaining, status, body.len);

        var vec: [2][]const u8 = .{
            headers,
            body,
        };

        try client.response_writer.writeVecAll(&vec);
        try client.response_writer.flush();
    }

    fn printResponseHeaders(
        buffer: []u8,
        status: Status,
        len: usize,
    ) error{ResponseBufferShort}![]u8 {
        return mem.print(buffer, "HTTP/1.1 {d} {t}\r\n" ++
            "Connection: close\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "\r\n", .{ @backingInt(status), status, len }) catch error.ResponseBufferShort;
    }
};

pub const Connection = struct {
    recv_buffer: []u8,
    send_buffer: []u8,

    pub const Buffer = struct {
        options: Options,
        count: usize,
        bytes: []u8,

        /// Allocates recv and send buffers for `count` of clients.
        pub fn init(gpa: Allocator, options: Options) Allocator.Error!Buffer {
            return .{
                .options = options,
                .count = options.connection_capacity,
                .bytes = try gpa.alloc(
                    u8,
                    (options.recv_buffer_size + options.send_buffer_size) * options.connection_capacity,
                ),
            };
        }

        pub fn deinit(buffer: *Buffer, gpa: Allocator) void {
            gpa.free(buffer.bytes);
            buffer.bytes = undefined;
        }

        fn nth(buffer: *const Buffer, n: usize) Connection {
            assert(n < buffer.count);

            const options = &buffer.options;
            const buf = buffer.bytes[n * (options.recv_buffer_size + options.send_buffer_size) ..];

            return .{
                .recv_buffer = buf[0..options.recv_buffer_size],
                .send_buffer = buf[options.recv_buffer_size..][0..options.send_buffer_size],
            };
        }
    };

    pub const Options = struct {
        connection_capacity: usize,
        /// Determines the upper bound on request size.
        recv_buffer_size: usize,
        /// Determines the upper bound on size of responses sent via `respondJson`.
        /// Does not affect `respondString`.
        send_buffer_size: usize,
    };
};

net_server: *Io.net.Server,
concurrent: bool,
connections_buffer: Connection.Buffer,
connections_group: Io.Group = .init,

pub const StartError = Io.Cancelable || Io.ConcurrentError;

/// If `server.concurrent` is true, this will return control to the caller
/// after starting concurrent tasks.
///
/// If `server.concurrent` is false, this will block until caller task is canceled.
/// In this case, `error.ConcurrencyUnavailable` is unreachable and `deinit` is a no-op.
///
/// `context` has to expose a `handle` function accepting self and
/// an instance of `Client` and must be threadsafe.
pub fn start(server: *Server, io: Io, context: anytype) StartError!void {
    assert(server.connections_buffer.count != 0);

    if (!server.concurrent) return runConnectionTask(
        io,
        server.connections_buffer.nth(0),
        server.net_server,
        context,
    );

    errdefer server.connections_group.cancel(io);

    const Context = @TypeOf(context);
    for (0..server.connections_buffer.count) |i| {
        try server.connections_group.concurrent(io, struct {
            fn run(task_io: Io, conn: Connection, ns: *Io.net.Server, ctx: Context) !void {
                try runConnectionTask(task_io, conn, ns, ctx);
            }
        }.run, .{ io, server.connections_buffer.nth(i), server.net_server, context });
    }
}

/// Idempotent. Not threadsafe.
pub fn deinit(server: *Server, io: Io) void {
    server.connections_group.cancel(io);
}

fn runConnectionTask(
    io: Io,
    connection: Connection,
    net_server: *Io.net.Server,
    context: anytype,
) Io.Cancelable!void {
    while (true) {
        const stream = net_server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };
        defer stream.close(io);

        var stream_reader = stream.reader(io, connection.recv_buffer);
        var stream_writer = stream.writer(io, &.{});

        serve(
            &stream_reader.interface,
            &stream_writer.interface,
            connection.send_buffer,
            context,
        ) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.EndOfStream => {},
            error.ReadFailed => switch (stream_reader.err.?) {
                error.Canceled => |e| return e,
                else => {},
            },
            error.WriteFailed => switch (stream_writer.err.?) {
                error.Canceled => |e| return e,
                else => {},
            },
        };
    }
}

pub const ServeError = Io.Cancelable || Io.Reader.Error || Io.Writer.Error;

pub const HandleError = Io.Cancelable || Client.RespondError;

fn serve(
    reader: *Io.Reader,
    writer: *Io.Writer,
    response_buffer: []u8,
    context: anytype,
) ServeError!void {
    while (reader.fillMore()) {
        assert(reader.seek == 0);
        const parsed = http.Request.parse(reader.buffer, reader.end) catch |err| switch (err) {
            error.ShortInput => if (reader.end == reader.buffer.len) return else continue,

            error.HttpHeadersInvalid,
            error.HttpVersionUnsupported,
            error.HttpMethodUnsupported,
            => return,
        };
        defer reader.toss(parsed.consumed_bytes);

        const client: Client = .{
            .request = &parsed.request,
            .response_buffer = response_buffer,
            .response_writer = writer,
        };

        context.handle(client) catch |err| switch (@as(HandleError, err)) {
            error.Canceled => |e| return e,
            error.WriteFailed => |e| return e,
            error.ResponseBufferShort => return,
        };

        return;
    } else |err| return err;
}
