// build.zig
const std = @import("std");
const sdl = @import("SDL2"); // Name from build.zig.zon

pub fn build(b: *std.Build) void {

    // Initialize SDL2 Sdk
    // .dep_name must match the dependency name in build.zig.zon
    const sdk = sdl.init(b, .{
        .dep_name = "SDL2",
    });

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

    sdk.link(exe, .dynamic, sdl.Library.SDL2);

    // Make SDL2 module available to pixels.zig
    root_module.addImport("sdl2", sdk.getWrapperModule());

    const zflecs = b.dependency("zflecs", .{});
    root_module.addImport("zflecs", zflecs.module("root"));
    exe.linkLibrary(zflecs.artifact("flecs"));

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run pixels");
    run_step.dependOn(&run_exe.step);
}
