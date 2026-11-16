const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const mw = @import("../material_world.zig");
const Engine = @import("../../engine/core.zig").Engine;
const input_mod = @import("../../engine/input.zig");
const pixel_mod = @import("../../engine/pixels.zig");
const Effect = @import("../../engine/effects.zig").Effect;
const physics = @import("physics.zig");

pub const BULLET_SPEED: f32 = 1000.0;

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

pub fn right_controller_stick_set_mouse_xy_system(it: *ecs.iter_t) void {
    const world = it.world;
    const input = C.singletonGetSafe(world, input_mod.InputState) orelse return;

    if (input.active_input_method != .controller) return;
    if (input.right_stick_x == 0.0 and input.right_stick_y == 0.0) return;

    const dims = worldDimensions(world) orelse return;
    const w = dims.w;
    const h = dims.h;

    if (C.singletonGetSafe(world, C.PlayerContainer)) |pc| {
        if (ecs.get(world, pc.entity, C.Position)) |pos| {
            const dx = input.right_stick_x;
            const dy = input.right_stick_y;

            const tx = if (dx > 0) (w - pos.x) / dx else if (dx < 0) -pos.x / dx else std.math.floatMax(f32);
            const ty = if (dy > 0) (h - pos.y) / dy else if (dy < 0) -pos.y / dy else std.math.floatMax(f32);
            const t = @min(tx, ty);
            const target_pos = C.Position{
                .x = pos.x + dx * t,
                .y = pos.y + dy * t,
            };

            _ = ecs.singleton_set(world, C.AimTarget, .{ .x = target_pos.x, .y = target_pos.y });
            const mouse_cursor = ecs.lookup(world, "MouseCursor");
            if (mouse_cursor != 0) {
                _ = ecs.set(world, mouse_cursor, C.Position, target_pos);
            }
        }
    }
}

pub fn gun_aim_system(it: *ecs.iter_t, gun_positions: []C.Position) void {
    const world = it.world;
    const aim = C.singletonGetSafe(world, C.AimTarget) orelse return;
    const phys = C.singletonGetSafe(world, C.PhysicsState);
    const grid = C.singletonGetSafe(world, mw.MaterialGrid);
    const player_container = C.singletonGetSafe(world, C.PlayerContainer) orelse return;
    const player_pos = ecs.get(world, player_container.entity, C.Position) orelse return;

    const GUN_RADIUS: f32 = 40.0;

    for (gun_positions) |*gpos| {
        const dx: f32 = aim.x - player_pos.x;
        const dy: f32 = aim.y - player_pos.y;
        const dist: f32 = @sqrt(dx * dx + dy * dy);

        const aim_dist = @min(dist, GUN_RADIUS);
        var final_dist = aim_dist;

        if (dist > 0.001) {
            const nx = dx / dist;
            const ny = dy / dist;

            if (grid) |mg| {
                const end_x = player_pos.x + nx * aim_dist;
                const end_y = player_pos.y + ny * aim_dist;
                if (mg.raycastSegment(player_pos.x, player_pos.y, end_x, end_y, false)) |hit| {
                    final_dist = @min(final_dist, @max(0.0, hit.t * aim_dist - 1.0));
                }
            }

            if (phys) |p| {
                if (p.ground_query) |ground_q| {
                    const ray = c2.Ray{
                        .p = c2.Vec2{ .x = player_pos.x, .y = player_pos.y },
                        .d = c2.Vec2{ .x = nx, .y = ny },
                        .t = aim_dist,
                    };
                    var q_it = ecs.query_iter(world, ground_q);
                    while (ecs.query_next(&q_it)) {
                        const g_positions = ecs.field(&q_it, C.Position, 1).?;
                        const g_colliders = ecs.field(&q_it, C.Collider, 2).?;
                        for (0..q_it.count()) |i| {
                            const ground_aabb = physics.getWorldAABB(g_positions[i], g_colliders[i]);
                            var cast_out: c2.Raycast = undefined;
                            if (c2.rayToAABB(ray, ground_aabb, &cast_out)) {
                                if (cast_out.t < final_dist) final_dist = cast_out.t;
                            }
                        }
                    }
                }
            }

            gpos.x = player_pos.x + nx * final_dist;
            gpos.y = player_pos.y + ny * final_dist;
        } else {
            gpos.x = player_pos.x;
            gpos.y = player_pos.y;
        }
    }
}

