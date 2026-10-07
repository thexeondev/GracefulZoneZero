const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetMailCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetMailScRsp, &.{
        .retcode = 0,
        .start = 0,
        .is_end = true,
        .mail_list = &.{},
    });
}
