const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize });
    const zat = b.dependency("zat", .{ .target = target, .optimize = optimize });
    const logfire = b.dependency("logfire", .{ .target = target, .optimize = optimize });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "websocket", .module = websocket.module("websocket") },
        .{ .name = "zat", .module = zat.module("zat") },
        .{ .name = "logfire", .module = logfire.module("logfire") },
    };

    const exe = b.addExecutable(.{
        .name = "leaflet-ingester",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = imports,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the ingester");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = imports,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
