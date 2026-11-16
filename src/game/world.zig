const std = @import("std");
const ecs = @import("zflecs");
const C = @import("components.zig");
const mw = @import("material_world.zig");
const Engine = @import("../engine/core.zig").Engine;
const input_mod = @import("../engine/input.zig");
const Effect = @import("../engine/effects.zig").Effect;
const systems = @import("systems.zig");

pub const PLAYER_SIZE: f32 = 30.0;

const pipeline_desc_t = extern struct {
    entity: ecs.entity_t = 0,
    query: ecs.query_desc_t = .{},
};

extern fn ecs_pipeline_init(world: *ecs.world_t, desc: *const pipeline_desc_t) ecs.entity_t;

pub fn setup_game(world: *ecs.world_t, engine: *Engine) !void {
    register_components(world);
    register_systems(world);
    try spawn_initial_entities(world, engine.allocator, engine.width, engine.height);
}

pub fn deinit(world: *ecs.world_t) void {
    if (C.singletonGetMutSafe(world, mw.MaterialGrid)) |grid| {
        grid.deinit();
    }
    if (C.singletonGetSafe(world, C.PhysicsState)) |phys| {
        if (phys.ground_query) |q| ecs.query_fini(q);
        ecs.query_fini(phys.verlet_query);
        ecs.query_fini(phys.player_landable_query);
        ecs.query_fini(phys.collider_query);
        if (phys.attachment_query) |q| ecs.query_fini(q);
        if (phys.reach_query) |q| ecs.query_fini(q);
        if (phys.bullet_query) |q| ecs.query_fini(q);
        if (phys.explosion_query) |q| ecs.query_fini(q);
        if (phys.render_actor_query) |q| ecs.query_fini(q);
    }
}

fn countQueryEntities(world: *ecs.world_t, query: *ecs.query_t) u32 {
    var q_it = ecs.query_iter(world, query);
    var total: u32 = 0;
    while (ecs.query_next(&q_it)) {
        total += @intCast(q_it.count());
    }
    return total;
}

pub fn updateEntityCounts(world: *ecs.world_t) void {
    const phys = C.singletonGetSafe(world, C.PhysicsState) orelse return;
    const metrics = C.singletonGetMutSafe(world, C.FrameMetrics) orelse return;

    metrics.ground_count = if (phys.ground_query) |q| countQueryEntities(world, q) else 0;
    metrics.verlet_count = countQueryEntities(world, phys.verlet_query);
    metrics.bullet_count = if (phys.bullet_query) |q| countQueryEntities(world, q) else 0;
    metrics.explosion_count = if (phys.explosion_query) |q| countQueryEntities(world, q) else 0;

    if (C.singletonGetSafe(world, mw.MaterialGrid)) |grid| {
        const counts = grid.countByMaterial();
        metrics.material_active_cells = grid.active_cells;
        metrics.material_rock_cells = counts.rock_cells;
        metrics.material_sand_cells = counts.sand_cells;
        metrics.material_liquid_cells = counts.totalLiquid();
    }
}

pub fn reset_game(world: *ecs.world_t, engine: *Engine) void {
    reset_world(
        world,
        engine.arena.allocator(),
        engine.width,
        engine.height,
        engine.sky_buffer,
        engine.background_buffer,
    );
}

pub fn reset_world(
    world: *ecs.world_t,
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    sky_buffer: []const u32,
    background_buffer: []u32,
) void {
    if (ecs.singleton_get(world, C.BulletsGroup)) |group| {
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }
    if (ecs.singleton_get(world, C.GroundGroup)) |group| {
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }
    if (ecs.singleton_get(world, C.CreaturesGroup)) |group| {
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }
    if (ecs.singleton_get(world, C.PlayerAttachmentsGroup)) |group| {
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }
    ecs.delete_with(world, ecs.id(C.ExplosionParticle));

    // Clean up any stray ground entities not parented to GroundGroup
    ecs.delete_with(world, ecs.id(C.Ground));

    const spawn_pos = playerSpawnPos(width, height);

    if (ecs.singleton_get(world, C.PlayerContainer)) |pc| {
        _ = ecs.set(world, pc.entity, C.Position, spawn_pos);
        _ = ecs.set(world, pc.entity, C.Velocity, .{ .x = 0.0, .y = 0.0 });
        _ = ecs.set(world, pc.entity, C.RecoilImpulse, .{ .x = 0.0 });
        _ = ecs.set(world, pc.entity, C.LiquidReservoir, .{});

        const gun = ecs.lookup_child(world, pc.entity, "Gun");
        if (gun != 0) {
            if (ecs.get_mut(world, gun, C.Gun)) |g| {
                g.cooldown = 0.0;
                g.was_pressing = false;
            }
        }

        if (ecs.singleton_get(world, C.PlayerAttachmentsGroup)) |attach_group| {
            spawn_player_tail(world, pc.entity, attach_group.entity);
        }
    }

    if (C.singletonGetMutSafe(world, mw.MaterialGrid)) |grid| {
        grid.clear();
    }

    @memcpy(background_buffer, sky_buffer);
    spawn_level(world, width, height);
    spawn_jellies(world, allocator, width, height);

    if (C.singletonGetMutSafe(world, C.FrameMetrics)) |metrics| {
        metrics.resetPerFrame();
    }
    updateEntityCounts(world);
}

