const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const C = @import("../components.zig");
const Engine = @import("../../engine/core.zig").Engine;
const input_mod = @import("../../engine/input.zig");
const physics = @import("physics.zig");

pub const BULLET_SPEED: f32 = 1000.0;

pub fn right_controller_stick_set_mouse_xy_system(it: *ecs.iter_t) void {
    const world = it.world;
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const engine = Engine.getEngine(world);

    if (input.active_input_method != .controller) return;
    if (input.right_stick_x == 0.0 and input.right_stick_y == 0.0) return;

    if (ecs.singleton_get(world, C.PlayerContainer)) |pc| {
        if (ecs.get(world, pc.entity, C.Position)) |pos| {
            const dx = input.right_stick_x;
            const dy = input.right_stick_y;
            const w: f32 = @floatFromInt(engine.width);
            const h: f32 = @floatFromInt(engine.height);

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
    const aim = ecs.singleton_get(world, C.AimTarget) orelse return;
    const phys = ecs.singleton_get(world, C.PhysicsState);
    const player_container = ecs.singleton_get(world, C.PlayerContainer) orelse return;
    const player_pos = ecs.get(world, player_container.entity, C.Position) orelse return;

    const GUN_RADIUS: f32 = 40.0;

    for (gun_positions) |*gpos| {
        const dx: f32 = aim.x - player_pos.x;
        const dy: f32 = aim.y - player_pos.y;
        const dist: f32 = @sqrt(dx * dx + dy * dy);

        const aim_dist = @min(dist, GUN_RADIUS);
        var final_dist = aim_dist;

        if (dist > 0.001 and phys != null) {
            const nx = dx / dist;
            const ny = dy / dist;
            const ray = c2.Ray{
                .p = c2.Vec2{ .x = player_pos.x, .y = player_pos.y },
                .d = c2.Vec2{ .x = nx, .y = ny },
                .t = aim_dist,
            };
            var q_it = ecs.query_iter(world, phys.?.ground_query);

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
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const bullets_group = ecs.singleton_get(world, C.BulletsGroup);

    for (positions, guns) |pos, *gun| {
        if (gun.cooldown > 0) {
            gun.cooldown = @max(0.0, gun.cooldown - it.delta_time);
        }
        if (!input.is_pressing or gun.cooldown > 0) continue;

        gun.cooldown = gun.fire_rate;

        const bullet = ecs.new_id(world);
        ecs.add(world, bullet, C.Bullet);
        _ = ecs.set(world, bullet, C.PhysicsBody, .{ .friction = 0.99 });

        if (bullets_group) |group| {
            ecs.add_pair(world, bullet, ecs.ChildOf, group.entity);
        }

        _ = ecs.set(world, bullet, C.Collider, .{
            .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 5 },
        });
        _ = ecs.set(world, bullet, C.Position, pos);
        _ = ecs.set(world, bullet, C.Renderable, .{
            .color = C.Color{ .r = 255, .g = 0, .b = 255, .a = 255 },
        });

        const aim = ecs.singleton_get(world, C.AimTarget) orelse {
            _ = ecs.set(world, bullet, C.Velocity, .{ .x = 0, .y = 0 });
            continue;
        };
        const dx = aim.x - pos.x;
        const dy = aim.y - pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        if (dist > 0) {
            const dir_x = dx / dist;
            const dir_y = dy / dist;

            _ = ecs.set(world, bullet, C.Velocity, .{
                .x = dir_x * BULLET_SPEED,
                .y = dir_y * BULLET_SPEED,
            });

            if (ecs.singleton_get(world, C.PlayerContainer)) |pc| {
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
    const engine = Engine.getEngine(it.world);
    const w: f32 = @floatFromInt(engine.width);
    const h: f32 = @floatFromInt(engine.height);
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
