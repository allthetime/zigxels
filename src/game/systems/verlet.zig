const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const mw = @import("../material_world.zig");
const Engine = @import("../../engine/core.zig").Engine;
const pixel_mod = @import("../../engine/pixels.zig");
const physics = @import("physics.zig");

pub const SOLVER_ITERATIONS: usize = 8;
pub const JELLY_REPULSION: f32 = 0.35;
pub const SELF_COLLISION_PRESERVE_VELOCITY: f32 = 0.15;
pub const MAX_VERLET_SPEED: f32 = 14.0;
const MAX_FAST_ADJ: usize = 128;

const DEFAULT_TERRAIN_BODY = C.PhysicsBody{
    .restitution = 0.0,
    .friction = 0.8,
};

/// Move a Verlet particle while preserving its implicit velocity (shifts both pos and old_pos).
pub fn translatePreserveVelocity(pos: *C.Position, state: *C.VerletState, dx: f32, dy: f32) void {
    pos.x += dx;
    pos.y += dy;
    state.old_x += dx;
    state.old_y += dy;
}

/// Move only the current position so the next Verlet integration step picks up the displacement as velocity.
pub fn translateInjectVelocity(pos: *C.Position, dx: f32, dy: f32) void {
    pos.x += dx;
    pos.y += dy;
}

/// Inject velocity directly into a Verlet particle by shifting old_pos opposite to the impulse.
pub fn applyImpulse(state: *C.VerletState, ix: f32, iy: f32) void {
    state.old_x -= ix;
    state.old_y -= iy;
}

/// True if `first` has an `AttachedTo` relation to `second` or vice versa.
pub fn areDirectlyLinked(world: *ecs.world_t, first: ecs.entity_t, second: ecs.entity_t) bool {
    return ecs.has_pair(world, first, ecs.id(C.AttachedTo), second) or
        ecs.has_pair(world, second, ecs.id(C.AttachedTo), first);
}

const ParticleEntry = struct {
    entity: ecs.entity_t,
    pos: *C.Position,
    state: *C.VerletState,
    collider: ?C.Collider,
    body: C.PhysicsBody,
    has_physics_body: bool,
    is_landable: bool,
    is_linked_to_player: bool = false,
    has_terrain_contact: bool = false,
    terrain_normal: c2.Vec2 = .{ .x = 0.0, .y = 0.0 },
};

fn findParticleIndex(particles: []const ParticleEntry, entity: ecs.entity_t) ?usize {
    var lo: usize = 0;
    var hi: usize = particles.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_ent = particles[mid].entity;
        if (mid_ent == entity) return mid;
        if (mid_ent < entity) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

inline fn packEdgeIndices(a: usize, b: usize) u64 {
    const lo: u64 = @min(a, b);
    const hi: u64 = @max(a, b);
    return (lo << 32) | hi;
}

fn isLinkedIndex(
    use_fast_adj: bool,
    fast_adj: *const [MAX_FAST_ADJ]u128,
    fallback_edges: []const u64,
    i: usize,
    j: usize,
) bool {
    if (use_fast_adj) {
        return (fast_adj[i] & (@as(u128, 1) << @intCast(j))) != 0;
    }
    const target = packEdgeIndices(i, j);
    var lo: usize = 0;
    var hi: usize = fallback_edges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const val = fallback_edges[mid];
        if (val == target) return true;
        if (val < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return false;
}

const ConstraintEntry = struct {
    child_entity: ecs.entity_t,
    parent_entity: ecs.entity_t,
    child_pos: *C.Position,
    parent_pos: *C.Position,
    parent_is_verlet: bool,
    dist: f32,
    stiffness: f32,
};

const GroundEntry = struct {
    pos: C.Position,
    col: C.Collider,
};

fn particleLessThan(_: void, a: ParticleEntry, b: ParticleEntry) bool {
    return a.entity < b.entity;
}

fn constraintLessThan(_: void, a: ConstraintEntry, b: ConstraintEntry) bool {
    if (a.child_entity != b.child_entity) return a.child_entity < b.child_entity;
    return a.parent_entity < b.parent_entity;
}

fn verletPredict(particles: []ParticleEntry, dt: f32) void {
    const accel_y = physics.GRAVITY * 1.6 * dt * dt;
    for (particles) |p| {
        const vx = (p.pos.x - p.state.old_x) * p.state.friction;
        const vy = (p.pos.y - p.state.old_y) * p.state.friction;

        p.state.old_x = p.pos.x;
        p.state.old_y = p.pos.y;

        p.pos.x += vx;
        p.pos.y += vy + accel_y;
    }
}

fn applyReachDrives(world: *ecs.world_t, reach_query: *ecs.query_t, dt: f32) void {
    var q_it = ecs.query_iter(world, reach_query);
    while (ecs.query_next(&q_it)) {
        const reach_data = ecs.field(&q_it, C.ReachTowards, 0).?;
        const pair_id = q_it.ids.?[0];
        const target_id = ecs.get_alive(world, ecs.pair_second(pair_id));
        if (target_id == 0) continue;

        const positions = ecs.field(&q_it, C.Position, 1).?;
        const t_pos = ecs.get(world, target_id, C.Position) orelse continue;

        for (reach_data, positions) |data, *pos| {
            const dx = t_pos.x - pos.x;
            const dy = t_pos.y - pos.y;
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq <= 0.0001) continue;

            if (data.stiffness < 0.25) {
                // Cap effective reach distance while preserving lively crawl/spin momentum
                const dist = @sqrt(dist_sq);
                const capped = @min(dist, 320.0);
                const scale = (capped / dist) * data.stiffness * dt;
                translateInjectVelocity(pos, dx * scale, dy * scale);
            } else {
                translateInjectVelocity(pos, dx * data.stiffness * dt, dy * data.stiffness * dt);
            }
        }
    }
}

fn solveAttachmentConstraints(constraints: []const ConstraintEntry) void {
    for (constraints) |c| {
        const dx = c.child_pos.x - c.parent_pos.x;
        const dy = c.child_pos.y - c.parent_pos.y;
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist <= 0.0001) continue;

        const diff = (dist - c.dist) / dist;
        if (c.parent_is_verlet) {
            const tx = dx * diff * 0.5 * c.stiffness;
            const ty = dy * diff * 0.5 * c.stiffness;
            translateInjectVelocity(c.child_pos, -tx, -ty);
            translateInjectVelocity(c.parent_pos, tx, ty);
        } else {
            const tx = dx * diff * c.stiffness;
            const ty = dy * diff * c.stiffness;
            translateInjectVelocity(c.child_pos, -tx, -ty);
        }
    }
}

