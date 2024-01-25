const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zig-json", .{ .source_file = .{ .path = "src/main.zig" } });
    defer _ = module;

    const lib = b.addStaticLibrary(.{
        .name = "zig-json",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const main_tests = b.addTest(.{
        .name = "zig-json-test",
        .root_source_file = .{.path = "src/main.zig"},
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    b.installArtifact(lib);
}
