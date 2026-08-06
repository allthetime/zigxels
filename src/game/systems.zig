const std = @import("std");
const ecs = @import("zflecs");
const SDL = @import("sdl2");
const components = @import("components.zig");
const Engine = @import("../engine/core.zig").Engine;
const c2 = @import("zig_c2");

const input_mod = @import("../engine/input.zig");
const pixel_mod = @import("../engine/pixels.zig");
const Effect = @import("../engine/effects.zig").Effect;

// const pixel_mod = @import("../engine/pixels.zig");

const Position = components.Position;
const Velocity = components.Velocity;
const AimTarget = components.AimTarget;
const Renderable = components.Renderable;
const Collider = components.Collider;
const Ground = components.Ground;
const Bullet = components.Bullet;
const Player = components.Player;
const PhysicsBody = components.PhysicsBody;

const Axis = enum { x, y };

pub const PLAYER_SPEED: f32 = 400.0;
pub const BULLET_SPEED: f32 = 1000.0;
pub const GRAVITY: f32 = 2500.0;
pub const JUMP_IMPULSE: f32 = -600.0;

pub const JELLY_REPULSION: f32 = 0.3; // How strongly jellies push each other apart (0.1 = squishy, 1.0 = rigid)
pub const JELLY_FRICTION: f32 = 0.85; // How quickly sliding objects lose energy
pub const JELLY_RESTITUTION: f32 = 0.2; // Extra bounce factor when they hit walls/each other

// --- Helper Functions ---

fn clamp(comptime T: type, value: T, min: T, max: T) T {
    return @max(min, @min(value, max));
}

fn f32_to_i32(value: f32) i32 {
    return @as(i32, @intFromFloat(value));
}

/// Helper to transform local collider to world space AABB
pub fn getWorldAABB(pos: Position, collider: Collider) c2.AABB {
    switch (collider) {
        .box => |b| {
            // Add world position to local bounds
            return c2.AABB{
                .min = .{ .x = b.min.x + pos.x, .y = b.min.y + pos.y },
                .max = .{ .x = b.max.x + pos.x, .y = b.max.y + pos.y },
            };
        },
        .circle => |c| {
            // Approximate circle as AABB for broadphase
            const min_x = (pos.x + c.p.x) - c.r;
            const min_y = (pos.y + c.p.y) - c.r;
            const max_x = (pos.x + c.p.x) + c.r;
            const max_y = (pos.y + c.p.y) + c.r;
            return c2.AABB{
                .min = .{ .x = min_x, .y = min_y },
                .max = .{ .x = max_x, .y = max_y },
            };
        },
    }
}