fn solveSelfCollisions(
    particles: []ParticleEntry,
    use_fast_adj: bool,
    fast_adj: *const [MAX_FAST_ADJ]u128,
    fallback_edges: []const u64,
    checks_out: *u32,
    hits_out: *u32,
) void {
    const inject_ratio: f32 = 1.0 - SELF_COLLISION_PRESERVE_VELOCITY;

    for (particles, 0..) |p1, i| {
        const c1 = p1.collider orelse continue;
        if (c1 != .circle) continue;
        const p1x = p1.pos.x + c1.circle.p.x;
        const p1y = p1.pos.y + c1.circle.p.y;
        const r1 = c1.circle.r;

        for (particles[i + 1 ..], i + 1..) |p2, j| {
            const c_2 = p2.collider orelse continue;
            if (c_2 != .circle) continue;

            checks_out.* += 1;
            const dx = (p2.pos.x + c_2.circle.p.x) - p1x;
            const dy = (p2.pos.y + c_2.circle.p.y) - p1y;
            const min_dist = r1 + c_2.circle.r;
            if (@abs(dx) >= min_dist or @abs(dy) >= min_dist) continue;

            const dist_sq = (dx * dx) + (dy * dy);
            if (dist_sq >= min_dist * min_dist) continue;
            if (isLinkedIndex(use_fast_adj, fast_adj, fallback_edges, i, j)) continue;

            hits_out.* += 1;
            const dist = @sqrt(dist_sq);
            const nx: f32 = if (dist > 0.0001) dx / dist else 1.0;
            const ny: f32 = if (dist > 0.0001) dy / dist else 0.0;
            const overlap = min_dist - dist;

            const push_x = nx * overlap * 0.5 * JELLY_REPULSION;
            const push_y = ny * overlap * 0.5 * JELLY_REPULSION;

            translatePreserveVelocity(p1.pos, p1.state, -push_x * SELF_COLLISION_PRESERVE_VELOCITY, -push_y * SELF_COLLISION_PRESERVE_VELOCITY);
            translateInjectVelocity(p1.pos, -push_x * inject_ratio, -push_y * inject_ratio);

            translatePreserveVelocity(p2.pos, p2.state, push_x * SELF_COLLISION_PRESERVE_VELOCITY, push_y * SELF_COLLISION_PRESERVE_VELOCITY);
            translateInjectVelocity(p2.pos, push_x * inject_ratio, push_y * inject_ratio);
        }
    }
}

fn solvePlayerContacts(
    particles: []ParticleEntry,
    player_pos: *C.Position,
    player_vel: *C.Velocity,
    player_col: C.Collider,
) void {
    if (player_col != .circle) return;
    const p_cx = player_pos.x + player_col.circle.p.x;
    const p_cy = player_pos.y + player_col.circle.p.y;
    const p_r = player_col.circle.r;

    for (particles) |p| {
        const col = p.collider orelse continue;

        if (p.is_landable) {
            if (col != .circle) continue;
            const max_r = p_r + col.circle.r;
            if (@abs(p.pos.x + col.circle.p.x - p_cx) >= max_r or
                @abs(p.pos.y + col.circle.p.y - p_cy) >= max_r) continue;

            const contact = physics.collideManifold(player_pos.*, player_col, p.pos.*, col);
            if (contact.count == 0) continue;

            const separation = contact.depths[0] + physics.SURFACE_EPSILON;
            const normal = contact.n; // Player -> jelly core
            const landing = player_vel.y >= 0.0 and normal.y > 0.5;

            if (landing) {
                const player_share: f32 = 0.85;
                const core_share: f32 = 0.15;

                player_pos.x -= normal.x * separation * player_share;
                player_pos.y -= normal.y * separation * player_share;
                if (player_vel.y > 0.0) {
                    player_vel.y = 0.0;
                }

                translatePreserveVelocity(
                    p.pos,
                    p.state,
                    normal.x * separation * core_share,
                    normal.y * separation * core_share,
                );
            } else {
                translatePreserveVelocity(
                    p.pos,
                    p.state,
                    normal.x * separation,
                    normal.y * separation,
                );
            }
        } else if (p.has_physics_body and !p.is_linked_to_player) {
            if (col == .circle) {
                const max_r = p_r + col.circle.r;
                if (@abs(p.pos.x + col.circle.p.x - p_cx) >= max_r or
                    @abs(p.pos.y + col.circle.p.y - p_cy) >= max_r) continue;
            }
            const m = physics.collideManifold(p.pos.*, col, player_pos.*, player_col);
            if (m.count > 0) {
                const push = m.depths[0] + physics.SURFACE_EPSILON;
                translateInjectVelocity(p.pos, -m.n.x * push, -m.n.y * push);
            }
        }
    }
}

