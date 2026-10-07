const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetCafeDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetCafeDataScRsp, &.{
        .retcode = 0,
        .cafe_data = .{
            .current_drink_id = 0,
            .today_cafe_ids = &.{},
            .day_drink_coffee_count = 0,
            .drunk_once_coffee_id_list = &.{},
        },
    });
}
