const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetQuestDataCsReq(session: *Session) !void {
    const request = try session.command.decodeBody(protobuf.gen.GetQuestDataCsReq.Decoded);

    try session.sink.respond(protobuf.gen.GetQuestDataScRsp, &.{
        .retcode = 0,
        .quest_type = request.quest_type,
        .quest_data = .{
            .special = .{},
            .main_city = .{},
            .archive_battle = .{},
            .private_message = .{},
            .archive_file = .{},
            .hollow_challenge = .{},
            .dungeon_inner = .{},
            .hollow = .{},
            .knowledge = .{},
        },
    });
}

pub fn GetArchiveDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetArchiveDataScRsp, &.{
        .retcode = 0,
        .archive_data = .{},
    });
}

pub fn GetHollowDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetHollowDataScRsp, &.{
        .retcode = 0,
        .hollow_data = .{},
    });
}