fn solveTerrainContacts(
    particles: []ParticleEntry,
    grid: ?*const mw.MaterialGrid,
    grounds: []const GroundEntry,
    checks_out: *u32,
    hits_out: *u32,
) void {
    if (grid) |mg| {
        if (mg.width > 0 and mg.height > 0) {
            const cs_f = mg.cellSizeF();
            const half = cs_f * 0.5;
            const max_w = @as(f32, @floatFromInt(mg.width)) * cs_f;
            const max_h = @as(f32, @floatFromInt(mg.height)) * cs_f;
            const cell_col = C.Collider{ .box = .{
                .min = .{ .x = -half, .y = -half },
                .max = .{ .x = half, .y = half },
            } };

            for (particles) |*p| {
                const col = p.collider orelse continue;

                const aabb = physics.getWorldAABB(p.pos.*, col);
                const min_gx = @max(0, mg.worldToCellX(aabb.min.x));
                const max_gx = @min(@as(i32, @intCast(mg.width)) - 1, mg.worldToCellX(aabb.max.x - 0.0001));
                const min_gy = @max(0, mg.worldToCellY(aabb.min.y));
                const max_gy = @min(@as(i32, @intCast(mg.height)) - 1, mg.worldToCellY(aabb.max.y - 0.0001));

                if (max_gx >= min_gx and max_gy >= min_gy) {
                    var best_depth: f32 = 0.0;
                    var best_n: c2.Vec2 = .{ .x = 0.0, .y = 0.0 };
                    var found = false;

                    switch (col) {
                        .circle => |c| {
                            const cx = p.pos.x + c.p.x;
                            const cy = p.pos.y + c.p.y;
                            const r = c.r;
                            const r_sq = r * r;

                            var gy = min_gy;
                            while (gy <= max_gy) : (gy += 1) {
                                const row_base = @as(usize, @intCast(gy)) * mg.width;
                                const cell_cy = (@as(f32, @floatFromInt(gy)) + 0.5) * cs_f;
                                const bmin_y = cell_cy - half;
                                const bmax_y = cell_cy + half;
                                const closest_y = std.math.clamp(cy, bmin_y, bmax_y);
                                const dy = closest_y - cy;
                                const dy_sq = dy * dy;

                                var gx = min_gx;
                                while (gx <= max_gx) : (gx += 1) {
                                    checks_out.* += 1;
                                    if (!mg.cells[row_base + @as(usize, @intCast(gx))].material.isSolid()) continue;

                                    const cell_cx = (@as(f32, @floatFromInt(gx)) + 0.5) * cs_f;
                                    const closest_x = std.math.clamp(cx, cell_cx - half, cell_cx + half);
                                    const dx = closest_x - cx;
                                    const dist_sq = dx * dx + dy_sq;
                                    if (dist_sq >= r_sq) continue;

                                    var depth: f32 = undefined;
                                    var nx: f32 = undefined;
                                    var ny: f32 = undefined;
                                    if (dist_sq > 1e-8) {
                                        const dist = @sqrt(dist_sq);
                                        depth = r - dist;
                                        nx = dx / dist;
                                        ny = dy / dist;
                                    } else {
                                        const px_pen = half - @abs(cx - cell_cx);
                                        const py_pen = half - @abs(cy - cell_cy);
                                        if (px_pen < py_pen) {
                                            depth = r + px_pen;
                                            nx = if (cx < cell_cx) 1.0 else -1.0;
                                            ny = 0.0;
                                        } else {
                                            depth = r + py_pen;
                                            nx = 0.0;
                                            ny = if (cy < cell_cy) 1.0 else -1.0;
                                        }
                                    }

                                    if (!found or depth > best_depth) {
                                        best_depth = depth;
                                        best_n = .{ .x = nx, .y = ny };
                                        found = true;
                                    }
                                }
                            }
                        },
                        .box => {
                            var gy = min_gy;
                            while (gy <= max_gy) : (gy += 1) {
                                const row_base = @as(usize, @intCast(gy)) * mg.width;
                                const cell_cy = (@as(f32, @floatFromInt(gy)) + 0.5) * cs_f;
                                var gx = min_gx;
                                while (gx <= max_gx) : (gx += 1) {
                                    checks_out.* += 1;
                                    if (!mg.cells[row_base + @as(usize, @intCast(gx))].material.isSolid()) continue;

                                    const cell_pos = C.Position{ .x = (@as(f32, @floatFromInt(gx)) + 0.5) * cs_f, .y = cell_cy };
                                    const m = physics.collideManifold(p.pos.*, col, cell_pos, cell_col);
                                    if (m.count == 0) continue;

                                    if (!found or m.depths[0] > best_depth) {
                                        best_depth = m.depths[0];
                                        best_n = m.n;
                                        found = true;
                                    }
                                }
                            }
                        },
                    }

                    if (found) {
                        hits_out.* += 1;
                        const push = best_depth + physics.SURFACE_EPSILON;
                        translateInjectVelocity(p.pos, -best_n.x * push, -best_n.y * push);
                        p.has_terrain_contact = true;
                        p.terrain_normal = best_n;
                    }
                }

                // Room-bounds safety containment so Verlet particles never escape the viewport
                const r_pad: f32 = switch (col) {
                    .circle => |c| c.r,
                    .box => |b| @max(b.max.x - b.min.x, b.max.y - b.min.y) * 0.5,
                };
                p.pos.x = std.math.clamp(p.pos.x, r_pad, @max(r_pad, max_w - r_pad));
                p.pos.y = std.math.clamp(p.pos.y, r_pad, @max(r_pad, max_h - r_pad));
            }
        }
    }

    for (particles) |*p| {
        const col = p.collider orelse continue;

        for (grounds) |g| {
            checks_out.* += 1;
            const m = physics.collideManifold(p.pos.*, col, g.pos, g.col);
            if (m.count == 0) continue;

            hits_out.* += 1;
            const push = m.depths[0] + physics.SURFACE_EPSILON;
            translateInjectVelocity(p.pos, -m.n.x * push, -m.n.y * push);
            p.has_terrain_contact = true;
            p.terrain_normal = m.n;
        }
    }
}

