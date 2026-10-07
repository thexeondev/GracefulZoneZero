const Sdk = @This();

const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const IpAddress = std.Io.net.IpAddress;
const DefaultCsprng = std.Random.DefaultCsprng;
const Base64Decoder = std.base64.standard.Decoder;

const grace = @import("grace");
const rsa = grace.rsa;
const http = grace.http;
const json = grace.json;
const process = grace.process;

const Account = @import("Sdk/Account.zig");

pub const log = std.log.scoped(.@"grace-sdk-server");

pub const main = process.main;

pub const usage = std.fmt.comptimePrint(
    \\Usage: grace-sdk-server [options]
    \\
    \\Options:
    \\  --help, -h            Print this help and exit
    \\  --listen-address      TCP listen address; default is {q}
    \\  --concurrency         Amount of connections to be processed concurrently; default is {d}
    \\  --require-entropy     Whether to abort on entropy unavailability; default is {any}
    \\  --storage-file        On-disk account storage file path; default is {q}
    \\  --account-limit       Allowed number of accounts to register; default is {d}
    \\
, .{
    default_listen_address,
    default_concurrency,
    default_require_entropy,
    default_storage_file,
    default_account_limit,
});

const default_listen_address = "127.0.0.1:20100";
const default_concurrency: u32 = if (process.have_concurrency) 16 else 1;
const default_require_entropy = true;
const default_storage_file = "storage/sdk_accounts.bin";
const default_account_limit = 32;

const decrypt_fail_message = "Login failed. Your client patch might be unsupported.";
const name_too_long_message = "Username is too long";
const password_mismatch_message = "Account or password error";
const token_mismatch_message = "For account safety, please log in again.";

pub const Args = struct {
    @"--listen-address": []const u8 = default_listen_address,
    @"--concurrency": u32 = default_concurrency,
    @"--require-entropy": bool = default_require_entropy,
    @"--storage-file": []const u8 = default_storage_file,
    @"--account-limit": u32 = default_account_limit,
};

io: Io,
account_storage: *Account.Storage,
account_storage_mutex: Io.Mutex,
account_storage_path: []const u8,
csprng: std.Random,

pub fn start(init: process.Init, args: Args) !void {
    const static_allocator = init.static_allocator;
    const gpa = static_allocator.allocator();
    const io = init.io;

    if (args.@"--concurrency" == 0)
        process.fatal(log, "--concurrency must be greater than zero", .{});

    const address = IpAddress.parseLiteral(args.@"--listen-address") catch
        process.fatal(log, "bad --listen-address {q}", .{args.@"--listen-address"});

    var csprng_seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
    io.randomSecure(&csprng_seed) catch |err| switch (err) {
        error.Canceled => unreachable, // no
        error.EntropyUnavailable => if (args.@"--require-entropy")
            process.fatal(log, "secure entropy source is uavailable", .{})
        else
            io.random(&csprng_seed),
    };
    var csprng: DefaultCsprng = .init(csprng_seed);

    var account_storage = Account.Storage.initCapacity(
        gpa,
        args.@"--account-limit",
    ) catch |err| switch (err) {
        error.OutOfMemory => process.fatal(log,
            \\failed to allocate in-memory account storage
            \\likely cause: --account-limit is higher than the system can process
        , .{}),
    };
    defer account_storage.deinit(gpa);

    if (Io.Dir.path.dirname(args.@"--storage-file")) |dir_path|
        try Io.Dir.cwd().createDirPath(io, dir_path);

    loadAccountStorageFromFileIfExists(
        io,
        &account_storage,
        args.@"--storage-file",
    ) catch |err| switch (err) {
        error.StorageFileVersionMismatch => process.fatal(log,
            \\storage file version doesn't match
        , .{}),
        error.StorageFileOversize => process.fatal(log,
            \\storage file contents exceed --account-limit
            \\likely cause: storage file is produced by a server with higher limit
        , .{}),
        else => |e| return e,
    };

    var connections_buffer = http.Server.Connection.Buffer.init(gpa, .{
        .connection_capacity = args.@"--concurrency",
        .recv_buffer_size = 4096,
        .send_buffer_size = 4096,
    }) catch |err| switch (err) {
        error.OutOfMemory => process.fatal(log,
            \\failed to allocate memory for {d} connections
            \\likely cause: --concurrency is higher than system can process
        , .{args.@"--concurrency"}),
    };
    defer connections_buffer.deinit(gpa);

    var net_server = address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 64,
    }) catch |err| switch (err) {
        error.AddressInUse => process.fatal(log,
            \\address {qf} is already in use
            \\likely cause: another instance of this server is already running
        , .{address}),
        else => |e| return e,
    };
    defer net_server.deinit(io);

    var http_server: http.Server = .{
        .concurrent = process.have_concurrency,
        .connections_buffer = connections_buffer,
        .net_server = &net_server,
    };
    defer http_server.deinit(io);

    var sdk: Sdk = .{
        .io = io,
        .account_storage = &account_storage,
        .account_storage_mutex = .init,
        .account_storage_path = args.@"--storage-file",
        .csprng = csprng.random(),
    };

    log.info("waiting for requests at http://{f}", .{net_server.socket.address});
    defer log.info("shutting down...", .{});

    http_server.start(io, &sdk) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.ConcurrencyUnavailable => process.fatal(log,
            \\failed to allocate concurrency for {d} clients
            \\likely cause: --concurrency is higher than system can process
        , .{args.@"--concurrency"}),
    };

    static_allocator.setBehavior(.@"unreachable");
    defer static_allocator.setBehavior(.allow_dealloc);

    if (process.have_concurrency) try process.Shutdown.wait(io);
}

