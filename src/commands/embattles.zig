const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetEmbattlesDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetEmbattlesDataScRsp, &.{
        .retcode = 0,
        .embattles_data = .{},
    });
}
