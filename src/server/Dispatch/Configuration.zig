const Configuration = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

const grace = @import("grace");
const rsa = grace.rsa;
const fatal = grace.process.fatal;

const log = std.log.scoped(.@"grace-dispatch-server");

/// User-facing representation.
pub const Zon = struct {
    pub const defaults: Zon = @import("defaults/dispatch.zon");

    servers: []const Server,
    versions: []const Version,

    pub const Server = struct {
        name: []const u8,
        title: []const u8,
        client_version: []const u8,
        gateway: struct {
            ip: []const u8,
            port: u16,
        },
        client_secret_key: []const u8,
    };

    pub const Version = struct {
        tag: []const u8,
        cdn: Cdn,
    };
};

// TODO: fix the naming, perhaps with custom jsonStringify
pub const Cdn = struct {
    GameResUrl: []const u8,
    P4ChangeList: u32,
    audio_revision: u32,
    data_revision: u32,
    res_revision: u32,
    silence_revision: u32,
    versions_list: []const struct {
        fileName: []const u8,
        fileSize: u32,
        fileMD5: []const u8,
    },
};

const Gateway = struct {
    client_version: []const u8,
    response: []const u8,
};

const StringMap = std.array_hash_map.String([]const u8);
const QueryGatewayMap = std.array_hash_map.String(Gateway);

arena: std.heap.ArenaAllocator,
query_dispatch_by_version: StringMap,
query_dispatch_fallback_response: []const u8,
query_gateway_by_server: QueryGatewayMap,
query_gateway_fallback_response: []const u8,

const default_query_gateway_fallback_response =
    \\{"retcode":1}
;

pub const Options = struct {
    zon: *const Zon,
    outer_url: []const u8,
};

pub fn build(gpa: Allocator, options: Options) Allocator.Error!Configuration {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    const query_dispatch_by_version = try buildQueryDispatchByVersion(
        arena.allocator(),
        options,
    );
    const query_dispatch_fallback_response = try buildQueryDispatchFallbackResponse(
        arena.allocator(),
        options,
    );
    const query_gateway_by_server = try buildQueryGatewayByServer(
        arena.allocator(),
        options,
    );

    return .{
        .arena = arena,
        .query_dispatch_by_version = query_dispatch_by_version,
        .query_dispatch_fallback_response = query_dispatch_fallback_response,
        .query_gateway_by_server = query_gateway_by_server,
        .query_gateway_fallback_response = default_query_gateway_fallback_response,
    };
}

pub fn deinit(conf: *Configuration) void {
    conf.arena.deinit();
    conf.* = undefined;
}

fn buildQueryDispatchByVersion(arena: Allocator, options: Options) Allocator.Error!StringMap {
    var query_dispatch_by_version: StringMap = .empty;
    try query_dispatch_by_version.ensureTotalCapacity(arena, options.zon.versions.len);

    for (options.zon.versions) |*version| {
        var allocating: Io.Writer.Allocating = .init(arena);
        var stringify: Stringify = .{ .writer = &allocating.writer };
        stringifyQueryDispatchForVersion(&stringify, options, version.tag) catch |err|
            switch (err) {
                error.WriteFailed => return error.OutOfMemory,
            };

        const response = allocating.written();
        if (response.len == 0) {
            log.warn("no servers configured for version {q}", .{version.tag});
            continue;
        }

        query_dispatch_by_version.putAssumeCapacity(version.tag, response);
    }

    return query_dispatch_by_version;
}