pub fn shoot_system(it: *ecs.iter_t, guns: []C.Gun, positions: []C.Position) void {
    const world = it.world;
    const input = C.singletonGetSafe(world, input_mod.InputState) orelse return;
    const bullets_group = C.singletonGetSafe(world, C.BulletsGroup);
    const player_container = C.singletonGetSafe(world, C.PlayerContainer);
    const aim = C.singletonGetSafe(world, C.AimTarget);

    const reservoir = if (player_container) |pc| ecs.get_mut(world, pc.entity, C.LiquidReservoir) else null;
    const player_pos = if (player_container) |pc| ecs.get(world, pc.entity, C.Position) else null;

    for (positions, guns) |pos, *gun| {
        if (gun.cooldown > 0.0) {
            gun.cooldown = @max(0.0, gun.cooldown - it.delta_time);
        }
        const newly_pressed = input.is_pressing and !gun.was_pressing;
        gun.was_pressing = input.is_pressing;

        if (reservoir) |res| {
            if (res.dry_push_cooldown > 0.0) {
                res.dry_push_cooldown = @max(0.0, res.dry_push_cooldown - it.delta_time);
            }
        }

        if (!input.is_pressing) continue;

        const origin_x = if (player_pos) |pp| pp.x else pos.x;
        const origin_y = if (player_pos) |pp| pp.y else pos.y;
        const aim_dx = if (aim) |a| a.x - origin_x else 0.0;
        const aim_dy = if (aim) |a| a.y - origin_y else 0.0;
        const aim_dist = @sqrt(aim_dx * aim_dx + aim_dy * aim_dy);

        if (reservoir) |res| {
            if (!res.hasAmmo()) {
                // Empty reservoir: single weak dry-push recoil per click with cooldown
                if (!newly_pressed or res.dry_push_cooldown > 0.0) continue;
                res.dry_push_cooldown = res.dry_push_rate;

                if (aim_dist > 0.0001) {
                    const dir_x = aim_dx / aim_dist;
                    const dir_y = aim_dy / aim_dist;
                    if (player_container) |pc| {
                        if (ecs.get_mut(world, pc.entity, C.Velocity)) |vel| {
                            vel.y -= dir_y * res.dry_push_recoil;
                        }
                        if (ecs.get_mut(world, pc.entity, C.RecoilImpulse)) |impulse| {
                            impulse.x -= dir_x * res.dry_push_recoil;
                        }
                    }
                    if (ecs.id(C.ExplosionParticle) != 0) {
                        physics.spawnExplosion(world, pos.x, pos.y, dir_x, dir_y, .{
                            .speed = 65.0,
                            .spread = 0.7,
                            .color = pixel_mod.packColor(210, 210, 225, 255),
                            .bounce = 0.1,
                            .randomness = 0.6,
                        });
                    }
                }
                continue;
            }

            if (gun.cooldown > 0.0) continue;
            if (!res.tryConsumeForShot()) continue;
        } else {
            if (gun.cooldown > 0.0) continue;
        }

        gun.cooldown = gun.fire_rate;

        const bullet = ecs.new_id(world);
        ecs.add(world, bullet, C.Bullet);
        _ = ecs.set(world, bullet, C.PhysicsBody, .{
            .friction = 0.99,
            .prev_x = pos.x,
            .prev_y = pos.y,
            .has_prev = true,
        });

        if (bullets_group) |group| {
            ecs.add_pair(world, bullet, ecs.ChildOf, group.entity);
        }

        _ = ecs.set(world, bullet, C.Collider, .{
            .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 5 },
        });
        _ = ecs.set(world, bullet, C.Position, pos);
        _ = ecs.set(world, bullet, C.Renderable, .{
            .color = C.Color{ .r = 215, .g = 70, .b = 255, .a = 255 },
        });
        if (ecs.id(Effect) != 0) {
            _ = ecs.set(world, bullet, Effect, Effect.glow_only);
        }

        if (aim != null and aim_dist > 0.0001) {
            const dir_x = aim_dx / aim_dist;
            const dir_y = aim_dy / aim_dist;

            _ = ecs.set(world, bullet, C.Velocity, .{
                .x = dir_x * BULLET_SPEED,
                .y = dir_y * BULLET_SPEED,
            });

            if (player_container) |pc| {
                if (ecs.get_mut(world, pc.entity, C.Velocity)) |vel| {
                    vel.y -= dir_y * gun.recoil;
                }
                if (ecs.get_mut(world, pc.entity, C.RecoilImpulse)) |impulse| {
                    impulse.x -= dir_x * gun.recoil;
                }
            }
        } else {
            _ = ecs.set(world, bullet, C.Velocity, .{ .x = 0, .y = 0 });
        }
    }
}

