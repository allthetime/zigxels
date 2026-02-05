const std = @import("std");
const SDL = @import("sdl2");
const ecs = @import("zflecs");

const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stdio.h");
});

const collision = @cImport({
    @cInclude("cute_c2/cute_c2.h");
});

const c2 = @import("cute_c2");
const z2 = @import("zig_c2");

const Bencher = @import("utils/benchmark.zig").Bencher;

const engine_mod = @import("engine/core.zig");
const input_mod = @import("engine/input.zig");
const pixels_mod = @import("engine/pixels.zig");
const game = @import("game/systems.zig");
const components = @import("game/components.zig");

// physics
const Position = components.Position;
const Velocity = components.Velocity;
const Target = components.Target;
const Box = components.Box; // rendery

// render
const Rectangle = components.Rectangle;

// tags
const Bullet = components.Bullet;
const Player = components.Player;
const Ground = components.Ground;

// groups
const BulletsGroup = components.BulletsGroup;

fn usize_to_f32(i: usize) f32 {
    return @as(f32, @floatFromInt(i));
}

const HEIGHT: usize = 768;
const WIDTH: usize = 1024;

fn runC2Loop(i: usize) void {
    const circle = collision.c2Circle{ .p = .{ .x = @as(f32, @floatFromInt(i % 100)), .y = @as(f32, @floatFromInt(i % 100)) }, .r = 5.0 };
    const box = collision.c2AABB{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 20, .y = 20 } };
    const collided = collision.c2CircletoAABB(circle, box) == 1;
    std.mem.doNotOptimizeAway(collided);
}

fn runZ2Loop(i: usize) void {
    const circle: z2.Circle = .{ .p = .{ .x = @as(f32, @floatFromInt(i % 100)), .y = @as(f32, @floatFromInt(i % 100)) }, .r = 5.0 };
    const box: z2.AABB = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 20, .y = 20 } };
    const collided = z2.circleToAABB(circle, box);
    std.mem.doNotOptimizeAway(collided);
}

fn tests() void {
    // Benchmarking Setup
    var bench = try Bencher(&.{
        .{ .name = "C2 Optimized Loop", .func = &runC2Loop },
        .{ .name = "Z2 Standard Loop", .func = &runZ2Loop },
    }).init(10_000_000);
    bench.runAll();

    const circle = collision.c2Circle{ .p = .{ .x = 10, .y = 10 }, .r = 5.0 };
    const box = collision.c2AABB{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 20, .y = 20 } };

    const c2_circle: c2.Circle = .{ .p = c2.vec2(10, 10), .r = 5.0 };
    const c2_box = c2.AABB{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 20, .y = 20 } };

    const hit = collision.c2CircletoAABB(circle, box);
    std.debug.print("Collision detected: {}\n", .{hit != 0});
    if (c2.check(c2_circle, c2_box)) {
        std.debug.print("Collision detected----!\n", .{});
    }

    // do the same for z2 lib
    const z2_circle: z2.Circle = .{ .p = z2.Vec2{ .x = 10, .y = 10 }, .r = 5.0 };
    const z2_box: z2.AABB = .{ .min = z2.Vec2{ .x = 0, .y = 0 }, .max = z2.Vec2{ .x = 20, .y = 20 } };
    if (z2.circleToAABB(z2_circle, z2_box)) {
        std.debug.print("Z2 Collision detected----!\n", .{});
    }
}

pub fn main() !void {
    var engine = try engine_mod.Engine.init(WIDTH, HEIGHT);
    defer engine.deinit();

    var input = input_mod.InputState{};

    // Generate gradient ONCE and store it in background_buffer (using SIMD-optimized version)
    pixels_mod.makeGradientSIMD(engine.background_buffer, engine.width, engine.height);
    // Copy to working buffer initially
    @memcpy(engine.pixel_buffer, engine.background_buffer);

    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.set_ctx(world, &engine, dummy_free);
    setup_game(world, &engine);

    var last_time = SDL.getTicks64();
    var cursor_size: f32 = 20.0;

    // Bullets Group to parent all bullets for easy dismissal and effect

    const bullets_group = ecs.new_entity(world, "Bullets");
    // 3. Store it in the Singleton
    _ = ecs.singleton_set(world, components.BulletsGroup, .{ .entity = bullets_group });

    while (!input.quit_requested) {
        engine.beginFrame();
        input.update();

        _ = ecs.singleton_set(world, input_mod.InputState, input);
        const dt = calculateDeltaTime(&last_time);

        try engine.renderer.setColorRGB(0xF7, 0xA4, 0x1D); // Background color
        try engine.renderer.clear();
        try engine.updateTexture();
        engine.restoreBackground();

        _ = ecs.progress(world, dt);

        const cursorSize = updateCursorSize(input.is_pressing, &cursor_size);
        try renderMouseCursor(engine.renderer, &input, cursorSize);

        if (input.reset) {
            reset_game(world, &engine);
            input.reset = false;
        }

        engine.renderer.present();
    }
}

