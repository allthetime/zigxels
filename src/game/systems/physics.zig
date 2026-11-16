const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const Engine = @import("../../engine/core.zig").Engine;
const pixel_mod = @import("../../engine/pixels.zig");
const Effect = @import("../../engine/effects.zig").Effect;

pub const GRAVITY: f32 = 2500.0;
pub const SURFACE_EPSILON: f32 = 0.01;

var explosion_prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);

pub fn getWorldAABB(pos: C.Position, collider: C.Collider) c2.AABB {
    return switch (collider) {
        .box => |b| .{
            .min = .{ .x = b.min.x + pos.x, .y = b.min.y + pos.y },
            .max = .{ .x = b.max.x + pos.x, .y = b.max.y + pos.y },
        },
        .circle => |c| .{
            .min = .{ .x = (pos.x + c.p.x) - c.r, .y = (pos.y + c.p.y) - c.r },
            .max = .{ .x = (pos.x + c.p.x) + c.r, .y = (pos.y + c.p.y) + c.r },
        },
    };
}

pub fn getWorldCircle(pos: C.Position, c: c2.Circle) c2.Circle {
    return .{
        .p = .{ .x = pos.x + c.p.x, .y = pos.y + c.p.y },
        .r = c.r,
    };
}

/// Compute collision manifold between shape A and shape B.
/// When `m.count > 0`, `m.n` always points from A toward B.
pub fn collideManifold(pos_a: C.Position, col_a: C.Collider, pos_b: C.Position, col_b: C.Collider) c2.Manifold {
    var m: c2.Manifold = undefined;
    m.count = 0;

    switch (col_a) {
        .circle => |ca| {
            const world_ca = getWorldCircle(pos_a, ca);
            switch (col_b) {
                .circle => |cb| c2.circleToCircleManifold(world_ca, getWorldCircle(pos_b, cb), &m),
                .box => c2.circleToAABBManifold(world_ca, getWorldAABB(pos_b, col_b), &m),
            }
        },
        .box => {
            const world_aa = getWorldAABB(pos_a, col_a);
            switch (col_b) {
                .circle => |cb| {
                    c2.circleToAABBManifold(getWorldCircle(pos_b, cb), world_aa, &m);
                    if (m.count > 0) m.n = m.n.neg();
                },
                .box => c2.aabbToAABBManifold(world_aa, getWorldAABB(pos_b, col_b), &m),
            }
        },
    }

    return m;
}

/// Check if an AABB overlaps any Ground entity.
pub fn checkCollision(world: *ecs.world_t, test_aabb: c2.AABB) bool {
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return false;
    var q_it = ecs.query_iter(world, phys.ground_query);

    while (ecs.query_next(&q_it)) {
        const g_positions = ecs.field(&q_it, C.Position, 1).?;
        const g_colliders = ecs.field(&q_it, C.Collider, 2).?;

        for (0..q_it.count()) |i| {
            const ground_aabb = getWorldAABB(g_positions[i], g_colliders[i]);
            if (c2.aabbToAABB(test_aabb, ground_aabb)) {
                ecs.iter_fini(&q_it);
                return true;
            }
        }
    }
    return false;
}

/// Separate body from penetration along normal `n` (pointing Entity -> Obstacle) and apply bounce/friction.
pub fn resolveBody(pos: *C.Position, vel: *C.Velocity, n: c2.Vec2, depth: f32, body: *const C.PhysicsBody) void {
    const push = depth + SURFACE_EPSILON;
    pos.x -= n.x * push;
    pos.y -= n.y * push;

    const v_dot_n = (vel.x * n.x) + (vel.y * n.y);
    if (v_dot_n > 0) {
        const vn_x = n.x * v_dot_n;
        const vn_y = n.y * v_dot_n;
        const vt_x = vel.x - vn_x;
        const vt_y = vel.y - vn_y;

        vel.x = (vt_x * body.friction) - (vn_x * body.restitution);
        vel.y = (vt_y * body.friction) - (vn_y * body.restitution);
    }
}

