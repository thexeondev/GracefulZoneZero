const std = @import("std");
const Build = std.Build;
const Optimize = std.lang.Optimize;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const steps = .{
        .@"test" = b.step("test", "run the tests"),
        .@"serve-dispatch" = b.step("serve-dispatch", "start the dispatch server"),
        .@"serve-sdk" = b.step("serve-sdk", "start the sdk server"),
        .@"serve-game" = b.step("serve-game", "start the game server"),
    };

    const grace_module = configureGraceModule(b, .{
        .@"test" = steps.@"test",
    }, .{
        .optimize = optimize,
        .target = target,
    });

    configureDispatchServer(b, .{
        .@"serve-dispatch" = steps.@"serve-dispatch",
    }, .{
        .optimize = optimize,
        .target = target,
        .grace_module = grace_module,
    });

    configureSdkServer(b, .{
        .@"serve-sdk" = steps.@"serve-sdk",
    }, .{
        .optimize = optimize,
        .target = target,
        .grace_module = grace_module,
    });

    configureGameServer(b, .{
        .@"serve-game" = steps.@"serve-game",
    }, .{
        .optimize = optimize,
        .target = target,
        .grace_module = grace_module,
    });
}

fn configureGraceModule(b: *Build, steps: struct {
    @"test": *Build.Step,
}, options: struct {
    optimize: Optimize,
    target: Build.ResolvedTarget,
}) *Build.Module {
    const protobuf_gen = configureProtobufCompilation(b);

    const module = b.addModule("grace", .{
        .root_source_file = b.path("src/grace.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "nap_generated", .module = protobuf_gen }},
    });

    importFilesFromDirectory(b, module, "assets/templatetb");

    const tests = b.addTest(.{ .root_module = module });
    steps.@"test".dependOn(&b.addRunArtifact(tests).step);

    return module;
}

fn configureDispatchServer(b: *Build, steps: struct {
    @"serve-dispatch": *Build.Step,
}, options: struct {
    optimize: Optimize,
    target: Build.ResolvedTarget,
    grace_module: *Build.Module,
}) void {
    const exe = b.addExecutable(.{
        .name = "grace-dispatch-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/Dispatch.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{ .module = options.grace_module, .name = "grace" }},
        }),
    });
    importFile(b, exe.root_module, "defaults/dispatch.zon");
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    steps.@"serve-dispatch".dependOn(&run.step);
}

fn configureSdkServer(b: *Build, steps: struct {
    @"serve-sdk": *Build.Step,
}, options: struct {
    optimize: Optimize,
    target: Build.ResolvedTarget,
    grace_module: *Build.Module,
}) void {
    const exe = b.addExecutable(.{
        .name = "grace-sdk-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/Sdk.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{ .module = options.grace_module, .name = "grace" }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    steps.@"serve-sdk".dependOn(&run.step);
}

const proto_dir_path = "src/protobuf/proto";

fn configureProtobufCompilation(b: *Build) *Build.Module {
    b.dependOnDirectoryContents(b.path("src/protobuf/proto"));

    const compiler = b.addExecutable(.{
        .name = "grace-compile-proto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/compile-proto.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const compile = b.addRunArtifact(compiler);
    compile.expectExitCode(0);

    const proto_dir = b.root.openDir(b.graph.io, proto_dir_path, .{ .iterate = true }) catch |err|
        std.debug.panic("failed to open dir {q}: {t}", .{ proto_dir_path, err });
    defer proto_dir.close(b.graph.io);

    var entries = proto_dir.iterateAssumeFirstIteration();
    while (entries.next(b.graph.io) catch @panic("failed to read proto dir")) |entry| {
        if (entry.kind != .file) continue;

        const file_path = b.fmt("{s}/{s}", .{ proto_dir_path, entry.name });
        compile.addFileArg2(b.path(file_path), .{});
    }

    const generated = compile.captureStdOut(.{ .basename = "nap_generated.zig" });
    return b.createModule(.{ .root_source_file = generated });
}

fn configureGameServer(b: *Build, steps: struct {
    @"serve-game": *Build.Step,
}, options: struct {
    optimize: Optimize,
    target: Build.ResolvedTarget,
    grace_module: *Build.Module,
}) void {
    const exe = b.addExecutable(.{
        .name = "grace-game-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/Game.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{ .module = options.grace_module, .name = "grace" }},
        }),
    });
    importFile(b, exe.root_module, "defaults/game.zon");
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    steps.@"serve-game".dependOn(&run.step);
}

fn importFile(b: *Build, into: *Build.Module, file_path: []const u8) void {
    into.addAnonymousImport(file_path, .{ .root_source_file = b.path(file_path) });
}

fn importFilesFromDirectory(b: *Build, into: *Build.Module, from_dir_path: []const u8) void {
    b.dependOnDirectoryContents(b.path(from_dir_path));

    const dir = b.root.openDir(b.graph.io, from_dir_path, .{ .iterate = true }) catch |err|
        std.debug.panic("failed to open dir {q}: {t}", .{ from_dir_path, err });
    defer dir.close(b.graph.io);

    var it = dir.iterateAssumeFirstIteration();
    while (it.next(b.graph.io) catch @panic("failed to read dir")) |entry| {
        if (entry.kind != .file) continue;
        const file_path = b.fmt("{s}/{s}", .{ from_dir_path, entry.name });
        importFile(b, into, file_path);
    }
}
