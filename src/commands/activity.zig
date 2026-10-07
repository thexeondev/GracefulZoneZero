const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetActivityListCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetActivityListScRsp, &.{
        .retcode = 0,
        .activity_list = &.{},
        .activity_pop_list = &.{},
    });
}
