const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const Engine = @import("../../engine/core.zig").Engine;
const physics = @import("physics.zig");

pub const SOLVER_ITERATIONS: usize = 8;
pub const JELLY_REPULSION: f32 = 0.35;
pub const SELF_COLLISION_PRESERVE_VELOCITY: f32 = 0.85;
pub const MAX_VERLET_SPEED: f32 = 20.0;

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
    has_terrain_contact: bool = false,
    terrain_normal: c2.Vec2 = .{ .x = 0.0, .y = 0.0 },
};

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
    const accel_y = physics.GRAVITY * 2.0 * dt * dt;
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
            translateInjectVelocity(pos, dx * data.stiffness * dt, dy * data.stiffness * dt);
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
    world: *ecs.world_t,
    particles: []ParticleEntry,
    checks_out: *u32,
    hits_out: *u32,
) void {
    const inject_ratio: f32 = 1.0 - SELF_COLLISION_PRESERVE_VELOCITY;

    for (particles, 0..) |p1, i| {
        const c1 = p1.collider orelse continue;
        if (c1 != .circle) continue;

        for (particles[i + 1 ..]) |p2| {
            const c_2 = p2.collider orelse continue;
            if (c_2 != .circle) continue;
            if (areDirectlyLinked(world, p1.entity, p2.entity)) continue;

            checks_out.* += 1;
            const dx = (p2.pos.x + c_2.circle.p.x) - (p1.pos.x + c1.circle.p.x);
            const dy = (p2.pos.y + c_2.circle.p.y) - (p1.pos.y + c1.circle.p.y);
            const dist_sq = (dx * dx) + (dy * dy);
            const min_dist = c1.circle.r + c_2.circle.r;
            if (dist_sq >= min_dist * min_dist) continue;

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
    world: *ecs.world_t,
    particles: []ParticleEntry,
    player_entity: ecs.entity_t,
    player_pos: *C.Position,
    player_vel: *C.Velocity,
    player_col: C.Collider,
) void {
    if (player_col != .circle) return;

    for (particles) |p| {
        const col = p.collider orelse continue;

        if (p.is_landable) {
            if (col != .circle) continue;
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
        } else if (p.has_physics_body and !areDirectlyLinked(world, p.entity, player_entity)) {
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
    grounds: []const GroundEntry,
    checks_out: *u32,
    hits_out: *u32,
) void {
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
            particles.append(allocator, .{
                .entity = v_ents[i],
                .pos = &v_positions[i],
                .state = &v_states[i],
                .collider = if (v_colliders) |cols| cols[i] else null,
                .body = if (v_bodies) |bodies| bodies[i] else DEFAULT_TERRAIN_BODY,
                .has_physics_body = v_bodies != null,
                .is_landable = ecs.has_id(world, v_ents[i], ecs.id(C.PlayerLandable)),
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
    var g_it = ecs.query_iter(world, phys.ground_query);
    while (ecs.query_next(&g_it)) {
        const g_positions = ecs.field(&g_it, C.Position, 1).?;
        const g_colliders = ecs.field(&g_it, C.Collider, 2).?;
        for (g_positions, g_colliders) |gp, gcol| {
            grounds.append(allocator, .{ .pos = gp, .col = gcol }) catch return;
        }
    }

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

    var ground_checks: u32 = 0;
    var ground_hits: u32 = 0;
    var self_checks: u32 = 0;
    var self_hits: u32 = 0;

    for (0..SOLVER_ITERATIONS) |_| {
        solveAttachmentConstraints(constraints.items);
        solveSelfCollisions(world, particles.items, &self_checks, &self_hits);
        if (player_pos != null and player_vel != null and player_col != null) {
            solvePlayerContacts(world, particles.items, player_entity, player_pos.?, player_vel.?, player_col.?);
        }
        solveTerrainContacts(particles.items, grounds.items, &ground_checks, &ground_hits);
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

    var q_it = ecs.query_iter(world, phys.verlet_query);

    while (ecs.query_next(&q_it)) {
        const v_positions = ecs.field(&q_it, C.Position, 0).?;
        const v_states = ecs.field(&q_it, C.VerletState, 1).?;
        const v_colliders = ecs.field(&q_it, C.Collider, 2) orelse continue;
        if (ecs.field(&q_it, C.PhysicsBody, 3) == null) continue;

        for (v_positions, v_states, v_colliders) |v_pos, *vs, v_col| {
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

                    const impact_force: f32 = 1.5;
                    applyImpulse(
                        vs,
                        n.x * v_dot_n * impact_force * it.delta_time,
                        n.y * v_dot_n * impact_force * it.delta_time,
                    );
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
    ecs.query_fini(phys.ground_query);
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
