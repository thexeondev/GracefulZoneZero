const Configuration = @This();

const std = @import("std");
const base64 = std.base64;

const grace = @import("grace");
const process = grace.process;
const Xorpad = grace.protocol.Xorpad;

const log = std.log.scoped(.@"grace-game-server");

pub const Zon = struct {
    pub const defaults: Zon = @import("defaults/game.zon");

    // base64
    xorpad: []const u8,
};

pub const Options = struct { zon: *const Zon };

xorpad: Xorpad,

pub fn build(options: Options) Configuration {
    if ((base64.standard.Decoder.calcSizeForSlice(options.zon.xorpad) catch 0) != @sizeOf(Xorpad))
        process.fatal(log, "invalid 'xorpad' in configuration file", .{});

    var xorpad: Xorpad = undefined;
    base64.standard.Decoder.decode(&xorpad, options.zon.xorpad) catch |err|
        process.fatal(log, "failed to decode 'xorpad' from configuration file: {t}", .{err});

    return .{
        .xorpad = xorpad,
    };
}
