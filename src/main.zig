const std = @import("std");
const SDL = @import("sdl2");
const ecs = @import("zflecs");
const z2 = @import("zig_c2");

const engine_mod = @import("engine/core.zig");
const input_mod = @import("engine/input.zig");
const pixels_mod = @import("engine/pixels.zig");
const Effect = @import("engine/effects.zig").Effect;
const game = @import("game/systems.zig");
const C = @import("game/components.zig");

const HEIGHT: usize = 1440 / 2;
const WIDTH: usize = 2560 / 2;

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

    // activate web console
    // https://www.flecs.dev/explorer?host=localhost:2771

    ecs.FlecsRestImport(world);
    const flecs_rest_id = ecs.lookup(world, "flecs.rest.Rest");
    const config = ecs.EcsRest{
        .port = 2771,
    };
    _ = ecs.set_id(world, flecs_rest_id, flecs_rest_id, @sizeOf(ecs.EcsRest), &config);

    std.log.info("Web console available at https://www.flecs.dev/explorer?host=localhost:2771", .{});

    while (!input.quit_requested) {
        const dt = calculateDeltaTime(&time_ticks);
        engine.beginFrame();

        input.update();

        // Remap mouse from window space to logical pixel buffer space.
        // We keep raw coords in `input` (so next frame's update() works correctly)
        // and only pass remapped coords to the ECS singleton.
        const logical = engine.windowToLogical(input.mouse_x, input.mouse_y);
        var ecs_input = input;
        ecs_input.mouse_x = logical.x;
        ecs_input.mouse_y = logical.y;

        _ = ecs.singleton_set(world, input_mod.InputState, ecs_input);

        const mouseCursor = ecs.lookup(world, "MouseCursor");
        if (mouseCursor != 0) {
            _ = ecs.set(world, mouseCursor, C.Position, .{ .x = @floatFromInt(ecs_input.mouse_x), .y = @floatFromInt(ecs_input.mouse_y) });
        }

        engine.restoreBackground();
        _ = ecs.progress(world, dt);

        // incase systems have altered input state (e.g. right stick override)
        // if (ecs.singleton_get(world, input_mod.InputState)) |s| {
        //     ecs_input = s.*;
        // }

        // Cursor — draw into pixel buffer using logical coords
        const cursor_color = pixels_mod.packColor(255, 0, 0, 255);
        pixels_mod.drawCursor(&engine, ecs_input.mouse_x, ecs_input.mouse_y, 10, cursor_color);

        // Debug collider overlay — draw into pixel buffer before GL upload
        if (input.debug_mode) game.debug_draw_colliders_with_sdl2_render(world);

        // Upload pixel + effect buffers to GPU and render via shader
        engine.renderFrame(dt);

        watch_for_reset_and_do_it(&input, reset_game, world, &engine);

        engine.present();
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
    if (ecs.singleton_get(world, C.BulletsGroup)) |group| {
        // Delete everything linked to this parent
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }
    if (ecs.singleton_get(world, C.PlayerContainer)) |pc| {
        const player_entity = pc.entity;
        // Reset Player Position
        _ = ecs.set(world, player_entity, C.Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 2.0 });
        _ = ecs.set(world, player_entity, C.Velocity, .{ .x = 0.0, .y = 0.0 });
    }

    if (ecs.singleton_get(world, C.GroundGroup)) |group| {
        // Delete everything linked to this parent
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }

    // Reset Level
    ecs.delete_with(world, ecs.id(C.Ground));
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

pub fn setup_game(world: *ecs.world_t, engine: *engine_mod.Engine) !void {
    register_components(world);
    register_systems(world);
    try spawn_initial_entities(world, engine);
}

fn register_components(world: *ecs.world_t) void {
    ecs.COMPONENT(world, C.Gun);
    ecs.COMPONENT(world, C.Target);
    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Velocity);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.Renderable);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.ExplosionParticle);
    ecs.COMPONENT(world, C.RecoilImpulse);
    // ecs.COMPONENT(world, C.ConstraintData);

    ecs.TAG(world, C.Bullet);
    ecs.TAG(world, C.Player);
    ecs.TAG(world, C.Ground);
    ecs.TAG(world, C.Destroyable);
    ecs.TAG(world, C.EffectZone);
    ecs.TAG(world, C.GroundGrid);

    ecs.COMPONENT(world, input_mod.InputState);
    ecs.COMPONENT(world, C.PhysicsState);
    ecs.COMPONENT(world, C.BulletsGroup);
    ecs.COMPONENT(world, C.GroundGroup);
    ecs.COMPONENT(world, C.PlayerContainer);

    // effects
    ecs.COMPONENT(world, Effect);

    // ik
    ecs.COMPONENT(world, C.VerletState);
    // ecs.COMPONENT(world, C.DistanceConstraint);
    // ecs.COMPONENT(world, C.TendencyTowards);

    ecs.COMPONENT(world, C.ReachTowards);
    ecs.COMPONENT(world, C.AttachedTo);
}

