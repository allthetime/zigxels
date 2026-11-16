const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const physics = @import("physics.zig");

pub const JELLY_REPULSION: f32 = 0.3;

pub fn verlet_integration_system(it: *ecs.iter_t, positions: []C.Position, verlets: []C.VerletState) void {
    const dt = it.delta_time;

    for (positions, verlets) |*pos, *vs| {
        const vx = (pos.x - vs.old_x) * vs.friction;
        const vy = (pos.y - vs.old_y) * vs.friction;

        vs.old_x = pos.x;
        vs.old_y = pos.y;

        pos.x += vx;
        pos.y += vy + (physics.GRAVITY * 2.0 * dt * dt);
    }
}

pub fn reach_system(it: *ecs.iter_t) void {
    const reach_data = ecs.field(it, C.ReachTowards, 0).?;
    const pair_id = it.ids.?[0];
    const target_id = ecs.pair_second(pair_id);
    const positions = ecs.field(it, C.Position, 1).?;

    const t_pos = ecs.get(it.world, target_id, C.Position) orelse return;

    for (reach_data, positions) |data, *pos| {
        const dx = t_pos.x - pos.x;
        const dy = t_pos.y - pos.y;

        pos.x += dx * data.stiffness * it.delta_time;
        pos.y += dy * data.stiffness * it.delta_time;
    }
}

pub fn attachment_solver_system(it: *ecs.iter_t) void {
    const world = it.world;
    const pair_id = it.ids.?[0];
    const target_id = ecs.pair_second(pair_id);

    const constraints = ecs.field(it, C.AttachedTo, 0).?;
    const positions = ecs.field(it, C.Position, 1).?;

    const solver_iterations = 24;
    const parent_is_player = ecs.has_id(world, target_id, ecs.id(C.Player));

    for (0..solver_iterations) |_| {
        for (0..it.count()) |i| {
            const data = constraints[i];
            const child_pos = &positions[i];
            const parent_pos = ecs.get_mut(world, target_id, C.Position) orelse continue;

            const dx = child_pos.x - parent_pos.x;
            const dy = child_pos.y - parent_pos.y;
            const dist = @sqrt(dx * dx + dy * dy);

            if (dist > 0.0001) {
                const diff = (dist - data.dist) / dist;
                const tx = dx * diff * 0.5 * data.stiffness;
                const ty = dy * diff * 0.5 * data.stiffness;

                child_pos.x -= tx;
                child_pos.y -= ty;

                if (!parent_is_player) {
                    parent_pos.x += tx;
                    parent_pos.y += ty;
                }
            }
        }
    }
}

fn resolveVerletBody(pos: *C.Position, n: c2.Vec2, depth: f32, body: *const C.PhysicsBody, vs: *C.VerletState) void {
    const push_x = n.x * (depth + physics.SURFACE_EPSILON);
    const push_y = n.y * (depth + physics.SURFACE_EPSILON);

    pos.x -= push_x;
    pos.y -= push_y;

    var vx = pos.x - vs.old_x;
    var vy = pos.y - vs.old_y;
    const v_dot_n = (vx * n.x) + (vy * n.y);

    if (v_dot_n > 0) {
        const vn_x = n.x * v_dot_n;
        const vn_y = n.y * v_dot_n;
        const vt_x = vx - vn_x;
        const vt_y = vy - vn_y;

        const max_verlet_speed: f32 = 20.0;
        const new_vx = std.math.clamp((vt_x * body.friction) - (vn_x * body.restitution), -max_verlet_speed, max_verlet_speed);
        const new_vy = std.math.clamp((vt_y * body.friction) - (vn_y * body.restitution), -max_verlet_speed, max_verlet_speed);

        vs.old_x = pos.x - new_vx;
        vs.old_y = pos.y - new_vy;
    } else {
        vx = pos.x - vs.old_x;
        vy = pos.y - vs.old_y;

        const vn_dot = (vx * n.x) + (vy * n.y);
        const vn_x = n.x * vn_dot;
        const vn_y = n.y * vn_dot;

        const vt_x = (vx - vn_x) * body.friction;
        const vt_y = (vy - vn_y) * body.friction;

        vs.old_x = pos.x - vt_x;
        vs.old_y = pos.y - vt_y;
    }
}

