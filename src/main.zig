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
const Collider = components.Collider;
const PhysicsBody = components.PhysicsBody;

// render
const Renderable = components.Renderable;
const ExplosionParticle = components.ExplosionParticle;

// tags
const Bullet = components.Bullet;
const Player = components.Player;
const Ground = components.Ground;
const Gun = components.Gun;
const Destroyable = components.Destroyable;

// groups
const BulletsGroup = components.BulletsGroup;

// state singletons
const PlayerContainer = components.PlayerContainer;
const PhysicsState = components.PhysicsState;

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

pub fn main() !void {
    var engine = try engine_mod.Engine.init(WIDTH, HEIGHT);
    defer engine.deinit();

    var input = input_mod.InputState{};

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

    // Generate gradient ONCE and store it in sky_buffer
    pixels_mod.makeGradientSIMD(engine.sky_buffer, engine.width, engine.height);
    // Copy to background buffer initially
    @memcpy(engine.background_buffer, engine.sky_buffer);
    // Copy to working buffer initially
    @memcpy(engine.pixel_buffer, engine.background_buffer);

    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.set_ctx(world, &engine, dummy_free);
    try setup_game(world, &engine);

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

        // Handle Mouse Press to Set Target
        if (input.is_pressing) {
            // _ = ecs.set(world, player, Target, .{ .x = @as(f32, @floatFromInt(input.mouse_x)), .y = @as(f32, @floatFromInt(input.mouse_y)) });
        }

        // SHOOTING LOGIC REMOVED -> Handled by shoot_system in systems.zig

        // Update ECS (Physics/Logic/Render)

        // Clear & Draw Texture (Pixel Layer)
        // Note: Using restoreBackground is faster than clear() if we just overwrite everything
        engine.restoreBackground();

        // Progress World
        _ = ecs.progress(world, dt);

        // Upload the pixel buffer to the GPU texture
        try engine.updateTexture();

        // Render Cursor (Manual for now, on top of everything)
        const cursorSize = updateCursorSize(input.is_pressing, &cursor_size);
        try renderMouseCursor(engine.renderer, &input, cursorSize);

        if (input.reset) {
            // delete all bullets
            if (ecs.singleton_get(world, components.BulletsGroup)) |group| {
                // Delete everything linked to this parent
                ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
            }
            if (ecs.singleton_get(world, PlayerContainer)) |pc| {
                const player_entity = pc.entity;
                // Reset Player Position
                _ = ecs.set(world, player_entity, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 2.0 });
                _ = ecs.set(world, player_entity, Velocity, .{ .x = 0.0, .y = 0.0 });
            }

            // Reset Level
            ecs.delete_with(world, ecs.id(Ground));
            @memcpy(engine.background_buffer, engine.sky_buffer);
            spawn_level(world, &engine);

            input.reset = false;
        }

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

pub fn setup_game(world: *ecs.world_t, engine: *engine_mod.Engine) !void {
    register_components(world);
    register_systems(world);
    try spawn_initial_entities(world, engine);
}

fn register_components(world: *ecs.world_t) void {
    ecs.COMPONENT(world, input_mod.InputState);
    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, Renderable);
    ecs.COMPONENT(world, Target);
    ecs.COMPONENT(world, BulletsGroup);
    ecs.COMPONENT(world, Collider);
    ecs.COMPONENT(world, PlayerContainer);
    ecs.COMPONENT(world, PhysicsState);
    ecs.COMPONENT(world, Gun);
    ecs.COMPONENT(world, ExplosionParticle);

    // TAGS (size 0)
    ecs.TAG(world, Bullet);
    ecs.TAG(world, Player);
    ecs.TAG(world, Ground);
    ecs.COMPONENT(world, PhysicsBody);
    // ecs.TAG(world, Gun);
    ecs.TAG(world, Destroyable);
}