fn register_systems(world: *ecs.world_t) void {
    // 1. Player Controller (Handling Input + Movement + Collision)

    _ = ecs.ADD_SYSTEM(world, "input_capture", ecs.OnUpdate, game.right_controller_stick_set_mouse_xy_system);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_controller", ecs.OnUpdate, game.player_controller_system, &.{
        .{ .id = ecs.id(C.Player) },
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.Collider) },
        .{ .id = ecs.id(C.RecoilImpulse) },
    });

    _ = ecs.ADD_SYSTEM(world, "seek", ecs.OnUpdate, game.seek_system);

    // Gravity (Generic: Requires PhysicsBody)
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "gravity", ecs.OnUpdate, game.gravity_system, &.{
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.PhysicsBody) },
        .{ .id = ecs.id(C.VerletState), .oper = .Not },
    });

    // Shoot system (explicit filter for Player)
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "shoot", ecs.OnUpdate, game.shoot_system, &.{
        .{ .id = ecs.id(C.Gun) },
        .{ .id = ecs.id(C.Position) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "verlet_integration", ecs.OnUpdate, game.verlet_integration_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.VerletState) },
    });

    // _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "tend_towards", ecs.OnUpdate, game.tend_towards_system, &.{
    //     .{ .id = ecs.id(C.Position) },
    //     .{ .id = ecs.id(C.TendencyTowards) },
    // });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "reach_system", ecs.OnUpdate, game.reach_system, &.{
        // Query for (ReachTowards, *) where ReachTowards is the data component
        .{ .id = ecs.pair(ecs.id(C.ReachTowards), ecs.Wildcard) },
        .{ .id = ecs.id(C.Position) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "attachment_system", ecs.OnUpdate, game.attachment_solver_system, &.{
        .{ .id = ecs.pair(ecs.id(C.AttachedTo), ecs.Wildcard) },
        .{ .id = ecs.id(C.Position) },
    });

    // _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "constraint_solver", ecs.OnUpdate, game.constraint_solver_system, &.{
    //     .{ .id = ecs.id(C.Position) },
    //     .{ .id = ecs.id(C.DistanceConstraint) },
    // });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "gun_aim", ecs.OnUpdate, game.gun_aim_system, &.{
        .{ .id = ecs.id(C.Gun) },
        .{ .id = ecs.id(C.Position) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "physics_movement", ecs.OnUpdate, game.physics_movement_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.PhysicsBody) },
        // IMPORTANT: Exclude entities that have VerletState
        .{ .id = ecs.id(C.VerletState), .oper = .Not },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "physics_collision", ecs.OnUpdate, game.physics_collision_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.Collider) },
        .{ .id = ecs.id(C.PhysicsBody) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_clamp", ecs.OnUpdate, game.player_clamp_system, &.{
        .{ .id = ecs.id(C.Player) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "bullet_cleanup", ecs.OnUpdate, game.bullet_cleanup_system, &.{
        .{ .id = ecs.id(C.Bullet) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "explosion", ecs.OnUpdate, game.explosion_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.ExplosionParticle) },
    });

    // Single unified pixel render system
    _ = ecs.ADD_SYSTEM(world, "render", ecs.OnStore, game.render_system);

    // Effect zones: invisible entities that stamp effect flags into the effect buffer
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "effect_zones", ecs.OnStore, game.effect_zone_system, &.{
        .{ .id = ecs.id(C.EffectZone) },
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Collider) },
        .{ .id = ecs.id(Effect) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "draw_constraints", ecs.OnStore, game.draw_attached_constraints_system, &.{
        .{ .id = ecs.pair(ecs.id(C.AttachedTo), ecs.Wildcard) },
        .{ .id = ecs.id(C.Position) },
    });

    // _ = ecs.ADD_SYSTEM(world, "debug_render", ecs.OnStore, game.debug_draw_colliders_with_sdl2_render);
}

