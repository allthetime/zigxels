const std = @import("std");
const ecs = @import("zflecs");
const C = @import("components.zig");
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
    try spawn_initial_entities(world, engine.arena.allocator(), engine.width, engine.height);
}

pub fn deinit(world: *ecs.world_t) void {
    if (ecs.singleton_get(world, C.PhysicsState)) |phys| {
        ecs.query_fini(phys.ground_query);
        ecs.query_fini(phys.verlet_query);
        ecs.query_fini(phys.player_landable_query);
        ecs.query_fini(phys.collider_query);
        if (phys.attachment_query) |q| ecs.query_fini(q);
        if (phys.reach_query) |q| ecs.query_fini(q);
        if (phys.bullet_query) |q| ecs.query_fini(q);
        if (phys.explosion_query) |q| ecs.query_fini(q);
        if (phys.render_ground_query) |q| ecs.query_fini(q);
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

    metrics.ground_count = countQueryEntities(world, phys.ground_query);
    metrics.verlet_count = countQueryEntities(world, phys.verlet_query);
    metrics.bullet_count = if (phys.bullet_query) |q| countQueryEntities(world, q) else 0;
    metrics.explosion_count = if (phys.explosion_query) |q| countQueryEntities(world, q) else 0;
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

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);

    if (ecs.singleton_get(world, C.PlayerContainer)) |pc| {
        _ = ecs.set(world, pc.entity, C.Position, .{ .x = w / 2.0, .y = h / 2.0 });
        _ = ecs.set(world, pc.entity, C.Velocity, .{ .x = 0.0, .y = 0.0 });
        _ = ecs.set(world, pc.entity, C.RecoilImpulse, .{ .x = 0.0 });

        const gun = ecs.lookup_child(world, pc.entity, "Gun");
        if (gun != 0) {
            if (ecs.get_mut(world, gun, C.Gun)) |g| {
                g.cooldown = 0.0;
            }
        }

        if (ecs.singleton_get(world, C.PlayerAttachmentsGroup)) |attach_group| {
            spawn_player_tail(world, pc.entity, attach_group.entity);
        }
    }

    @memcpy(background_buffer, sky_buffer);
    spawn_level(world, width, height);
    spawn_jellies(world, allocator, width);

    if (C.singletonGetMutSafe(world, C.FrameMetrics)) |metrics| {
        metrics.resetPerFrame();
    }
    updateEntityCounts(world);
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

    ecs.TAG(world, C.Bullet);
    ecs.TAG(world, C.Player);
    ecs.TAG(world, C.Ground);
    ecs.TAG(world, C.Destroyable);
    ecs.TAG(world, C.EffectZone);
    ecs.TAG(world, C.GroundGrid);
    ecs.TAG(world, C.PlayerLandable);

    ecs.COMPONENT(world, input_mod.InputState);
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
        .{ .id = ecs.id(C.Position) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "shoot", ecs.OnUpdate, systems.weapons.shoot_system, &.{
        .{ .id = ecs.id(C.Gun) },
        .{ .id = ecs.id(C.Position) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_controller", ecs.OnUpdate, systems.player.player_controller_system, &.{
        .{ .id = ecs.id(C.Player) },
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.Collider) },
        .{ .id = ecs.id(C.RecoilImpulse) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "physics_movement", ecs.OnUpdate, systems.physics.physics_movement_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.PhysicsBody) },
        .{ .id = ecs.id(C.VerletState), .oper = .Not },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "physics_collision", ecs.OnUpdate, systems.physics.physics_collision_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.Collider) },
        .{ .id = ecs.id(C.PhysicsBody) },
        .{ .id = ecs.id(C.VerletState), .oper = .Not },
    });

    var verlet_sys_desc = ecs.SYSTEM_DESC(systems.verlet.verlet_solver_system);
    verlet_sys_desc.phase = ecs.OnUpdate;
    verlet_sys_desc.immediate = true;
    _ = ecs.SYSTEM(world, "verlet_solver", &verlet_sys_desc);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "verlet_bullet_collision", ecs.OnUpdate, systems.verlet.verlet_bullet_collision_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.Collider) },
        .{ .id = ecs.id(C.Bullet) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_clamp", ecs.OnUpdate, systems.player.player_clamp_system, &.{
        .{ .id = ecs.id(C.Player) },
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.Collider) },
    });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "bullet_cleanup", ecs.OnUpdate, systems.weapons.bullet_cleanup_system, &.{
        .{ .id = ecs.id(C.Bullet) },
        .{ .id = ecs.id(C.Position) },
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

    const mouse_cursor = ecs.new_entity(world, "MouseCursor");
    _ = ecs.set(world, mouse_cursor, C.Position, .{ .x = 0.0, .y = 0.0 });

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);

    const player = ecs.new_entity(world, "Player");
    ecs.add(world, player, C.Player);
    _ = ecs.set(world, player, C.Position, .{ .x = w / 2.0, .y = h / 2.0 });
    _ = ecs.set(world, player, C.Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = PLAYER_SIZE / 2.0 } });
    _ = ecs.set(world, player, C.Renderable, .{ .color = C.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    _ = ecs.set(world, player, C.RecoilImpulse, .{ .x = 0.0 });
    _ = ecs.singleton_set(world, C.PlayerContainer, .{ .entity = player });

    const gun = ecs.new_entity(world, "Gun");
    _ = ecs.set(world, gun, C.Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, gun, C.Renderable, .{ .color = C.Color{ .r = 0, .g = 0, .b = 255, .a = 255 } });
    _ = ecs.set(world, gun, C.Collider, .{ .box = .{ .min = .{ .x = -4, .y = -4 }, .max = .{ .x = 4, .y = 4 } } });
    _ = ecs.set(world, gun, C.Gun, .{ .fire_rate = 0.05 });
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
    spawn_jellies(world, allocator, width);

    var ground_desc = ecs.query_desc_t{};
    ground_desc.terms[0] = .{ .id = ecs.id(C.Ground) };
    ground_desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .In };
    ground_desc.terms[2] = .{ .id = ecs.id(C.Collider), .inout = .In };
    ground_desc.terms[3] = .{ .id = ecs.id(C.ExplosionParticle), .oper = .Not };
    const ground_q = ecs.query_init(world, &ground_desc) catch unreachable;

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

    var render_ground_desc = ecs.query_desc_t{};
    render_ground_desc.terms[0] = .{ .id = ecs.id(C.Ground) };
    render_ground_desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .In };
    render_ground_desc.terms[2] = .{ .id = ecs.id(C.Collider), .inout = .In };
    render_ground_desc.terms[3] = .{ .id = ecs.id(C.Renderable), .inout = .In };
    const render_ground_q = ecs.query_init(world, &render_ground_desc) catch unreachable;

    var render_actor_desc = ecs.query_desc_t{};
    render_actor_desc.terms[0] = .{ .id = ecs.id(C.Position), .inout = .In };
    render_actor_desc.terms[1] = .{ .id = ecs.id(C.Collider), .inout = .In };
    render_actor_desc.terms[2] = .{ .id = ecs.id(C.Renderable), .inout = .In };
    render_actor_desc.terms[3] = .{ .id = ecs.id(C.Ground), .oper = .Not };
    render_actor_desc.terms[4] = .{ .id = ecs.id(C.VerletState), .oper = .Not };
    const render_actor_q = ecs.query_init(world, &render_actor_desc) catch unreachable;

    _ = ecs.singleton_set(world, C.PhysicsState, .{
        .ground_query = ground_q,
        .verlet_query = verlet_q,
        .player_landable_query = landable_q,
        .collider_query = collider_q,
        .attachment_query = attach_q,
        .reach_query = reach_q,
        .bullet_query = bullet_q,
        .explosion_query = explosion_q,
        .render_ground_query = render_ground_q,
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
    const ground_group = ecs.singleton_get(world, C.GroundGroup) orelse return;
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const wall_thickness_half: f32 = 50.0;

    const left_wall = ecs.new_entity(world, "LeftWall");
    _ = ecs.set(world, left_wall, C.Position, .{ .x = -wall_thickness_half, .y = h / 2.0 });
    _ = ecs.set(world, left_wall, C.Collider, .{ .box = .{ .min = .{ .x = -wall_thickness_half, .y = -h }, .max = .{ .x = wall_thickness_half, .y = h } } });
    ecs.add(world, left_wall, C.Ground);
    ecs.add_pair(world, left_wall, ecs.ChildOf, ground_group.entity);

    const right_wall = ecs.new_entity(world, "RightWall");
    _ = ecs.set(world, right_wall, C.Position, .{ .x = w + wall_thickness_half, .y = h / 2.0 });
    _ = ecs.set(world, right_wall, C.Collider, .{ .box = .{ .min = .{ .x = -wall_thickness_half, .y = -h }, .max = .{ .x = wall_thickness_half, .y = h } } });
    ecs.add(world, right_wall, C.Ground);
    ecs.add_pair(world, right_wall, ecs.ChildOf, ground_group.entity);

    const split_width_in_30 = w / 30.0;
    const split_height_in_30 = h / 30.0;
    for (0..60) |j| {
        const i = j / 2;
        const cx = split_width_in_30 * @as(f32, @floatFromInt(i)) + (split_width_in_30 / 2.0);
        const cy = split_height_in_30 * @as(f32, @floatFromInt(i)) + (split_height_in_30 / 2.0);
        spawnGroundGrid(world, cx - 5, cy - 5, 10, 10, ground_group.entity);
    }

    const floor = ecs.new_entity(world, "Floor");
    _ = ecs.set(world, floor, C.Position, .{ .x = w / 2.0, .y = h - 50.0 });
    _ = ecs.set(world, floor, C.Collider, .{ .box = .{ .min = .{ .x = -w / 2.0, .y = -50.0 }, .max = .{ .x = w / 2.0, .y = 50 } } });
    _ = ecs.set(world, floor, C.Renderable, .{ .color = C.Color{ .r = 0, .g = 255, .b = 0, .a = 255 } });
    ecs.add(world, floor, C.Ground);
    ecs.add_pair(world, floor, ecs.ChildOf, ground_group.entity);

    const heat_zone = ecs.new_entity(world, "Hot Ground Effect Zone");
    ecs.add(world, heat_zone, C.EffectZone);
    _ = ecs.set(world, heat_zone, C.Position, .{ .x = w / 2.0, .y = h - 50.0 });
    _ = ecs.set(world, heat_zone, C.Collider, .{ .box = .{ .min = .{ .x = -w / 2.0, .y = -100.0 }, .max = .{ .x = w / 2.0, .y = 50 } } });
    _ = ecs.set(world, heat_zone, Effect, Effect.heat_only);
    ecs.add_pair(world, heat_zone, ecs.ChildOf, ground_group.entity);
}

fn spawnGroundGrid(world: *ecs.world_t, start_x: f32, start_y: f32, width: f32, height: f32, ground_group: ecs.entity_t) void {
    const tile_size: f32 = 5.0;
    const cols: usize = @intFromFloat(width / tile_size);
    const rows: usize = @intFromFloat(height / tile_size);

    const grid_grouping = ecs.new_id(world);
    ecs.add(world, grid_grouping, C.GroundGrid);
    ecs.add_pair(world, grid_grouping, ecs.ChildOf, ground_group);

    for (0..rows) |r| {
        for (0..cols) |c_| {
            const e = ecs.new_id(world);
            ecs.add(world, e, C.Ground);

            const tx = start_x + (@as(f32, @floatFromInt(c_)) * tile_size) + (tile_size / 2.0);
            const ty = start_y + (@as(f32, @floatFromInt(r)) * tile_size) + (tile_size / 2.0);
            const half = tile_size / 2.0;

            _ = ecs.set(world, e, C.Position, .{ .x = tx, .y = ty });
            _ = ecs.set(world, e, C.Collider, .{ .box = .{ .min = .{ .x = -half, .y = -half }, .max = .{ .x = half, .y = half } } });
            _ = ecs.set(world, e, C.Renderable, .{ .color = C.Color{ .r = 0, .g = 255, .b = 0, .a = 255 } });
            ecs.add(world, e, C.Destroyable);
            ecs.add_pair(world, e, ecs.ChildOf, grid_grouping);
        }
    }
}

fn spawn_jellies(world: *ecs.world_t, allocator: std.mem.Allocator, width: usize) void {
    const creatures_group = ecs.singleton_get(world, C.CreaturesGroup) orelse return;
    const center_x = @as(f32, @floatFromInt(width)) / 2.0;

    const j1 = spawn_jelly_blob(world, allocator, creatures_group.entity, center_x * 2.0 - 100.0, 150.0, 80.0, 10, null);
    _ = spawn_jelly_blob(world, allocator, creatures_group.entity, center_x * 2.0 - 100.0 - 160.0, 150.0, 80.0, 10, &j1);
}

fn spawn_jelly_blob(
    world: *ecs.world_t,
    allocator: std.mem.Allocator,
    creatures_group: ecs.entity_t,
    cx: f32,
    cy: f32,
    radius: f32,
    segments: usize,
    connect_to: ?*const ecs.entity_t,
) ecs.entity_t {
    const nodes = allocator.alloc(ecs.entity_t, segments) catch unreachable;
    defer allocator.free(nodes);

    const center = ecs.new_id(world);
    ecs.add(world, center, C.PlayerLandable);
    ecs.add_pair(world, center, ecs.ChildOf, creatures_group);

    _ = ecs.set(world, center, C.Position, .{ .x = cx, .y = cy });
    _ = ecs.set(world, center, C.VerletState, .{ .old_x = cx, .old_y = cy, .friction = 0.99 });
    _ = ecs.set(world, center, C.Renderable, .{ .color = C.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    _ = ecs.set(world, center, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = radius / 2.0 } });
    _ = ecs.set(world, center, C.PhysicsBody, .{ .restitution = 0.2, .friction = 0.8 });

    const angle_step = (std.math.pi * 2.0) / @as(f32, @floatFromInt(segments));
    const perimeter_dist = @sqrt((radius * radius) + (radius * radius) - (2.0 * radius * radius * @cos(angle_step)));
    const player = ecs.singleton_get(world, C.PlayerContainer).?.entity;

    for (0..segments) |i| {
        const angle = @as(f32, @floatFromInt(i)) * angle_step;
        const px = cx + @cos(angle) * radius;
        const py = cy + @sin(angle) * radius;

        const node = ecs.new_id(world);
        nodes[i] = node;
        ecs.add_pair(world, node, ecs.ChildOf, creatures_group);

        _ = ecs.set(world, node, C.Position, .{ .x = px, .y = py });
        _ = ecs.set(world, node, C.VerletState, .{ .old_x = px, .old_y = py, .friction = 0.99 });
        _ = ecs.set(world, node, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 2.0 } });
        _ = ecs.set(world, node, C.PhysicsBody, .{ .restitution = 0.1, .friction = 0.9 });
        _ = ecs.set(world, node, C.Renderable, .{ .color = C.Color{ .r = 0, .g = 255, .b = 255, .a = 255 } });

        _ = ecs.set_pair(world, node, ecs.id(C.ReachTowards), player, C.ReachTowards, .{
            .stiffness = 0.1,
        });

        _ = ecs.set_pair(world, node, ecs.id(C.AttachedTo), center, C.AttachedTo, .{
            .dist = radius + (2.0 * @as(f32, @floatFromInt(i))),
            .stiffness = 0.05,
        });
    }

    for (0..segments) |i| {
        const current = nodes[i];
        const next = nodes[(i + 1) % segments];
        _ = ecs.set_pair(world, current, ecs.id(C.AttachedTo), next, C.AttachedTo, .{
            .dist = perimeter_dist,
            .stiffness = 1.0,
        });
    }

    if (connect_to) |parent| {
        const parent_pos = ecs.get(world, parent.*, C.Position).?;
        const dx = cx - parent_pos.x;
        const dy = cy - parent_pos.y;
        const actual_dist = @sqrt(dx * dx + dy * dy);
        _ = ecs.set_pair(world, center, ecs.id(C.AttachedTo), parent.*, C.AttachedTo, .{
            .dist = actual_dist,
            .stiffness = 0.1,
        });
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

test "reset_world clears and respawns jellies, bullets, tail, and ground without leaks" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);
    defer deinit(world);

    register_components(world);
    register_systems(world);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try spawn_initial_entities(world, arena.allocator(), 640, 360);

    const initial_verlets = countWithId(world, ecs.id(C.VerletState));
    const initial_ground = countWithId(world, ecs.id(C.Ground));

    // Spawn a bullet and modify gun cooldown to verify reset clears them
    const bullets_group = ecs.singleton_get(world, C.BulletsGroup).?.entity;
    const bullet = ecs.new_id(world);
    ecs.add(world, bullet, C.Bullet);
    ecs.add_pair(world, bullet, ecs.ChildOf, bullets_group);

    const gun = ecs.lookup(world, "Player.Gun");
    try testing.expect(gun != 0);
    ecs.get_mut(world, gun, C.Gun).?.cooldown = 0.5;

    var sky: [16]u32 = @splat(0x11111111);
    var bg: [16]u32 = @splat(0x22222222);
    reset_world(world, arena.allocator(), 640, 360, &sky, &bg);

    try testing.expectEqual(@as(usize, 0), countWithId(world, ecs.id(C.Bullet)));
    try testing.expectEqual(initial_verlets, countWithId(world, ecs.id(C.VerletState)));
    try testing.expectEqual(initial_ground, countWithId(world, ecs.id(C.Ground)));
    try testing.expectEqual(@as(f32, 0.0), ecs.get(world, gun, C.Gun).?.cooldown);
    try testing.expectEqual(@as(u32, 0x11111111), bg[0]);

    // Verify Verlet entities do not have Velocity component and only Player has Velocity
    try testing.expectEqual(@as(usize, 1), countWithId(world, ecs.id(C.Velocity)));

    // Step full PBD solver across initial world and again after reset_world
    for (0..10) |_| {
        systems.verlet.stepVerletPBDWithAllocator(world, arena.allocator(), 1.0 / 120.0);
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