/// Helper to check if an AABB collides with ANY Ground entity
fn checkCollision(world: *ecs.world_t, test_aabb: c2.AABB) bool {
    const phys = ecs.singleton_get(world, components.PhysicsState) orelse return false;
    var q_it = ecs.query_iter(world, phys.ground_query);

    while (ecs.query_next(&q_it)) {
        const g_positions = ecs.field(&q_it, Position, 1).?;
        const g_colliders = ecs.field(&q_it, Collider, 2).?;

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

fn playerTouchesLandable(world: *ecs.world_t, player_pos: Position, player_col: Collider) bool {
    const phys = ecs.singleton_get(world, components.PhysicsState) orelse return false;
    const player_circle = switch (player_col) {
        .circle => |circle| c2.Circle{
            .p = .{ .x = player_pos.x + circle.p.x, .y = player_pos.y + circle.p.y },
            .r = circle.r,
        },
        .box => return false,
    };

    var q_it = ecs.query_iter(world, phys.player_landable_query);
    while (ecs.query_next(&q_it)) {
        const core_positions = ecs.field(&q_it, Position, 1).?;
        const core_colliders = ecs.field(&q_it, Collider, 2).?;

        for (core_positions, core_colliders) |core_pos, core_col| {
            const core_circle = switch (core_col) {
                .circle => |circle| c2.Circle{
                    .p = .{ .x = core_pos.x + circle.p.x, .y = core_pos.y + circle.p.y },
                    .r = circle.r,
                },
                .box => continue,
            };

            var contact: c2.Manifold = undefined;
            contact.count = 0;
            c2.circleToCircleManifold(player_circle, core_circle, &contact);

            if (contact.count > 0) return true;
        }
    }

    return false;
}

fn resolvePlayerLandableContacts(
    world: *ecs.world_t,
    player_pos: *Position,
    player_vel: *Velocity,
    player_col: Collider,
) void {
    const phys = ecs.singleton_get(world, components.PhysicsState) orelse return;

    const player_circle = switch (player_col) {
        .circle => |circle| c2.Circle{
            .p = .{
                .x = player_pos.x + circle.p.x,
                .y = player_pos.y + circle.p.y,
            },
            .r = circle.r,
        },
        .box => return,
    };

    var q_it = ecs.query_iter(world, phys.player_landable_query);
    while (ecs.query_next(&q_it)) {
        const core_positions = ecs.field(&q_it, Position, 1).?;
        const core_colliders = ecs.field(&q_it, Collider, 2).?;
        const core_verlets = ecs.field(&q_it, components.VerletState, 3).?;

        for (core_positions, core_colliders, core_verlets) |*core_pos, core_col, *core_verlet| {
            const core_circle = switch (core_col) {
                .circle => |circle| c2.Circle{
                    .p = .{
                        .x = core_pos.x + circle.p.x,
                        .y = core_pos.y + circle.p.y,
                    },
                    .r = circle.r,
                },
                .box => continue,
            };

            var contact: c2.Manifold = undefined;
            contact.count = 0;
            c2.circleToCircleManifold(player_circle, core_circle, &contact);

            if (contact.count == 0) continue;

            const separation = contact.depths[0] + 0.01;
            const normal = contact.n; // Player -> jelly core
            const landing = player_vel.y > 0.0 and normal.y > 0.5;

            if (landing) {
                // Keep the player primarily responsible for separating, so it can stand.
                const player_share: f32 = 0.85;
                const core_share: f32 = 0.15;

                player_pos.x -= normal.x * separation * player_share;
                player_pos.y -= normal.y * separation * player_share;
                player_vel.y = 0.0;

                // Slightly compress the core while preserving its implicit Verlet velocity.
                const push_x = normal.x * separation * core_share;
                const push_y = normal.y * separation * core_share;
                core_pos.x += push_x;
                core_pos.y += push_y;
                core_verlet.old_x += push_x;
                core_verlet.old_y += push_y;
            } else {
                // Preserve the current strong “player pushes jelly away” behavior.
                core_pos.x += normal.x * separation;
                core_pos.y += normal.y * separation;
                core_verlet.old_x += normal.x * separation;
                core_verlet.old_y += normal.y * separation;
            }
        }
    }
}

// --- Systems ---

pub fn gravity_system(it: *ecs.iter_t, velocities: []Velocity) void {
    const dt = it.delta_time;

    for (velocities) |*vel| {
        vel.y += GRAVITY * dt;
    }
}

pub fn player_clamp_system(it: *ecs.iter_t, positions: []Position) void {
    const engine = Engine.getEngine(it.world);
    const w = @as(f32, @floatFromInt(engine.width));
    const h = @as(f32, @floatFromInt(engine.height));

    for (positions) |*pos| {
        pos.x = clamp(f32, pos.x, 0.0, w);
        pos.y = clamp(f32, pos.y, 0.0, h);
    }
}

pub fn bullet_cleanup_system(it: *ecs.iter_t, positions: []Position) void {
    const engine = Engine.getEngine(it.world);
    const w = @as(f32, @floatFromInt(engine.width));
    const h = @as(f32, @floatFromInt(engine.height));
    const ents = it.entities();

    for (0..it.count()) |i| {
        const pos = positions[i];
        if (pos.x < 0 or pos.x > w or pos.y > h) {
            ecs.delete(it.world, ents[i]);
        }
    }
}

pub fn seek_system(it: *ecs.iter_t) void {
    _ = it;
}

pub fn render_system(it: *ecs.iter_t, positions: []Position, colliders: []Collider, renderables: []Renderable) void {
    const engine = Engine.getEngine(it.world);
    const ents = it.entities();

    for (positions, colliders, renderables, 0..) |pos, col, rend, i| {
        // 1. Get World AABB
        const aabb = getWorldAABB(pos, col);

        // 2. Convert to Screen Coordinates (Pixels)
        const min_x = f32_to_i32(aabb.min.x);
        const min_y = f32_to_i32(aabb.min.y);
        const max_x = f32_to_i32(aabb.max.x);
        const max_y = f32_to_i32(aabb.max.y);

        // 3. Width/Height
        const w = @as(usize, @intCast(@max(0, max_x - min_x)));
        const h = @as(usize, @intCast(@max(0, max_y - min_y)));

        // 4. Pack Color
        const color = pixel_mod.packColor(rend.color.r, rend.color.g, rend.color.b, rend.color.a);

        // 5. Optional per-entity Effect (defaults to none)
        const effect = ecs.get(it.world, ents[i], Effect) orelse &Effect.none;

        // 6. Draw
        pixel_mod.drawRect(engine, min_x, min_y, w, h, color, effect.*);
    }
}

/// Stamps effect flags into the effect_buffer for invisible "effect zone" entities.
/// These entities have Position + Collider + Effect + EffectZone tag, but no Renderable.
pub fn effect_zone_system(it: *ecs.iter_t, positions: []Position, colliders: []Collider, effects: []Effect) void {
    const engine = Engine.getEngine(it.world);

    for (positions, colliders, effects) |pos, col, fx| {
        const aabb = getWorldAABB(pos, col);
        const min_x = f32_to_i32(aabb.min.x);
        const min_y = f32_to_i32(aabb.min.y);
        const max_x = f32_to_i32(aabb.max.x);
        const max_y = f32_to_i32(aabb.max.y);
        const w = @as(usize, @intCast(@max(0, max_x - min_x)));
        const h = @as(usize, @intCast(@max(0, max_y - min_y)));

        pixel_mod.drawEffectOnly(engine, min_x, min_y, w, h, fx, 20);
    }
}

/// KINEMATIC PLAYER CONTROLLER
/// Handles Movement, Gravity, and Collision sequentially to ensure tight controls without glitches.
pub fn player_controller_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, colliders: []Collider, recoils: []components.RecoilImpulse) void {
    const world = it.world;
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const dt = it.delta_time;

    for (positions, velocities, colliders, recoils) |*pos, *vel, col, *recoil| {
        // // 1. Horizontal Input
        // var dx: f32 = 0;
        // if (input.pressed_directions.left) dx -= 1;
        // if (input.pressed_directions.right) dx += 1;
        // // Decay Recoil
        // const decay: f32 = 5.0;
        // recoil.x = recoil.x * std.math.exp(-decay * dt);

        // // Combine: Instant Input + Decaying Recoil
        // vel.x = (dx * PLAYER_SPEED) + recoil.x;

        // // 2. Vertical Input (Gravity + Jump)
        // vel.y += GRAVITY * dt;
        // if (input.pressed_directions.up) {
        //     // Jump only if on ground (simple check: if we are colliding with ground below)
        //     //
        //     // This is a simple way to check if we're on the ground: we move the player down slightly and see if it collides. If it does, we can jump.
        //     // Note: This is a common technique in platformers to allow jumping only when the player is "grounded".
        //     // We only check for collision below the player to allow jumping even if we're touching a wall on the side.
        //     // We can adjust the offset (e.g., 1 pixel) to be more or less strict about what counts as "grounded".
        //     const test_pos = Position{ .x = pos.x, .y = pos.y + 1 };
        //     const test_aabb = getWorldAABB(test_pos, col);
        //     if (checkCollision(world, test_aabb)) {
        //         vel.y = -PLAYER_SPEED * 1.5;
        //     }
        // } else if (input.pressed_directions.down) {
        //     vel.y = PLAYER_SPEED;
        // }

        // Ground Check
        const test_pos = Position{ .x = pos.x, .y = pos.y + 1 };
        const test_aabb = getWorldAABB(test_pos, col);
        // const is_grounded = checkCollision(world, test_aabb);
        const is_grounded =
            checkCollision(world, test_aabb) or
            playerTouchesLandable(world, test_pos, col);

        // 1. Horizontal Input
        var dx: f32 = 0;
        if (input.pressed_directions.left) dx -= 1;
        if (input.pressed_directions.right) dx += 1;

        if (is_grounded) {
            // Ground Logic: Snappy Control + Temporary Recoil
            const decay: f32 = 5.0;
            recoil.x = recoil.x * std.math.exp(-decay * dt);
            vel.x = (dx * PLAYER_SPEED) + recoil.x;
        } else {
            // Air Logic: Momentum Based
            // 1. Absorb pending recoil into momentum
            vel.x += recoil.x;
            recoil.x = 0;

            // 2. Weak Air Control (Drift towards target)
            const target_vx = dx * PLAYER_SPEED;
            const air_control: f32 = 2.0; // Low value = slippery/heavy air feel
            vel.x = target_vx + (vel.x - target_vx) * std.math.exp(-air_control * dt);
        }

        // 2. Vertical Input (Gravity + Jump)
        vel.y += GRAVITY * dt;
        if (input.pressed_directions.up and is_grounded) {
            vel.y = -PLAYER_SPEED * 1.5;
        } else if (input.pressed_directions.down) {
            vel.y = PLAYER_SPEED;
        }

        // 3. MOVE X
        pos.x += vel.x * dt;
        var player_aabb = getWorldAABB(pos.*, col);
        if (checkCollision(world, player_aabb)) {
            // HIT WALL -> Undo Move X
            pos.x -= vel.x * dt;
            vel.x = 0;
        }

        // 4. MOVE Y
        pos.y += vel.y * dt;
        player_aabb = getWorldAABB(pos.*, col); // Re-calc AABB with new Y
        if (checkCollision(world, player_aabb)) {
            // HIT FLOOR/CEILING -> Undo Move Y
            pos.y -= vel.y * dt;
            vel.y = 0;
        }

        resolvePlayerLandableContacts(world, pos, vel, col);
    }
}

pub fn shoot_system(it: *ecs.iter_t, guns: []components.Gun, positions: []Position) void {
    const world = it.world;
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const bullets_group = ecs.singleton_get(world, components.BulletsGroup);

    // If mouse not pressed, do nothing
    if (!input.is_pressing) return;

    for (positions, guns) |pos, *gun| {
        // Create Bullet Entity

        if (gun.cooldown > 0) {
            // Still cooling down, skip shooting
            gun.cooldown -= it.delta_time;
            continue;
        } else {
            // Reset cooldown
            gun.cooldown = gun.fire_rate;
        }

        const bullet = ecs.new_id(world);
        ecs.add(world, bullet, Bullet); // TAG
        _ = ecs.set(world, bullet, PhysicsBody, .{
            .friction = 0.99,
        }); // NEW: Bullet is physics controlled

        // Add to Group
        if (bullets_group) |group| {
            ecs.add_pair(world, bullet, ecs.ChildOf, group.entity);
        }

        // Physics Components (10x10 Box centered)
        // Local AABB: -5 to 5
        // _ = ecs.set(world, bullet, Collider, .{
        //     .box = .{ .min = .{ .x = -5, .y = -5 }, .max = .{ .x = 5, .y = 5 } },
        // });

        _ = ecs.set(world, bullet, Collider, .{
            .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 5 },
        });

        _ = ecs.set(world, bullet, Position, pos);

        // Rendering Component (Purple)
        _ = ecs.set(world, bullet, Renderable, .{
            .color = SDL.Color{ .r = 255, .g = 0, .b = 255, .a = 255 },
        });

        // _ = ecs.set(world, bullet, Effect, Effect.none); // NEW: Bullet has special render effect

        // Calculate Velocity
        const aim = ecs.singleton_get(world, components.AimTarget) orelse return;
        const dx = aim.x - pos.x;
        const dy = aim.y - pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        if (dist > 0) {
            const dir_x = dx / dist;
            const dir_y = dy / dist;

            // make_explosion(world, pos.x, pos.y, dir_x, dir_y, .{
            //     .speed = 2000.0,
            //     .spread = 0.0,
            //     .color = 0xFF00FFFF,
            //     .bounce = 0.0,
            //     .randomness = 0.5,
            // }); // Muzzle Flash

            _ = ecs.set(world, bullet, Velocity, .{
                .x = dir_x * BULLET_SPEED,
                .y = dir_y * BULLET_SPEED,
            });

            if (ecs.singleton_get(world, components.PlayerContainer)) |pc| {
                if (ecs.get_mut(world, pc.entity, Velocity)) |vel| {
                    // Y affects momentum (fighting gravity)
                    vel.y -= dir_y * gun.recoil;
                }
                if (ecs.get_mut(world, pc.entity, components.RecoilImpulse)) |impulse| {
                    // X affects temporary impulse
                    impulse.x -= dir_x * gun.recoil;
                }
            }
        } else {
            _ = ecs.set(world, bullet, Velocity, .{ .x = 0, .y = 0 });
        }
    }
}