pub fn refill_player_liquid(world: *ecs.world_t) void {
    if (C.singletonGetSafe(world, C.PlayerContainer)) |pc| {
        if (ecs.get_mut(world, pc.entity, C.LiquidReservoir)) |res| {
            res.refillFull(.purple);
        }
    }
    if (C.singletonGetMutSafe(world, mw.MaterialGrid)) |grid| {
        const counts = grid.countByMaterial();
        if (counts.liquid_purple_cells < 160 and grid.width >= 100 and grid.height >= 20) {
            const floor_top: i32 = @intCast(grid.height - 14);
            grid.fillCellRect(48, floor_top - 8, 96, floor_top, .liquid_purple, false);
        }
    }
}

fn playerSpawnPos(width: usize, height: usize) C.Position {
    const cs: f32 = @floatFromInt(mw.CELL_SIZE);
    const max_x = @as(f32, @floatFromInt(width)) - 32.0;
    const max_y = @as(f32, @floatFromInt(height)) - 32.0;
    return .{
        .x = std.math.clamp(24.0 * cs, 32.0, @max(32.0, max_x)),
        .y = std.math.clamp(154.0 * cs - PLAYER_SIZE * 0.5 - 2.0, 32.0, @max(32.0, max_y)),
    };
}

fn register_components(world: *ecs.world_t) void {
    ecs.COMPONENT(world, C.Gun);
    ecs.COMPONENT(world, C.AimTarget);
    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Velocity);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.Renderable);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.ExplosionParticle);
    ecs.COMPONENT(world, C.RecoilImpulse);
    ecs.COMPONENT(world, C.LiquidReservoir);

    ecs.TAG(world, C.Bullet);
    ecs.TAG(world, C.Player);
    ecs.TAG(world, C.Ground);
    ecs.TAG(world, C.Destroyable);
    ecs.TAG(world, C.EffectZone);
    ecs.TAG(world, C.PlayerLandable);

    ecs.COMPONENT(world, input_mod.InputState);
    ecs.COMPONENT(world, mw.MaterialGrid);
    ecs.COMPONENT(world, C.PhysicsState);
    ecs.COMPONENT(world, C.GamePipelines);
    ecs.COMPONENT(world, C.FrameMetrics);
    ecs.COMPONENT(world, C.BulletsGroup);
    ecs.COMPONENT(world, C.GroundGroup);
    ecs.COMPONENT(world, C.CreaturesGroup);
    ecs.COMPONENT(world, C.PlayerAttachmentsGroup);
    ecs.COMPONENT(world, C.PlayerContainer);

    ecs.COMPONENT(world, Effect);
    ecs.COMPONENT(world, C.VerletState);
    ecs.COMPONENT(world, C.ReachTowards);
    ecs.COMPONENT(world, C.AttachedTo);
}

fn createPipelines(world: *ecs.world_t) C.GamePipelines {
    var sim_desc = pipeline_desc_t{
        .entity = ecs.new_entity(world, "SimPipeline"),
    };
    sim_desc.query.terms[0] = .{ .id = ecs.System };
    sim_desc.query.terms[1] = .{ .id = ecs.OnUpdate };
    sim_desc.query.terms[2] = .{ .id = ecs.Disabled, .src = .{ .id = ecs.Up }, .trav = ecs.DependsOn, .oper = .Not };
    sim_desc.query.terms[3] = .{ .id = ecs.Disabled, .src = .{ .id = ecs.Up }, .trav = ecs.ChildOf, .oper = .Not };
    const sim_pip = ecs_pipeline_init(world, &sim_desc);

    var render_desc = pipeline_desc_t{
        .entity = ecs.new_entity(world, "RenderPipeline"),
    };
    render_desc.query.terms[0] = .{ .id = ecs.System };
    render_desc.query.terms[1] = .{ .id = ecs.Phase, .src = .{ .id = ecs.Cascade }, .trav = ecs.DependsOn };
    render_desc.query.terms[2] = .{ .id = ecs.OnStore, .oper = .Or };
    render_desc.query.terms[3] = .{ .id = ecs.PostFrame };
    render_desc.query.terms[4] = .{ .id = ecs.Disabled, .src = .{ .id = ecs.Up }, .trav = ecs.DependsOn, .oper = .Not };
    render_desc.query.terms[5] = .{ .id = ecs.Disabled, .src = .{ .id = ecs.Up }, .trav = ecs.ChildOf, .oper = .Not };
    const render_pip = ecs_pipeline_init(world, &render_desc);

    return .{ .sim = sim_pip, .render = render_pip };
}