const mdk_shield_config_json =
    \\{"retcode":0,"message":"OK","data":{"id":31,"game_key":"nap_cn","client":"PC","identity":"I_IDENTITY","guest":false,"ignore_versions":"","scene":"S_NORMAL","name":"Nap","disable_regist":false,"enable_email_captcha":false,"thirdparty":[],"disable_mmt":false,"server_guest":false,"thirdparty_ignore":{},"enable_ps_bind_account":false,"thirdparty_login_configs":{},"initialize_firebase":false,"bbs_auth_login":false,"bbs_auth_login_ignore":[],"fetch_instance_id":false,"enable_flash_login":false,"enable_logo_18":false,"logo_height":"0","logo_width":"0","enable_cx_bind_account":false,"firebase_blacklist_devices_switch":false,"firebase_blacklist_devices_version":0,"hoyolab_auth_login":false,"hoyolab_auth_login_ignore":[],"hoyoplay_auth_login":true,"enable_douyin_flash_login":false,"enable_age_gate":false,"enable_age_gate_ignore":[]}}
;

pub fn handle(sdk: *Sdk, client: http.Server.Client) http.Server.HandleError!void {
    const Path = enum {
        @"/account/risky/api/check",
        @"/nap_global/mdk/shield/api/login",
        @"/nap_global/mdk/shield/api/verify",
        @"/nap_global/combo/granter/login/v2/login",
    };

    const path_tag_maybe = std.meta.stringToEnum(Path, client.request.line.path) orelse
        strip_prefix: {
            // findScalarPos - starting with index `1`,
            // because at index `0` there's the leading separator.
            const path = client.request.line.path;
            const next_component_index = mem.findScalarPos(u8, path, 1, '/') orelse
                break :strip_prefix null;

            break :strip_prefix std.meta.stringToEnum(Path, path[next_component_index..]);
        };

    const path_tag = path_tag_maybe orelse
        return client.respondString(.not_found, "404 Not Found");

    switch (path_tag) {
        .@"/account/risky/api/check" => try client.respondJson(.ok, .{
            .data = @as(struct {}, .{}),
            .message = "OK",
            .retcode = 0,
        }),
        .@"/nap_global/mdk/shield/api/login" => {
            serveLoginByPassword(sdk, client) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => {},
            };
        },
        .@"/nap_global/mdk/shield/api/verify" => {
            return serveVerifyToken(sdk, client);
        },
        .@"/nap_global/combo/granter/login/v2/login" => {
            return serveComboGranterLoginV2(client);
        },
    }
}

fn serveComboGranterLoginV2(client: http.Server.Client) !void {
    const Body = struct {
        data: [:0]u8,
        app_id: u32,
        channel_id: u32,
        device: []const u8,
        sign: []const u8,

        const Data = struct {
            uid: []const u8,
            token: []const u8,
            guest: bool,
        };
    };

    const body = json.parse(Body, client.request.body) catch
        return try client.respondString(.bad_request, "");

    const data = json.parse(Body.Data, body.data) catch
        return try client.respondString(.bad_request, "");

    try client.respondJson(.ok, .{
        .retcode = 0,
        .message = "OK",
        .data = .{
            .account_type = 1,
            .combo_id = data.uid,
            .combo_token = data.token,
            .data = .{ .guest = false },
            .heartbeat = false,
            .open_id = data.uid,
        },
    });
}