pub fn gun_aim_system(it: *ecs.iter_t, gun_positions: []Position) void {
    const world = it.world;
    const aim = ecs.singleton_get(world, components.AimTarget) orelse return;
    const phys = ecs.singleton_get(world, components.PhysicsState);
    const player_container = ecs.singleton_get(world, components.PlayerContainer) orelse return;
    const player_pos = ecs.get(world, player_container.entity, Position) orelse return;

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
                const g_positions = ecs.field(&q_it, Position, 1).?;
                const g_colliders = ecs.field(&q_it, Collider, 2).?;
                for (0..q_it.count()) |i| {
                    const ground_aabb = getWorldAABB(g_positions[i], g_colliders[i]);
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

fn resolveBody(pos: *Position, vel: *Velocity, n: c2.Vec2, depth: f32, body: *PhysicsBody) void {
    // 1. Un-penetrate (Push out)
    // We add a tiny epsilon (0.01) to prevent floating point re-penetration
    const push = depth + 0.01;
    pos.x -= n.x * push;
    pos.y -= n.y * push;

    // 2. Velocity Reflection (Bounce)
    // n points from Entity -> Wall.
    // If v_dot_n > 0, we are moving INTO the wall.
    const v_dot_n = (vel.x * n.x) + (vel.y * n.y);
    if (v_dot_n > 0) {
        // Restitution: 0.8 = Bouncy, 0.1 = Dead weight
        const restitution: f32 = body.restitution; // We can have different restitution per body for variety

        // Friction: 0.9 = Rough, 1.0 = No Friction
        const friction: f32 = body.friction; // We can also have different friction per body

        // vn = component of velocity perpendicular to wall (Impact velocity)
        const vn_x = n.x * v_dot_n;
        const vn_y = n.y * v_dot_n;

        // vt = component of velocity parallel to wall (Slide velocity)
        const vt_x = vel.x - vn_x;
        const vt_y = vel.y - vn_y;

        // Apply bounce to normal, friction to tangent
        // We flip the normal component (-restitution) to bounce OFF the wall
        vel.x = (vt_x * friction) - (vn_x * restitution);
        vel.y = (vt_y * friction) - (vn_y * restitution);
    }
}

fn resolveVerletBody(pos: *Position, n: c2.Vec2, depth: f32, body: *PhysicsBody, vs: *components.VerletState) void {
    // 1. Un-penetrate (Push out)
    // Avoid aggressive pushing which can cause snapping to corners
    const push_x = n.x * (depth + 0.01);
    const push_y = n.y * (depth + 0.01);

    pos.x -= push_x;
    pos.y -= push_y;

    // 2. Adjust old_pos to handle friction and restitution
    var vx = pos.x - vs.old_x;
    var vy = pos.y - vs.old_y;

    // Check if we are moving INTO the wall
    const v_dot_n = (vx * n.x) + (vy * n.y);

    if (v_dot_n > 0) {
        // We are moving INTO the wall (or we were pushed into it)
        // Reflect velocity?

        // Normal component
        const vn_x = n.x * v_dot_n;
        const vn_y = n.y * v_dot_n;

        // Tangent component
        const vt_x = vx - vn_x;
        const vt_y = vy - vn_y;

        const friction = body.friction;
        const restitution = body.restitution;

        // New Velocity
        var new_vx = (vt_x * friction) - (vn_x * restitution);
        var new_vy = (vt_y * friction) - (vn_y * restitution);

        // Limit velocity to prevent crazy jitter if squeezed
        const MAX_VERLET_SPEED: f32 = 20.0; // clamp max movement per frame
        new_vx = clamp(f32, new_vx, -MAX_VERLET_SPEED, MAX_VERLET_SPEED);
        new_vy = clamp(f32, new_vy, -MAX_VERLET_SPEED, MAX_VERLET_SPEED);

        vs.old_x = pos.x - new_vx;
        vs.old_y = pos.y - new_vy;
    } else {
        // We are moving AWAY from the wall, but we were overlapping.
        // This usually happens when hanging off an edge or dragged by a constraint.
        // We just accepted the push-out (step 1), which naturally kills the normal velocity
        // effectively making it 0 relative to the wall surface for this frame.
        //
        // However, we must ensure old_pos is updated so we don't 'gain' velocity from the push
        // The push changed pos.x/y. If we leave old_x/y alone, (pos-old) changes, creating fake velocity.
        // We want to PRESERVE the relative velocity we had, minus the normal component (cancellation).

        // Current implicit velocity relative to old_pos
        // (This includes the push-out we just did!)
        // NO wait. vs.old_x is from previous frame. pos.x is NEW pushed position.
        // So (pos.x - vs.old_x) IS the new velocity.

        // If we do NOTHING, the particle accelerates in the direction of the push.
        // This is physically correct for a hard collision, BUT in Verlet it adds energy.
        // We should dampen the component of the velocity that was added by the push.

        // The push added (-push_x, -push_y) to position.
        // So velocity effectively changed by that amount.
        // We want to neutralize that velocity addition usually?
        // Actually, for a solid wall, canceling velocity into the wall is correct.

        // Let's just apply simple friction to the tangential part and kill the normal part.
        // This stops "sliding" from turning into "launching".

        // Re-calculate local vel based on the NEW compacted position
        vx = pos.x - vs.old_x;
        vy = pos.y - vs.old_y;

        const vn_x = n.x * ((vx * n.x) + (vy * n.y));
        const vn_y = n.y * ((vx * n.x) + (vy * n.y));

        var vt_x = vx - vn_x;
        var vt_y = vy - vn_y;

        // Apply friction to sliding
        vt_x *= body.friction;
        vt_y *= body.friction;

        // Reconstruct old_pos to represent purely tangential velocity (0 normal velocity)
        vs.old_x = pos.x - vt_x;
        vs.old_y = pos.y - vt_y;
    }
}

pub fn physics_collision_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, colliders: []Collider, physicsBodies: []PhysicsBody) void {
    const world = it.world;
    const phys = ecs.singleton_get(world, components.PhysicsState) orelse return;

    var doomed_ground: [64]ecs.entity_t = undefined;
    var doomed_ground_count: usize = 0;
    var doomed_bullets: [64]ecs.entity_t = undefined;
    var doomed_bullet_count: usize = 0;

    var q_it = ecs.query_iter(world, phys.ground_query);
    while (ecs.query_next(&q_it)) {
        const g_positions = ecs.field(&q_it, Position, 1).?;
        const g_colliders = ecs.field(&q_it, Collider, 2).?;

        for (0..q_it.count()) |i| {
            // We assume Ground is always AABB for now (as per setup)
            const gp = g_positions[i];
            const ground_shape = g_colliders[i].box;

            // Construct World AABB for ground
            const ground_aabb = c2.AABB{
                .min = .{ .x = ground_shape.min.x + gp.x, .y = ground_shape.min.y + gp.y },
                .max = .{ .x = ground_shape.max.x + gp.x, .y = ground_shape.max.y + gp.y },
            };

            for (positions, velocities, colliders, physicsBodies, 0..) |*pos, *vel, col, *pb, entity_idx| {
                var m: c2.Manifold = undefined;
                m.count = 0;

                // Dispatch based on Entity Shape
                switch (col) {
                    .circle => |c| {
                        // Circle vs AABB (Best for Bouncing Bullets)
                        const world_circle = c2.Circle{ .p = .{ .x = pos.x + c.p.x, .y = pos.y + c.p.y }, .r = c.r };
                        c2.circleToAABBManifold(world_circle, ground_aabb, &m);
                    },
                    .box => |b| {
                        // AABB vs AABB (Fallback for boxes)
                        const world_aabb = c2.AABB{
                            .min = .{ .x = b.min.x + pos.x, .y = b.min.y + pos.y },
                            .max = .{ .x = b.max.x + pos.x, .y = b.max.y + pos.y },
                        };
                        c2.aabbToAABBManifold(world_aabb, ground_aabb, &m);
                    },
                }

                if (m.count > 0) {
                    const entity = it.entities()[entity_idx];
                    const is_bullet = ecs.has_id(world, entity, ecs.id(Bullet));

                    if (is_bullet) {
                        // Destroy ground tile
                        const ground_entity = q_it.entities()[i];

                        // check if ground_entity has Destroyable tag
                        // if it doesn't, skip destruction (e.g., indestructible walls)
                        // This allows us to have a mix of destructible and indestructible terrain
                        // In a real game, we might want to add a "Health" component to ground pieces for multiple hits, but for now it's just Destroyable or not.
                        // Note: We check for the Destroyable tag on the ground entity before queuing it for deletion. This way, we can have some ground pieces that are indestructible (e.g., bedrock) and won't be affected by bullets.
                        // If the ground piece is not Destroyable, we simply skip the deletion logic and let the bullet bounce off as normal.
                        // This also means that indestructible ground will still cause bullets to bounce, while destructible ground will be removed and allow bullets to pass through on subsequent shots.
                        // This adds an extra layer of strategy, as players can choose to shoot through destructible terrain to create new paths or take cover behind indestructible walls.
                        // In the future, we could expand this system to allow for different types of destructible terrain (e.g., wood that takes 2 hits, stone that takes 5 hits) by adding a "Health" component to ground entities and reducing it on each hit until it reaches zero, at which point we delete the entity.
                        if (!ecs.has_id(world, ground_entity, ecs.id(components.Destroyable))) {
                            // Not destroyable, just bounce bullet as normal
                            resolveBody(pos, vel, m.n, m.depths[0], pb);
                            continue;
                        }

                        // Queue Ground Deletion (Unique)
                        var already_doomed = false;
                        for (0..doomed_ground_count) |k| {
                            if (doomed_ground[k] == ground_entity) {
                                already_doomed = true;
                                break;
                            }
                        }

                        if (!already_doomed and doomed_ground_count < doomed_ground.len) {
                            // Restore visual immediately (safe because we just write to pixels)
                            const engine = Engine.getEngine(world);
                            const gw = ground_shape.max.x - ground_shape.min.x;
                            const gh = ground_shape.max.y - ground_shape.min.y;
                            const gx = f32_to_i32(ground_aabb.min.x);
                            const gy = f32_to_i32(ground_aabb.min.y);
                            pixel_mod.restoreRect(engine, gx, gy, @as(usize, @intFromFloat(gw)), @as(usize, @intFromFloat(gh)));

                            doomed_ground[doomed_ground_count] = ground_entity;
                            doomed_ground_count += 1;
                        }

                        // Queue Bullet Deletion
                        if (doomed_bullet_count < doomed_bullets.len) {
                            doomed_bullets[doomed_bullet_count] = entity;
                            doomed_bullet_count += 1;
                        }

                        // slow bullet on hit (optional, can be removed for instant destruction)
                        vel.x *= 0.5;
                    } else {
                        resolveBody(pos, vel, m.n, m.depths[0], pb);
                    }
                }
            }
        }
    }

    for (0..doomed_ground_count) |i| {
        ecs.delete(world, doomed_ground[i]);
    }
    for (0..doomed_bullet_count) |i| {
        ecs.delete(world, doomed_bullets[i]);
    }
}

pub fn verlet_collision_system(it: *ecs.iter_t, positions: []Position, verlets: []components.VerletState, colliders: []Collider, physicsBodies: []PhysicsBody) void {
    const world = it.world;
    const phys = ecs.singleton_get(world, components.PhysicsState) orelse return;

    var q_it = ecs.query_iter(world, phys.ground_query);
    while (ecs.query_next(&q_it)) {
        const g_positions = ecs.field(&q_it, Position, 1).?;
        const g_colliders = ecs.field(&q_it, Collider, 2).?;

        for (0..q_it.count()) |i| {
            const gp = g_positions[i];
            const ground_shape = g_colliders[i].box;

            const ground_aabb = c2.AABB{
                .min = .{ .x = ground_shape.min.x + gp.x, .y = ground_shape.min.y + gp.y },
                .max = .{ .x = ground_shape.max.x + gp.x, .y = ground_shape.max.y + gp.y },
            };

            for (positions, verlets, colliders, physicsBodies) |*pos, *vs, col, *pb| {
                var m: c2.Manifold = undefined;
                m.count = 0;

                switch (col) {
                    .circle => |c| {
                        const world_circle = c2.Circle{ .p = .{ .x = pos.x + c.p.x, .y = pos.y + c.p.y }, .r = c.r };
                        c2.circleToAABBManifold(world_circle, ground_aabb, &m);
                    },
                    .box => |b| {
                        const world_aabb = c2.AABB{
                            .min = .{ .x = b.min.x + pos.x, .y = b.min.y + pos.y },
                            .max = .{ .x = b.max.x + pos.x, .y = b.max.y + pos.y },
                        };
                        c2.aabbToAABBManifold(world_aabb, ground_aabb, &m);
                    },
                }

                if (m.count > 0) {
                    // Only push out if we are moving INTO the wall?
                    // For verlet, we just resolve penetration.
                    resolveVerletBody(pos, m.n, m.depths[0], pb, vs);
                }
            }
        }
    }

    if (ecs.singleton_get(world, components.PlayerContainer)) |pc| {
        if (ecs.get(world, pc.entity, Position)) |p_pos| {
            if (ecs.get(world, pc.entity, Collider)) |p_col| {
                const player_aabb = getWorldAABB(p_pos.*, p_col.*);

                const verlet_entities = it.entities();

                for (positions, verlets, colliders, physicsBodies, 0..) |*pos, *vs, col, *pb, entity_index| {
                    const entity = verlet_entities[entity_index];

                    if (ecs.has_id(world, entity, ecs.id(components.PlayerLandable))) {
                        continue;
                    }

                    var m: c2.Manifold = undefined;
                    m.count = 0;

                    // Same check we did against ground!
                    switch (col) {
                        .circle => |c| {
                            const world_circle = c2.Circle{ .p = .{ .x = pos.x + c.p.x, .y = pos.y + c.p.y }, .r = c.r };
                            c2.circleToAABBManifold(world_circle, player_aabb, &m);
                        },
                        .box => |b| {
                            const world_aabb = c2.AABB{
                                .min = .{ .x = b.min.x + pos.x, .y = b.min.y + pos.y },
                                .max = .{ .x = b.max.x + pos.x, .y = b.max.y + pos.y },
                            };
                            c2.aabbToAABBManifold(world_aabb, player_aabb, &m);
                        },
                    }

                    if (m.count > 0) {
                        // The particle touches the player! Push it away.
                        resolveVerletBody(pos, m.n, m.depths[0], pb, vs);
                    }
                }
            }
        }
    }
}

pub fn verlet_self_collision_system(it: *ecs.iter_t, positions: []Position, verlets: []components.VerletState, colliders: []Collider) void {
    const world = it.world;
    const phys = ecs.singleton_get(world, components.PhysicsState) orelse return;
    const ents = it.entities();

    // Query all verlets in the world to compare against this current iteration chunk
    var q_it = ecs.query_iter(world, phys.verlet_query);

    _ = verlets;

    while (ecs.query_next(&q_it)) {
        const other_positions = ecs.field(&q_it, Position, 0).?;
        const other_colliders = ecs.field(&q_it, Collider, 2).?;
        const other_ents = q_it.entities();

        for (positions, colliders, 0..) |*p1, c1, i| {
            const e1 = ents[i];

            // Get the parent entity this node is attached to (to prevent inner-jelly collisions)
            const parent1 = ecs.get_target(world, e1, ecs.id(components.AttachedTo), 0);

            for (other_positions, other_colliders, 0..) |*p2, c_2, j| {
                const e2 = other_ents[j];

                // 1. Skip self, and skip checking pairs twice (e1 vs e2, then e2 vs e1)
                if (e1 >= e2) continue;

                // 2. IMPORTANT: Do not collide parts of the SAME jelly together!
                const parent2 = ecs.get_target(world, e2, ecs.id(components.AttachedTo), 0);
                if (parent1 != 0 and parent1 == parent2) continue;

                // 3. Resolve Circle vs Circle collision
                if (c1 == .circle and c_2 == .circle) {
                    const r1 = c1.circle.r;
                    const r2 = c_2.circle.r;

                    const dx = (p2.x + c_2.circle.p.x) - (p1.x + c1.circle.p.x);
                    const dy = (p2.y + c_2.circle.p.y) - (p1.y + c1.circle.p.y);
                    const dist_sq = (dx * dx) + (dy * dy);
                    const min_dist = r1 + r2;

                    // If they are overlapping
                    if (dist_sq < min_dist * min_dist and dist_sq > 0.0001) {
                        const dist = @sqrt(dist_sq);
                        const overlap = min_dist - dist;

                        // Normal pointing from p1 to p2
                        const nx = dx / dist;
                        const ny = dy / dist;

                        // Push them apart symmetrically using our tunable Repulsion constant
                        const push_x = nx * overlap * 0.5 * JELLY_REPULSION;
                        const push_y = ny * overlap * 0.5 * JELLY_REPULSION;

                        // Moving 'pos' without moving 'old' naturally boosts velocity next frame!
                        p1.x -= push_x;
                        p1.y -= push_y;
                        p2.x += push_x;
                        p2.y += push_y;
                    }
                }
            }
        }
    }
}

pub fn verlet_bullet_collision_system(it: *ecs.iter_t, bullet_positions: []Position, bullet_velocities: []Velocity, bullet_colliders: []Collider) void {
    const world = it.world;
    const phys = ecs.singleton_get(world, components.PhysicsState) orelse return;

    // We use phys.verlet_query to get all the jelly chunks
    var q_it = ecs.query_iter(world, phys.verlet_query);

    while (ecs.query_next(&q_it)) {
        const v_positions = ecs.field(&q_it, Position, 0).?;
        const v_states = ecs.field(&q_it, components.VerletState, 1).?;
        const v_colliders = ecs.field(&q_it, Collider, 2).?;
        // const pb = ecs.field(&q_it, PhysicsBody, 4).?;  // Not strictly needed since bullets don't care about the verlet's physical properties besides position/radius

        for (v_positions, v_states, v_colliders, 0..) |*v_pos, *vs, v_col, v_idx| {
            _ = v_idx;

            for (bullet_positions, bullet_velocities, bullet_colliders, 0..) |*b_pos, *b_vel, b_col, b_idx| {
                _ = b_idx;
                var m: c2.Manifold = undefined;
                m.count = 0;

                // Bullet is A, Verlet is B
                // A = Circle, B = Circle  (in most cases)
                switch (v_col) {
                    .circle => |v_c| {
                        switch (b_col) {
                            .circle => |b_c| {
                                const circle_a = c2.Circle{ .p = .{ .x = b_pos.x + b_c.p.x, .y = b_pos.y + b_c.p.y }, .r = b_c.r };
                                const circle_b = c2.Circle{ .p = .{ .x = v_pos.x + v_c.p.x, .y = v_pos.y + v_c.p.y }, .r = v_c.r };
                                c2.circleToCircleManifold(circle_a, circle_b, &m);
                            },
                            .box => |b_b| {
                                const world_b_aabb = c2.AABB{
                                    .min = .{ .x = b_b.min.x + b_pos.x, .y = b_b.min.y + b_pos.y },
                                    .max = .{ .x = b_b.max.x + b_pos.x, .y = b_b.max.y + b_pos.y },
                                };
                                const world_v_circle = c2.Circle{ .p = .{ .x = v_pos.x + v_c.p.x, .y = v_pos.y + v_c.p.y }, .r = v_c.r };
                                c2.circleToAABBManifold(world_v_circle, world_b_aabb, &m); // Might need inverse
                            },
                        }
                    },
                    .box => |v_b| {
                        _ = v_b;
                        // Handle box verlets if you make them
                    },
                }

                if (m.count > 0) {
                    // Interaction:
                    // 1. Deflect bullet
                    // 2. Transfer momentum to Verlet old_pos to make it flinch

                    const overlap = m.depths[0];
                    const n = m.n; // Normal pointing from Bullet -> Verlet

                    // Resolve bullet penetration
                    b_pos.x -= n.x * (overlap + 0.01);
                    b_pos.y -= n.y * (overlap + 0.01);

                    // Bounce the bullet
                    const v_dot_n = (b_vel.x * n.x) + (b_vel.y * n.y);
                    if (v_dot_n > 0) {
                        // Invert the normal velocity to bounce
                        const restitution = 1.2; // Extra bouncy jellies!
                        b_vel.x -= n.x * v_dot_n * (1.0 + restitution);
                        b_vel.y -= n.y * v_dot_n * (1.0 + restitution);

                        // Give the jelly a solid smack!
                        // In verlet, moving old_pos backwards equates to adding forward velocity next frame
                        const impact_force = 1.5;
                        vs.old_x -= n.x * v_dot_n * impact_force * it.delta_time;
                        vs.old_y -= n.y * v_dot_n * impact_force * it.delta_time;
                    }
                }
            }
        }
    }
}

const ExplosionOptions = struct {
    speed: f32 = 150.0,
    spread: f32 = 1.5,
    color: u32 = 0xFF00FF00,
    bounce: f32 = 0.3,
    randomness: f32 = 1.0, // Additional random velocity factor (0.0 = no randomness, 1.0 = full random direction)
};

fn make_explosion(world: *ecs.world_t, x: f32, y: f32, dir_x: f32, dir_y: f32, options: ExplosionOptions) void {
    const rnd = std.crypto.random;
    for (0..10) |_| {
        const e = ecs.new_id(world);

        // Random spread
        const spread_angle = ((rnd.float(f32)) - 0.5) * options.spread;
        const cos_a = std.math.cos(spread_angle);
        const sin_a = std.math.sin(spread_angle);

        const p_vx = dir_x * cos_a - dir_y * sin_a;
        const p_vy = dir_x * sin_a + dir_y * cos_a;

        const speed = 100.0 + (rnd.float(f32) * options.randomness) * options.speed;

        _ = ecs.set(world, e, Position, .{ .x = x, .y = y });
        //
        // HERE
        // making explosion Ground
        // has weird smoke effect
        // fucks up the system though
        // see manual query and note in checkCollision about ignoring ExplosionParticle in ground_query
        //
        // ecs.add(world, e, Ground);
        _ = ecs.set(world, e, Velocity, .{ .x = p_vx * speed, .y = p_vy * speed });
        _ = ecs.set(world, e, Collider, .{
            .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 1 },
        });
        // _ = ecs.set(world, e, Collider, .{
        //     .box = .{ .min = .{ .x = -2, .y = -2 }, .max = .{ .x = 2, .y = 2 } },
        // });
        _ = ecs.set(world, e, components.ExplosionParticle, .{
            .lifetime = 0.3 + rnd.float(f32) * 0.4,
            .color = options.color,
        });
        _ = ecs.set(world, e, PhysicsBody, .{
            .restitution = options.bounce,
            .friction = 0.8,
        });
    }
}

