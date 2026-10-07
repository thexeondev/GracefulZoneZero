const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetMonsterCardDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetMonsterCardDataScRsp, &.{
        .retcode = 0,
        .data = .{
            .monster_card_machine = .{},
            .monster_card_list = &.{},
        },
    });
}
