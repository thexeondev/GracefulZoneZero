const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetArcadeAchievementListCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetArcadeAchievementListScRsp, &.{
        .retcode = 0,
        .achievement_list = &.{},
    });
}
