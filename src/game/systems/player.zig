const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const Engine = @import("../../engine/core.zig").Engine;
const input_mod = @import("../../engine/input.zig");
const physics = @import("physics.zig");

pub const PLAYER_SPEED: f32 = 400.0;

const Axis = enum { x, y };

/// True only when the player overlaps the top surface of a PlayerLandable entity.
fn playerTouchesLandable(world: *ecs.world_t, player_pos: C.Position, player_col: C.Collider) bool {
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return false;
    if (player_col != .circle) return false;
    const metrics = C.singletonGetMutSafe(world, C.FrameMetrics);

    var q_it = ecs.query_iter(world, phys.player_landable_query);

    while (ecs.query_next(&q_it)) {
        const core_positions = ecs.field(&q_it, C.Position, 1).?;
        const core_colliders = ecs.field(&q_it, C.Collider, 2).?;

        for (core_positions, core_colliders) |core_pos, core_col| {
            if (core_col != .circle) continue;
            if (metrics) |m| m.physics_checks += 1;
            const contact = physics.collideManifold(player_pos, player_col, core_pos, core_col);
            if (contact.count > 0 and contact.n.y > 0.5) {
                if (metrics) |m| m.physics_hits += 1;
                ecs.iter_fini(&q_it);
                return true;
            }
        }
    }

    return false;
}

/// Resolve axis movement flush against overlapping Ground AABBs instead of rolling back full dt steps.
fn resolveAxisGroundCollision(
    world: *ecs.world_t,
    pos: *C.Position,
    vel: *C.Velocity,
    col: C.Collider,
    prev_coord: f32,
    axis: Axis,
) void {
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return;
    const metrics = C.singletonGetMutSafe(world, C.FrameMetrics);
    const local_aabb = physics.getWorldAABB(.{ .x = 0, .y = 0 }, col);

    var q_it = ecs.query_iter(world, phys.ground_query);

    var hit = false;
    while (ecs.query_next(&q_it)) {
        const g_positions = ecs.field(&q_it, C.Position, 1).?;
        const g_colliders = ecs.field(&q_it, C.Collider, 2).?;

        for (0..q_it.count()) |i| {
            if (metrics) |m| m.physics_checks += 1;
            const player_aabb = physics.getWorldAABB(pos.*, col);
            const ground_aabb = physics.getWorldAABB(g_positions[i], g_colliders[i]);
            if (!c2.aabbToAABB(player_aabb, ground_aabb)) continue;
            if (metrics) |m| m.physics_hits += 1;

            hit = true;
            switch (axis) {
                .x => {
                    if (vel.x > 0) {
                        const snap_x = ground_aabb.min.x - physics.SURFACE_EPSILON - local_aabb.max.x;
                        pos.x = @max(prev_coord, @min(pos.x, snap_x));
                    } else if (vel.x < 0) {
                        const snap_x = ground_aabb.max.x + physics.SURFACE_EPSILON - local_aabb.min.x;
                        pos.x = @min(prev_coord, @max(pos.x, snap_x));
                    }
                },
                .y => {
                    if (vel.y > 0) {
                        const snap_y = ground_aabb.min.y - physics.SURFACE_EPSILON - local_aabb.max.y;
                        pos.y = @max(prev_coord, @min(pos.y, snap_y));
                    } else if (vel.y < 0) {
                        const snap_y = ground_aabb.max.y + physics.SURFACE_EPSILON - local_aabb.min.y;
                        pos.y = @min(prev_coord, @max(pos.y, snap_y));
                    }
                },
            }
        }
    }

    if (hit) {
        switch (axis) {
            .x => vel.x = 0,
            .y => vel.y = 0,
        }
    }
}

/// Kinematic player controller: handles input, gravity, jump, recoil, and swept axis terrain collision.
pub fn player_controller_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    velocities: []C.Velocity,
    colliders: []C.Collider,
    recoils: []C.RecoilImpulse,
) void {
    const world = it.world;
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const dt = it.delta_time;

    for (positions, velocities, colliders, recoils) |*pos, *vel, col, *recoil| {
        const test_pos = C.Position{ .x = pos.x, .y = pos.y + 1 };
        const test_aabb = physics.getWorldAABB(test_pos, col);
        const is_grounded =
            physics.checkCollision(world, test_aabb) or
            playerTouchesLandable(world, test_pos, col);

        var dx: f32 = 0;
        if (input.pressed_directions.left) dx -= 1;
        if (input.pressed_directions.right) dx += 1;

        if (is_grounded) {
            const decay: f32 = 5.0;
            recoil.x = recoil.x * std.math.exp(-decay * dt);
            vel.x = (dx * PLAYER_SPEED) + recoil.x;
        } else {
            vel.x += recoil.x;
            recoil.x = 0;

            const target_vx = dx * PLAYER_SPEED;
            const air_control: f32 = 2.0;
            vel.x = target_vx + (vel.x - target_vx) * std.math.exp(-air_control * dt);
        }

        vel.y += physics.GRAVITY * dt;
        if (input.pressed_directions.up and is_grounded) {
            vel.y = -PLAYER_SPEED * 1.5;
        } else if (input.pressed_directions.down) {
            vel.y = PLAYER_SPEED;
        }

        const prev_x = pos.x;
        pos.x += vel.x * dt;
        resolveAxisGroundCollision(world, pos, vel, col, prev_x, .x);

        const prev_y = pos.y;
        pos.y += vel.y * dt;
        resolveAxisGroundCollision(world, pos, vel, col, prev_y, .y);
    }
}