pub fn gravity_system(it: *ecs.iter_t, velocities: []C.Velocity) void {
    const dt = it.delta_time;
    for (velocities) |*vel| {
        vel.y += GRAVITY * dt;
    }
}

pub fn physics_movement_system(it: *ecs.iter_t, positions: []C.Position, velocities: []C.Velocity) void {
    const dt = it.delta_time;
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;
    }
}

fn containsEntity(items: []const ecs.entity_t, target: ecs.entity_t) bool {
    for (items) |e| {
        if (e == target) return true;
    }
    return false;
}

pub fn physics_collision_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    velocities: []C.Velocity,
    colliders: []C.Collider,
    physicsBodies: []C.PhysicsBody,
) void {
    const world = it.world;
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return;
    const engine = Engine.getEngine(world);
    const arena = engine.arena.allocator();
    const ents = it.entities();

    var doomed_ground: std.ArrayList(ecs.entity_t) = .empty;
    var doomed_bullets: std.ArrayList(ecs.entity_t) = .empty;
    const entity_doomed = arena.alloc(bool, it.count()) catch return;
    @memset(entity_doomed, false);

    // 1. Dynamic bodies vs. ground
    var q_it = ecs.query_iter(world, phys.ground_query);
    while (ecs.query_next(&q_it)) {
        const g_positions = ecs.field(&q_it, C.Position, 1).?;
        const g_colliders = ecs.field(&q_it, C.Collider, 2).?;
        const g_ents = q_it.entities();

        for (0..q_it.count()) |i| {
            const gp = g_positions[i];
            const gcol = g_colliders[i];
            const ground_entity = g_ents[i];
            const ground_aabb = getWorldAABB(gp, gcol);

            for (positions, velocities, colliders, physicsBodies, 0..) |*pos, *vel, col, *pb, entity_idx| {
                if (entity_doomed[entity_idx]) continue;

                const m = collideManifold(pos.*, col, gp, gcol);
                if (m.count == 0) continue;

                const entity = ents[entity_idx];
                const is_bullet = ecs.has_id(world, entity, ecs.id(C.Bullet));

                if (is_bullet and ecs.has_id(world, ground_entity, ecs.id(C.Destroyable))) {
                    if (!containsEntity(doomed_ground.items, ground_entity)) {
                        const gw = ground_aabb.max.x - ground_aabb.min.x;
                        const gh = ground_aabb.max.y - ground_aabb.min.y;
                        if (gw > 0 and gh > 0) {
                            pixel_mod.restoreRect(
                                engine,
                                @intFromFloat(ground_aabb.min.x),
                                @intFromFloat(ground_aabb.min.y),
                                @intFromFloat(gw),
                                @intFromFloat(gh),
                            );
                        }
                        doomed_ground.append(arena, ground_entity) catch {};
                    }

                    entity_doomed[entity_idx] = true;
                    doomed_bullets.append(arena, entity) catch {};
                    vel.x *= 0.5;
                } else {
                    resolveBody(pos, vel, m.n, m.depths[0], pb);
                }
            }
        }
    }

    // 2. Surviving bullets vs. surviving bullets
    for (0..it.count()) |i| {
        if (entity_doomed[i]) continue;
        if (!ecs.has_id(world, ents[i], ecs.id(C.Bullet))) continue;
        if (colliders[i] != .circle) continue;

        for (i + 1..it.count()) |j| {
            if (entity_doomed[j]) continue;
            if (!ecs.has_id(world, ents[j], ecs.id(C.Bullet))) continue;
            if (colliders[j] != .circle) continue;

            const m = collideManifold(positions[i], colliders[i], positions[j], colliders[j]);
            if (m.count > 0) {
                resolveBody(&positions[i], &velocities[i], m.n, m.depths[0] * 0.5, &physicsBodies[i]);
                resolveBody(&positions[j], &velocities[j], m.n.neg(), m.depths[0] * 0.5, &physicsBodies[j]);
            }
        }
    }

    // 3. Delete destroyed ground and bullets after all collision reads finish
    for (doomed_ground.items) |ground_e| {
        ecs.delete(world, ground_e);
    }
    for (doomed_bullets.items) |bullet_e| {
        ecs.delete(world, bullet_e);
    }
}