fn spawn_player_tail(world: *ecs.world_t, player: ecs.entity_t) void {
    var parent = player;
    const segment_count = 5;
    const segment_dist = 10.0;

    const p_pos = ecs.get(world, player, C.Position).?;
    const friction_base = 0.7;

    // const engine = engine_mod.Engine.getEngine(world);

    const mouseCursor = ecs.new_entity(world, "MouseCursor");
    _ = ecs.set(world, mouseCursor, C.Position, .{ .x = 0.0, .y = 0.0 });

    var i: usize = 0;
    var first_one: u64 = 0;
    while (i < segment_count) : (i += 1) {
        const last_one = (i == segment_count - 1);
        const seg = ecs.new_id(world);
        if (i == 0) first_one = seg;
        const start_x = p_pos.x - (@as(f32, @floatFromInt(i + 1)) * segment_dist);
        const start_y = p_pos.y;
        const segment_friction = friction_base - (@as(f32, @floatFromInt(i)) * 0.01);

        _ = ecs.set(world, seg, C.Position, .{ .x = start_x, .y = start_y });
        _ = ecs.set(world, seg, C.VerletState, .{
            .old_x = start_x,
            .old_y = start_y,
            .friction = segment_friction,
        });
        _ = ecs.set(world, seg, C.Velocity, .{ .x = 0, .y = 0 }); // Required for integration
        _ = ecs.set_pair(world, seg, ecs.id(C.AttachedTo), parent, C.AttachedTo, .{
            .dist = segment_dist,
            .stiffness = 1.0,
        });
        _ = ecs.set(world, seg, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 3.0 } });

        // Add PhysicsBody! This allows existing gravity_system and physics_collision_system to work.
        _ = ecs.set(world, seg, C.PhysicsBody, .{ .restitution = 0.3, .friction = 0.9 });
        _ = ecs.set(world, seg, C.Renderable, .{ .color = SDL.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } });
        // _ = ecs.set(world, seg, Effect, Effect.glow_only);

        if (last_one) {
            // _ = ecs.set(world, seg, C.TendencyTowards, .{ .target = mouseCursor, .strength = 1.0 });
            _ = ecs.set_pair(world, seg, ecs.id(C.ReachTowards), mouseCursor, C.ReachTowards, .{
                .stiffness = 0.5,
            });

            _ = ecs.set_pair(world, seg, ecs.id(C.AttachedTo), first_one, C.AttachedTo, .{
                .stiffness = 0.1,
                .dist = segment_dist * segment_count, // Looser connection for the last segment to allow more freedom to reach towards the cursor
            });
        }

        parent = seg;
    }
}

const PLAYER_SIZE = 30.0;

fn spawn_initial_entities(world: *ecs.world_t, engine: *engine_mod.Engine) !void {
    const player = ecs.new_entity(world, "Player");
    ecs.add(world, player, C.Player);
    _ = ecs.set(world, player, C.Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 2.0 });
    _ = ecs.set(world, player, C.Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = PLAYER_SIZE / 2.0 } });
    _ = ecs.set(world, player, C.Renderable, .{ .color = SDL.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    _ = ecs.set(world, player, C.RecoilImpulse, .{ .x = 0.0 });
    _ = ecs.singleton_set(world, C.PlayerContainer, .{ .entity = player });

    const gun = ecs.new_entity(world, "Gun");
    _ = ecs.set(world, gun, C.Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, gun, C.Renderable, .{ .color = SDL.Color{ .r = 0, .g = 0, .b = 255, .a = 255 } });
    _ = ecs.set(world, gun, C.Collider, .{ .box = .{ .min = .{ .x = -4, .y = -4 }, .max = .{ .x = 4, .y = 4 } } });
    _ = ecs.set(world, gun, C.Gun, .{ .fire_rate = 0.05 });
    _ = ecs.add_pair(world, gun, ecs.ChildOf, player);

    spawn_player_tail(world, player);

    const ground_group = ecs.new_entity(world, "GroundGroup");
    _ = ecs.singleton_set(world, C.GroundGroup, .{ .entity = ground_group });
    spawn_level(world, engine);

    // Cache the Ground Query for Physics Systems
    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = ecs.id(C.Ground) };
    desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .In };
    desc.terms[2] = .{ .id = ecs.id(C.Collider), .inout = .In };
    // desc.terms[3] = .{ .id = ecs.id(components.ExplosionParticle), .oper = .Not };
    const ground_q = ecs.query_init(world, &desc) catch unreachable;
    _ = ecs.singleton_set(world, C.PhysicsState, .{ .ground_query = ground_q });

    // all bullets group
    const bullets_group = ecs.new_entity(world, "Bullets");
    _ = ecs.singleton_set(world, C.BulletsGroup, .{ .entity = bullets_group });
}

const OffsetDimensions = struct {
    offset_x: f32,
    offset_y: f32,
    width: f32,
    height: f32,
};

fn offsetDimensionsToAABB(offset: OffsetDimensions) z2.AABB {
    const half_width = offset.width / 2.0;
    const half_height = offset.height / 2.0;
    return z2.AABB{
        .min = .{ .x = offset.offset_x - half_width, .y = offset.offset_y - half_height },
        .max = .{ .x = offset.offset_x + half_width, .y = offset.offset_y + half_height },
    };
}