fn serveLoginByPassword(
    sdk: *Sdk,
    client: http.Server.Client,
) !void {
    const Body = struct {
        /// Username string
        account: []const u8,
        /// Base64-encoded
        password: []u8,
        is_crypto: bool,
    };

    const io = sdk.io;
    const body = json.parse(Body, client.request.body) catch
        return try client.respondString(.bad_request, "");

    const password = rsa.decryptString(body.password) orelse
        return try respondError(client, decrypt_fail_message);

    const username = Account.Username.fromSlice(body.account) orelse
        return try respondError(client, name_too_long_message);

    const account_new: Account = .{
        .username = username,
        .password = .init(sdk.csprng, password),
        .token = .random(sdk.csprng),
    };

    try sdk.account_storage_mutex.lock(io);
    defer sdk.account_storage_mutex.unlock(io);

    const result = sdk.account_storage.getOrInsertByUsername(
        account_new,
    ) catch |err| switch (err) {
        error.AccountStorageCapacityExceeded => {
            log.warn("account storage is full; aborting new account creation", .{});
            return try respondError(client, password_mismatch_message);
        },
    };

    const account: Account = account: {
        if (!result.found) {
            // New account has been created, save it.
            try saveAccountStorage(io, sdk);
            break :account account_new;
        } else {
            // Verify password of existing account.
            const account_old = sdk.account_storage.list.get(@backingInt(result.index));
            if (account_old.password.verify(body.password))
                break :account account_old;

            return try respondError(client, password_mismatch_message);
        }
    };

    try respondShieldLoginSuccess(
        client,
        result.index,
        &account,
    );
}

fn serveVerifyToken(
    sdk: *Sdk,
    client: http.Server.Client,
) !void {
    const Body = struct {
        uid: []const u8,
        token: []const u8,
    };

    const body = json.parse(Body, client.request.body) catch
        return try client.respondString(.bad_request, "400 Bad Request");

    const uid_int = std.fmt.parseInt(u32, body.uid, 10) catch
        return try client.respondString(.bad_request, "400 Bad Request");

    const account_index = Account.Index.fromUid(uid_int) orelse
        return try client.respondString(.bad_request, "400 Bad Request");

    const io = sdk.io;
    try sdk.account_storage_mutex.lock(io);
    defer sdk.account_storage_mutex.unlock(io);

    const account = sdk.account_storage.getByIndex(account_index) orelse
        return try respondError(client, token_mismatch_message);

    if (!account.token.eql(body.token))
        return try respondError(client, token_mismatch_message);

    try respondShieldLoginSuccess(
        client,
        account_index,
        &account,
    );
}

fn respondShieldLoginSuccess(
    client: http.Server.Client,
    account_index: Account.Index,
    account: *const Account,
) !void {
    var uid_buf: ["4294967295".len]u8 = undefined;
    const uid = mem.print(&uid_buf, "{d}", .{account_index.toUid()}) catch unreachable;

    const response = .{
        .retcode = 0,
        .message = "OK",
        .data = .{
            .account = .{
                .area_code = "**",
                .email = account.username.toSlice(),
                .country = "RU",
                .is_email_verify = "1",
                .token = &account.token.chars,
                .uid = uid,
            },
            .device_grant_required = false,
            .reactive_required = false,
            .realperson_required = false,
            .safe_mobile_required = false,
        },
    };

    try client.respondJson(.ok, response);
}

fn respondError(client: http.Server.Client, comptime msg: []const u8) !void {
    try client.respondString(.ok,
        \\{"retcode":-101,"message":"
    ++ msg ++
        \\","data":null}
    );
}

fn loadAccountStorageFromFileIfExists(
    io: Io,
    storage: *Account.Storage,
    sub_path: []const u8,
) !void {
    const file = Io.Dir.cwd().openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer file.close(io);

    // with vectored read this buffer might be not useful,
    // but some operating systems may not support
    // vectored I/O, for these it is possible
    // to lower the amount of syscalls
    // by saving data to this extra buffer especially for small files.
    var file_reader_buffer: [1024]u8 = undefined;
    var file_reader = file.readerStreaming(io, &file_reader_buffer);

    const header = file_reader.interface.takeStruct(
        Account.Storage.Header,
        .little,
    ) catch |err| switch (err) {
        error.EndOfStream => |e| return e,
        error.ReadFailed => return file_reader.err.?,
    };

    if (header.version != Account.Storage.Header.current_version)
        return error.StorageFileVersionMismatch;

    if (header.item_count > storage.list.capacity)
        return error.StorageFileOversize;

    assert(storage.list.len == 0);
    storage.list.len = header.item_count;

    var vector = storage.writableVector();
    file_reader.interface.readVecAll(&vector) catch |err| switch (err) {
        error.EndOfStream => |e| return e,
        error.ReadFailed => return file_reader.err.?,
    };

    storage.reIndexAssumeFirstIndexing();
}

fn saveAccountStorage(io: Io, sdk: *Sdk) !void {
    const file = try Io.Dir.cwd().createFile(io, sdk.account_storage_path, .{});
    defer file.close(io);

    var file_writer_buffer: [1024]u8 = undefined;
    var file_writer = file.writerStreaming(io, &file_writer_buffer);

    const header: Account.Storage.Header = .{
        .version = Account.Storage.Header.current_version,
        .item_count = @intCast(sdk.account_storage.count()),
    };
    file_writer.interface.writeAll(@ptrCast(&header)) catch return file_writer.err.?;

    var vector = sdk.account_storage.readableVector();
    file_writer.interface.writeVecAll(&vector) catch return file_writer.err.?;
    file_writer.interface.flush() catch return file_writer.err.?;
}