pub fn physics_movement_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity) void {
    const dt = it.delta_time;
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;
    }
}

pub fn explosion_system(it: *ecs.iter_t, positions: []Position, particles: []components.ExplosionParticle) void {
    const dt = it.delta_time;
    const engine = Engine.getEngine(it.world);

    const sprite_size = 5;

    for (positions, particles, 0..) |*pos, *p, i| {
        p.lifetime -= dt;

        if (p.lifetime <= 0) {
            ecs.delete(it.world, it.entities()[i]);
            continue;
        }

        const alpha = @as(u8, @intFromFloat((p.lifetime / 0.7) * 255)); // Fade out over time (assuming max lifetime is around 0.7s)
        const color = setAlpha(p.color, alpha);
        // Render specially to pixel buffer
        // 1x1 pixel
        pixel_mod.drawRect(engine, f32_to_i32(pos.x), f32_to_i32(pos.y), sprite_size, sprite_size, color, Effect.none);
        // pixel_mod.drawRect(engine, f32_to_i32(pos.x), f32_to_i32(pos.y), sprite_size, sprite_size, color, Effect.chromatic_only);
    }
}

fn setAlpha(color: u32, alpha: u8) u32 {
    return (color & 0x00FFFFFF) | (@as(u32, alpha) << 24);
}