fn spawn_level(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    const ground_group = ecs.singleton_get(world, C.GroundGroup);

    const cx1 = @as(f32, @floatFromInt(engine.width)) / 2.0;
    const cy1 = @as(f32, @floatFromInt(engine.height)) / 1.5;
    spawnGroundGrid(world, cx1 - 150, cy1 - 25, 300, 50, ground_group);

    const cx2 = @as(f32, @floatFromInt(engine.width)) / 2.0 - 200;
    const cy2 = @as(f32, @floatFromInt(engine.height)) / 1.5 - 100;
    spawnGroundGrid(world, cx2 - 100, cy2 - 10, 200, 20, ground_group);

    const cx3 = @as(f32, @floatFromInt(engine.width)) / 2.0 + 100;
    const cy3 = @as(f32, @floatFromInt(engine.height)) / 1.5 - 60;
    spawnGroundGrid(world, cx3 - 50, cy3 - 10, 100, 20, ground_group);

    const floor = ecs.new_entity(world, "Floor");
    _ = ecs.set(world, floor, C.Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) - 50.0 });
    _ = ecs.set(world, floor, C.Collider, .{ .box = .{ .min = .{ .x = -@as(f32, @floatFromInt(engine.width)) / 2.0, .y = -50.0 }, .max = .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = 50 } } });
    _ = ecs.set(world, floor, C.Renderable, .{ .color = SDL.Color{ .r = 0, .g = 255, .b = 0, .a = 255 } });
    ecs.add(world, floor, C.Ground);

    // Heat shimmer zone above the main platform (invisible — effect only)
    const heat_zone = ecs.new_entity(world, "Hot Ground Effect Zone");
    ecs.add(world, heat_zone, C.EffectZone);
    _ = ecs.set(world, heat_zone, C.Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) - 50.0 });
    _ = ecs.set(world, heat_zone, C.Collider, .{ .box = .{ .min = .{ .x = -@as(f32, @floatFromInt(engine.width)) / 2.0, .y = -100.0 }, .max = .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = 50 } } });
    _ = ecs.set(world, heat_zone, Effect, Effect.heat_only);

    // const heat_zone_2 = ecs.new_entity(world, "Player HEAT");
    // ecs.add(world, heat_zone_2, C.EffectZone);
    // _ = ecs.set(world, heat_zone_2, C.Position, .{ .x = 0.0, .y = 0.0 }); // This zone will follow the player, so start at 0,0
    // _ = ecs.set(world, heat_zone_2, C.Collider, .{ .box = offsetDimensionsToAABB(.{ .offset_x = 0.0, .offset_y = 0.0, .width = PLAYER_SIZE * 2, .height = PLAYER_SIZE * 2 }) });
    // _ = ecs.set(world, heat_zone_2, Effect, Effect.bloom_only);

    // const player_container = ecs.singleton_get(world, C.PlayerContainer);

    // _ = ecs.set_pair(world, heat_zone_2, ecs.id(C.AttachedTo), player_container.?.entity, C.AttachedTo, .{
    //     .dist = 0.0,
    //     .stiffness = 1.0,
    // });

}

fn spawnGroundGrid(world: *ecs.world_t, start_x: f32, start_y: f32, width: f32, height: f32, ground_group: ?*const C.GroundGroup) void {
    const tile_size: f32 = 5.0;
    const cols = @as(usize, @intFromFloat(width / tile_size));
    const rows = @as(usize, @intFromFloat(height / tile_size));

    const grid_grouping = ecs.new_id(world);
    ecs.add(world, grid_grouping, C.GroundGrid);
    ecs.add_pair(world, grid_grouping, ecs.ChildOf, ground_group.?.entity);

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        var c_: usize = 0;
        while (c_ < cols) : (c_ += 1) {
            const e = ecs.new_id(world);
            ecs.add(world, e, C.Ground);

            const tx = start_x + (@as(f32, @floatFromInt(c_)) * tile_size) + (tile_size / 2.0);
            const ty = start_y + (@as(f32, @floatFromInt(r)) * tile_size) + (tile_size / 2.0);

            _ = ecs.set(world, e, C.Position, .{ .x = tx, .y = ty });
            // Small collider for each tile
            const half = tile_size / 2.0;
            _ = ecs.set(world, e, C.Collider, .{ .box = .{ .min = .{ .x = -half, .y = -half }, .max = .{ .x = half, .y = half } } });
            _ = ecs.set(world, e, C.Renderable, .{ .color = SDL.Color{ .r = 0, .g = 255, .b = 0, .a = 255 } });
            _ = ecs.add(world, e, C.Destroyable);
            ecs.add_pair(world, e, ecs.ChildOf, grid_grouping);
        }
    }
}

fn usize_to_f32(i: usize) f32 {
    return @as(f32, @floatFromInt(i));
}
