const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetRamenDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetRamenDataScRsp, &.{
        .retcode = 0,
        .ramen_data = .{
            .unlock_ramen = &.{},
            .cur_ramen_id = 0,
            .new_flag_unlock_ramen_list = &.{},
            .is_show_new_ramen = false,
            .random_attr_id_list = &.{},
            .used_times = 0,
            .unlock_initiative_item = &.{},
            .unlock_initiative_item_group = &.{},
        },
    });
}