pub fn right_controller_stick_set_mouse_xy_system(it: *ecs.iter_t) void {
    const world = it.world;
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const engine = Engine.getEngine(world);

    if (input.active_input_method != .controller) return;
    if (input.right_stick_x == 0.0 and input.right_stick_y == 0.0) return;

    if (ecs.singleton_get(world, components.PlayerContainer)) |pc| {
        if (ecs.get(world, pc.entity, Position)) |pos| {
            const dx = input.right_stick_x;
            const dy = input.right_stick_y;
            const tx = if (dx > 0) (@as(f32, @floatFromInt(engine.width)) - pos.x) / dx else if (dx < 0) -pos.x / dx else std.math.floatMax(f32);
            const ty = if (dy > 0) (@as(f32, @floatFromInt(engine.height)) - pos.y) / dy else if (dy < 0) -pos.y / dy else std.math.floatMax(f32);
            const t = @min(tx, ty);
            _ = ecs.singleton_set(world, components.AimTarget, .{
                .x = pos.x + dx * t,
                .y = pos.y + dy * t,
            });
        }
    }
}

// IK
//
//

pub fn verlet_integration_system(it: *ecs.iter_t, positions: []Position, verlets: []components.VerletState) void {
    const dt = it.delta_time;

    for (positions, verlets) |*pos, *vs| {
        // 1. Calculate velocity from the distance moved since last frame
        const vx = (pos.x - vs.old_x) * vs.friction;
        const vy = (pos.y - vs.old_y) * vs.friction;

        // 2. Update 'old' position to current
        vs.old_x = pos.x;
        vs.old_y = pos.y;

        // 3. Apply the movement + Gravity
        pos.x += vx;
        pos.y += vy + (GRAVITY * 2 * dt * dt);
    }
}

