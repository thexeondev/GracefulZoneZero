const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;
const templates = grace.assets.templates;

pub fn VideoGetInfoCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.VideoGetInfoScRsp, &.{
        .retcode = 0,
        .keys = &.{}, // TODO
    });
}

pub fn GetFunctionSwitchCsReq(session: *Session) !void {
    const request = try session.command.decodeBody(protobuf.gen.GetFunctionSwitchCsReq.Decoded);

    try session.sink.respond(protobuf.gen.GetFunctionSwitchScRsp, &.{
        .retcode = 0,
        .type = request.type,
        .function_switch = .{
            .open_systems = &.{},
            .bgm_id = 1002,
            .switch_of_story_mode = false,
            .switch_of_qte = false,
        },
    });
}

pub fn GetMiscDataCsReq(session: *Session) !void {
    var unlock_config_ids: [templates.UnlockConfigTemplate.items.len]i32 = undefined;
    for (&unlock_config_ids, templates.UnlockConfigTemplate.items) |*id, config|
        id.* = config.id;

    var teleport_config_ids: [templates.TeleportConfigTemplate.items.len]i32 = undefined;
    for (&teleport_config_ids, templates.TeleportConfigTemplate.items) |*id, config|
        id.* = config.id;

    try session.sink.respond(protobuf.gen.GetMiscDataScRsp, &.{
        .retcode = 0,
        .data = .{
            .unlock = .{ .unlocked_id = &unlock_config_ids },
            .teleport = .{ .unlocked_id = &teleport_config_ids },
            .hollow_event = .{},
            .curse = .{},
            .hollow_card = .{},
            .hollow_item = .{},
            .newbie = .{},
            .perform = .{},
            .news_stand = .{},
        },
    });
}

pub fn GetNewsStandDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetNewsStandDataScRsp, &.{
        .retcode = 0,
        .news_stand_data = .{},
    });
}

pub fn PlayerOperationCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.PlayerOperationScRsp, &.{
        .retcode = 0,
    });
}

pub fn PlayerLogCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.PlayerLogScRsp, &.{
        .retcode = 0,
    });
}