pub fn player_clamp_system(it: *ecs.iter_t, positions: []C.Position, velocities: []C.Velocity, colliders: []C.Collider) void {
    const engine = Engine.getEngine(it.world);
    const w: f32 = @floatFromInt(engine.width);
    const h: f32 = @floatFromInt(engine.height);

    for (positions, velocities, colliders) |*pos, *vel, col| {
        const local_aabb = physics.getWorldAABB(.{ .x = 0, .y = 0 }, col);
        const min_x = -local_aabb.min.x;
        const max_x = @max(min_x, w - local_aabb.max.x);
        const min_y = -local_aabb.min.y;
        const max_y = @max(min_y, h - local_aabb.max.y);

        pos.x = std.math.clamp(pos.x, min_x, max_x);
        pos.y = std.math.clamp(pos.y, min_y, max_y);

        if ((pos.x == min_x and vel.x < 0) or (pos.x == max_x and vel.x > 0)) {
            vel.x = 0;
        }
        if ((pos.y == min_y and vel.y < 0) or (pos.y == max_y and vel.y > 0)) {
            vel.y = 0;
        }
    }
}

test "playerTouchesLandable only triggers on top-facing overlap" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.PhysicsState);
    ecs.TAG(world, C.Ground);
    ecs.TAG(world, C.PlayerLandable);

    var ground_desc = ecs.query_desc_t{};
    ground_desc.terms[0] = .{ .id = ecs.id(C.Ground) };
    ground_desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .In };
    ground_desc.terms[2] = .{ .id = ecs.id(C.Collider), .inout = .In };
    const ground_q = ecs.query_init(world, &ground_desc) catch unreachable;
    defer ecs.query_fini(ground_q);

    var verlet_desc = ecs.query_desc_t{};
    verlet_desc.terms[0] = .{ .id = ecs.id(C.Position), .inout = .InOut };
    const verlet_q = ecs.query_init(world, &verlet_desc) catch unreachable;
    defer ecs.query_fini(verlet_q);

    var landable_desc = ecs.query_desc_t{};
    landable_desc.terms[0] = .{ .id = ecs.id(C.PlayerLandable) };
    landable_desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .In };
    landable_desc.terms[2] = .{ .id = ecs.id(C.Collider), .inout = .In };
    const landable_q = ecs.query_init(world, &landable_desc) catch unreachable;
    defer ecs.query_fini(landable_q);

    var collider_desc = ecs.query_desc_t{};
    collider_desc.terms[0] = .{ .id = ecs.id(C.Position), .inout = .In };
    const collider_q = ecs.query_init(world, &collider_desc) catch unreachable;
    defer ecs.query_fini(collider_q);

    _ = ecs.singleton_set(world, C.PhysicsState, .{
        .ground_query = ground_q,
        .verlet_query = verlet_q,
        .player_landable_query = landable_q,
        .collider_query = collider_q,
    });

    const core = ecs.new_id(world);
    ecs.add(world, core, C.PlayerLandable);
    _ = ecs.set(world, core, C.Position, .{ .x = 100, .y = 100 });
    _ = ecs.set(world, core, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 20 } });

    const player_col = C.Collider{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 15 } };

    // Top contact -> true
    try testing.expect(playerTouchesLandable(world, .{ .x = 100, .y = 70 }, player_col));
    // Side contact -> false
    try testing.expect(!playerTouchesLandable(world, .{ .x = 70, .y = 100 }, player_col));
    // Bottom contact -> false
    try testing.expect(!playerTouchesLandable(world, .{ .x = 100, .y = 130 }, player_col));
    // No overlap -> false
    try testing.expect(!playerTouchesLandable(world, .{ .x = 200, .y = 200 }, player_col));
}