fn register_systems(world: *ecs.world_t) void {
    _ = ecs.ADD_SYSTEM(world, "input_capture", ecs.OnUpdate, systems.weapons.right_controller_stick_set_mouse_xy_system);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "gravity", ecs.OnUpdate, systems.physics.gravity_system, &.{
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.PhysicsBody) },
        .{ .id = ecs.id(C.VerletState), .oper = .Not },
    });

    // Aim runs before shoot so bullets spawn from current-frame gun position.
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "gun_aim", ecs.OnUpdate, systems.weapons.gun_aim_system, &.{
        .{ .id = ecs.id(C.Gun) },
    });

    _ = ecs.ADD_SYSTEM(world, "shoot", ecs.OnUpdate, systems.weapons.shoot_system);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_controller", ecs.OnUpdate, systems.player.player_controller_system, &.{
        .{ .id = ecs.id(C.Player) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_drink", ecs.OnUpdate, systems.player.player_drink_system, &.{
        .{ .id = ecs.id(C.Player) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "physics_movement", ecs.OnUpdate, systems.physics.physics_movement_system, &.{
        .{ .id = ecs.id(C.VerletState), .oper = .Not },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "physics_collision", ecs.OnUpdate, systems.physics.physics_collision_system, &.{
        .{ .id = ecs.id(C.VerletState), .oper = .Not },
    });

    var verlet_sys_desc = ecs.SYSTEM_DESC(systems.verlet.verlet_solver_system);
    verlet_sys_desc.phase = ecs.OnUpdate;
    verlet_sys_desc.immediate = true;
    _ = ecs.SYSTEM(world, "verlet_solver", &verlet_sys_desc);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "verlet_bullet_collision", ecs.OnUpdate, systems.verlet.verlet_bullet_collision_system, &.{
        .{ .id = ecs.id(C.Bullet) },
    });

    _ = ecs.ADD_SYSTEM(world, "material_step", ecs.OnUpdate, systems.physics.material_step_system);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_clamp", ecs.OnUpdate, systems.player.player_clamp_system, &.{
        .{ .id = ecs.id(C.Player) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "bullet_cleanup", ecs.OnUpdate, systems.weapons.bullet_cleanup_system, &.{
        .{ .id = ecs.id(C.Bullet) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "explosion_lifetime", ecs.OnUpdate, systems.physics.explosion_lifetime_system, &.{
        .{ .id = ecs.id(C.ExplosionParticle) },
    });

    _ = ecs.ADD_SYSTEM(world, "render", ecs.OnStore, systems.render.render_system);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "explosion_render", ecs.OnStore, systems.physics.explosion_render_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.ExplosionParticle) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "effect_zones", ecs.OnStore, systems.render.effect_zone_system, &.{
        .{ .id = ecs.id(C.EffectZone) },
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Collider) },
        .{ .id = ecs.id(Effect) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "draw_constraints", ecs.OnStore, systems.render.draw_attached_constraints_system, &.{
        .{ .id = ecs.pair(ecs.id(C.AttachedTo), ecs.Wildcard) },
        .{ .id = ecs.id(C.Position) },
    });

    const pipelines = createPipelines(world);
    _ = ecs.singleton_set(world, C.GamePipelines, pipelines);
}