pub fn bullet_cleanup_system(it: *ecs.iter_t, positions: []C.Position) void {
    const dims = worldDimensions(it.world) orelse return;
    const w = dims.w;
    const h = dims.h;
    const ents = it.entities();

    for (0..it.count()) |i| {
        const pos = positions[i];
        if (pos.x < 0 or pos.x > w or pos.y < 0 or pos.y > h) {
            ecs.delete(it.world, ents[i]);
        }
    }
}

test "shoot_system ticks cooldown down even when trigger is released" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Gun);
    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Velocity);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.Renderable);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.AimTarget);
    ecs.COMPONENT(world, C.BulletsGroup);
    ecs.COMPONENT(world, C.PlayerContainer);
    ecs.COMPONENT(world, input_mod.InputState);
    ecs.TAG(world, C.Bullet);

    const bullets_group = ecs.new_entity(world, "Bullets");
    _ = ecs.singleton_set(world, C.BulletsGroup, .{ .entity = bullets_group });
    _ = ecs.singleton_set(world, C.AimTarget, .{ .x = 100.0, .y = 0.0 });
    _ = ecs.singleton_set(world, input_mod.InputState, .{ .is_pressing = false });

    const gun_e = ecs.new_id(world);
    _ = ecs.set(world, gun_e, C.Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, gun_e, C.Gun, .{ .cooldown = 0.05, .fire_rate = 0.1 });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "test_shoot", ecs.OnUpdate, shoot_system, &.{
        .{ .id = ecs.id(C.Gun) },
        .{ .id = ecs.id(C.Position) },
    });

    // Advance while NOT pressing: cooldown must decay to 0 without firing.
    _ = ecs.progress(world, 0.06);
    try testing.expectEqual(@as(f32, 0.0), ecs.get(world, gun_e, C.Gun).?.cooldown);

    // Now press fire: should spawn a bullet immediately and reset cooldown.
    _ = ecs.singleton_set(world, input_mod.InputState, .{ .is_pressing = true });
    _ = ecs.progress(world, 0.016);
    try testing.expectApproxEqAbs(@as(f32, 0.1), ecs.get(world, gun_e, C.Gun).?.cooldown, 0.0001);
}