/// If no servers are configured for this version, nothing is written.
fn stringifyQueryDispatchForVersion(
    stringify: *Stringify,
    options: Options,
    version: []const u8,
) Io.Writer.Error!void {
    var any_server_matched: bool = false;

    for (options.zon.servers) |*server| {
        if (!mem.eql(u8, server.client_version, version)) continue;

        if (!any_server_matched) {
            try stringify.beginObject();
            try stringify.objectField("region_list");
            try stringify.beginArray();

            any_server_matched = true;
        }

        const DispatchUrl = struct {
            prefix: []const u8,
            server_name: []const u8,

            pub fn jsonStringify(url: *const @This(), s: *Stringify) !void {
                try s.print("\"{s}/query_gateway/{s}\"", .{ url.prefix, url.server_name });
            }
        };

        try stringify.write(.{
            .retcode = 0,
            .name = server.name,
            .title = server.title,
            .dispatch_url = @as(DispatchUrl, .{
                .prefix = options.outer_url,
                .server_name = server.name,
            }),
            .biz = "nap_global",
            .env = 2,
        });
    }

    if (any_server_matched) {
        try stringify.endArray();
        try stringify.objectField("retcode");
        try stringify.write(@as(i32, 0));
        try stringify.endObject();
    }
}

fn buildQueryDispatchFallbackResponse(
    arena: Allocator,
    options: Options,
) Allocator.Error![]const u8 {
    var response_message: std.ArrayList(u8) = .empty;
    var any_appended: bool = false;

    for (options.zon.versions) |*version| {
        const has_any_server = for (options.zon.servers) |*server| {
            if (mem.eql(u8, server.client_version, version.tag))
                break true;
        } else false;

        if (!has_any_server) continue;

        if (!any_appended) {
            try response_message.appendSlice(arena,
                \\Your game version is not supported.
                \\Supported versions: 
            );

            any_appended = true;
        } else {
            try response_message.appendSlice(arena, ", ");
        }

        try response_message.appendSlice(arena, version.tag);
    }

    if (any_appended) {
        assert(response_message.items.len != 0);
        return try arena.print(
            \\{{"retcode":72,"msg":{q}}}
        , .{response_message.items});
    } else {
        return
        \\{"retcode":71}
        ;
    }
}

fn buildQueryGatewayByServer(arena: Allocator, options: Options) Allocator.Error!QueryGatewayMap {
    var query_gateway_by_server: QueryGatewayMap = .empty;
    try query_gateway_by_server.ensureTotalCapacity(arena, options.zon.servers.len);

    for (options.zon.servers) |*server| {
        const version = for (options.zon.versions) |*version| {
            if (mem.eql(u8, server.client_version, version.tag))
                break version;
        } else {
            log.warn("server {q} refers to a non-existent version {q}, skipping", .{
                server.name,
                server.client_version,
            });
            continue;
        };

        const server_dispatch_data = .{
            .retcode = 0,
            .region_name = server.name,
            .title = server.title,
            .env = 2,
            .oaserver_url = "",
            .gateway = server.gateway,
            .client_secret_key = server.client_secret_key,
            .cdn_conf_ext = version.cdn,
            .region_ext = .{ .func_switch = .{
                .disableExecuteAsync = 0,
                .disableSRPHelper = 0,
                .disableiOSShaderHibernation = 0,
                .disableiOSGPUBufferOpt = 0,
                .disableSkinMeshStrip = 0,
                .disableTexStreamingVisbilityOpt = 0,
                .enableiOSShaderWarmupOnStartup = 0,
                .disableSRPInstancing = 0,
                .disableObjectInstanceCache = 0,
                .disableMetalPSOCreateAsync = 0,
            } },
        };

        const content_plain = try arena.print("{f}", .{std.json.fmt(server_dispatch_data, .{})});
        const content_encrypted = try rsa.encryptAlloc(arena, content_plain);

        var sign: rsa.Block = undefined;
        rsa.server_private_key.sign(&sign, content_plain);

        const response = try arena.print(
            \\{{"content":"{b64}","sign":"{b64}"}}
        , .{ content_encrypted, &sign });

        query_gateway_by_server.putAssumeCapacity(server.name, .{
            .client_version = server.client_version,
            .response = response,
        });
    }

    return query_gateway_by_server;
}
