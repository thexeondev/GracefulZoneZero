const std = @import("std");
const ArrayList = std.ArrayList;

const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;
const templates = grace.assets.templates;

pub fn GetAvatarDataCsReq(session: *Session) !void {
    var avatars_buf: [templates.AvatarConfigTemplate.items.len]protobuf.gen.AvatarInfo = undefined;
    var avatars: ArrayList(protobuf.gen.AvatarInfo) = .initBuffer(&avatars_buf);
    for (templates.AvatarConfigTemplate.items) |*config| {
        if (config.id >= 2_000) continue;

        avatars.appendAssumeCapacity(.{
            .id = config.id,
            .level = 1,
            .rank = 1,
            .exp = 0,
            .star = 0,
            .talent = 0,
            .cur_weapon_uid = 0,
            .skill_level_list = &skill_level_list,
            .dressed_equip_list = &.{},
        });
    }

    try session.sink.respond(protobuf.gen.GetAvatarDataScRsp, &.{
        .retcode = 0,
        .avatar_list = avatars.items,
    });
}

const skill_level_list: [6]protobuf.gen.AvatarSkillLevel = list: {
    var array: [6]protobuf.gen.AvatarSkillLevel = undefined;
    for (&array, 0..) |*data, skill_type|
        data.* = .{
            .skill_type = @intCast(skill_type),
            .level = 1,
        };

    break :list array;
};