fn finalizeVerletVelocities(particles: []ParticleEntry) void {
    for (particles) |p| {
        if (p.has_terrain_contact) {
            const vx = p.pos.x - p.state.old_x;
            const vy = p.pos.y - p.state.old_y;
            const n = p.terrain_normal;
            const v_dot_n = (vx * n.x) + (vy * n.y);
            const vn_x = n.x * v_dot_n;
            const vn_y = n.y * v_dot_n;
            const vt_x = (vx - vn_x) * p.body.friction;
            const vt_y = (vy - vn_y) * p.body.friction;

            const new_vx = if (v_dot_n > 0.0) vt_x - (vn_x * p.body.restitution) else vt_x + vn_x;
            const new_vy = if (v_dot_n > 0.0) vt_y - (vn_y * p.body.restitution) else vt_y + vn_y;

            p.state.old_x = p.pos.x - new_vx;
            p.state.old_y = p.pos.y - new_vy;
        }

        const clamped_vx = std.math.clamp(p.pos.x - p.state.old_x, -MAX_VERLET_SPEED, MAX_VERLET_SPEED);
        const clamped_vy = std.math.clamp(p.pos.y - p.state.old_y, -MAX_VERLET_SPEED, MAX_VERLET_SPEED);
        p.state.old_x = p.pos.x - clamped_vx;
        p.state.old_y = p.pos.y - clamped_vy;
    }
}

/// Execute one unified deterministic Verlet / PBD simulation step:
/// 1) predict positions (+ ReachTowards drives),
/// 2) run `SOLVER_ITERATIONS` global relaxation iterations (attachments, self-collision, player, terrain),
/// 3) apply terrain contact velocity response once and clamp implicit velocity.
pub fn stepVerletPBDWithAllocator(world: *ecs.world_t, allocator: std.mem.Allocator, dt: f32) void {
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return;

    var particles: std.ArrayList(ParticleEntry) = .empty;
    defer particles.deinit(allocator);
    var v_it = ecs.query_iter(world, phys.verlet_query);
    while (ecs.query_next(&v_it)) {
        const v_positions = ecs.field(&v_it, C.Position, 0).?;
        const v_states = ecs.field(&v_it, C.VerletState, 1).?;
        const v_colliders = ecs.field(&v_it, C.Collider, 2);
        const v_bodies = ecs.field(&v_it, C.PhysicsBody, 3);
        const v_ents = v_it.entities();

        for (0..v_it.count()) |i| {
            const v_ent = v_ents[i];
            particles.append(allocator, .{
                .entity = v_ent,
                .pos = &v_positions[i],
                .state = &v_states[i],
                .collider = if (v_colliders) |cols| cols[i] else null,
                .body = if (v_bodies) |bodies| bodies[i] else DEFAULT_TERRAIN_BODY,
                .has_physics_body = v_bodies != null,
                .is_landable = ecs.has_id(world, v_ent, ecs.id(C.PlayerLandable)),
            }) catch return;
        }
    }
    if (particles.items.len == 0) return;

    std.sort.pdq(ParticleEntry, particles.items, {}, particleLessThan);

    var constraints: std.ArrayList(ConstraintEntry) = .empty;
    defer constraints.deinit(allocator);
    if (phys.attachment_query) |attach_q| {
        var a_it = ecs.query_iter(world, attach_q);
        while (ecs.query_next(&a_it)) {
            const links = ecs.field(&a_it, C.AttachedTo, 0).?;
            const pair_id = a_it.ids.?[0];
            const parent_entity = ecs.get_alive(world, ecs.pair_second(pair_id));
            if (parent_entity == 0) continue;

            const parent_pos = ecs.get_mut(world, parent_entity, C.Position) orelse continue;
            const parent_is_verlet = ecs.has_id(world, parent_entity, ecs.id(C.VerletState));
            const child_positions = ecs.field(&a_it, C.Position, 1).?;
            const child_ents = a_it.entities();

            for (0..a_it.count()) |i| {
                constraints.append(allocator, .{
                    .child_entity = child_ents[i],
                    .parent_entity = parent_entity,
                    .child_pos = &child_positions[i],
                    .parent_pos = parent_pos,
                    .parent_is_verlet = parent_is_verlet,
                    .dist = links[i].dist,
                    .stiffness = links[i].stiffness,
                }) catch return;
            }
        }
    }
    std.sort.pdq(ConstraintEntry, constraints.items, {}, constraintLessThan);

    var grounds: std.ArrayList(GroundEntry) = .empty;
    defer grounds.deinit(allocator);
    if (phys.ground_query) |ground_q| {
        var g_it = ecs.query_iter(world, ground_q);
        while (ecs.query_next(&g_it)) {
            const g_positions = ecs.field(&g_it, C.Position, 1).?;
            const g_colliders = ecs.field(&g_it, C.Collider, 2).?;
            for (g_positions, g_colliders) |gp, gcol| {
                grounds.append(allocator, .{ .pos = gp, .col = gcol }) catch return;
            }
        }
    }
    const grid = C.singletonGetSafe(world, mw.MaterialGrid);

    verletPredict(particles.items, dt);
    if (phys.reach_query) |reach_q| {
        applyReachDrives(world, reach_q, dt);
    }

    var player_entity: ecs.entity_t = 0;
    var player_pos: ?*C.Position = null;
    var player_vel: ?*C.Velocity = null;
    var player_col: ?C.Collider = null;
    if (C.singletonGetSafe(world, C.PlayerContainer)) |pc| {
        player_entity = pc.entity;
        player_pos = ecs.get_mut(world, pc.entity, C.Position);
        player_vel = ecs.get_mut(world, pc.entity, C.Velocity);
        if (ecs.get(world, pc.entity, C.Collider)) |pcol| {
            player_col = pcol.*;
        }
    }

    // Precompute O(1) self-collision adjacency and player-link flags once outside the solver loop.
    const use_fast_adj = particles.items.len <= MAX_FAST_ADJ;
    var fast_adj: [MAX_FAST_ADJ]u128 = @splat(0);
    var fallback_edges: std.ArrayList(u64) = .empty;
    defer fallback_edges.deinit(allocator);

    for (constraints.items) |c| {
        const ci_opt = findParticleIndex(particles.items, c.child_entity);
        const pi_opt = findParticleIndex(particles.items, c.parent_entity);
        if (player_entity != 0) {
            if (c.parent_entity == player_entity) {
                if (ci_opt) |ci| particles.items[ci].is_linked_to_player = true;
            } else if (c.child_entity == player_entity) {
                if (pi_opt) |pi| particles.items[pi].is_linked_to_player = true;
            }
        }
        if (ci_opt) |ci| {
            if (pi_opt) |pi| {
                if (use_fast_adj) {
                    fast_adj[ci] |= @as(u128, 1) << @intCast(pi);
                    fast_adj[pi] |= @as(u128, 1) << @intCast(ci);
                } else {
                    fallback_edges.append(allocator, packEdgeIndices(ci, pi)) catch return;
                }
            }
        }
    }
    if (!use_fast_adj and fallback_edges.items.len > 1) {
        std.sort.pdq(u64, fallback_edges.items, {}, std.sort.asc(u64));
    }

    var ground_checks: u32 = 0;
    var ground_hits: u32 = 0;
    var self_checks: u32 = 0;
    var self_hits: u32 = 0;

    for (0..SOLVER_ITERATIONS) |iter| {
        solveAttachmentConstraints(constraints.items);
        solveSelfCollisions(particles.items, use_fast_adj, &fast_adj, fallback_edges.items, &self_checks, &self_hits);
        if (player_pos != null and player_vel != null and player_col != null) {
            solvePlayerContacts(particles.items, player_pos.?, player_vel.?, player_col.?);
        }
        if ((iter & 1) == 0 or iter == SOLVER_ITERATIONS - 1) {
            solveTerrainContacts(particles.items, grid, grounds.items, &ground_checks, &ground_hits);
        }
    }

    finalizeVerletVelocities(particles.items);

    if (C.singletonGetMutSafe(world, C.FrameMetrics)) |metrics| {
        metrics.verlet_ground_checks += ground_checks;
        metrics.verlet_ground_hits += ground_hits;
        metrics.verlet_self_checks += self_checks;
        metrics.verlet_self_hits += self_hits;
    }
}

