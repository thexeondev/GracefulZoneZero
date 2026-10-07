const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetLandReviveDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetLandReviveDataScRsp, &.{
        .retcode = 0,
        .land_revive_data = .{},
    });
}
