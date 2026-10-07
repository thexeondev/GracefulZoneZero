const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetVhsStoreDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetVhsStoreDataScRsp, &.{
        .retcode = 0,
        .data = .{},
    });
}