fn spawn_initial_entities(world: *ecs.world_t, allocator: std.mem.Allocator, width: usize, height: usize) !void {
    _ = ecs.singleton_set(world, C.AimTarget, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.singleton_set(world, C.FrameMetrics, .{});

    const grid = try mw.MaterialGrid.initForPixels(allocator, width, height, mw.CELL_SIZE);
    _ = ecs.singleton_set(world, mw.MaterialGrid, grid);

    const mouse_cursor = ecs.new_entity(world, "MouseCursor");
    _ = ecs.set(world, mouse_cursor, C.Position, .{ .x = 0.0, .y = 0.0 });

    const spawn_pos = playerSpawnPos(width, height);

    const player = ecs.new_entity(world, "Player");
    ecs.add(world, player, C.Player);
    _ = ecs.set(world, player, C.Position, spawn_pos);
    _ = ecs.set(world, player, C.Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = PLAYER_SIZE / 2.0 } });
    _ = ecs.set(world, player, C.Renderable, .{ .color = C.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    _ = ecs.set(world, player, C.RecoilImpulse, .{ .x = 0.0 });
    _ = ecs.set(world, player, C.LiquidReservoir, .{});
    _ = ecs.singleton_set(world, C.PlayerContainer, .{ .entity = player });

    const gun = ecs.new_entity(world, "Gun");
    _ = ecs.set(world, gun, C.Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, gun, C.Renderable, .{ .color = C.Color{ .r = 0, .g = 0, .b = 255, .a = 255 } });
    _ = ecs.set(world, gun, C.Collider, .{ .box = .{ .min = .{ .x = -4, .y = -4 }, .max = .{ .x = 4, .y = 4 } } });
    _ = ecs.set(world, gun, C.Gun, .{ .fire_rate = 0.055, .recoil = 210.0 });
    _ = ecs.add_pair(world, gun, ecs.ChildOf, player);

    const bullets_group = ecs.new_entity(world, "Bullets");
    _ = ecs.singleton_set(world, C.BulletsGroup, .{ .entity = bullets_group });

    const ground_group = ecs.new_entity(world, "GroundGroup");
    _ = ecs.singleton_set(world, C.GroundGroup, .{ .entity = ground_group });

    const creatures_group = ecs.new_entity(world, "Creatures");
    _ = ecs.singleton_set(world, C.CreaturesGroup, .{ .entity = creatures_group });

    const attachments_group = ecs.new_entity(world, "PlayerAttachments");
    _ = ecs.singleton_set(world, C.PlayerAttachmentsGroup, .{ .entity = attachments_group });

    spawn_player_tail(world, player, attachments_group);
    spawn_level(world, width, height);
    spawn_jellies(world, allocator, width, height);

    var verlet_desc = ecs.query_desc_t{};
    verlet_desc.terms[0] = .{ .id = ecs.id(C.Position), .inout = .InOut };
    verlet_desc.terms[1] = .{ .id = ecs.id(C.VerletState), .inout = .InOut };
    verlet_desc.terms[2] = .{ .id = ecs.id(C.Collider), .inout = .In, .oper = .Optional };
    verlet_desc.terms[3] = .{ .id = ecs.id(C.PhysicsBody), .inout = .In, .oper = .Optional };
    const verlet_q = ecs.query_init(world, &verlet_desc) catch unreachable;

    var landable_desc = ecs.query_desc_t{};
    landable_desc.terms[0] = .{ .id = ecs.id(C.PlayerLandable) };
    landable_desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .InOut };
    landable_desc.terms[2] = .{ .id = ecs.id(C.Collider), .inout = .In };
    landable_desc.terms[3] = .{ .id = ecs.id(C.VerletState), .inout = .InOut };
    const landable_q = ecs.query_init(world, &landable_desc) catch unreachable;

    var collider_desc = ecs.query_desc_t{};
    collider_desc.terms[0] = .{ .id = ecs.id(C.Position), .inout = .In };
    collider_desc.terms[1] = .{ .id = ecs.id(C.Collider), .inout = .In };
    const collider_q = ecs.query_init(world, &collider_desc) catch unreachable;

    var attach_desc = ecs.query_desc_t{};
    attach_desc.terms[0] = .{ .id = ecs.pair(ecs.id(C.AttachedTo), ecs.Wildcard), .inout = .In };
    attach_desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .InOut };
    const attach_q = ecs.query_init(world, &attach_desc) catch unreachable;

    var reach_desc = ecs.query_desc_t{};
    reach_desc.terms[0] = .{ .id = ecs.pair(ecs.id(C.ReachTowards), ecs.Wildcard), .inout = .In };
    reach_desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .InOut };
    const reach_q = ecs.query_init(world, &reach_desc) catch unreachable;

    var bullet_desc = ecs.query_desc_t{};
    bullet_desc.terms[0] = .{ .id = ecs.id(C.Bullet) };
    const bullet_q = ecs.query_init(world, &bullet_desc) catch unreachable;

    var explosion_desc = ecs.query_desc_t{};
    explosion_desc.terms[0] = .{ .id = ecs.id(C.ExplosionParticle) };
    const explosion_q = ecs.query_init(world, &explosion_desc) catch unreachable;

    var render_actor_desc = ecs.query_desc_t{};
    render_actor_desc.terms[0] = .{ .id = ecs.id(C.Position), .inout = .In };
    render_actor_desc.terms[1] = .{ .id = ecs.id(C.Collider), .inout = .In };
    render_actor_desc.terms[2] = .{ .id = ecs.id(C.Renderable), .inout = .In };
    render_actor_desc.terms[3] = .{ .id = ecs.id(C.Ground), .oper = .Not };
    render_actor_desc.terms[4] = .{ .id = ecs.id(C.VerletState), .oper = .Not };
    const render_actor_q = ecs.query_init(world, &render_actor_desc) catch unreachable;

    _ = ecs.singleton_set(world, C.PhysicsState, .{
        .ground_query = null,
        .verlet_query = verlet_q,
        .player_landable_query = landable_q,
        .collider_query = collider_q,
        .attachment_query = attach_q,
        .reach_query = reach_q,
        .bullet_query = bullet_q,
        .explosion_query = explosion_q,
        .render_actor_query = render_actor_q,
    });

    updateEntityCounts(world);
}

fn spawn_player_tail(world: *ecs.world_t, player: ecs.entity_t, attachments_group: ecs.entity_t) void {
    var parent = player;
    const segment_count: usize = 5;
    const segment_dist: f32 = 10.0;

    const p_pos = ecs.get(world, player, C.Position).?;
    const friction_base: f32 = 0.86;
    const mouse_cursor = ecs.lookup(world, "MouseCursor");

    for (0..segment_count) |i| {
        const last_one = (i == segment_count - 1);
        const seg = ecs.new_id(world);
        const start_x = p_pos.x - (@as(f32, @floatFromInt(i + 1)) * segment_dist);
        const start_y = p_pos.y;
        const segment_friction = friction_base - (@as(f32, @floatFromInt(i)) * 0.01);
        const seg_radius = 6.0 - @as(f32, @floatFromInt(i));

        _ = ecs.set(world, seg, C.Position, .{ .x = start_x, .y = start_y });
        _ = ecs.set(world, seg, C.VerletState, .{
            .old_x = start_x,
            .old_y = start_y,
            .friction = segment_friction,
        });
        _ = ecs.set_pair(world, seg, ecs.id(C.AttachedTo), parent, C.AttachedTo, .{
            .dist = segment_dist,
            .stiffness = 1.0,
        });
        _ = ecs.set(world, seg, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = seg_radius } });
        _ = ecs.set(world, seg, C.Renderable, .{ .color = C.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } });
        _ = ecs.set(world, seg, Effect, Effect.glow_only);
        ecs.add_pair(world, seg, ecs.ChildOf, attachments_group);

        if (last_one) {
            _ = ecs.set(world, seg, C.PhysicsBody, .{ .restitution = 0.0, .friction = 0.5 });
            if (mouse_cursor != 0) {
                _ = ecs.set_pair(world, seg, ecs.id(C.ReachTowards), mouse_cursor, C.ReachTowards, .{
                    .stiffness = 0.5,
                });
            }
        }

        parent = seg;
    }
}