pub fn stepVerletPBD(world: *ecs.world_t, dt: f32) void {
    if (ecs.get_ctx(world)) |ctx| {
        const engine: *Engine = @ptrCast(@alignCast(ctx));
        stepVerletPBDWithAllocator(world, engine.arena.allocator(), dt);
    } else {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        stepVerletPBDWithAllocator(world, arena.allocator(), dt);
    }
}

pub fn verlet_solver_system(it: *ecs.iter_t) void {
    stepVerletPBD(it.world, it.delta_time);
}

pub fn verlet_bullet_collision_system(
    it: *ecs.iter_t,
    bullet_positions: []C.Position,
    bullet_velocities: []C.Velocity,
    bullet_colliders: []C.Collider,
) void {
    const world = it.world;
    const phys = C.singletonGetSafe(world, C.PhysicsState) orelse return;
    const metrics = C.singletonGetMutSafe(world, C.FrameMetrics);
    const attachments_group = if (C.singletonGetSafe(world, C.PlayerAttachmentsGroup)) |g| g.entity else 0;

    var q_it = ecs.query_iter(world, phys.verlet_query);

    while (ecs.query_next(&q_it)) {
        const v_positions = ecs.field(&q_it, C.Position, 0).?;
        const v_states = ecs.field(&q_it, C.VerletState, 1).?;
        const v_colliders = ecs.field(&q_it, C.Collider, 2) orelse continue;
        if (ecs.field(&q_it, C.PhysicsBody, 3) == null) continue;
        const v_ents = q_it.entities();

        for (v_positions, v_states, v_colliders, 0..) |v_pos, *vs, v_col, v_idx| {
            const v_ent = v_ents[v_idx];
            if (attachments_group != 0 and ecs.has_pair(world, v_ent, ecs.ChildOf, attachments_group)) continue;

            for (bullet_positions, bullet_velocities, bullet_colliders) |*b_pos, *b_vel, b_col| {
                if (metrics) |mtr| mtr.verlet_bullet_checks += 1;
                const m = physics.collideManifold(b_pos.*, b_col, v_pos, v_col);
                if (m.count == 0) continue;
                if (metrics) |mtr| mtr.verlet_bullet_hits += 1;

                const overlap = m.depths[0];
                const n = m.n; // Points Bullet -> Verlet

                b_pos.x -= n.x * (overlap + physics.SURFACE_EPSILON);
                b_pos.y -= n.y * (overlap + physics.SURFACE_EPSILON);

                const v_dot_n = (b_vel.x * n.x) + (b_vel.y * n.y);
                if (v_dot_n > 0) {
                    const restitution: f32 = 1.2;
                    b_vel.x -= n.x * v_dot_n * (1.0 + restitution);
                    b_vel.y -= n.y * v_dot_n * (1.0 + restitution);

                    const impact_force: f32 = 3.5;
                    applyImpulse(
                        vs,
                        n.x * v_dot_n * impact_force * it.delta_time,
                        n.y * v_dot_n * impact_force * it.delta_time,
                    );

                    if (ecs.id(C.ExplosionParticle) != 0) {
                        physics.spawnExplosion(world, b_pos.x, b_pos.y, -n.x, -n.y, .{
                            .speed = 90.0,
                            .spread = 1.8,
                            .color = pixel_mod.packColor(210, 120, 255, 255),
                            .bounce = 0.2,
                        });
                    }
                }
            }
        }
    }
}

