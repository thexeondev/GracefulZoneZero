const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetBuddyDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetBuddyDataScRsp, &.{
        .retcode = 0,
        .buddy_list = &.{},
        .buddy_component_id_list = &.{},
    });
}
