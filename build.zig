const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // KCP module
    const kcp_mod = b.addModule("kcp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Server executable
    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kcp", .module = kcp_mod },
            },
        }),
    });
    server_exe.linkLibC();
    b.installArtifact(server_exe);

    // Client executable
    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kcp", .module = kcp_mod },
            },
        }),
    });
    client_exe.linkLibC();
    b.installArtifact(client_exe);

    // Run steps
    const run_server_cmd = b.addRunArtifact(server_exe);
    const run_server_step = b.step("run-server", "Run the KCP server");
    run_server_step.dependOn(&run_server_cmd.step);

    const run_client_cmd = b.addRunArtifact(client_exe);
    const run_client_step = b.step("run-client", "Run the KCP client");
    run_client_step.dependOn(&run_client_cmd.step);

    // Tests
    const root_tests = b.addTest(.{
        .root_module = kcp_mod,
    });
    const run_root_tests = b.addRunArtifact(root_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_root_tests.step);
}
