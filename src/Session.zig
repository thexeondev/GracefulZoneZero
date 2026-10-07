const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const grace = @import("grace.zig");
const protocol = grace.protocol;
const Command = grace.protocol.Command;

time: Io.Timestamp,
command: Command,
sink: Sink,
player_uid: u32,

pub const Error = grace.protobuf.DecodeError || Sink.SendError;

pub const Sink = struct {
    packet_id_counter: *u32,
    ack_packet_id: u32,
    fixed_writer: Io.Writer,
    xorpad: *const protocol.Xorpad,
    response_sent: bool = false,

    pub const SendError = error{SendBufferExceeded};

    pub fn respond(sink: *Sink, comptime Body: type, body: *const Body) SendError!void {
        assert(!sink.response_sent);
        sink.response_sent = true;

        const packet_id = sink.packet_id_counter.*;
        sink.packet_id_counter.* +%= 1;

        protocol.Command.encode(Body, body, .{
            .head = &.{ .packet_id = packet_id, .ack_packet_id = sink.ack_packet_id },
            .writer = &sink.fixed_writer,
            .xorpad = sink.xorpad,
        }) catch |err| switch (err) {
            error.WriteFailed,
            error.PacketTooLong,
            => return error.SendBufferExceeded,
        };
    }

    pub fn notify(sink: *Sink, comptime Body: type, body: *const Body) SendError!void {
        const packet_id = sink.packet_id_counter.*;
        sink.packet_id_counter.* +%= 1;

        protocol.Command.encode(Body, body, .{
            .head = &.{ .packet_id = packet_id, .ack_packet_id = 0 },
            .writer = &sink.fixed_writer,
            .xorpad = sink.xorpad,
        }) catch |err| switch (err) {
            error.WriteFailed,
            error.PacketTooLong,
            => return error.SendBufferExceeded,
        };
    }
};