fn register_systems(world: *ecs.world_t) void {
    // 1. Player Controller (Handling Input + Movement + Collision)
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_controller", ecs.OnUpdate, game.player_controller_system, &.{
        .{ .id = ecs.id(Player) },
        .{ .id = ecs.id(Position) },
        .{ .id = ecs.id(Velocity) },
        .{ .id = ecs.id(Collider) },
    });

    _ = ecs.ADD_SYSTEM(world, "seek", ecs.OnUpdate, game.seek_system);

    // Gravity (Generic: Requires PhysicsBody)
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "gravity", ecs.OnUpdate, game.gravity_system, &.{
        .{ .id = ecs.id(Velocity) },
        .{ .id = ecs.id(PhysicsBody) },
    });

    // Shoot system (explicit filter for Player)
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "shoot", ecs.OnUpdate, game.shoot_system, &.{
        .{ .id = ecs.id(Gun) },
        .{ .id = ecs.id(Position) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "gun_aim", ecs.OnUpdate, game.gun_aim_system, &.{
        .{ .id = ecs.id(Gun) },
        .{ .id = ecs.id(Position) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "physics_movement", ecs.OnUpdate, game.physics_movement_system, &.{
        .{ .id = ecs.id(Position) },
        .{ .id = ecs.id(Velocity) },
        .{ .id = ecs.id(PhysicsBody) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "physics_collision", ecs.OnUpdate, game.physics_collision_system, &.{
        .{ .id = ecs.id(Position) },
        .{ .id = ecs.id(Velocity) },
        .{ .id = ecs.id(Collider) },
        .{ .id = ecs.id(PhysicsBody) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_clamp", ecs.OnUpdate, game.player_clamp_system, &.{
        .{ .id = ecs.id(Player) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "bullet_cleanup", ecs.OnUpdate, game.bullet_cleanup_system, &.{
        .{ .id = ecs.id(Bullet) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "explosion", ecs.OnUpdate, game.explosion_system, &.{
        .{ .id = ecs.id(Position) },
        .{ .id = ecs.id(Velocity) },
        .{ .id = ecs.id(components.ExplosionParticle) },
    });

    // Single unified pixel render system
    _ = ecs.ADD_SYSTEM(world, "render", ecs.OnStore, game.render_system);
}

fn spawn_initial_entities(world: *ecs.world_t, engine: *engine_mod.Engine) !void {
    const player = ecs.new_entity(world, "Player");
    _ = ecs.set(world, player, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 2.0 });
    _ = ecs.set(world, player, Velocity, .{ .x = 0.0, .y = 0.0 });
    // _ = ecs.set(world, player, Collider, .{ .box = .{ .min = .{ .x = -25, .y = -25 }, .max = .{ .x = 25, .y = 25 } } });
    _ = ecs.set(world, player, Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 15 } });
    _ = ecs.set(world, player, Renderable, .{ .color = SDL.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    ecs.add(world, player, Player);
    _ = ecs.singleton_set(world, PlayerContainer, .{ .entity = player });

    // we have a gun
    // this element is positioned relative to the player and is a child of the player
    const gun = ecs.new_entity(world, "Gun");
    // For simplicity we write gun world position; gun_aim_system will overwrite it at runtime.
    _ = ecs.set(world, gun, Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, gun, Renderable, .{ .color = SDL.Color{ .r = 0, .g = 0, .b = 255, .a = 255 } });
    // Small box collider so it renders via render_system (width x height)
    _ = ecs.set(world, gun, Collider, .{
        .box = .{ .min = .{ .x = -4, .y = -4 }, .max = .{ .x = 4, .y = 4 } },
    });
    _ = ecs.set(world, gun, Gun, .{
        .fire_rate = 0.05,
    });
    // ecs.add(world, gun, PhysicsBody);
    _ = ecs.add_pair(world, gun, ecs.ChildOf, player);

    spawn_level(world, engine);

    // Cache the Ground Query for Physics Systems
    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = ecs.id(Ground) };
    desc.terms[1] = .{ .id = ecs.id(Position), .inout = .In };
    desc.terms[2] = .{ .id = ecs.id(Collider), .inout = .In };
    const ground_q = ecs.query_init(world, &desc) catch unreachable;
    _ = ecs.singleton_set(world, components.PhysicsState, .{ .ground_query = ground_q });
}

fn spawn_level(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    const cx1 = @as(f32, @floatFromInt(engine.width)) / 2.0;
    const cy1 = @as(f32, @floatFromInt(engine.height)) / 1.5;
    spawnGroundGrid(world, cx1 - 150, cy1 - 25, 300, 50);

    const cx2 = @as(f32, @floatFromInt(engine.width)) / 2.0 - 200;
    const cy2 = @as(f32, @floatFromInt(engine.height)) / 1.5 - 100;
    spawnGroundGrid(world, cx2 - 100, cy2 - 10, 200, 20);

    const cx3 = @as(f32, @floatFromInt(engine.width)) / 2.0 + 100;
    const cy3 = @as(f32, @floatFromInt(engine.height)) / 1.5 - 60;
    spawnGroundGrid(world, cx3 - 50, cy3 - 10, 100, 20);

    const floor = ecs.new_entity(world, "Floor");
    _ = ecs.set(world, floor, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) - 50.0 });
    _ = ecs.set(world, floor, Collider, .{ .box = .{ .min = .{ .x = -@as(f32, @floatFromInt(engine.width)) / 2.0, .y = -50.0 }, .max = .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = 50 } } });
    _ = ecs.set(world, floor, Renderable, .{ .color = SDL.Color{ .r = 0, .g = 255, .b = 0, .a = 255 } });
    ecs.add(world, floor, Ground);
}

fn spawnGroundGrid(world: *ecs.world_t, start_x: f32, start_y: f32, width: f32, height: f32) void {
    const tile_size: f32 = 5.0;
    const cols = @as(usize, @intFromFloat(width / tile_size));
    const rows = @as(usize, @intFromFloat(height / tile_size));

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        var c_: usize = 0;
        while (c_ < cols) : (c_ += 1) {
            const e = ecs.new_id(world);
            ecs.add(world, e, Ground);

            const tx = start_x + (@as(f32, @floatFromInt(c_)) * tile_size) + (tile_size / 2.0);
            const ty = start_y + (@as(f32, @floatFromInt(r)) * tile_size) + (tile_size / 2.0);

            _ = ecs.set(world, e, Position, .{ .x = tx, .y = ty });
            // Small collider for each tile
            const half = tile_size / 2.0;
            _ = ecs.set(world, e, Collider, .{ .box = .{ .min = .{ .x = -half, .y = -half }, .max = .{ .x = half, .y = half } } });
            _ = ecs.set(world, e, Renderable, .{ .color = SDL.Color{ .r = 0, .g = 255, .b = 0, .a = 255 } });
            _ = ecs.add(world, e, Destroyable);
        }
    }
}
