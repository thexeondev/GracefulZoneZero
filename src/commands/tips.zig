const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetTipsDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetTipsDataScRsp, &.{
        .retcode = 0,
        .data = .{
            .tips = .{},
            .fairy = .{},
            .popup_window = .{},
            .loading_page_tips = .{},
        },
    });
}