fn reset_game(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    // delete all bullets
    if (ecs.singleton_get(world, components.BulletsGroup)) |group| {
        // Delete everything linked to this parent
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }
    if (ecs.singleton_get(world, components.PlayerContainer)) |pc| {
        const player_entity = pc.entity;
        // Reset Player Position
        _ = ecs.set(world, player_entity, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 2.0 });
        _ = ecs.set(world, player_entity, Velocity, .{ .x = 0.0, .y = 0.0 });
    }
}

fn dummy_free(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

fn calculateDeltaTime(last_time: *u64) f32 {
    const now = SDL.getTicks64();
    const dt = @as(f32, @floatFromInt(now - last_time.*)) / 1000.0;
    last_time.* = now;
    // Cap delta time to prevent large jumps (e.g., first frame or lag)
    return @min(dt, 1.0 / 60.0); // Max 60 FPS equivalent
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

pub fn setup_game(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    register_components(world);
    register_systems(world);
    spawn_initial_entities(world, engine);
}

fn register_components(world: *ecs.world_t) void {
    ecs.COMPONENT(world, input_mod.InputState);
    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, Rectangle);
    ecs.COMPONENT(world, Target);
    ecs.COMPONENT(world, BulletsGroup);
    ecs.COMPONENT(world, Box);
    ecs.TAG(world, Bullet);
    ecs.TAG(world, Player);
    ecs.TAG(world, Ground);
    ecs.COMPONENT(world, components.PlayerContainer);
}

fn register_systems(world: *ecs.world_t) void {
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_input_logic", ecs.PreUpdate, game.player_input_system, &.{
        .{ .id = ecs.id(Player) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "shoot", ecs.OnUpdate, game.shoot_system, &.{
        .{ .id = ecs.id(Player) },
        .{ .id = ecs.id(Position) }, // (Redundant if inferred, but harmless)
    });

    _ = ecs.ADD_SYSTEM(world, "seek", ecs.OnUpdate, game.seek_system);
    _ = ecs.ADD_SYSTEM(world, "gravity", ecs.OnUpdate, game.gravity_system);

    // Separated Axis Movement & Collision
    _ = ecs.ADD_SYSTEM(world, "move_x", ecs.OnUpdate, game.move_x_system);
    _ = ecs.ADD_SYSTEM(world, "ground_collision_x", ecs.OnUpdate, game.ground_collision_x_system);
    _ = ecs.ADD_SYSTEM(world, "move_y", ecs.OnUpdate, game.move_y_system);
    _ = ecs.ADD_SYSTEM(world, "ground_collision_y", ecs.OnUpdate, game.ground_collision_y_system);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_clamp", ecs.OnUpdate, game.player_clamp_system, &.{
        .{ .id = ecs.id(Player) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "bullet_cleanup", ecs.OnUpdate, game.bullet_cleanup_system, &.{
        .{ .id = ecs.id(Bullet) },
    });

    _ = ecs.ADD_SYSTEM(world, "render", ecs.OnStore, game.render_rect_system);
    _ = ecs.ADD_SYSTEM(world, "pixel_boxer", ecs.OnStore, game.render_pixel_box);
}

fn spawn_initial_entities(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    const player = ecs.new_entity(world, "Player");
    _ = ecs.set(world, player, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 2.0 });
    _ = ecs.set(world, player, Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, Rectangle, .{ .w = 50.0, .h = 50.0, .color = SDL.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    _ = ecs.add(world, player, Player);
    _ = ecs.set(world, player, Box, .{ .size = 25 });

    _ = ecs.singleton_set(world, components.PlayerContainer, .{ .entity = player });

    const ground1 = ecs.new_entity(world, "Ground1");
    _ = ecs.add(world, ground1, Ground);
    _ = ecs.set(world, ground1, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 1.5 });
    _ = ecs.set(world, ground1, Box, .{ .size = 25 });
}
