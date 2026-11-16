const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const mw = @import("../material_world.zig");
const Engine = @import("../../engine/core.zig").Engine;
const input_mod = @import("../../engine/input.zig");
const pixel_mod = @import("../../engine/pixels.zig");
const physics = @import("physics.zig");

// --- Tunable Player Movement & Quake/CS Air-Strafe Constants ---
pub const PLAYER_SPEED: f32 = 360.0; // Max ground run speed (px/s)
pub const JUMP_SPEED: f32 = 590.0; // Initial vertical jump velocity (px/s)
pub const FAST_DROP_SPEED: f32 = 400.0; // Downward velocity when pressing down
pub const GROUND_ACCEL: f32 = 14.0; // Ground acceleration factor (subtle ramp on launch)
pub const GROUND_FRICTION: f32 = 30.0; // Ground deceleration when no horizontal input (snappy stop)
pub const GROUND_REVERSE_MULT: f32 = 2.5; // Extra braking multiplier when counter-strafing on ground
pub const GROUND_STOP_THRESHOLD: f32 = 18.0; // Snap low ground drift cleanly to 0
pub const AIR_STRAFE_MAX_SPEED: f32 = 260.0; // Quake-style air-strafe cap along wish dir (preserves higher momentum!)
pub const AIR_STRAFE_ACCEL: f32 = 18.0; // Quake-style air acceleration multiplier when A/D pressed
pub const AIR_DRAG: f32 = 0.25; // Light passive air drag when no horizontal input

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

/// Resolve axis movement flush against overlapping MaterialGrid solid cells (O(1) local window)
/// and optional Ground AABBs. Supports 1-cell step-up along X so carved terrain stairs stay smooth.
fn resolveAxisGroundCollision(
    world: *ecs.world_t,
    pos: *C.Position,
    vel: *C.Velocity,
    col: C.Collider,
    prev_coord: f32,
    axis: Axis,
) void {
    const metrics = C.singletonGetMutSafe(world, C.FrameMetrics);
    const local_aabb = physics.getWorldAABB(.{ .x = 0, .y = 0 }, col);
    var hit = false;

    if (C.singletonGetSafe(world, mw.MaterialGrid)) |grid| {
        if (grid.width > 0 and grid.height > 0) {
            const player_aabb = physics.getWorldAABB(pos.*, col);
            const min_gx = @max(0, grid.worldToCellX(player_aabb.min.x));
            const max_gx = @min(@as(i32, @intCast(grid.width)) - 1, grid.worldToCellX(player_aabb.max.x - 0.0001));
            const min_gy = @max(0, grid.worldToCellY(player_aabb.min.y));
            const max_gy = @min(@as(i32, @intCast(grid.height)) - 1, grid.worldToCellY(player_aabb.max.y - 0.0001));

            if (max_gx >= min_gx and max_gy >= min_gy) {
                if (axis == .x and vel.x != 0.0) {
                    var any_solid = false;
                    var min_hit_cell_y: f32 = std.math.inf(f32);
                    var gy_probe = min_gy;
                    while (gy_probe <= max_gy) : (gy_probe += 1) {
                        var gx_probe = min_gx;
                        while (gx_probe <= max_gx) : (gx_probe += 1) {
                            if (grid.isSolidAtCell(gx_probe, gy_probe)) {
                                any_solid = true;
                                const cell_min_y = grid.cellToWorldMinY(gy_probe);
                                if (cell_min_y < min_hit_cell_y) min_hit_cell_y = cell_min_y;
                            }
                        }
                    }

                    if (any_solid) {
                        const step_up = player_aabb.max.y - min_hit_cell_y + physics.SURFACE_EPSILON;
                        if (step_up > 0.0 and step_up <= grid.cellSizeF() + 0.5) {
                            const stepped_pos = C.Position{ .x = pos.x, .y = pos.y - step_up };
                            const stepped_aabb = physics.getWorldAABB(stepped_pos, col);
                            if (!grid.aabbOverlapsSolid(stepped_aabb, null, null)) {
                                pos.y = stepped_pos.y;
                                return;
                            }
                        }
                    }
                }

                var gy = min_gy;
                while (gy <= max_gy) : (gy += 1) {
                    var gx = min_gx;
                    while (gx <= max_gx) : (gx += 1) {
                        if (metrics) |m| m.physics_checks += 1;
                        if (!grid.isSolidAtCell(gx, gy)) continue;

                        const cur_aabb = physics.getWorldAABB(pos.*, col);
                        const cell_aabb = grid.cellWorldAABB(gx, gy);
                        if (!c2.aabbToAABB(cur_aabb, cell_aabb)) continue;
                        if (metrics) |m| m.physics_hits += 1;

                        hit = true;
                        switch (axis) {
                            .x => {
                                if (vel.x > 0) {
                                    const snap_x = cell_aabb.min.x - physics.SURFACE_EPSILON - local_aabb.max.x;
                                    pos.x = @max(prev_coord, @min(pos.x, snap_x));
                                } else if (vel.x < 0) {
                                    const snap_x = cell_aabb.max.x + physics.SURFACE_EPSILON - local_aabb.min.x;
                                    pos.x = @min(prev_coord, @max(pos.x, snap_x));
                                }
                            },
                            .y => {
                                if (vel.y > 0) {
                                    const snap_y = cell_aabb.min.y - physics.SURFACE_EPSILON - local_aabb.max.y;
                                    pos.y = @max(prev_coord, @min(pos.y, snap_y));
                                } else if (vel.y < 0) {
                                    const snap_y = cell_aabb.max.y + physics.SURFACE_EPSILON - local_aabb.min.y;
                                    pos.y = @min(prev_coord, @max(pos.y, snap_y));
                                }
                            },
                        }
                    }
                }
            }
        }
    }

    if (C.singletonGetSafe(world, C.PhysicsState)) |phys| {
        if (phys.ground_query) |ground_q| {
            var q_it = ecs.query_iter(world, ground_q);
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
        }
    }

    if (hit) {
        switch (axis) {
            .x => vel.x = 0,
            .y => vel.y = 0,
        }
    }
}