fn spawn_level(world: *ecs.world_t, width: usize, height: usize) void {
    _ = width;
    _ = height;
    const grid = C.singletonGetMutSafe(world, mw.MaterialGrid) orelse return;
    const gw: i32 = @intCast(grid.width);
    const gh: i32 = @intCast(grid.height);
    if (gw < 16 or gh < 16) return;

    // 1. Open sandbox room enclosure (walls, ceiling, main floor)
    const wall_t: i32 = 4;
    const floor_top: i32 = @max(wall_t + 8, gh - 14);
    grid.fillCellRect(0, 0, wall_t, gh, .rock, true);
    grid.fillCellRect(gw - wall_t, 0, gw, gh, .rock, true);
    grid.fillCellRect(0, 0, gw, wall_t, .rock, true);
    grid.fillCellRect(0, floor_top, gw, gh, .rock, true);

    // 2. Left spawn ledge + generous Purple drink basin
    const ledge_top = floor_top - 12;
    const basin_rim_top = floor_top - 10;
    grid.fillCellRect(wall_t, ledge_top, @min(46, gw - wall_t), floor_top, .rock, true);
    grid.fillCellRect(98, basin_rim_top, 106, floor_top, .rock, true);
    grid.fillCellRect(46, floor_top - 9, 98, floor_top, .liquid_purple, false);

    // 3. Water showcase trough + exposed sand mound + destructible sand hopper above water
    const water_rim_top = floor_top - 12;
    grid.fillCellRect(168, water_rim_top, 176, floor_top, .rock, true);
    grid.fillCellRect(106, floor_top - 8, 168, floor_top, .liquid_water, false);
    grid.fillCellRect(176, floor_top - 8, 196, floor_top, .sand, false);

    // Suspended destructible rock hopper holding falling sand above the water trough
    grid.fillCellRect(124, 98, 150, 101, .rock, false);
    grid.fillCellRect(124, 84, 126, 98, .rock, false);
    grid.fillCellRect(148, 84, 150, 98, .rock, false);
    grid.fillCellRect(126, 85, 148, 98, .sand, false);

    // 4. Open destructible platforms & elevated arches (free-form sandbox traversal)
    grid.fillCellRect(60, floor_top - 38, 100, floor_top - 33, .rock, false);
    grid.fillCellRect(116, floor_top - 26, 156, floor_top - 22, .rock, false);
    grid.fillCellRect(184, floor_top - 48, 248, floor_top - 44, .rock, false);
    grid.fillCellRect(198, floor_top - 44, 206, floor_top - 14, .rock, false); // open doorway below (14 cells clearance)
    grid.fillCellRect(256, floor_top - 64, 304, floor_top - 60, .rock, false);
}

fn spawn_jellies(world: *ecs.world_t, allocator: std.mem.Allocator, width: usize, height: usize) void {
    const creatures_group = ecs.singleton_get(world, C.CreaturesGroup) orelse return;
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);

    // 1. 3-core kinetic jelly chain in clear open air above right-mid platform (x=736..992)
    const c_x = std.math.clamp(w * 0.675, 220.0, w - 180.0);
    const c_y = std.math.clamp(h * 0.34, 120.0, h - 300.0);
    const j0 = spawn_jelly_blob(world, allocator, creatures_group.entity, c_x - 88.0, c_y + 8.0, 18.0, 40.0, 8, 0.085, null);
    const j1 = spawn_jelly_blob(world, allocator, creatures_group.entity, c_x, c_y - 10.0, 22.0, 46.0, 8, 0.085, j0);
    _ = spawn_jelly_blob(world, allocator, creatures_group.entity, c_x + 88.0, c_y + 8.0, 18.0, 40.0, 8, 0.085, j1);

    // 2. Playful 2-core connected buddy blob in the open lower-right floor area
    const b_x = std.math.clamp(w * 0.83, 180.0, w - 130.0);
    const b_y = std.math.clamp(h * 0.81, 140.0, h - 110.0);
    const b0 = spawn_jelly_blob(world, allocator, creatures_group.entity, b_x - 86.0, b_y, 16.0, 36.0, 8, 0.065, null);
    _ = spawn_jelly_blob(world, allocator, creatures_group.entity, b_x, b_y - 4.0, 18.0, 38.0, 8, 0.065, b0);
}

fn attachWithDist(
    world: *ecs.world_t,
    child: ecs.entity_t,
    parent: ecs.entity_t,
    dist_override: ?f32,
    stiffness: f32,
) void {
    const d = dist_override orelse blk: {
        const cp = ecs.get(world, child, C.Position).?;
        const pp = ecs.get(world, parent, C.Position).?;
        const dx = cp.x - pp.x;
        const dy = cp.y - pp.y;
        break :blk @sqrt(dx * dx + dy * dy);
    };
    _ = ecs.set_pair(world, child, ecs.id(C.AttachedTo), parent, C.AttachedTo, .{
        .dist = d,
        .stiffness = stiffness,
    });
}