// pub fn constraint_solver_system(it: *ecs.iter_t, positions: []Position, constraints: []components.DistanceConstraint) void {
//     const world = it.world;

//     for (0..8) |_| { // More iterations = stiffer, more responsive chain
//         for (0..it.count()) |i| {
//             const child_pos = &positions[i];
//             const c = constraints[i];
//             const parent_pos = ecs.get_mut(world, c.target, Position) orelse continue;

//             const dx = child_pos.x - parent_pos.x;
//             const dy = child_pos.y - parent_pos.y;
//             const dist = @sqrt(dx * dx + dy * dy);

//             if (dist > c.target_dist) {
//                 const diff = (dist - c.target_dist) / dist;
//                 const tx = dx * diff * 0.5; // Split the correction
//                 const ty = dy * diff * 0.5;

//                 // Move child toward parent
//                 child_pos.x -= tx;
//                 child_pos.y -= ty;

//                 // PULL parent toward child (Only if parent isn't the Player!)
//                 if (!ecs.has_id(world, c.target, ecs.id(components.Player))) {
//                     parent_pos.x += tx;
//                     parent_pos.y += ty;
//                 }
//             }
//         }
//     }
// }

pub fn drawCirclePixels(engine: *Engine, cx: f32, cy: f32, radius: f32, color: u32) void {
    const segments: usize = 32;
    const step = (std.math.pi * 2.0) / @as(f32, @floatFromInt(segments));

    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const theta1 = @as(f32, @floatFromInt(i)) * step;
        const theta2 = @as(f32, @floatFromInt(i + 1)) * step;

        const x1 = cx + @cos(theta1) * radius;
        const y1 = cy + @sin(theta1) * radius;
        const x2 = cx + @cos(theta2) * radius;
        const y2 = cy + @sin(theta2) * radius;

        drawLinePixels(engine, x1, y1, x2, y2, color);
    }
}