/// Push any falling sand grains that fell directly inside the player's body out into nearby air
/// so debris never traps the player mid-stride.
fn displaceTrappedSand(grid: *mw.MaterialGrid, pos: C.Position, col: C.Collider) void {
    if (grid.width == 0 or grid.height == 0) return;
    const aabb = physics.getWorldAABB(pos, col);
    const min_gx = @max(0, grid.worldToCellX(aabb.min.x + 1.0));
    const max_gx = @min(@as(i32, @intCast(grid.width)) - 1, grid.worldToCellX(aabb.max.x - 1.0));
    const min_gy = @max(0, grid.worldToCellY(aabb.min.y + 1.0));
    const max_gy = @min(@as(i32, @intCast(grid.height)) - 1, grid.worldToCellY(aabb.max.y - 1.0));
    if (max_gx < min_gx or max_gy < min_gy) return;

    var gy = min_gy;
    while (gy <= max_gy) : (gy += 1) {
        var gx = min_gx;
        while (gx <= max_gx) : (gx += 1) {
            const cell = grid.getCell(gx, gy) orelse continue;
            if (cell.material != .sand) continue;

            // Prefer displacing upward above player or outward to the side
            const offsets = [_][2]i32{
                .{ 0, -1 },
                .{ -1, -1 },
                .{ 1, -1 },
                .{ -2, 0 },
                .{ 2, 0 },
                .{ 0, -2 },
            };
            for (offsets) |off| {
                const tx = gx + off[0];
                const ty = gy + off[1];
                if (grid.getCell(tx, ty)) |dst| {
                    if (dst.material == .air) {
                        grid.setCell(tx, ty, cell);
                        grid.setCell(gx, gy, mw.Cell{});
                        break;
                    }
                }
            }
        }
    }
}

