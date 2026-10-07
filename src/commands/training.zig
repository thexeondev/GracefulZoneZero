const std = @import("std");

const grace = @import("../grace.zig");
const Session = grace.Session;
const protobuf = grace.protobuf;

pub fn BeginTrainingCsReq(session: *Session) !void {
    const log = std.log.scoped(.BeginTrainingCsReq);

    const request = try session.command.decodeBody(protobuf.gen.BeginTrainingCsReq.Decoded);
    log.debug("special_training_id={d}", .{request.special_training_id});

    try session.sink.respond(protobuf.gen.BeginTrainingScRsp, &.{
        .retcode = 0,
        .training_uid = session.time.toSeconds(),
    });
}

pub fn EndTrainingCsReq(session: *Session) !void {
    const log = std.log.scoped(.EndTrainingCsReq);

    const request = try session.command.decodeBody(protobuf.gen.EndTrainingCsReq.Decoded);
    log.debug("pass_time={d}, result={d}", .{ request.pass_time, request.result });

    try session.sink.respond(protobuf.gen.EndTrainingScRsp, &.{
        .retcode = 0,
    });
}
