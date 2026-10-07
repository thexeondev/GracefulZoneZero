const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn PlayerLoginCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.PlayerLoginScRsp, &.{
        .retcode = 0,
    });
}

pub fn KeepAliveNotify(session: *Session) !void {
    _ = session;
}

pub fn GetPlayerBasicInfoCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetPlayerBasicInfoScRsp, &.{
        .retcode = 0,
        .basic_info = .{
            .nick_name = "xeondev",
            .level = 1,
            .exp = 0,
            .avatar_id = 2021,
            .control_avatar_id = 2021,
            .name_change_times = 1,
            .portrait_id = 0,
            .role_create_time = 0,
            .is_guest = false,
        },
    });
}

pub fn GetServerTimestampCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetServerTimestampScRsp, &.{
        .retcode = 0,
        .timestamp = @intCast(session.time.toMilliseconds()),
        .utc_offset = 3, // TODO: move this to config
    });
}

pub fn GetPlayerTransactionCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetPlayerTransactionScRsp, &.{
        .retcode = 0,
        .transaction = "1337-1",
    });
}
