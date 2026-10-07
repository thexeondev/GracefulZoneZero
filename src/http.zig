const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

pub const Server = @import("http/Server.zig");

pub const Version = enum {
    @"HTTP/1.0",
    @"HTTP/1.1",
};

pub const Request = struct {
    const headers_max = 64;

    line: Line,
    body: [:0]u8,

    pub const Method = enum {
        GET,
        POST,
    };

    pub const ParseError = Cutter.Error || error{
        HttpHeadersInvalid,
        HttpVersionUnsupported,
        HttpMethodUnsupported,
    };

    pub const Parsed = struct {
        consumed_bytes: usize,
        request: Request,
    };

    pub fn parse(buffer: []u8, readable_size: usize) ParseError!Parsed {
        const readable_bytes = buffer[0..readable_size];

        var cutter: Cutter = .init(readable_bytes);
        const line_string = try cutter.take('\n');
        const line: Line = try .parse(line_string);

        var headers: Header.Iterator = .{ .cutter = &cutter };
        var headers_count: u32 = 0;
        var content_length: u31 = 0;

        while (try headers.next()) |header| : (headers_count += 1) {
            if (headers_count > headers_max)
                return error.HttpHeadersInvalid;

            if (std.ascii.eqlIgnoreCase(header.key, "content-length")) {
                content_length = std.fmt.parseInt(u31, header.value, 10) catch
                    return error.HttpHeadersInvalid;
            }
        }

        const body_offset = readable_size - cutter.remaining.len;

        if (body_offset + content_length > readable_size)
            return error.ShortInput;

        if (body_offset + content_length + 1 > buffer.len)
            return error.HttpHeadersInvalid;

        buffer[body_offset + content_length] = 0;
        const body: [:0]u8 = @ptrCast(buffer[body_offset..][0..content_length]);
        assert(body[body.len] == 0);

        return .{
            .consumed_bytes = body_offset + content_length,
            .request = .{
                .line = line,
                .body = @ptrCast(body),
            },
        };
    }

    pub const Line = struct {
        version: Version,
        method: Method,
        path: []const u8,
        query: []const u8,

        pub fn parse(line: []u8) ParseError!Line {
            if (line.len == 0 or line[line.len - 1] != '\r')
                return error.HttpHeadersInvalid;

            var cutter: Cutter = .init(line);
            const method_string = try cutter.take(' ');
            const method_tag = std.meta.stringToEnum(Method, method_string) orelse
                return error.HttpMethodUnsupported;

            const target = try cutter.take(' ');
            const path_string, const query_string = mem.cutScalar(u8, target, '?') orelse
                .{ target, "" };

            const version_string = try cutter.take('\r');
            const version_tag = std.meta.stringToEnum(Version, version_string) orelse
                return error.HttpVersionUnsupported;

            return .{
                .version = version_tag,
                .method = method_tag,
                .path = path_string,
                .query = query_string,
            };
        }
    };
};

const Cutter = struct {
    remaining: []u8,

    pub fn init(buffer: []u8) Cutter {
        return .{ .remaining = buffer };
    }

    pub const Error = error{ShortInput};

    pub fn take(cutter: *Cutter, delimiter: u8) Error![]u8 {
        const cut, const rest = mem.cutScalar(u8, cutter.remaining, delimiter) orelse
            return error.ShortInput;

        cutter.remaining = @constCast(rest);
        return @constCast(cut);
    }
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,

    const Iterator = struct {
        cutter: *Cutter,

        fn next(it: *Iterator) !?Header {
            const line = try it.cutter.take('\n');
            if (line.len == 0 or line[line.len - 1] != '\r')
                return error.HttpHeadersInvalid;

            if (line.len == 1) return null;

            const pair = line[0 .. line.len - 1];

            const key, const value = mem.cut(u8, pair, ": ") orelse
                return error.HttpHeadersInvalid;

            return .{ .key = key, .value = value };
        }
    };
};

pub const query = struct {
    pub fn parseFromSlice(comptime T: type, slice: []const u8) ?T {
        const Field = std.meta.FieldEnum(T);
        var seen_fields: std.EnumSet(Field) = .empty;
        var result: T = undefined;

        var it = mem.splitScalar(u8, slice, '&');
        while (it.next()) |entry| {
            const key_string, const value = mem.cutScalar(u8, entry, '=') orelse
                return null;

            const key = std.meta.stringToEnum(Field, key_string) orelse continue;

            if (seen_fields.contains(key)) return null;
            seen_fields.insert(key);

            switch (key) {
                inline else => |key_comptime| {
                    @field(result, @tagName(key_comptime)) = value;
                },
            }
        }

        return if (seen_fields.eql(.full)) result else null;
    }
};
