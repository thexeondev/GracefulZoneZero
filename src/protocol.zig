const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const grace = @import("grace.zig");
const protobuf = grace.protobuf;
const PacketHead = grace.protobuf.gen.PacketHead;

pub const Command = struct {
    const overhead: usize = 16;
    const head_magic: u32 = 0x01234567;
    const tail_magic: u32 = 0x89ABCDEF;

    id: u16,
    head: []u8,
    body: []u8,

    pub const DecodeError = Io.Reader.Error || error{
        MagicNumberMismatch,
        StreamTooLong,
    };

    pub fn decode(reader: *Io.Reader) DecodeError!Command {
        const recv_head_magic = try reader.takeInt(u32, .big);
        if (head_magic != recv_head_magic) return error.MagicNumberMismatch;

        const cmd_id = try reader.takeInt(u16, .big);
        const head_len = try reader.takeInt(u16, .big);
        const body_len = try reader.takeInt(u32, .big);

        const rest_len = head_len + body_len + 4;
        if (reader.buffer.len < rest_len) return error.StreamTooLong;

        // must `take` all at once because subsequent reads invalidate previous results.
        // head, body, tail_magic
        const rest = try reader.take(rest_len);
        const recv_tail_magic = std.mem.readInt(u32, rest[head_len + body_len ..][0..4], .big);
        if (tail_magic != recv_tail_magic) return error.MagicNumberMismatch;

        return .{
            .id = cmd_id,
            .head = rest[0..head_len],
            .body = rest[head_len..][0..body_len],
        };
    }

    /// Assumes `body` is unencrypted.
    pub fn decodeBody(command: *const Command, comptime Body: type) protobuf.DecodeError!Body {
        assert(command.id == Body.Parent.cmd_id);
        return protobuf.decode(Body, command.body);
    }

    pub const EncodeOptions = struct {
        head: *const PacketHead,
        writer: *Io.Writer,
        xorpad: *const Xorpad,
    };

    pub const EncodeError = Io.Writer.Error || error{
        PacketTooLong,
    };

    pub fn encode(
        comptime Body: type,
        body: *const Body,
        options: EncodeOptions,
    ) EncodeError!void {
        const head = options.head;
        const writer = options.writer;

        const head_len: u16 = @intCast(protobuf.encodingLength(PacketHead, head));
        const body_len: u32 = @intCast(protobuf.encodingLength(Body, body));

        if (writer.buffer.len < head_len + body_len + overhead)
            return error.PacketTooLong;

        try writer.writeInt(u32, head_magic, .big);
        try writer.writeInt(u16, Body.cmd_id, .big);
        try writer.writeInt(u16, head_len, .big);
        try writer.writeInt(u32, body_len, .big);

        const head_buffer = try writer.writableSlice(head_len);
        var head_writer: Io.Writer = .fixed(head_buffer);
        protobuf.encode(PacketHead, head, &head_writer) catch unreachable;
        assert(head_writer.end == head_len);

        const body_buffer = try writer.writableSlice(body_len);
        var body_writer: Io.Writer = .fixed(body_buffer);
        protobuf.encode(Body, body, &body_writer) catch unreachable;
        assert(body_writer.end == body_len);

        xor(body_buffer, options.xorpad);
        try writer.writeInt(u32, tail_magic, .big);
    }
};

pub const Xorpad = [4096]u8;

pub fn xor(data: []u8, xorpad: *const Xorpad) void {
    for (data, 0..) |*byte, index|
        byte.* ^= xorpad[index % xorpad.len];
}