fn setupTestPhysicsState(world: *ecs.world_t) C.PhysicsState {
    var ground_desc = ecs.query_desc_t{};
    ground_desc.terms[0] = .{ .id = ecs.id(C.Ground) };
    ground_desc.terms[1] = .{ .id = ecs.id(C.Position), .inout = .In };
    ground_desc.terms[2] = .{ .id = ecs.id(C.Collider), .inout = .In };
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

    const phys = C.PhysicsState{
        .ground_query = ground_q,
        .verlet_query = verlet_q,
        .player_landable_query = landable_q,
        .collider_query = collider_q,
        .attachment_query = attach_q,
        .reach_query = reach_q,
    };
    _ = ecs.singleton_set(world, C.PhysicsState, phys);
    return phys;
}

fn finiTestPhysicsState(phys: C.PhysicsState) void {
    if (phys.ground_query) |q| ecs.query_fini(q);
    ecs.query_fini(phys.verlet_query);
    ecs.query_fini(phys.player_landable_query);
    ecs.query_fini(phys.collider_query);
    if (phys.attachment_query) |q| ecs.query_fini(q);
    if (phys.reach_query) |q| ecs.query_fini(q);
}

test "Verlet position-adjustment policies behave as specified" {
    const testing = std.testing;
    var pos = C.Position{ .x = 10.0, .y = 20.0 };
    var vs = C.VerletState{ .old_x = 8.0, .old_y = 19.0 };

    // Initial implicit velocity is (2, 1)
    translatePreserveVelocity(&pos, &vs, 5.0, -3.0);
    try testing.expectApproxEqAbs(@as(f32, 15.0), pos.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 17.0), pos.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), pos.x - vs.old_x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), pos.y - vs.old_y, 0.0001);

    // Inject velocity moves only pos -> implicit velocity increases by (4, -2) -> (6, -1)
    translateInjectVelocity(&pos, 4.0, -2.0);
    try testing.expectApproxEqAbs(@as(f32, 6.0), pos.x - vs.old_x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), pos.y - vs.old_y, 0.0001);

    // Impulse modifies old_pos opposite to impulse -> implicit velocity increases by (3, 2) -> (9, 1)
    applyImpulse(&vs, 3.0, 2.0);
    try testing.expectApproxEqAbs(@as(f32, 9.0), pos.x - vs.old_x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), pos.y - vs.old_y, 0.0001);
}

test "PBD solver converges stretched attachment chain without Velocity component" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Velocity);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.PhysicsState);
    ecs.COMPONENT(world, C.VerletState);
    ecs.COMPONENT(world, C.AttachedTo);
    ecs.COMPONENT(world, C.ReachTowards);
    ecs.TAG(world, C.Ground);
    ecs.TAG(world, C.PlayerLandable);

    const phys = setupTestPhysicsState(world);
    defer finiTestPhysicsState(phys);

    // Non-Verlet anchor at (0, 0), Verlet chain stretched out to (100, 0) and (220, 0)
    const anchor = ecs.new_id(world);
    _ = ecs.set(world, anchor, C.Position, .{ .x = 0.0, .y = 0.0 });

    const n1 = ecs.new_id(world);
    _ = ecs.set(world, n1, C.Position, .{ .x = 50.0, .y = 0.0 });
    _ = ecs.set(world, n1, C.VerletState, .{ .old_x = 50.0, .old_y = 0.0, .friction = 0.9 });
    _ = ecs.set_pair(world, n1, ecs.id(C.AttachedTo), anchor, C.AttachedTo, .{ .dist = 20.0, .stiffness = 1.0 });

    const n2 = ecs.new_id(world);
    _ = ecs.set(world, n2, C.Position, .{ .x = 120.0, .y = 0.0 });
    _ = ecs.set(world, n2, C.VerletState, .{ .old_x = 120.0, .old_y = 0.0, .friction = 0.9 });
    _ = ecs.set_pair(world, n2, ecs.id(C.AttachedTo), n1, C.AttachedTo, .{ .dist = 20.0, .stiffness = 1.0 });

    try testing.expect(!ecs.has_id(world, n1, ecs.id(C.Velocity)));
    try testing.expect(!ecs.has_id(world, n2, ecs.id(C.Velocity)));

    const fixed_dt: f32 = 1.0 / 120.0;
    for (0..20) |_| {
        stepVerletPBDWithAllocator(world, testing.allocator, fixed_dt);
    }

    const p_anchor = ecs.get(world, anchor, C.Position).?;
    const p1 = ecs.get(world, n1, C.Position).?;
    const p2 = ecs.get(world, n2, C.Position).?;

    const d01 = @sqrt((p1.x - p_anchor.x) * (p1.x - p_anchor.x) + (p1.y - p_anchor.y) * (p1.y - p_anchor.y));
    const d12 = @sqrt((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y));
    try testing.expectApproxEqAbs(@as(f32, 20.0), d01, 1.5);
    try testing.expectApproxEqAbs(@as(f32, 20.0), d12, 1.5);
}