test "shoot_system performs single dry-push when empty and spends liquid ammo until exhausted" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Gun);
    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Velocity);
    ecs.COMPONENT(world, C.RecoilImpulse);
    ecs.COMPONENT(world, C.Collider);
    ecs.COMPONENT(world, C.Renderable);
    ecs.COMPONENT(world, C.PhysicsBody);
    ecs.COMPONENT(world, C.LiquidReservoir);
    ecs.COMPONENT(world, C.AimTarget);
    ecs.COMPONENT(world, C.BulletsGroup);
    ecs.COMPONENT(world, C.PlayerContainer);
    ecs.COMPONENT(world, input_mod.InputState);
    ecs.TAG(world, C.Bullet);

    const bullets_group = ecs.new_entity(world, "Bullets");
    _ = ecs.singleton_set(world, C.BulletsGroup, .{ .entity = bullets_group });
    _ = ecs.singleton_set(world, C.AimTarget, .{ .x = 0.0, .y = 200.0 }); // Aim straight down
    _ = ecs.singleton_set(world, input_mod.InputState, .{ .is_pressing = false });

    const player = ecs.new_entity(world, "Player");
    _ = ecs.set(world, player, C.Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, C.Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, C.RecoilImpulse, .{ .x = 0.0 });
    _ = ecs.set(world, player, C.LiquidReservoir, .{
        .amount = 0,
        .capacity = 20,
        .shot_cost = 2,
        .dry_push_rate = 0.4,
        .dry_push_recoil = 150.0,
    });
    _ = ecs.singleton_set(world, C.PlayerContainer, .{ .entity = player });

    const gun_e = ecs.new_id(world);
    _ = ecs.set(world, gun_e, C.Position, .{ .x = 0.0, .y = 20.0 });
    _ = ecs.set(world, gun_e, C.Gun, .{ .fire_rate = 0.05, .recoil = 300.0 });

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "test_shoot", ecs.OnUpdate, shoot_system, &.{
        .{ .id = ecs.id(C.Gun) },
        .{ .id = ecs.id(C.Position) },
    });

    var bullet_desc = ecs.query_desc_t{};
    bullet_desc.terms[0] = .{ .id = ecs.id(C.Bullet) };
    const bullet_q = ecs.query_init(world, &bullet_desc) catch unreachable;
    defer ecs.query_fini(bullet_q);

    // 1. Click while empty -> dry-push upward (-150), 0 bullets spawned
    _ = ecs.singleton_set(world, input_mod.InputState, .{ .is_pressing = true });
    _ = ecs.progress(world, 0.016);
    try testing.expectApproxEqAbs(@as(f32, -150.0), ecs.get(world, player, C.Velocity).?.y, 0.01);

    // Holding button does NOT repeat dry-push
    _ = ecs.progress(world, 0.5);
    try testing.expectApproxEqAbs(@as(f32, -150.0), ecs.get(world, player, C.Velocity).?.y, 0.01);

    var q_it = ecs.query_iter(world, bullet_q);
    var bullets_seen: usize = 0;
    while (ecs.query_next(&q_it)) bullets_seen += q_it.count();
    try testing.expectEqual(@as(usize, 0), bullets_seen);

    // 2. Fill reservoir with 2 units (1 shot) and click -> fires 1 bullet, strong recoil (-300), runs dry
    _ = ecs.singleton_set(world, input_mod.InputState, .{ .is_pressing = false });
    _ = ecs.progress(world, 0.016);
    _ = ecs.get_mut(world, player, C.LiquidReservoir).?.addLiquid(.purple, 2);
    ecs.get_mut(world, player, C.Velocity).?.y = 0.0;

    _ = ecs.singleton_set(world, input_mod.InputState, .{ .is_pressing = true });
    _ = ecs.progress(world, 0.016);

    try testing.expectEqual(@as(u32, 0), ecs.get(world, player, C.LiquidReservoir).?.amount);
    try testing.expect(!ecs.get(world, player, C.LiquidReservoir).?.hasAmmo());
    try testing.expectApproxEqAbs(@as(f32, -300.0), ecs.get(world, player, C.Velocity).?.y, 0.01);

    q_it = ecs.query_iter(world, bullet_q);
    bullets_seen = 0;
    while (ecs.query_next(&q_it)) bullets_seen += q_it.count();
    try testing.expectEqual(@as(usize, 1), bullets_seen);

    // Next shot after cooldown while still holding does NOT fire because reservoir is empty
    _ = ecs.progress(world, 0.1);
    q_it = ecs.query_iter(world, bullet_q);
    bullets_seen = 0;
    while (ecs.query_next(&q_it)) bullets_seen += q_it.count();
    try testing.expectEqual(@as(usize, 1), bullets_seen);
}

test "gun_aim_system clamps gun tip before MaterialGrid rock via DDA" {
    const testing = std.testing;
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, C.Position);
    ecs.COMPONENT(world, C.Gun);
    ecs.COMPONENT(world, C.AimTarget);
    ecs.COMPONENT(world, C.PlayerContainer);
    ecs.COMPONENT(world, mw.MaterialGrid);

    var grid = try mw.MaterialGrid.init(testing.allocator, 32, 16, 4);
    defer grid.deinit();
    // Solid rock wall at gx=15 (x = 60..64)
    grid.fillCellRect(15, 0, 16, 16, .rock, true);
    _ = ecs.singleton_set(world, mw.MaterialGrid, grid);

    const player = ecs.new_id(world);
    _ = ecs.set(world, player, C.Position, .{ .x = 40.0, .y = 32.0 });
    _ = ecs.singleton_set(world, C.PlayerContainer, .{ .entity = player });
    _ = ecs.singleton_set(world, C.AimTarget, .{ .x = 120.0, .y = 32.0 });

    const gun = ecs.new_id(world);
    _ = ecs.set(world, gun, C.Position, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, gun, C.Gun, .{});

    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "test_aim", ecs.OnUpdate, gun_aim_system, &.{
        .{ .id = ecs.id(C.Gun) },
    });

    _ = ecs.progress(world, 0.016);
    const gp = ecs.get(world, gun, C.Position).?;
    // Without rock, GUN_RADIUS=40 would put gun at x=80; rock at x=60 clamps it to ~59
    try testing.expect(gp.x < 60.0);
    try testing.expect(gp.x > 55.0);
}
