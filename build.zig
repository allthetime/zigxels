// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");

    const sdl_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/engine/sdl3.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_tc.addIncludePath(sdl_dep.path("include"));
    const sdl_mod = sdl_tc.createModule();

    const zflecs = b.dependency("zflecs", .{
        .target = target,
        .optimize = optimize,
    });

    const zig_c2 = b.createModule(.{
        .root_source_file = b.path("lib/cute_c2/zoot_c2.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("sdl3", sdl_mod);
    root_module.linkLibrary(sdl_lib);
    root_module.addImport("zflecs", zflecs.module("root"));
    root_module.linkLibrary(zflecs.artifact("flecs"));
    root_module.addImport("zig_c2", zig_c2);

    const exe = b.addExecutable(.{
        .name = "pixels",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run pixels");
    run_step.dependOn(&run_exe.step);

    const tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
