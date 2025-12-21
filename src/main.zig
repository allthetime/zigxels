const std = @import("std");
const SDL = @import("sdl2");
const ecs = @import("zflecs");

const engine_mod = @import("engine/core.zig");
const input_mod = @import("engine/input.zig");
const pixels_mod = @import("engine/pixels.zig");
const game = @import("game/systems.zig");
const components = @import("game/components.zig");

const Position = components.Position;
const Velocity = components.Velocity;
const Rectangle = components.Rectangle;
const Target = components.Target;

pub fn main() !void {
    var engine = try engine_mod.Engine.init(640, 480);
    defer engine.deinit();

    var input = input_mod.InputState{};

    // Fill pixel buffer with a gradient
    pixels_mod.makeGradient(engine.pixel_buffer, engine.width, engine.height, null);

    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.set_ctx(world, engine, dummy_free);

    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, Rectangle);
    ecs.COMPONENT(world, Target);

    _ = ecs.ADD_SYSTEM(world, "move", ecs.OnUpdate, game.move_system);
    _ = ecs.ADD_SYSTEM(world, "seek", ecs.OnUpdate, game.seek_system);
    _ = ecs.ADD_SYSTEM(world, "render", ecs.OnStore, game.render_rect_system);

    // Create Player
    const player = ecs.new_entity(world, "Player");
    _ = ecs.set(world, player, Position, .{ .x = 100.0, .y = 100.0 });
    _ = ecs.set(world, player, Velocity, .{ .x = 1.0, .y = 2.0 });
    _ = ecs.set(world, player, Rectangle, .{ .w = 50.0, .h = 50.0, .color = SDL.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });

    var last_time = SDL.getTicks64();
    var cursor_size: f32 = 20.0;

    while (!input.quit_requested) {
        engine.beginFrame();
        input.update();

        const dt = calculateDeltaTime(&last_time);

        // Handle Drag Logic
        if (input.is_pressing) {
            _ = ecs.set(world, player, Target, .{ .x = @as(f32, @floatFromInt(input.mouse_x)), .y = @as(f32, @floatFromInt(input.mouse_y)) });
        }

        // Clear & Draw Texture (Pixel Layer)
        try engine.renderer.setColorRGB(0xF7, 0xA4, 0x1D); // Background color
        try engine.renderer.clear();
        try engine.updateTexture();

        // Update ECS (Physics/Logic/Render)
        _ = ecs.progress(world, dt);

        // Render Cursor (Manual for now)
        const cursorSize = updateCursorSize(input.is_pressing, &cursor_size);
        try renderMouseCursor(engine.renderer, &input, cursorSize);

        engine.renderer.present();
    }
}

fn dummy_free(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

fn calculateDeltaTime(last_time: *u64) f32 {
    const now = SDL.getTicks64();
    const dt = @as(f32, @floatFromInt(now - last_time.*)) / 1000.0;
    last_time.* = now;
    return dt;
}

fn updateCursorSize(pressing: bool, current: *f32) i32 {
    const target: f32 = if (pressing) 5 else 10;
    const delta = lerp_delta(current.*, target, 0.1);
    current.* += delta;
    return @as(i32, @intFromFloat(current.*));
}

fn lerp_delta(current: f32, target: f32, time: f32) f32 {
    return (target - current) * time;
}

fn renderMouseCursor(renderer: SDL.Renderer, input: *input_mod.InputState, size: i32) !void {
    try renderer.setDrawBlendMode(.blend);
    try renderer.setColorRGBA(0xff, 0x00, 0x00, 0xAA);
    try renderer.fillRect(.{
        .x = input.mouse_x - @divTrunc(size, 2),
        .y = input.mouse_y - @divTrunc(size, 2),
        .width = size,
        .height = size,
    });
}