/// Spawn a simple kinetic jelly blob (one `PlayerLandable` center + outer skin ring),
/// optionally tethered directly to another core with one connecting arm.
fn spawn_jelly_blob(
    world: *ecs.world_t,
    allocator: std.mem.Allocator,
    creatures_group: ecs.entity_t,
    cx: f32,
    cy: f32,
    core_radius: f32,
    skin_radius: f32,
    segments: usize,
    reach_stiffness: f32,
    connect_to: ?ecs.entity_t,
) ecs.entity_t {
    const nodes = allocator.alloc(ecs.entity_t, segments) catch unreachable;
    defer allocator.free(nodes);

    const center = ecs.new_id(world);
    ecs.add(world, center, C.PlayerLandable);
    ecs.add_pair(world, center, ecs.ChildOf, creatures_group);
    _ = ecs.set(world, center, C.Position, .{ .x = cx, .y = cy });
    _ = ecs.set(world, center, C.VerletState, .{ .old_x = cx, .old_y = cy, .friction = 0.99 });
    _ = ecs.set(world, center, C.Renderable, .{ .color = C.Color{ .r = 255, .g = 35, .b = 65, .a = 255 } });
    _ = ecs.set(world, center, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = core_radius } });
    _ = ecs.set(world, center, C.PhysicsBody, .{ .restitution = 0.30, .friction = 0.85 });

    const angle_step = (std.math.pi * 2.0) / @as(f32, @floatFromInt(segments));
    const perimeter_dist = @sqrt(2.0 * skin_radius * skin_radius * (1.0 - @cos(angle_step)));
    const player = ecs.singleton_get(world, C.PlayerContainer).?.entity;

    for (0..segments) |i| {
        const angle = @as(f32, @floatFromInt(i)) * angle_step;
        const px = cx + @cos(angle) * skin_radius;
        const py = cy + @sin(angle) * skin_radius;

        const node = ecs.new_id(world);
        nodes[i] = node;
        ecs.add_pair(world, node, ecs.ChildOf, creatures_group);
        _ = ecs.set(world, node, C.Position, .{ .x = px, .y = py });
        _ = ecs.set(world, node, C.VerletState, .{ .old_x = px, .old_y = py, .friction = 0.99 });
        _ = ecs.set(world, node, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 2.5 } });
        _ = ecs.set(world, node, C.PhysicsBody, .{ .restitution = 0.20, .friction = 0.90 });
        _ = ecs.set(world, node, C.Renderable, .{ .color = C.Color{ .r = 0, .g = 255, .b = 255, .a = 255 } });

        if (reach_stiffness > 0.0) {
            _ = ecs.set_pair(world, node, ecs.id(C.ReachTowards), player, C.ReachTowards, .{
                .stiffness = reach_stiffness,
            });
        }

        // Asymmetric soft spokes create organic slosh and rotational momentum
        attachWithDist(world, node, center, skin_radius + 2.0 * @as(f32, @floatFromInt(i)), 0.16);
    }

    for (0..segments) |i| {
        const current = nodes[i];
        const next = nodes[(i + 1) % segments];
        attachWithDist(world, current, next, perimeter_dist, 0.98);
    }

    if (connect_to) |parent| {
        attachWithDist(world, center, parent, null, 0.22);
    }

    return center;
}

fn countWithId(world: *ecs.world_t, component_id: ecs.id_t) usize {
    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = component_id };
    const q = ecs.query_init(world, &desc) catch unreachable;
    defer ecs.query_fini(q);

    var q_it = ecs.query_iter(world, q);

    var total: usize = 0;
    while (ecs.query_next(&q_it)) {
        total += q_it.count();
    }
    return total;
}

test "reset_world clears and respawns multi-core blobs, bullets, tail, MaterialGrid, and reservoir without leaks" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);
    defer deinit(world);

    register_components(world);
    register_systems(world);

    try spawn_initial_entities(world, testing.allocator, 1280, 720);

    const initial_verlets = countWithId(world, ecs.id(C.VerletState));
    const initial_cores = countWithId(world, ecs.id(C.PlayerLandable));
    try testing.expectEqual(@as(usize, 5), initial_cores); // 3-core chain + 2-core buddy
    try testing.expectEqual(@as(usize, 0), countWithId(world, ecs.id(C.Ground)));

    const grid_before = ecs.singleton_get(world, mw.MaterialGrid).?;
    try testing.expectEqual(@as(usize, 320), grid_before.width);
    try testing.expectEqual(@as(usize, 180), grid_before.height);
    const counts_before = grid_before.countByMaterial();
    try testing.expect(counts_before.rock_cells > 0);
    try testing.expect(counts_before.sand_cells > 0);
    try testing.expect(counts_before.liquid_purple_cells > 0);
    try testing.expect(counts_before.liquid_water_cells > 0);

    // Mutate player reservoir, grid rock, bullet, and gun cooldown before reset
    const player = ecs.singleton_get(world, C.PlayerContainer).?.entity;
    _ = ecs.get_mut(world, player, C.LiquidReservoir).?.addLiquid(.purple, 20);
    _ = ecs.singleton_get_mut(world, mw.MaterialGrid).?.carveCircle(300.0, 520.0, 20.0);

    const bullets_group = ecs.singleton_get(world, C.BulletsGroup).?.entity;
    const bullet = ecs.new_id(world);
    ecs.add(world, bullet, C.Bullet);
    ecs.add_pair(world, bullet, ecs.ChildOf, bullets_group);

    const gun = ecs.lookup(world, "Player.Gun");
    try testing.expect(gun != 0);
    ecs.get_mut(world, gun, C.Gun).?.cooldown = 0.5;

    var sky: [16]u32 = @splat(0x11111111);
    var bg: [16]u32 = @splat(0x22222222);
    reset_world(world, testing.allocator, 1280, 720, &sky, &bg);

    try testing.expectEqual(@as(usize, 0), countWithId(world, ecs.id(C.Bullet)));
    try testing.expectEqual(initial_verlets, countWithId(world, ecs.id(C.VerletState)));
    try testing.expectEqual(initial_cores, countWithId(world, ecs.id(C.PlayerLandable)));
    try testing.expectEqual(@as(f32, 0.0), ecs.get(world, gun, C.Gun).?.cooldown);
    try testing.expectEqual(@as(u32, 0), ecs.get(world, player, C.LiquidReservoir).?.amount);
    try testing.expectEqual(@as(u32, 0x11111111), bg[0]);
    try testing.expectEqual(counts_before.rock_cells, ecs.singleton_get(world, mw.MaterialGrid).?.countByMaterial().rock_cells);

    // Verify Verlet entities do not have Velocity component and only Player has Velocity
    try testing.expectEqual(@as(usize, 1), countWithId(world, ecs.id(C.Velocity)));

    // Step full PBD solver across reset world
    for (0..10) |_| {
        systems.verlet.stepVerletPBDWithAllocator(world, testing.allocator, 1.0 / 120.0);
    }
    const metrics = ecs.singleton_get(world, C.FrameMetrics).?;
    try testing.expect(metrics.verlet_ground_checks > 0);
    try testing.expect(metrics.verlet_self_checks > 0);
}

