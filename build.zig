// build.zig
const std = @import("std");
const sdl = @import("SDL2"); // Name from build.zig.zon

pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "pixels",
        .root_module = root_module,
    });

    // SDL2

    const sdk = sdl.init(b, .{
        .dep_name = "SDL2",
    });
    sdk.link(exe, .dynamic, sdl.Library.SDL2);
    root_module.addImport("sdl2", sdk.getWrapperModule());

    // zflecs

    const zflecs = b.dependency("zflecs", .{});
    root_module.addImport("zflecs", zflecs.module("root"));
    exe.linkLibrary(zflecs.artifact("flecs"));

    // tinyc2
    // gemini zig rewrite

    const antigravity_c2 = b.createModule(.{
        .root_source_file = b.path("lib/cute_c2/zoot_c2.zig"),
    });
    root_module.addImport("zig_c2", antigravity_c2);

    // TESTS

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run pixels");
    run_step.dependOn(&run_exe.step);
}