pub fn verlet_collision_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    verlets: []C.VerletState,
    colliders: []C.Collider,
    physicsBodies: []C.PhysicsBody,
) void {
    const world = it.world;
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return;

    // 1. Verlet vs. ground
    var q_it = ecs.query_iter(world, phys.ground_query);

    while (ecs.query_next(&q_it)) {
        const g_positions = ecs.field(&q_it, C.Position, 1).?;
        const g_colliders = ecs.field(&q_it, C.Collider, 2).?;

        for (0..q_it.count()) |i| {
            const gp = g_positions[i];
            const gcol = g_colliders[i];

            for (positions, verlets, colliders, physicsBodies) |*pos, *vs, col, *pb| {
                const m = physics.collideManifold(pos.*, col, gp, gcol);
                if (m.count > 0) {
                    resolveVerletBody(pos, m.n, m.depths[0], pb, vs);
                }
            }
        }
    }

    // 2. Non-landable Verlet particles vs. player
    if (ecs.singleton_get(world, C.PlayerContainer)) |pc| {
        const p_pos = ecs.get(world, pc.entity, C.Position) orelse return;
        const p_col = ecs.get(world, pc.entity, C.Collider) orelse return;
        const player_box = C.Collider{ .box = physics.getWorldAABB(p_pos.*, p_col.*) };
        const origin = C.Position{ .x = 0, .y = 0 };
        const verlet_entities = it.entities();

        for (positions, verlets, colliders, physicsBodies, 0..) |*pos, *vs, col, *pb, entity_index| {
            if (ecs.has_id(world, verlet_entities[entity_index], ecs.id(C.PlayerLandable))) continue;

            const m = physics.collideManifold(pos.*, col, origin, player_box);
            if (m.count > 0) {
                resolveVerletBody(pos, m.n, m.depths[0], pb, vs);
            }
        }
    }
}

pub fn verlet_self_collision_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    verlets: []C.VerletState,
    colliders: []C.Collider,
) void {
    _ = verlets;
    const world = it.world;
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return;
    const ents = it.entities();

    var q_it = ecs.query_iter(world, phys.verlet_query);

    while (ecs.query_next(&q_it)) {
        const other_positions = ecs.field(&q_it, C.Position, 0).?;
        const other_colliders = ecs.field(&q_it, C.Collider, 2).?;
        const other_ents = q_it.entities();

        for (positions, colliders, 0..) |*p1, c1, i| {
            if (c1 != .circle) continue;
            const e1 = ents[i];
            const parent1 = ecs.get_target(world, e1, ecs.id(C.AttachedTo), 0);

            for (other_positions, other_colliders, 0..) |*p2, c_2, j| {
                if (c_2 != .circle) continue;
                const e2 = other_ents[j];
                if (e1 >= e2) continue;

                const parent2 = ecs.get_target(world, e2, ecs.id(C.AttachedTo), 0);
                if (parent1 != 0 and parent1 == parent2) continue;

                const dx = (p2.x + c_2.circle.p.x) - (p1.x + c1.circle.p.x);
                const dy = (p2.y + c_2.circle.p.y) - (p1.y + c1.circle.p.y);
                const dist_sq = (dx * dx) + (dy * dy);
                const min_dist = c1.circle.r + c_2.circle.r;

                if (dist_sq < min_dist * min_dist and dist_sq > 0.0001) {
                    const dist = @sqrt(dist_sq);
                    const overlap = min_dist - dist;
                    const nx = dx / dist;
                    const ny = dy / dist;

                    const push_x = nx * overlap * 0.5 * JELLY_REPULSION;
                    const push_y = ny * overlap * 0.5 * JELLY_REPULSION;

                    p1.x -= push_x;
                    p1.y -= push_y;
                    p2.x += push_x;
                    p2.y += push_y;
                }
            }
        }
    }
}

pub fn verlet_bullet_collision_system(
    it: *ecs.iter_t,
    bullet_positions: []C.Position,
    bullet_velocities: []C.Velocity,
    bullet_colliders: []C.Collider,
) void {
    const world = it.world;
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return;

    var q_it = ecs.query_iter(world, phys.verlet_query);

    while (ecs.query_next(&q_it)) {
        const v_positions = ecs.field(&q_it, C.Position, 0).?;
        const v_states = ecs.field(&q_it, C.VerletState, 1).?;
        const v_colliders = ecs.field(&q_it, C.Collider, 2).?;

        for (v_positions, v_states, v_colliders) |v_pos, *vs, v_col| {
            for (bullet_positions, bullet_velocities, bullet_colliders) |*b_pos, *b_vel, b_col| {
                const m = physics.collideManifold(b_pos.*, b_col, v_pos, v_col);
                if (m.count == 0) continue;

                const overlap = m.depths[0];
                const n = m.n; // Points Bullet -> Verlet

                b_pos.x -= n.x * (overlap + physics.SURFACE_EPSILON);
                b_pos.y -= n.y * (overlap + physics.SURFACE_EPSILON);

                const v_dot_n = (b_vel.x * n.x) + (b_vel.y * n.y);
                if (v_dot_n > 0) {
                    const restitution: f32 = 1.2;
                    b_vel.x -= n.x * v_dot_n * (1.0 + restitution);
                    b_vel.y -= n.y * v_dot_n * (1.0 + restitution);

                    const impact_force: f32 = 1.5;
                    vs.old_x -= n.x * v_dot_n * impact_force * it.delta_time;
                    vs.old_y -= n.y * v_dot_n * impact_force * it.delta_time;
                }
            }
        }
    }
}