test "sim and render pipelines separate OnUpdate from OnStore and PostFrame" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    const Counters = struct {
        update_runs: u32 = 0,
        last_update_dt: f32 = 0.0,
        store_runs: u32 = 0,
        post_frame_runs: u32 = 0,
    };
    ecs.COMPONENT(world, Counters);
    _ = ecs.singleton_set(world, Counters, .{});

    const S = struct {
        fn onUpdate(it: *ecs.iter_t) void {
            const c = ecs.singleton_get_mut(it.world, Counters).?;
            c.update_runs += 1;
            c.last_update_dt = it.delta_time;
        }
        fn onStore(it: *ecs.iter_t) void {
            const c = ecs.singleton_get_mut(it.world, Counters).?;
            c.store_runs += 1;
        }
        fn onPostFrame(it: *ecs.iter_t) void {
            const c = ecs.singleton_get_mut(it.world, Counters).?;
            c.post_frame_runs += 1;
        }
    };

    _ = ecs.ADD_SYSTEM(world, "test_update", ecs.OnUpdate, S.onUpdate);
    _ = ecs.ADD_SYSTEM(world, "test_store", ecs.OnStore, S.onStore);
    _ = ecs.ADD_SYSTEM(world, "test_post_frame", ecs.PostFrame, S.onPostFrame);

    const pipelines = createPipelines(world);
    const fixed_dt: f32 = 1.0 / 120.0;

    // Frame with 3 sim steps and 1 render pass
    _ = ecs.frame_begin(world, 0.025);
    for (0..3) |_| {
        ecs.run_pipeline(world, pipelines.sim, fixed_dt);
    }
    ecs.run_pipeline(world, pipelines.render, 0.025);
    ecs.frame_end(world);

    var c = ecs.singleton_get(world, Counters).?;
    try testing.expectEqual(@as(u32, 3), c.update_runs);
    try testing.expectApproxEqAbs(fixed_dt, c.last_update_dt, 0.00001);
    try testing.expectEqual(@as(u32, 1), c.store_runs);
    try testing.expectEqual(@as(u32, 1), c.post_frame_runs);

    // Frame with 0 sim steps still runs OnStore and PostFrame once
    _ = ecs.frame_begin(world, 0.002);
    ecs.run_pipeline(world, pipelines.render, 0.002);
    ecs.frame_end(world);

    c = ecs.singleton_get(world, Counters).?;
    try testing.expectEqual(@as(u32, 3), c.update_runs);
    try testing.expectEqual(@as(u32, 2), c.store_runs);
    try testing.expectEqual(@as(u32, 2), c.post_frame_runs);
}

