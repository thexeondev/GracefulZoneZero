const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetRewardBuffDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetRewardBuffDataScRsp, &.{
        .retcode = 0,
        .data = .{ .reward_buff_list = &.{} },
    });
}
