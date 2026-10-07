const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetItemDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetItemDataScRsp, &.{
        .retcode = 0,
        .weapon_list = &.{},
        .material_list = &.{},
        .equipment_list = &.{},
        .auto_recovery_info = &.{},
    });
}