test "sandbox SimPipeline runs multi-step frame: drink purple, refill key helper, carve rock, and push multi-core blobs" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);
    defer deinit(world);

    register_components(world);
    register_systems(world);
    try spawn_initial_entities(world, testing.allocator, 1280, 720);

    _ = ecs.singleton_set(world, input_mod.InputState, .{});
    const pipelines = ecs.singleton_get(world, C.GamePipelines).?.*;
    const player = ecs.singleton_get(world, C.PlayerContainer).?.entity;
    const fixed_dt: f32 = 1.0 / 120.0;

    // 1. Place player in purple drink basin (gx=46..98, gy=162 -> world x=260, y=645) and step 2x/frame
    _ = ecs.set(world, player, C.Position, .{ .x = 260.0, .y = 645.0 });
    _ = ecs.singleton_set(world, C.AimTarget, .{ .x = 260.0, .y = 700.0 });
    for (0..8) |_| {
        _ = ecs.frame_begin(world, fixed_dt * 2.0);
        ecs.run_pipeline(world, pipelines.sim, fixed_dt);
        ecs.run_pipeline(world, pipelines.sim, fixed_dt);
        ecs.frame_end(world);
    }

    const res_after_drink = ecs.get(world, player, C.LiquidReservoir).?;
    try testing.expect(res_after_drink.amount > 0);
    try testing.expect(res_after_drink.has_drunk_once);
    try testing.expect(res_after_drink.hasAmmo());

    // 2. Quick-refill helper fills reservoir to capacity
    refill_player_liquid(world);
    const res_refilled = ecs.get(world, player, C.LiquidReservoir).?;
    try testing.expectEqual(res_refilled.capacity, res_refilled.amount);

    // 3. Shoot destructible left-mid platform (gx=60..100, gy=128..133 -> x=320, y=520)
    _ = ecs.set(world, player, C.Position, .{ .x = 220.0, .y = 520.0 });
    _ = ecs.set(world, player, C.Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.singleton_set(world, C.AimTarget, .{ .x = 320.0, .y = 520.0 });
    _ = ecs.singleton_set(world, input_mod.InputState, .{ .is_pressing = true });

    for (0..18) |_| {
        _ = ecs.frame_begin(world, fixed_dt * 2.0);
        ecs.run_pipeline(world, pipelines.sim, fixed_dt);
        ecs.run_pipeline(world, pipelines.sim, fixed_dt);
        ecs.frame_end(world);
    }

    const mg = ecs.singleton_get(world, mw.MaterialGrid).?;
    try testing.expect(mg.getCell(62, 130).?.material != .rock);
    try testing.expectEqual(@as(usize, 5), countWithId(world, ecs.id(C.PlayerLandable)));

    // 4. Step full simulation for 240 ticks (2 full seconds) and verify all creature nodes stay
    //    contained inside the room and remain structurally inflated (no collapse or fly-away).
    _ = ecs.singleton_set(world, input_mod.InputState, .{});
    for (0..120) |_| {
        _ = ecs.frame_begin(world, fixed_dt * 2.0);
        ecs.run_pipeline(world, pipelines.sim, fixed_dt);
        ecs.run_pipeline(world, pipelines.sim, fixed_dt);
        ecs.frame_end(world);
    }

    const creatures_group = ecs.singleton_get(world, C.CreaturesGroup).?.entity;
    const landable_id = ecs.id(C.PlayerLandable);
    const attached_id = ecs.id(C.AttachedTo);
    var core_ids: [5]ecs.entity_t = @splat(0);
    var blob_min_y: [5]f32 = @splat(10000.0);
    var blob_max_y: [5]f32 = @splat(-10000.0);
    var core_count: usize = 0;
    var core_arms: usize = 0;

    var v_it = ecs.query_iter(world, ecs.singleton_get(world, C.PhysicsState).?.verlet_query);
    while (ecs.query_next(&v_it)) {
        const positions = ecs.field(&v_it, C.Position, 0).?;
        const ents = v_it.entities();
        for (positions, 0..) |p, idx| {
            const e = ents[idx];
            try testing.expect(std.math.isFinite(p.x) and std.math.isFinite(p.y));
            try testing.expect(p.x >= 0.0 and p.x <= 1280.0);
            try testing.expect(p.y >= 0.0 and p.y <= 720.0);
            if (!ecs.has_pair(world, e, ecs.ChildOf, creatures_group)) continue;
            if (ecs.has_id(world, e, landable_id)) {
                try testing.expect(core_count < core_ids.len);
                core_ids[core_count] = e;
                blob_min_y[core_count] = @min(blob_min_y[core_count], p.y);
                blob_max_y[core_count] = @max(blob_max_y[core_count], p.y);
                core_count += 1;
                try testing.expect(p.y > 16.0 and p.y < 680.0);
                if (ecs.get_target(world, e, attached_id, 0) != 0) {
                    core_arms += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 5), core_count);
    try testing.expectEqual(@as(usize, 3), core_arms); // 2 arms in 3-core chain + 1 arm in 2-core buddy

    var v_it2 = ecs.query_iter(world, ecs.singleton_get(world, C.PhysicsState).?.verlet_query);
    while (ecs.query_next(&v_it2)) {
        const positions = ecs.field(&v_it2, C.Position, 0).?;
        const ents = v_it2.entities();
        for (positions, 0..) |p, idx| {
            const e = ents[idx];
            if (!ecs.has_pair(world, e, ecs.ChildOf, creatures_group)) continue;
            if (ecs.has_id(world, e, landable_id)) continue;

            var t_idx: i32 = 0;
            while (t_idx < 4) : (t_idx += 1) {
                const raw_target = ecs.get_target(world, e, attached_id, t_idx);
                if (raw_target == 0) break;
                const target = ecs.get_alive(world, raw_target);
                for (core_ids, 0..) |cid, c_idx| {
                    if (target == cid) {
                        if (p.y < blob_min_y[c_idx]) blob_min_y[c_idx] = p.y;
                        if (p.y > blob_max_y[c_idx]) blob_max_y[c_idx] = p.y;
                        break;
                    }
                }
            }
        }
    }

    for (0..core_count) |c_idx| {
        try testing.expect((blob_max_y[c_idx] - blob_min_y[c_idx]) > 40.0);
    }
}