fn drawLinePixels(engine: *Engine, x0: f32, y0: f32, x1: f32, y1: f32, color: u32) void {
    // Simple Bresenham-style line
    const dx = @abs(x1 - x0);
    const dy = @abs(y1 - y0);
    const steps: usize = @intFromFloat(@max(dx, dy) + 1);

    var s: usize = 0;
    while (s <= steps) : (s += 1) {
        const t: f32 = if (steps == 0) 0.0 else @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
        const px = x0 + (x1 - x0) * t;
        const py = y0 + (y1 - y0) * t;

        const ix = @as(i32, @intFromFloat(px));
        const iy = @as(i32, @intFromFloat(py));
        if (ix >= 0 and iy >= 0 and ix < @as(i32, @intCast(engine.width)) and iy < @as(i32, @intCast(engine.height))) {
            const idx = @as(usize, @intCast(iy)) * engine.width + @as(usize, @intCast(ix));
            engine.pixel_buffer[idx] = color;
        }
    }
}

fn draw_colliders(positions: []Position, colliders: []Collider, engine: *Engine, up_size: f32, color: u32) void {
    var i: usize = 0;
    while (i < positions.len) : (i += 1) {
        const p = positions[i];
        const col = colliders[i];

        switch (col) {
            .circle => |c| {
                const world_x = p.x + c.p.x;
                const world_y = p.y + c.p.y;
                drawCirclePixels(engine, world_x, world_y, c.r + up_size, color);
            },
            .box => |b| {
                const min_x = p.x + b.min.x;
                const min_y = p.y + b.min.y;
                const max_x = p.x + b.max.x + up_size;
                const max_y = p.y + b.max.y + up_size;
                // Draw 4 edges
                drawLinePixels(engine, min_x, min_y, max_x, min_y, color);
                drawLinePixels(engine, max_x, min_y, max_x, max_y, color);
                drawLinePixels(engine, max_x, max_y, min_x, max_y, color);
                drawLinePixels(engine, min_x, max_y, min_x, min_y, color);
            },
        }
    }
}