/// Compute updated horizontal velocity using smooth ground acceleration/friction
/// and Quake/CS-style air-strafe (`AirAccelerate`) so momentum carries in air while
/// directional keys provide responsive midair steering.
pub fn stepHorizontalVelocity(vel_x_in: f32, recoil_x: *f32, dx: f32, is_grounded: bool, dt: f32) f32 {
    var vx = vel_x_in + recoil_x.*;
    recoil_x.* = 0.0;

    if (is_grounded) {
        if (dx != 0.0) {
            const target_vx = dx * PLAYER_SPEED;
            const reversing = (vx * dx) < 0.0;
            const accel_rate = if (reversing) GROUND_ACCEL * GROUND_REVERSE_MULT else GROUND_ACCEL;
            vx = target_vx + (vx - target_vx) * std.math.exp(-accel_rate * dt);
        } else {
            vx *= std.math.exp(-GROUND_FRICTION * dt);
            if (@abs(vx) < GROUND_STOP_THRESHOLD) vx = 0.0;
        }
    } else {
        if (dx != 0.0) {
            const current_in_wish = vx * dx;
            const add_speed = AIR_STRAFE_MAX_SPEED - current_in_wish;
            if (add_speed > 0.0) {
                const accel_speed = @min(add_speed, AIR_STRAFE_ACCEL * AIR_STRAFE_MAX_SPEED * dt);
                vx += dx * accel_speed;
            }
        } else {
            vx *= std.math.exp(-AIR_DRAG * dt);
        }
    }

    return vx;
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
        if (C.singletonGetMutSafe(world, mw.MaterialGrid)) |grid| {
            displaceTrappedSand(grid, pos.*, col);
        }

        const test_pos = C.Position{ .x = pos.x, .y = pos.y + 1 };
        const test_aabb = physics.getWorldAABB(test_pos, col);
        const is_grounded =
            physics.checkCollision(world, test_aabb) or
            playerTouchesLandable(world, test_pos, col);

        var dx: f32 = 0.0;
        if (input.pressed_directions.left) dx -= 1.0;
        if (input.pressed_directions.right) dx += 1.0;

        vel.x = stepHorizontalVelocity(vel.x, &recoil.x, dx, is_grounded, dt);

        vel.y += physics.GRAVITY * dt;
        if (input.pressed_directions.up and is_grounded) {
            vel.y = -JUMP_SPEED;
        } else if (input.pressed_directions.down) {
            vel.y = FAST_DROP_SPEED;
        }

        const prev_x = pos.x;
        pos.x += vel.x * dt;
        resolveAxisGroundCollision(world, pos, vel, col, prev_x, .x);

        const prev_y = pos.y;
        pos.y += vel.y * dt;
        resolveAxisGroundCollision(world, pos, vel, col, prev_y, .y);
    }
}

fn worldDimensions(world: *ecs.world_t) ?struct { w: f32, h: f32 } {
    if (ecs.get_ctx(world)) |ctx| {
        const engine: *Engine = @ptrCast(@alignCast(ctx));
        return .{ .w = @floatFromInt(engine.width), .h = @floatFromInt(engine.height) };
    }
    if (C.singletonGetSafe(world, mw.MaterialGrid)) |grid| {
        return .{
            .w = @as(f32, @floatFromInt(grid.width * grid.cell_size)),
            .h = @as(f32, @floatFromInt(grid.height * grid.cell_size)),
        };
    }
    return null;
}

