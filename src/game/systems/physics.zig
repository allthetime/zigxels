const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const mw = @import("../material_world.zig");
const Engine = @import("../../engine/core.zig").Engine;
const pixel_mod = @import("../../engine/pixels.zig");
const Effect = @import("../../engine/effects.zig").Effect;

pub const GRAVITY: f32 = 2500.0;
pub const SURFACE_EPSILON: f32 = 0.01;
pub const BULLET_CARVE_RADIUS: f32 = 14.0;
pub const BULLET_DEBRIS_CHANCE: f32 = 0.25;

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

/// Check if an AABB overlaps solid MaterialGrid cells or any optional Ground entity.
pub fn checkCollision(world: *ecs.world_t, test_aabb: c2.AABB) bool {
    const metrics = C.singletonGetMutSafe(world, C.FrameMetrics);
    if (C.singletonGetSafe(world, mw.MaterialGrid)) |grid| {
        if (grid.aabbOverlapsSolid(
            test_aabb,
            if (metrics) |m| &m.physics_checks else null,
            if (metrics) |m| &m.physics_hits else null,
        )) {
            return true;
        }
    }

    const phys = C.singletonGetSafe(world, C.PhysicsState) orelse return false;
    const ground_q = phys.ground_query orelse return false;
    var q_it = ecs.query_iter(world, ground_q);

    while (ecs.query_next(&q_it)) {
        const g_positions = ecs.field(&q_it, C.Position, 1).?;
        const g_colliders = ecs.field(&q_it, C.Collider, 2).?;

        for (0..q_it.count()) |i| {
            if (metrics) |m| m.physics_checks += 1;
            const ground_aabb = getWorldAABB(g_positions[i], g_colliders[i]);
            if (c2.aabbToAABB(test_aabb, ground_aabb)) {
                if (metrics) |m| m.physics_hits += 1;
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

pub fn physics_movement_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    velocities: []C.Velocity,
    physicsBodies: []C.PhysicsBody,
) void {
    const dt = it.delta_time;
    for (positions, velocities, physicsBodies) |*pos, vel, *pb| {
        pb.prev_x = pos.x;
        pb.prev_y = pos.y;
        pb.has_prev = true;
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;
    }
}

fn resolveBodyAgainstMaterialGrid(
    grid: *const mw.MaterialGrid,
    pos: *C.Position,
    vel: *C.Velocity,
    col: C.Collider,
    pb: *const C.PhysicsBody,
    metrics: ?*C.FrameMetrics,
) void {
    if (grid.width == 0 or grid.height == 0) return;

    const aabb = getWorldAABB(pos.*, col);
    const min_gx = @max(0, grid.worldToCellX(aabb.min.x));
    const max_gx = @min(@as(i32, @intCast(grid.width)) - 1, grid.worldToCellX(aabb.max.x - 0.0001));
    const min_gy = @max(0, grid.worldToCellY(aabb.min.y));
    const max_gy = @min(@as(i32, @intCast(grid.height)) - 1, grid.worldToCellY(aabb.max.y - 0.0001));
    if (max_gx < min_gx or max_gy < min_gy) return;

    const half = grid.cellSizeF() * 0.5;
    const cell_col = C.Collider{ .box = .{
        .min = .{ .x = -half, .y = -half },
        .max = .{ .x = half, .y = half },
    } };

    var gy = min_gy;
    while (gy <= max_gy) : (gy += 1) {
        const cy = grid.cellToWorldCenterY(gy);
        var gx = min_gx;
        while (gx <= max_gx) : (gx += 1) {
            if (metrics) |mtr| mtr.physics_checks += 1;
            if (!grid.isSolidAtCell(gx, gy)) continue;

            const cell_pos = C.Position{ .x = grid.cellToWorldCenterX(gx), .y = cy };
            const m = collideManifold(pos.*, col, cell_pos, cell_col);
            if (m.count == 0) continue;

            if (metrics) |mtr| mtr.physics_hits += 1;
            resolveBody(pos, vel, m.n, m.depths[0], pb);
        }
    }
}

fn findBulletCellOverlap(
    grid: *const mw.MaterialGrid,
    pos: C.Position,
    col: C.Collider,
    metrics: ?*C.FrameMetrics,
) ?mw.RaycastHit {
    if (grid.width == 0 or grid.height == 0) return null;
    const aabb = getWorldAABB(pos, col);
    const min_gx = @max(0, grid.worldToCellX(aabb.min.x));
    const max_gx = @min(@as(i32, @intCast(grid.width)) - 1, grid.worldToCellX(aabb.max.x - 0.0001));
    const min_gy = @max(0, grid.worldToCellY(aabb.min.y));
    const max_gy = @min(@as(i32, @intCast(grid.height)) - 1, grid.worldToCellY(aabb.max.y - 0.0001));
    if (max_gx < min_gx or max_gy < min_gy) return null;

    const half = grid.cellSizeF() * 0.5;
    const cell_col = C.Collider{ .box = .{
        .min = .{ .x = -half, .y = -half },
        .max = .{ .x = half, .y = half },
    } };

    var gy = min_gy;
    while (gy <= max_gy) : (gy += 1) {
        const cy = grid.cellToWorldCenterY(gy);
        var gx = min_gx;
        while (gx <= max_gx) : (gx += 1) {
            if (metrics) |mtr| mtr.physics_checks += 1;
            const cell = grid.getCell(gx, gy) orelse continue;
            if (!cell.material.isSolid()) continue;

            const cell_pos = C.Position{ .x = grid.cellToWorldCenterX(gx), .y = cy };
            const m = collideManifold(pos, col, cell_pos, cell_col);
            if (m.count == 0) continue;

            if (metrics) |mtr| mtr.physics_hits += 1;
            return .{
                .t = 1.0,
                .world_x = pos.x,
                .world_y = pos.y,
                .cell_x = gx,
                .cell_y = gy,
                .normal = m.n.neg(),
                .material = cell.material,
                .indestructible = cell.indestructible,
            };
        }
    }
    return null;
}

pub fn physics_collision_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    velocities: []C.Velocity,
    colliders: []C.Collider,
    physicsBodies: []C.PhysicsBody,
) void {
    const world = it.world;
    const phys = C.singletonGetSafe(world, C.PhysicsState);
    const grid = C.singletonGetMutSafe(world, mw.MaterialGrid);
    const metrics = C.singletonGetMutSafe(world, C.FrameMetrics);
    const ents = it.entities();

    var fallback_arena: ?std.heap.ArenaAllocator = null;
    defer if (fallback_arena) |*a| a.deinit();
    const arena: std.mem.Allocator = if (ecs.get_ctx(world)) |ctx|
        @as(*Engine, @ptrCast(@alignCast(ctx))).arena.allocator()
    else blk: {
        fallback_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        break :blk fallback_arena.?.allocator();
    };

    var doomed_ground: std.ArrayList(ecs.entity_t) = .empty;
    var doomed_bullets: std.ArrayList(ecs.entity_t) = .empty;
    const entity_doomed = arena.alloc(bool, it.count()) catch return;
    @memset(entity_doomed, false);

    // 1. Dynamic bodies vs. MaterialGrid (swept DDA for bullets, local O(1) cell checks for debris)
    if (grid) |mg| {
        for (positions, velocities, colliders, physicsBodies, 0..) |*pos, *vel, col, *pb, entity_idx| {
            const entity = ents[entity_idx];
            const is_bullet = ecs.has_id(world, entity, ecs.id(C.Bullet));

            if (is_bullet) {
                const prev_x = if (pb.has_prev) pb.prev_x else pos.x;
                const prev_y = if (pb.has_prev) pb.prev_y else pos.y;
                if (metrics) |mtr| mtr.physics_checks += 1;

                const hit_opt = mg.raycastSegment(prev_x, prev_y, pos.x, pos.y, false) orelse
                    findBulletCellOverlap(mg, pos.*, col, metrics);

                if (hit_opt) |hit| {
                    if (metrics) |mtr| mtr.physics_hits += 1;
                    pos.x = hit.world_x;
                    pos.y = hit.world_y;

                    _ = mg.carveCircleWithDebris(hit.world_x, hit.world_y, BULLET_CARVE_RADIUS, BULLET_DEBRIS_CHANCE);
                    const burst_color: u32 = if (hit.indestructible)
                        pixel_mod.packColor(220, 140, 255, 255)
                    else
                        pixel_mod.packColor(200, 70, 255, 255);
                    spawnExplosion(world, hit.world_x, hit.world_y, hit.normal.x, hit.normal.y, .{
                        .speed = 110.0,
                        .spread = 2.0,
                        .color = burst_color,
                        .bounce = 0.25,
                    });

                    entity_doomed[entity_idx] = true;
                    doomed_bullets.append(arena, entity) catch {};
                    vel.x *= 0.5;
                }
            } else {
                resolveBodyAgainstMaterialGrid(mg, pos, vel, col, pb, metrics);
            }
        }
    }

    // 1b. Optional legacy Ground entities (if any exist in isolated tests)
    if (phys) |p| {
        if (p.ground_query) |ground_q| {
            var q_it = ecs.query_iter(world, ground_q);
            while (ecs.query_next(&q_it)) {
                const g_positions = ecs.field(&q_it, C.Position, 1).?;
                const g_colliders = ecs.field(&q_it, C.Collider, 2).?;
                const g_ents = q_it.entities();

                for (0..q_it.count()) |i| {
                    const gp = g_positions[i];
                    const gcol = g_colliders[i];
                    const ground_entity = g_ents[i];

                    for (positions, velocities, colliders, physicsBodies, 0..) |*pos, *vel, col, *pb, entity_idx| {
                        if (entity_doomed[entity_idx]) continue;

                        if (metrics) |mtr| mtr.physics_checks += 1;
                        const m = collideManifold(pos.*, col, gp, gcol);
                        if (m.count == 0) continue;
                        if (metrics) |mtr| mtr.physics_hits += 1;

                        const entity = ents[entity_idx];
                        const is_bullet = ecs.has_id(world, entity, ecs.id(C.Bullet));

                        if (is_bullet and ecs.has_id(world, ground_entity, ecs.id(C.Destroyable))) {
                            if (!containsEntity(doomed_ground.items, ground_entity)) {
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

            if (metrics) |mtr| mtr.physics_checks += 1;
            const m = collideManifold(positions[i], colliders[i], positions[j], colliders[j]);
            if (m.count > 0) {
                if (metrics) |mtr| mtr.physics_hits += 1;
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

pub fn material_step_system(it: *ecs.iter_t) void {
    const grid = C.singletonGetMutSafe(it.world, mw.MaterialGrid) orelse return;
    grid.stepMaterials();
}

fn containsEntity(items: []const ecs.entity_t, target: ecs.entity_t) bool {
    for (items) |e| {
        if (e == target) return true;
    }
    return false;
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

    for (positions, particles) |pos, p| {
        const fade = std.math.clamp(p.lifetime / 0.5, 0.0, 1.0);
        const alpha: u8 = @intFromFloat(fade * 255.0);
        pixel_mod.drawCircleFilledAlpha(
            engine,
            pos.x,
            pos.y,
            3.0,
            p.color,
            alpha,
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

test "swept bullet collision vs MaterialGrid hits thin rock without tunneling and preserves indestructible walls" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Velocity);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.ExplosionParticle);
    ecs.COMPONENT(world, mw.MaterialGrid);
    ecs.TAG(world, C.Bullet);

    var grid = try mw.MaterialGrid.init(testing.allocator, 40, 20, 4);
    defer grid.deinit();

    // Thin 1-cell destructible rock wall at gx=12 (x = 48..52)
    grid.fillCellRect(12, 2, 13, 18, .rock, false);
    // Indestructible wall at gx=30 (x = 120..124)
    grid.fillCellRect(30, 2, 31, 18, .rock, true);
    _ = ecs.singleton_set(world, mw.MaterialGrid, grid);

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "test_move", ecs.OnUpdate, physics_movement_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.PhysicsBody) },
    });
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "test_col", ecs.OnUpdate, physics_collision_system, &.{
        .{ .id = ecs.id(C.Position) },
        .{ .id = ecs.id(C.Velocity) },
        .{ .id = ecs.id(C.Collider) },
        .{ .id = ecs.id(C.PhysicsBody) },
    });

    // Bullet traveling 1000 px/s with large dt=0.05 (moves 50px in one step across 4px wall!)
    const b1 = ecs.new_id(world);
    ecs.add(world, b1, C.Bullet);
    _ = ecs.set(world, b1, C.Position, .{ .x = 24.0, .y = 40.0 });
    _ = ecs.set(world, b1, C.Velocity, .{ .x = 1000.0, .y = 0.0 });
    _ = ecs.set(world, b1, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 4.0 } });
    _ = ecs.set(world, b1, C.PhysicsBody, .{});

    // Second bullet hitting indestructible wall
    const b2 = ecs.new_id(world);
    ecs.add(world, b2, C.Bullet);
    _ = ecs.set(world, b2, C.Position, .{ .x = 100.0, .y = 40.0 });
    _ = ecs.set(world, b2, C.Velocity, .{ .x = 1000.0, .y = 0.0 });
    _ = ecs.set(world, b2, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 4.0 } });
    _ = ecs.set(world, b2, C.PhysicsBody, .{});

    _ = ecs.progress(world, 0.05);

    const mg = ecs.singleton_get(world, mw.MaterialGrid).?;
    // Both bullets must be deleted on impact rather than tunneling past the walls
    try testing.expect(!ecs.is_alive(world, b1));
    try testing.expect(!ecs.is_alive(world, b2));
    // Destructible wall at (12, 10) carved out; indestructible wall at (30, 10) preserved
    try testing.expect(mg.getCell(12, 10).?.material != .rock);
    try testing.expectEqual(mw.Material.rock, mg.getCell(30, 10).?.material);
}