test "PBD self-collision separates unlinked particles while excluding directly linked pairs" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.PhysicsState);
    ecs.COMPONENT(world, C.VerletState);
    ecs.COMPONENT(world, C.AttachedTo);
    ecs.COMPONENT(world, C.ReachTowards);
    ecs.TAG(world, C.Ground);
    ecs.TAG(world, C.PlayerLandable);

    const phys = setupTestPhysicsState(world);
    defer finiTestPhysicsState(phys);

    // Pair A & B: radius 10 each (min_dist=20), directly linked at dist=8, starting 8px apart -> MUST NOT self-collide
    const a = ecs.new_id(world);
    const b = ecs.new_id(world);
    const hub = ecs.new_id(world);
    _ = ecs.set(world, hub, C.Position, .{ .x = 4.0, .y = -50.0 });
    _ = ecs.set(world, hub, C.VerletState, .{ .old_x = 4.0, .old_y = -50.0, .friction = 1.0 });

    _ = ecs.set(world, a, C.Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, a, C.VerletState, .{ .old_x = 0.0, .old_y = 0.0, .friction = 1.0 });
    _ = ecs.set(world, a, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 10.0 } });

    _ = ecs.set(world, b, C.Position, .{ .x = 8.0, .y = 0.0 });
    _ = ecs.set(world, b, C.VerletState, .{ .old_x = 8.0, .old_y = 0.0, .friction = 1.0 });
    _ = ecs.set(world, b, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 10.0 } });

    // Give `a` TWO AttachedTo targets (`hub` first, `b` second) to verify multi-target direct-link detection
    _ = ecs.set_pair(world, a, ecs.id(C.AttachedTo), hub, C.AttachedTo, .{ .dist = 50.0, .stiffness = 0.0 });
    _ = ecs.set_pair(world, a, ecs.id(C.AttachedTo), b, C.AttachedTo, .{ .dist = 8.0, .stiffness = 1.0 });
    try testing.expect(areDirectlyLinked(world, a, b));
    try testing.expect(areDirectlyLinked(world, b, a));

    // Pair C & D: unlinked overlapping circles at x=200 and x=208, r=10 each -> MUST separate toward min_dist=20
    const c_ent = ecs.new_id(world);
    const d_ent = ecs.new_id(world);
    _ = ecs.set(world, c_ent, C.Position, .{ .x = 200.0, .y = 0.0 });
    _ = ecs.set(world, c_ent, C.VerletState, .{ .old_x = 200.0, .old_y = 0.0, .friction = 1.0 });
    _ = ecs.set(world, c_ent, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 10.0 } });

    _ = ecs.set(world, d_ent, C.Position, .{ .x = 208.0, .y = 0.0 });
    _ = ecs.set(world, d_ent, C.VerletState, .{ .old_x = 208.0, .old_y = 0.0, .friction = 1.0 });
    _ = ecs.set(world, d_ent, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 10.0 } });
    try testing.expect(!areDirectlyLinked(world, c_ent, d_ent));

    stepVerletPBDWithAllocator(world, testing.allocator, 1.0 / 120.0);

    const pa = ecs.get(world, a, C.Position).?;
    const pb = ecs.get(world, b, C.Position).?;
    try testing.expectApproxEqAbs(@as(f32, 8.0), pb.x - pa.x, 0.05);

    const pc = ecs.get(world, c_ent, C.Position).?;
    const pd = ecs.get(world, d_ent, C.Position).?;
    try testing.expect((pd.x - pc.x) > 19.0);
}

test "PBD resolves recycled target entities across reset without generation assertions" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.PhysicsState);
    ecs.COMPONENT(world, C.VerletState);
    ecs.COMPONENT(world, C.AttachedTo);
    ecs.COMPONENT(world, C.ReachTowards);
    ecs.TAG(world, C.Ground);
    ecs.TAG(world, C.PlayerLandable);

    const phys = setupTestPhysicsState(world);
    defer finiTestPhysicsState(phys);

    const old_parent = ecs.new_id(world);
    ecs.delete(world, old_parent);

    // Spawn recycled parent (generation > 0) and child attached to it
    const new_parent = ecs.new_id(world);
    _ = ecs.set(world, new_parent, C.Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, new_parent, C.VerletState, .{ .old_x = 0.0, .old_y = 0.0, .friction = 0.95 });

    const child = ecs.new_id(world);
    _ = ecs.set(world, child, C.Position, .{ .x = 40.0, .y = 0.0 });
    _ = ecs.set(world, child, C.VerletState, .{ .old_x = 40.0, .old_y = 0.0, .friction = 0.95 });
    _ = ecs.set_pair(world, child, ecs.id(C.AttachedTo), new_parent, C.AttachedTo, .{ .dist = 15.0, .stiffness = 1.0 });

    for (0..8) |_| {
        stepVerletPBDWithAllocator(world, testing.allocator, 1.0 / 120.0);
    }

    const pp = ecs.get(world, new_parent, C.Position).?;
    const cp = ecs.get(world, child, C.Position).?;
    const dist = @sqrt((cp.x - pp.x) * (cp.x - pp.x) + (cp.y - pp.y) * (cp.y - pp.y));
    try testing.expectApproxEqAbs(@as(f32, 15.0), dist, 0.5);
}