pub fn player_clamp_system(it: *ecs.iter_t, positions: []C.Position, velocities: []C.Velocity, colliders: []C.Collider) void {
    const dims = worldDimensions(it.world) orelse return;
    const w = dims.w;
    const h = dims.h;

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

/// Consume up to `max_cells` closest `liquid_purple` cells within `reach_radius` into `reservoir`.
pub fn drinkNearbyLiquid(
    grid: *mw.MaterialGrid,
    pos: C.Position,
    reach_radius: f32,
    reservoir: *C.LiquidReservoir,
    max_cells: u32,
) u32 {
    if (grid.width == 0 or grid.height == 0 or max_cells == 0) return 0;
    if (reservoir.amount >= reservoir.capacity) return 0;

    const min_gx = @max(0, grid.worldToCellX(pos.x - reach_radius));
    const max_gx = @min(@as(i32, @intCast(grid.width)) - 1, grid.worldToCellX(pos.x + reach_radius));
    const min_gy = @max(0, grid.worldToCellY(pos.y - reach_radius));
    const max_gy = @min(@as(i32, @intCast(grid.height)) - 1, grid.worldToCellY(pos.y + reach_radius));
    if (max_gx < min_gx or max_gy < min_gy) return 0;

    const r_sq = reach_radius * reach_radius;
    var drunk: u32 = 0;

    while (drunk < max_cells and reservoir.amount < reservoir.capacity) {
        var best_gx: i32 = -1;
        var best_gy: i32 = -1;
        var best_d_sq: f32 = r_sq + 1.0;

        var gy = min_gy;
        while (gy <= max_gy) : (gy += 1) {
            const wy = grid.cellToWorldCenterY(gy);
            const dy = wy - pos.y;
            var gx = min_gx;
            while (gx <= max_gx) : (gx += 1) {
                const cell = grid.getCell(gx, gy) orelse continue;
                if (cell.material != .liquid_purple) continue;

                const wx = grid.cellToWorldCenterX(gx);
                const dx = wx - pos.x;
                const d_sq = dx * dx + dy * dy;
                if (d_sq <= r_sq and d_sq < best_d_sq) {
                    best_d_sq = d_sq;
                    best_gx = gx;
                    best_gy = gy;
                }
            }
        }

        if (best_gx < 0) break;
        if (reservoir.addLiquid(.purple, 1) == 0) break;
        grid.setCell(best_gx, best_gy, mw.Cell{});
        drunk += 1;
    }

    return drunk;
}

pub fn player_drink_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    colliders: []C.Collider,
    reservoirs: []C.LiquidReservoir,
) void {
    const world = it.world;
    const dt = it.delta_time;
    const grid = C.singletonGetMutSafe(world, mw.MaterialGrid);
    const input = C.singletonGetSafe(world, input_mod.InputState);
    const interact_held = if (input) |inp| inp.interact else false;

    for (positions, colliders, reservoirs) |pos, col, *res| {
        if (res.drink_cooldown > 0.0) {
            res.drink_cooldown = @max(0.0, res.drink_cooldown - dt);
        }
        if (res.dry_push_cooldown > 0.0) {
            res.dry_push_cooldown = @max(0.0, res.dry_push_cooldown - dt);
        }

        const mg = grid orelse continue;
        if (res.amount >= res.capacity or res.drink_cooldown > 0.0) continue;

        const base_r = switch (col) {
            .circle => |c| c.r,
            .box => |b| @max(b.max.x - b.min.x, b.max.y - b.min.y) * 0.5,
        };
        const reach = base_r + (if (interact_held) @as(f32, 16.0) else @as(f32, 6.0));
        const max_sip: u32 = if (interact_held) 2 else 1;

        const drunk = drinkNearbyLiquid(mg, pos, reach, res, max_sip);
        if (drunk > 0) {
            res.drink_cooldown = if (interact_held) 0.008 else 0.016;
            physics.spawnExplosion(world, pos.x, pos.y + base_r * 0.4, 0.0, -1.0, .{
                .speed = 45.0,
                .spread = 1.6,
                .color = pixel_mod.packColor(210, 80, 255, 255),
                .bounce = 0.0,
            });
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

test "drinkNearbyLiquid consumes liquid_purple into reservoir, ignores water, and respects capacity" {
    const testing = std.testing;
    var grid = try mw.MaterialGrid.init(testing.allocator, 20, 20, 4);
    defer grid.deinit();

    // Place 4 purple cells and 4 water cells within reach of (40, 40)
    grid.setMaterial(9, 10, .liquid_purple);
    grid.setMaterial(10, 10, .liquid_purple);
    grid.setMaterial(11, 10, .liquid_purple);
    grid.setMaterial(10, 11, .liquid_purple);
    grid.setMaterial(9, 9, .liquid_water);
    grid.setMaterial(10, 9, .liquid_water);

    var res = C.LiquidReservoir{ .capacity = 3, .shot_cost = 2 };
    try testing.expect(!res.hasAmmo());

    const drunk = drinkNearbyLiquid(&grid, .{ .x = 40.0, .y = 40.0 }, 20.0, &res, 10);
    // Capacity is 3, so exactly 3 purple cells are consumed; 1 purple cell and water cells remain
    try testing.expectEqual(@as(u32, 3), drunk);
    try testing.expectEqual(@as(u32, 3), res.amount);
    try testing.expectEqual(C.ReservoirMaterial.purple, res.material);
    try testing.expect(res.hasAmmo());
    try testing.expectEqual(mw.Material.liquid_water, grid.getCell(9, 9).?.material);
    try testing.expectEqual(mw.Material.liquid_water, grid.getCell(10, 9).?.material);

    // Spend 2 units for 1 shot -> 1 unit left (< shot_cost 2), so hasAmmo becomes false
    try testing.expect(res.tryConsumeForShot());
    try testing.expectEqual(@as(u32, 1), res.amount);
    try testing.expect(!res.hasAmmo());
    try testing.expect(!res.tryConsumeForShot());
}

test "resolveAxisGroundCollision resolves MaterialGrid walls and steps up 1-cell ledges" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, mw.MaterialGrid);
    var grid = try mw.MaterialGrid.init(testing.allocator, 32, 32, 4);
    defer grid.deinit();

    // Flat rock floor at gy=20 (y=80..84), single 1-cell step at (14, 19), tall wall at gx=18 (gy=10..19)
    grid.fillCellRect(0, 20, 32, 21, .rock, true);
    grid.setMaterial(14, 19, .rock);
    grid.fillCellRect(18, 10, 19, 20, .rock, true);
    _ = ecs.singleton_set(world, mw.MaterialGrid, grid);

    const col = C.Collider{ .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 10.0 } };
    // Start standing flush on row 20: bottom at 80.0 - 0.01 = 79.99 -> pos.y = 69.99
    var pos = C.Position{ .x = 40.0, .y = 69.99 };
    var vel = C.Velocity{ .x = 200.0, .y = 0.0 };

    // Move across the 1-cell step at x=56..60 (pos.x = 50 -> player max.x = 60)
    const prev_x = pos.x;
    pos.x = 48.0;
    resolveAxisGroundCollision(world, &pos, &vel, col, prev_x, .x);
    // Should step up by ~4px onto row 19 instead of zeroing vel.x!
    try testing.expect(vel.x > 0.0);
    try testing.expect(pos.y < 67.0);

    // Move right into tall wall at gx=18 (x = 72)
    pos.x = 66.0; // max.x = 76 > 72
    resolveAxisGroundCollision(world, &pos, &vel, col, 60.0, .x);
    try testing.expectEqual(@as(f32, 0.0), vel.x);
    try testing.expectApproxEqAbs(@as(f32, 62.0 - physics.SURFACE_EPSILON), pos.x, 0.01);
}

