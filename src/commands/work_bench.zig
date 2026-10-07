const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn GetWorkBenchDataCsReq(session: *Session) !void {
    try session.sink.respond(protobuf.gen.GetWorkBenchDataScRsp, &.{
        .retcode = 0,
        .work_bench_data = .{
            .clue_board = .{},
            .workbench_app_ids = &.{},
        },
    });
}
