const std = @import("std");
const SDL = @import("sdl2");
const ecs = @import("zflecs");
const z2 = @import("zig_c2");

const engine_mod = @import("engine/core.zig");
const input_mod = @import("engine/input.zig");
const pixels_mod = @import("engine/pixels.zig");
const game = @import("game/systems.zig");
const components = @import("game/components.zig");

// components
const Position = components.Position;
const Velocity = components.Velocity;
const Target = components.Target;
const Collider = components.Collider;
const PhysicsBody = components.PhysicsBody;
const Renderable = components.Renderable;
const ExplosionParticle = components.ExplosionParticle;
const Gun = components.Gun;
const RecoilImpulse = components.RecoilImpulse;
// tags
const Bullet = components.Bullet;
const Player = components.Player;
const Ground = components.Ground;
const Destroyable = components.Destroyable;
// singletons
const BulletsGroup = components.BulletsGroup;
const PlayerContainer = components.PlayerContainer;
const PhysicsState = components.PhysicsState;

const HEIGHT: usize = 768;
const WIDTH: usize = 1024;

pub fn main() !void {
    var engine = try engine_mod.Engine.init(WIDTH, HEIGHT);
    defer engine.deinit();

    var input = input_mod.InputState{};

    pixels_mod.makeGradientSIMD(engine.sky_buffer, engine.width, engine.height);
    @memcpy(engine.background_buffer, engine.sky_buffer);
    @memcpy(engine.pixel_buffer, engine.background_buffer);

    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.set_ctx(world, &engine, dummy_free);
    try setup_game(world, &engine);

    var time_ticks = SDL.getTicks64();
    var cursor_size: f32 = 20.0;

    while (!input.quit_requested) {
        const dt = calculateDeltaTime(&time_ticks);
        engine.beginFrame();

        input.update();

        // if (input.right_stick_x != 0.0 or input.right_stick_y != 0.0) {
        //     if (ecs.singleton_get(world, PlayerContainer)) |pc| {
        //         if (ecs.get(world, pc.entity, Position)) |pos| {
        //             const dx = input.right_stick_x;
        //             const dy = input.right_stick_y;
        //             // Calculate intersection with screen bounds (0,0) -> (WIDTH, HEIGHT)
        //             // Ray: pos + t * (dx, dy)
        //             // We want smallest positive t where ray hits bounds.
        //             const tx = if (dx > 0) (@as(f32, @floatFromInt(WIDTH)) - pos.x) / dx else if (dx < 0) -pos.x / dx else std.math.floatMax(f32);
        //             const ty = if (dy > 0) (@as(f32, @floatFromInt(HEIGHT)) - pos.y) / dy else if (dy < 0) -pos.y / dy else std.math.floatMax(f32);
        //             const t = @min(tx, ty);
        //             input.mouse_x = @intFromFloat(pos.x + dx * t);
        //             input.mouse_y = @intFromFloat(pos.y + dy * t);
        //         }
        //     }
        // }

        _ = ecs.singleton_set(world, input_mod.InputState, input);

        _ = ecs.singleton_set(world, input_mod.InputState, input);

        engine.restoreBackground();
        _ = ecs.progress(world, dt);
        try engine.updateTexture();

        // incase systems have altered input state
        if (ecs.singleton_get(world, input_mod.InputState)) |s| {
            input = s.*;
        }

        const cursorSize = updateCursorSize(input.is_pressing, &cursor_size);
        try renderMouseCursor(engine.renderer, &input, cursorSize);

        watch_for_reset_and_do_it(&input, reset_game, world, &engine);

        engine.renderer.present();
    }
}

fn watch_for_reset_and_do_it(input: *input_mod.InputState, fnToRun: fn (*ecs.world_t, *engine_mod.Engine) void, world: *ecs.world_t, engine: *engine_mod.Engine) void {
    if (input.reset) {
        fnToRun(world, engine);
        input.reset = false;
    }
}

fn reset_game(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    // delete all bullets
    if (ecs.singleton_get(world, BulletsGroup)) |group| {
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
    spawn_level(world, engine);
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
    ecs.COMPONENT(world, Gun);
    ecs.COMPONENT(world, Target);
    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, Collider);
    ecs.COMPONENT(world, Renderable);
    ecs.COMPONENT(world, PhysicsBody);
    ecs.COMPONENT(world, ExplosionParticle);
    ecs.COMPONENT(world, RecoilImpulse);

    ecs.TAG(world, Bullet);
    ecs.TAG(world, Player);
    ecs.TAG(world, Ground);
    ecs.TAG(world, Destroyable);

    ecs.COMPONENT(world, input_mod.InputState);
    ecs.COMPONENT(world, PhysicsState);
    ecs.COMPONENT(world, BulletsGroup);
    ecs.COMPONENT(world, PlayerContainer);
}

fn register_systems(world: *ecs.world_t) void {
    // 1. Player Controller (Handling Input + Movement + Collision)

    _ = ecs.ADD_SYSTEM(world, "input_capture", ecs.OnUpdate, game.right_controller_stick_set_mouse_xy_system);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_controller", ecs.OnUpdate, game.player_controller_system, &.{
        .{ .id = ecs.id(Player) },
        .{ .id = ecs.id(Position) },
        .{ .id = ecs.id(Velocity) },
        .{ .id = ecs.id(Collider) },
        .{ .id = ecs.id(RecoilImpulse) },
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
        .{ .id = ecs.id(ExplosionParticle) },
    });

    // Single unified pixel render system
    _ = ecs.ADD_SYSTEM(world, "render", ecs.OnStore, game.render_system);
}

fn spawn_initial_entities(world: *ecs.world_t, engine: *engine_mod.Engine) !void {
    const player = ecs.new_entity(world, "Player");
    ecs.add(world, player, Player);
    _ = ecs.set(world, player, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 2.0 });
    _ = ecs.set(world, player, Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 15 } });
    _ = ecs.set(world, player, Renderable, .{ .color = SDL.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    _ = ecs.set(world, player, RecoilImpulse, .{ .x = 0.0 });
    _ = ecs.singleton_set(world, PlayerContainer, .{ .entity = player });

    const gun = ecs.new_entity(world, "Gun");
    _ = ecs.set(world, gun, Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, gun, Renderable, .{ .color = SDL.Color{ .r = 0, .g = 0, .b = 255, .a = 255 } });
    _ = ecs.set(world, gun, Collider, .{ .box = .{ .min = .{ .x = -4, .y = -4 }, .max = .{ .x = 4, .y = 4 } } });
    _ = ecs.set(world, gun, Gun, .{ .fire_rate = 0.05 });
    _ = ecs.add_pair(world, gun, ecs.ChildOf, player);

    spawn_level(world, engine);

    // Cache the Ground Query for Physics Systems
    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = ecs.id(Ground) };
    desc.terms[1] = .{ .id = ecs.id(Position), .inout = .In };
    desc.terms[2] = .{ .id = ecs.id(Collider), .inout = .In };
    // desc.terms[3] = .{ .id = ecs.id(components.ExplosionParticle), .oper = .Not };
    const ground_q = ecs.query_init(world, &desc) catch unreachable;
    _ = ecs.singleton_set(world, PhysicsState, .{ .ground_query = ground_q });

    // all bullets group
    const bullets_group = ecs.new_entity(world, "Bullets");
    _ = ecs.singleton_set(world, BulletsGroup, .{ .entity = bullets_group });
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

fn usize_to_f32(i: usize) f32 {
    return @as(f32, @floatFromInt(i));
}