test "stepHorizontalVelocity gives subtle ground launch and Quake-style air strafe momentum carry" {
    const testing = std.testing;
    const dt: f32 = 1.0 / 120.0;
    var recoil_x: f32 = 0.0;

    // 1. Pressing Right from standstill on ground ramps smoothly instead of snapping to full speed
    const launch_vx = stepHorizontalVelocity(0.0, &recoil_x, 1.0, true, dt);
    try testing.expect(launch_vx > 0.0);
    try testing.expect(launch_vx < PLAYER_SPEED * 0.25);

    // 2. Carrying high horizontal speed (e.g. running jump or recoil) in air while pressing same dir preserves speed
    const carried_vx = stepHorizontalVelocity(350.0, &recoil_x, 1.0, false, dt);
    try testing.expectApproxEqAbs(@as(f32, 350.0), carried_vx, 0.01);

    // 3. Pressing Left in air brakes and reverses briskly via AIR_STRAFE_ACCEL
    var air_vx: f32 = 200.0;
    for (0..20) |_| {
        air_vx = stepHorizontalVelocity(air_vx, &recoil_x, -1.0, false, dt);
    }
    try testing.expect(air_vx < -50.0);

    // 4. Releasing keys on ground stops full run speed snappily (~0.1s) without long sliding
    var ground_vx: f32 = PLAYER_SPEED;
    for (0..14) |_| {
        ground_vx = stepHorizontalVelocity(ground_vx, &recoil_x, 0.0, true, dt);
    }
    try testing.expectEqual(@as(f32, 0.0), ground_vx);
}