test "PBD solver rests multi-core blob on MaterialGrid floor and bullets push/bounce without killing it" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Velocity);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.PhysicsState);
    ecs.COMPONENT(world, C.VerletState);
    ecs.COMPONENT(world, C.AttachedTo);
    ecs.COMPONENT(world, C.ReachTowards);
    ecs.COMPONENT(world, C.PlayerAttachmentsGroup);
    ecs.COMPONENT(world, mw.MaterialGrid);
    ecs.TAG(world, C.Ground);
    ecs.TAG(world, C.PlayerLandable);
    ecs.TAG(world, C.Bullet);

    const phys = setupTestPhysicsState(world);
    defer finiTestPhysicsState(phys);

    var grid = try mw.MaterialGrid.init(testing.allocator, 40, 30, 4);
    defer grid.deinit();
    // Solid rock floor at gy=20 (y=80..84)
    grid.fillCellRect(0, 20, 40, 22, .rock, true);
    _ = ecs.singleton_set(world, mw.MaterialGrid, grid);

    // Two cores connected via an intermediate spine limb
    const core_a = ecs.new_id(world);
    ecs.add(world, core_a, C.PlayerLandable);
    _ = ecs.set(world, core_a, C.Position, .{ .x = 60.0, .y = 60.0 });
    _ = ecs.set(world, core_a, C.VerletState, .{ .old_x = 60.0, .old_y = 60.0, .friction = 0.98 });
    _ = ecs.set(world, core_a, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 10.0 } });
    _ = ecs.set(world, core_a, C.PhysicsBody, .{ .restitution = 0.0, .friction = 0.8 });

    const core_b = ecs.new_id(world);
    ecs.add(world, core_b, C.PlayerLandable);
    _ = ecs.set(world, core_b, C.Position, .{ .x = 100.0, .y = 60.0 });
    _ = ecs.set(world, core_b, C.VerletState, .{ .old_x = 100.0, .old_y = 60.0, .friction = 0.98 });
    _ = ecs.set(world, core_b, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 10.0 } });
    _ = ecs.set(world, core_b, C.PhysicsBody, .{ .restitution = 0.0, .friction = 0.8 });

    const spine_limb = ecs.new_id(world);
    _ = ecs.set(world, spine_limb, C.Position, .{ .x = 80.0, .y = 60.0 });
    _ = ecs.set(world, spine_limb, C.VerletState, .{ .old_x = 80.0, .old_y = 60.0, .friction = 0.98 });
    _ = ecs.set(world, spine_limb, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 4.0 } });
    _ = ecs.set(world, spine_limb, C.PhysicsBody, .{});
    _ = ecs.set_pair(world, spine_limb, ecs.id(C.AttachedTo), core_a, C.AttachedTo, .{ .dist = 20.0, .stiffness = 1.0 });
    _ = ecs.set_pair(world, spine_limb, ecs.id(C.AttachedTo), core_b, C.AttachedTo, .{ .dist = 20.0, .stiffness = 1.0 });

    // Player tail particle that bullets must ignore
    const attach_grp = ecs.new_entity(world, "PlayerAttachments");
    _ = ecs.singleton_set(world, C.PlayerAttachmentsGroup, .{ .entity = attach_grp });
    const tail_seg = ecs.new_id(world);
    ecs.add_pair(world, tail_seg, ecs.ChildOf, attach_grp);
    _ = ecs.set(world, tail_seg, C.Position, .{ .x = 20.0, .y = 20.0 });
    _ = ecs.set(world, tail_seg, C.VerletState, .{ .old_x = 20.0, .old_y = 20.0 });
    _ = ecs.set(world, tail_seg, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 4.0 } });
    _ = ecs.set(world, tail_seg, C.PhysicsBody, .{});

    // Step PBD: connected blob settles above rock floor at y=80
    for (0..40) |_| {
        stepVerletPBDWithAllocator(world, testing.allocator, 1.0 / 120.0);
    }
    const core_y = ecs.get(world, core_a, C.Position).?.y;
    try testing.expect(core_y <= 71.5);
    try testing.expect(core_y >= 65.0);

    // Bullet hits spine_limb -> bounces bullet (-X), pushes limb (+X), keeps creature alive
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "test_v_bullet", ecs.OnUpdate, verlet_bullet_collision_system, &.{
        .{ .id = ecs.id(C.Bullet) },
    });
    const limb_pos = ecs.get(world, spine_limb, C.Position).?.*;
    const b1 = ecs.new_id(world);
    ecs.add(world, b1, C.Bullet);
    _ = ecs.set(world, b1, C.Position, .{ .x = limb_pos.x - 4.0, .y = limb_pos.y });
    _ = ecs.set(world, b1, C.Velocity, .{ .x = 500.0, .y = 0.0 });
    _ = ecs.set(world, b1, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 5.0 } });

    // Second bullet overlapping player tail must pass right through untouched
    const b2 = ecs.new_id(world);
    ecs.add(world, b2, C.Bullet);
    _ = ecs.set(world, b2, C.Position, .{ .x = 20.0, .y = 20.0 });
    _ = ecs.set(world, b2, C.Velocity, .{ .x = 500.0, .y = 0.0 });
    _ = ecs.set(world, b2, C.Collider, .{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 5.0 } });

    _ = ecs.progress(world, 1.0 / 120.0);
    try testing.expect(ecs.is_alive(world, core_a));
    try testing.expect(ecs.is_alive(world, core_b));
    try testing.expect(ecs.is_alive(world, spine_limb));
    try testing.expect(ecs.get(world, b1, C.Velocity).?.x < 0.0);
    try testing.expect(ecs.get(world, spine_limb, C.Position).?.x - ecs.get(world, spine_limb, C.VerletState).?.old_x > 0.0);
    try testing.expectApproxEqAbs(@as(f32, 500.0), ecs.get(world, b2, C.Velocity).?.x, 0.01);
}
