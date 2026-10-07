const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

const default_hall_scene: protobuf.gen.SceneData = .{
    .scene_type = 1,
    .hall_scene = .{
        .section_id = 2,
        .control_avatar_id = 2021,
        .scene_time_in_minutes = 360,
        .day_of_week = 5,
    },
};

pub fn EnterWorldCsReq(session: *Session) !void {
    try session.sink.notify(protobuf.gen.EnterSceneScNotify, &.{
        .scene = default_hall_scene,
    });

    try session.sink.respond(protobuf.gen.EnterWorldScRsp, &.{
        .retcode = 0,
    });
}

pub fn EnterSectionCompleteCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.EnterSectionCompleteScRsp, &.{
        .retcode = 0,
    });
}

pub fn EnterSectionCsReq(session: *Session) !void {
    const request = try session.command.decodeBody(protobuf.gen.EnterSectionCsReq.Decoded);

    var scene = default_hall_scene;
    scene.hall_scene.?.section_id = request.section_id;

    try session.sink.notify(protobuf.gen.EnterSceneScNotify, &.{
        .scene = scene,
    });

    try session.sink.respond(protobuf.gen.EnterSectionScRsp, &.{
        .retcode = 0,
    });
}

pub fn SavePosInMainCityCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.SavePosInMainCityScRsp, &.{
        .retcode = 0,
    });
}

pub fn EnterTrainingRoomCsReq(session: *Session) !void {
    try session.sink.notify(protobuf.gen.EnterSceneScNotify, &.{
        .scene = .{
            .scene_type = 6,
        },
    });

    try session.sink.respond(protobuf.gen.EnterTrainingRoomScRsp, &.{
        .retcode = 0,
    });
}

pub fn LeaveTrainingRoomCsReq(session: *Session) !void {
    try session.sink.notify(protobuf.gen.EnterSceneScNotify, &.{
        .scene = default_hall_scene,
    });

    try session.sink.respond(protobuf.gen.LeaveTrainingRoomScRsp, &.{
        .retcode = 0,
    });
}
