const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetPartnerTrustDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetPartnerTrustDataScRsp, &.{
        .retcode = 0,
        .partner_trust_data = .{},
    });
}