// pub fn debug_draw_colliders_with_sdl2_render(it: *ecs.iter_t, positions: []Position, colliders: []Collider) void {
pub fn debug_draw_colliders_with_sdl2_render(world: *ecs.world_t) void {
    const engine = Engine.getEngine(world);

    const debug_red = pixel_mod.packColor(255, 0, 0, 255);
    // const debug_magenta = pixel_mod.packColor(255, 0, 255, 255);
    // const debug_cyan = pixel_mod.packColor(0, 255, 255, 255);

    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = ecs.id(Position), .inout = .In };
    desc.terms[1] = .{ .id = ecs.id(Collider), .inout = .In };
    const ground_q = ecs.query_init(world, &desc) catch unreachable;
    var q_it = ecs.query_iter(world, ground_q);

    while (ecs.query_next(&q_it)) {
        const positions = ecs.field(&q_it, Position, 0).?;
        const colliders = ecs.field(&q_it, Collider, 1).?;

        draw_colliders(positions, colliders, engine, 0, debug_red);
    }
    ecs.query_fini(ground_q);

    // --- LOOP 2: Draw the Constraints (Dedicated and safe) ---
    // var cons_desc = ecs.query_desc_t{};
    // cons_desc.terms[0] = .{ .id = ecs.id(Position), .inout = .In };
    // cons_desc.terms[1] = .{ .id = ecs.id(components.DistanceConstraint), .inout = .In };
    // cons_desc.terms[2] = .{
    //     .id = ecs.id(components.Collider),
    // };
    // const cons_q = ecs.query_init(world, &cons_desc) catch unreachable;
    // var cons_it = ecs.query_iter(world, cons_q);

    // while (ecs.query_next(&cons_it)) {
    //     const positions = ecs.field(&cons_it, Position, 0).?;
    //     const constraints = ecs.field(&cons_it, components.DistanceConstraint, 1).?;
    //     const colliders = ecs.field(&cons_it, Collider, 2).?;

    //     draw_colliders(positions, colliders, engine, 2, debug_magenta);

    //     for (0..cons_it.count()) |i| {
    //         const p = positions[i];
    //         const cons = constraints[i];

    //         // Look up the target's position directly
    //         if (ecs.get(world, cons.target, Position)) |target_p| {
    //             drawLinePixels(engine, p.x, p.y, target_p.x, target_p.y, debug_cyan);
    //         }
    //     }
    // }
}

pub fn draw_attached_constraints_system(it: *ecs.iter_t) void {
    const world = it.world;

    // Term 1 is the Pair (AttachedTo, Target)
    // Term 2 is the Subject's Position
    const pair_id = it.ids.?[0];
    const target_id = ecs.pair_second(pair_id);
    const positions = ecs.field(it, components.Position, 1).?;

    // We need the engine/renderer context to draw
    // Assuming you stored your engine in the Flecs context
    const engine = Engine.getEngine(world);

    for (positions) |pos| {
        // Get the parent position
        if (ecs.get(world, target_id, components.Position)) |parent_pos| {
            const color = pixel_mod.packColor(100, 100, 255, 255); // Light blue for constraints

            // Draw a line from child to parent
            // Replace with your actual line drawing function
            drawLinePixels(engine, pos.x, pos.y, parent_pos.x, parent_pos.y, color);
            // draw_line(engine, pos.x, pos.y, parent_pos.x, parent_pos.y, color);
        }
    }
}

// pub fn tend_towards_system(it: *ecs.iter_t, positions: []Position, targets: []components.TendencyTowards) void {
//     const world = it.world;
//     for (positions, targets) |*pos, target_cfg| {
//         const t_pos = ecs.get(world, target_cfg.target, Position) orelse continue;

//         const dx = t_pos.x - pos.x;
//         const dy = t_pos.y - pos.y;

//         // Nudge the node toward the target
//         pos.x += dx * target_cfg.strength * it.delta_time;
//         pos.y += dy * target_cfg.strength * it.delta_time;
//     }
// }

pub fn reach_system(it: *ecs.iter_t) void {
    // Data is retrieved using the Relation ID
    const reach_data = ecs.field(it, components.ReachTowards, 0).?;
    const pair_id = it.ids.?[0];
    const target_id = ecs.pair_second(pair_id);
    const positions = ecs.field(it, components.Position, 1).?;

    for (reach_data, positions) |data, *pos| {
        const t_pos = ecs.get(it.world, target_id, components.Position) orelse continue;
        // One-way nudge logic
        // pos.x += (t_pos.x - pos.x) * data.stiffness;
        // pos.y += (t_pos.y - pos.y) * data.stiffness;
        const dx = t_pos.x - pos.x;
        const dy = t_pos.y - pos.y;

        // Nudge the node toward the target
        pos.x += dx * data.stiffness * it.delta_time;
        pos.y += dy * data.stiffness * it.delta_time;
    }
}

pub fn attachment_solver_system(it: *ecs.iter_t) void {
    const world = it.world;

    // 1. Get resolved Pair ID from Term 1 (AttachedTo, Target)
    const pair_id = it.ids.?[0];
    const target_id = ecs.pair_second(pair_id);

    // 2. Get Data Fields (1-based indices)
    const constraints = ecs.field(it, components.AttachedTo, 0).?;
    const positions = ecs.field(it, components.Position, 1).?;

    const solver_iterations = 24;

    // 3. Relaxation Loop
    for (0..solver_iterations) |_| {
        for (0..it.count()) |i| {
            const data = constraints[i];
            const child_pos = &positions[i];

            // Get parent position (get_mut because we modify it)
            const parent_pos = ecs.get_mut(world, target_id, components.Position) orelse continue;

            const dx = child_pos.x - parent_pos.x;
            const dy = child_pos.y - parent_pos.y;
            const dist = @sqrt(dx * dx + dy * dy);

            // Using dist > 0 to avoid division by zero
            if (dist > 0.0001) {
                // RIGID logic: solve for BOTH extension and compression
                const diff = (dist - data.dist) / dist;

                // stiffness 1.0 = rigid bone, < 1.0 = elastic
                const tx = dx * diff * 0.5 * data.stiffness;
                const ty = dy * diff * 0.5 * data.stiffness;

                child_pos.x -= tx;
                child_pos.y -= ty;

                // Pull parent toward child if it's not a static anchor (Player)
                if (!ecs.has_id(world, target_id, ecs.id(components.Player))) {
                    parent_pos.x += tx;
                    parent_pos.y += ty;
                }
            }
        }
    }
}