pub const ExplosionOptions = struct {
    speed: f32 = 150.0,
    spread: f32 = 1.5,
    color: u32 = 0xFF00FF00,
    bounce: f32 = 0.3,
    randomness: f32 = 1.0,
};

pub fn spawnExplosion(world: *ecs.world_t, x: f32, y: f32, dir_x: f32, dir_y: f32, options: ExplosionOptions) void {
    const rnd = explosion_prng.random();
    for (0..10) |_| {
        const e = ecs.new_id(world);
        const spread_angle = (rnd.float(f32) - 0.5) * options.spread;
        const cos_a = std.math.cos(spread_angle);
        const sin_a = std.math.sin(spread_angle);

        const p_vx = dir_x * cos_a - dir_y * sin_a;
        const p_vy = dir_x * sin_a + dir_y * cos_a;
        const speed = 100.0 + (rnd.float(f32) * options.randomness) * options.speed;

        _ = ecs.set(world, e, C.Position, .{ .x = x, .y = y });
        _ = ecs.set(world, e, C.Velocity, .{ .x = p_vx * speed, .y = p_vy * speed });
        _ = ecs.set(world, e, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 1 } });
        _ = ecs.set(world, e, C.ExplosionParticle, .{
            .lifetime = 0.3 + rnd.float(f32) * 0.4,
            .color = options.color,
        });
        _ = ecs.set(world, e, C.PhysicsBody, .{
            .restitution = options.bounce,
            .friction = 0.8,
        });
    }
}

pub fn explosion_lifetime_system(it: *ecs.iter_t, particles: []C.ExplosionParticle) void {
    const dt = it.delta_time;
    const ents = it.entities();

    for (particles, 0..) |*p, i| {
        p.lifetime -= dt;
        if (p.lifetime <= 0) {
            ecs.delete(it.world, ents[i]);
        }
    }
}

pub fn explosion_render_system(it: *ecs.iter_t, positions: []C.Position, particles: []C.ExplosionParticle) void {
    const engine = Engine.getEngine(it.world);
    const sprite_size: usize = 5;

    for (positions, particles) |pos, p| {
        pixel_mod.drawRect(
            engine,
            @intFromFloat(pos.x),
            @intFromFloat(pos.y),
            sprite_size,
            sprite_size,
            p.color,
            Effect.none,
        );
    }
}

test "collideManifold always points normal from A to B across all shape combinations" {
    const testing = std.testing;
    const circle = C.Collider{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 10 } };
    const box = C.Collider{ .box = .{ .min = .{ .x = -10, .y = -10 }, .max = .{ .x = 10, .y = 10 } } };

    // A at (0, 0), B at (15, 0) => A -> B normal must point +X
    const pos_a = C.Position{ .x = 0, .y = 0 };
    const pos_b = C.Position{ .x = 15, .y = 0 };

    const m_cc = collideManifold(pos_a, circle, pos_b, circle);
    try testing.expect(m_cc.count > 0 and m_cc.n.x > 0.99);

    const m_cb = collideManifold(pos_a, circle, pos_b, box);
    try testing.expect(m_cb.count > 0 and m_cb.n.x > 0.99);

    const m_bc = collideManifold(pos_a, box, pos_b, circle);
    try testing.expect(m_bc.count > 0 and m_bc.n.x > 0.99);

    const m_bb = collideManifold(pos_a, box, pos_b, box);
    try testing.expect(m_bb.count > 0 and m_bb.n.x > 0.99);
}
