const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetGachaDataCsReq(session: *Session) !void {
    const request = try session.command.decodeBody(protobuf.gen.GetGachaDataCsReq.Decoded);

    try session.sink.respond(protobuf.gen.GetGachaDataScRsp, &.{
        .retcode = 0,
        .gacha_type = request.gacha_type,
        .gacha_data = .{
            .gacha_random = 1337,
            .equip_gacha = .{},
            .payment_gacha = .{},
            .trash_gacha = .{},
        },
    });
}
