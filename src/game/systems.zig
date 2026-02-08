const std = @import("std");
const ecs = @import("zflecs");
const SDL = @import("sdl2");
const components = @import("components.zig");
const Engine = @import("../engine/core.zig").Engine;
const c2 = @import("zig_c2");

const input_mod = @import("../engine/input.zig");
const pixel_mod = @import("../engine/pixels.zig");

const Position = components.Position;
const Velocity = components.Velocity;
const Target = components.Target;
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
    // const phys = ecs.singleton_get(world, components.PhysicsState) orelse return false;
    // var q_it = ecs.query_iter(world, phys.ground_query);
    // _ = ecs.singleton_set(world, PhysicsState, .{ .ground_query = ground_q });

    // we want to ignore ground with components.ExplosionParticle
    // this allows us to have temporary "ghost" ground pieces that exist visually but don't block the player, which is useful for explosion effects where we want the debris to fly through the air without causing additional collisions.
    // By excluding entities with the ExplosionParticle component from collision checks, we can create more dynamic and visually interesting explosions without affecting gameplay mechanics. This also allows us to reuse the same ground entities for both solid terrain and temporary explosion effects, simplifying our entity management.
    // In the future, we could expand this system to allow for different types of temporary ground effects (e.g., slippery ice that doesn't block but affects movement, or sticky goo that slows down entities) by adding additional components and logic to determine how they interact with the player and other entities.
    // Note: We check for the ExplosionParticle component on the ground entities during the collision check. If an entity has this component, we simply skip it and don't consider it for collision, allowing the player to pass through it as if it were not there.
    // This is a common technique in games to create temporary visual effects that don't interfere with gameplay, and it adds an extra layer of polish and immersion to our explosions without complicating our collision logic.
    // In our current setup, explosion particles are created as separate entities with their own components, so they won't have the Ground tag and thus won't be included in the ground_query. However, if we were to create explosion particles that also have the Ground tag for visual purposes, we would need to ensure they also have a component (like ExplosionParticle) that allows us to exclude them from collision checks, as described above.
    // This also means that we can have explosion particles that visually appear as part of the ground but don't actually block movement, which can create more dynamic and visually interesting explosions without affecting the player's ability to move through the environment.
    // Overall, this approach allows us to maintain a clear separation between visual effects and gameplay mechanics, giving us more flexibility in how we design our explosions and their interactions with the player and the environment.
    // In summary, by excluding entities with the ExplosionParticle component from collision checks, we can create temporary visual effects that enhance the game's aesthetics without interfering with gameplay, allowing for more dynamic and immersive explosions while keeping our collision logic straightforward and efficient.
    // In our current implementation, we simply don't add the ExplosionParticle component to ground entities, so they won't be included in the ground_query at all. However, if we wanted to have some ground entities that also serve as explosion particles for visual purposes, we could add the ExplosionParticle component to those entities and then modify our collision check to skip any entities that have that component, ensuring they don't interfere with player movement while still providing the desired visual effect.

    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = ecs.id(Ground) };
    desc.terms[1] = .{ .id = ecs.id(Position), .inout = .In };
    desc.terms[2] = .{ .id = ecs.id(Collider), .inout = .In };
    desc.terms[3] = .{ .id = ecs.id(components.ExplosionParticle), .oper = .Not };
    const ground_q = ecs.query_init(world, &desc) catch unreachable;
    var q_it = ecs.query_iter(world, ground_q);

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

pub fn seek_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, targets: []Target) void {
    _ = it;
    _ = positions;
    _ = velocities;
    _ = targets;
    // for (positions, velocities, targets) |pos, *vel, target| {
    //     const p = c2.Vec2{ .x = pos.x, .y = pos.y };
    //     const t = c2.Vec2{ .x = target.x, .y = target.y };
    //     const diff = t.sub(p);
    //     const dist = diff.len();

    //     // If we are further than 2 pixels away, move towards target
    //     if (dist > 2.0) {
    //         const v = diff.norm().mul(BULLET_SPEED);
    //         vel.x = v.x;
    //         vel.y = v.y;
    //     } else {
    //         vel.x = 0;
    //         vel.y = 0;
    //     }
    // }
}

pub fn render_system(it: *ecs.iter_t, positions: []Position, colliders: []Collider, renderables: []Renderable) void {
    const engine = Engine.getEngine(it.world);

    for (positions, colliders, renderables) |pos, col, rend| {
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

        // 5. Draw
        pixel_mod.drawRect(engine, min_x, min_y, w, h, color);
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
        const is_grounded = checkCollision(world, test_aabb);

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

        // Calculate Velocity
        const mouse_x = @as(f32, @floatFromInt(input.mouse_x));
        const mouse_y = @as(f32, @floatFromInt(input.mouse_y));
        const dx = mouse_x - pos.x;
        const dy = mouse_y - pos.y;
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
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const phys = ecs.singleton_get(world, components.PhysicsState);

    // 1. Get the player entity ID from the singleton
    const player_container = ecs.singleton_get(world, components.PlayerContainer) orelse return;
    const player_entity = player_container.entity;

    // 2. Get the player's position directly
    const player_pos = ecs.get(world, player_entity, Position) orelse return;

    const mouse_x = @as(f32, @floatFromInt(input.mouse_x));
    const mouse_y = @as(f32, @floatFromInt(input.mouse_y));

    const GUN_RADIUS: f32 = 40.0;

    for (gun_positions) |*gpos| {
        const dx: f32 = mouse_x - player_pos.x;
        const dy: f32 = mouse_y - player_pos.y;
        const dist: f32 = @sqrt(dx * dx + dy * dy);

        // Calculate desired distance (clamped to radius)
        var aim_dist = dist;
        if (aim_dist > GUN_RADIUS) aim_dist = GUN_RADIUS;

        // Default to aiming at the target distance
        var final_dist = aim_dist;

        if (dist > 0.001 and phys != null) {
            // Normalized Direction
            const nx = dx / dist;
            const ny = dy / dist;

            // Ray from Player Center towards Mouse
            const ray = c2.Ray{
                .p = c2.Vec2{ .x = player_pos.x, .y = player_pos.y },
                .d = c2.Vec2{ .x = nx, .y = ny },
                .t = aim_dist, // Only check as far as the gun reaches
            };

            // Check against all Ground objects
            var q_it = ecs.query_iter(world, phys.?.ground_query);
            while (ecs.query_next(&q_it)) {
                const g_positions = ecs.field(&q_it, Position, 1).?;
                const g_colliders = ecs.field(&q_it, Collider, 2).?;

                for (0..q_it.count()) |i| {
                    const gp = g_positions[i];
                    // Get the world AABB for this ground piece
                    const ground_aabb = getWorldAABB(gp, g_colliders[i]);

                    var cast_out: c2.Raycast = undefined;
                    // Raycast against the AABB
                    if (c2.rayToAABB(ray, ground_aabb, &cast_out)) {
                        // If we hit something closer, shorten the gun distance
                        if (cast_out.t < final_dist) {
                            final_dist = cast_out.t;
                        }
                    }
                }
            }

            // Set final position based on shortest distance (clamped by wall or radius)
            gpos.x = player_pos.x + nx * final_dist;
            gpos.y = player_pos.y + ny * final_dist;
        } else {
            // No direction (mouse on player), default to player center
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

                            // Spawn explosion particles
                            const center_x = ground_aabb.min.x + gw / 2.0;
                            const center_y = ground_aabb.min.y + gh / 2.0;
                            // const rnd = std.crypto.random;

                            // Direction opposite to bullet velocity
                            const vel_len = std.math.sqrt(vel.x * vel.x + vel.y * vel.y);
                            var dir_x: f32 = 0;
                            var dir_y: f32 = 0;
                            if (vel_len > 0) {
                                dir_x = -vel.x / vel_len;
                                dir_y = -vel.y / vel_len;
                            }

                            make_explosion(world, center_x, center_y, dir_x, dir_y, .{});
                            //     for (0..10) |_| {
                            //         const e = ecs.new_id(world);

                            //         // Random spread
                            //         const spread_angle = (rnd.float(f32) - 0.5) * 1.5;
                            //         const cos_a = std.math.cos(spread_angle);
                            //         const sin_a = std.math.sin(spread_angle);

                            //         const p_vx = dir_x * cos_a - dir_y * sin_a;
                            //         const p_vy = dir_x * sin_a + dir_y * cos_a;

                            //         const speed = 100.0 + rnd.float(f32) * 150.0;

                            //         _ = ecs.set(world, e, Position, .{ .x = center_x, .y = center_y });
                            //         _ = ecs.set(world, e, Velocity, .{ .x = p_vx * speed, .y = p_vy * speed });
                            //         _ = ecs.set(world, e, Collider, .{
                            //             .circle = .{ .p = .{ .x = 0, .y = 0 }, .r = 1 },
                            //         });
                            //         _ = ecs.set(world, e, components.ExplosionParticle, .{
                            //             .lifetime = 0.3 + rnd.float(f32) * 0.4,
                            //             .color = 0x00FF00FF,
                            //         });
                            //         _ = ecs.set(world, e, PhysicsBody, .{
                            //             .restitution = 0.3,
                            //             .friction = 0.8,
                            //         });
                            //     }
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

const ExplosionOptions = struct {
    speed: f32 = 150.0,
    spread: f32 = 1.5,
    color: u32 = 0x00FF00FF,
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

pub fn explosion_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, particles: []components.ExplosionParticle) void {
    const dt = it.delta_time;
    const engine = Engine.getEngine(it.world);

    _ = velocities; // We don't actually need to update velocity here, but we include it in the query for easy access if we want to add movement to particles later (e.g., gravity or fading out)

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
        pixel_mod.drawRect(engine, f32_to_i32(pos.x), f32_to_i32(pos.y), 4, 4, color);
    }
}

fn setAlpha(color: u32, alpha: u8) u32 {
    return (color & 0xFFFFFF00) | (@as(u32, alpha) << 24);
}

pub fn right_controller_stick_set_mouse_xy_system(it: *ecs.iter_t) void {
    // _ = it;
    const world = it.world;
    const input = ecs.singleton_get_mut(world, input_mod.InputState) orelse return;
    const engine = Engine.getEngine(world);

    if (input.right_stick_x != 0.0 or input.right_stick_y != 0.0) {
        if (ecs.singleton_get(world, components.PlayerContainer)) |pc| {
            if (ecs.get(world, pc.entity, Position)) |pos| {
                const dx = input.right_stick_x;
                const dy = input.right_stick_y;
                // Calculate intersection with screen bounds (0,0) -> (WIDTH, HEIGHT)
                // Ray: pos + t * (dx, dy)
                // We want smallest positive t where ray hits bounds.
                const tx = if (dx > 0) (@as(f32, @floatFromInt(engine.width)) - pos.x) / dx else if (dx < 0) -pos.x / dx else std.math.floatMax(f32);

                const ty = if (dy > 0) (@as(f32, @floatFromInt(engine.height)) - pos.y) / dy else if (dy < 0) -pos.y / dy else std.math.floatMax(f32);
                const t = @min(tx, ty);

                input.mouse_x = @intFromFloat(pos.x + dx * t);
                input.mouse_y = @intFromFloat(pos.y + dy * t);
            }
        }
    }
    _ = ecs.singleton_set(world, input_mod.InputState, input.*);
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

pub fn constraint_solver_system(it: *ecs.iter_t, positions: []Position, constraints: []components.DistanceConstraint) void {
    const world = it.world;

    for (0..it.count()) |i| {
        const cons = constraints[i];
        const pos = &positions[i];

        // 1. Get the target (Player or previous segment)
        const target_pos = ecs.get(world, cons.target, Position) orelse continue;

        // 2. Vector from Segment to Target
        const dx = target_pos.x - pos.x;
        const dy = target_pos.y - pos.y;
        const current_dist = @sqrt(dx * dx + dy * dy);

        if (current_dist == 0) continue;

        // 3. How much do we need to move to hit target_dist?
        // If current_dist is 10 and target_dist is 6, we need to move 4 units closer.
        const delta = (current_dist - cons.target_dist) / current_dist;

        // 4. Apply the correction
        // We move the segment TOWARD the target by the delta amount
        pos.x += dx * delta * cons.stiffness;
        pos.y += dy * delta * cons.stiffness;
    }
}

pub fn drawCircleLines(renderer: SDL.Renderer, cx: f32, cy: f32, radius: f32) void {
    const segments: usize = 16;
    const step = (std.math.pi * 2.0) / @as(f32, @floatFromInt(segments));

    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const theta1 = @as(f32, @floatFromInt(i)) * step;
        const theta2 = @as(f32, @floatFromInt(i + 1)) * step;

        const x1 = cx + @cos(theta1) * radius;
        const y1 = cy + @sin(theta1) * radius;
        const x2 = cx + @cos(theta2) * radius;
        const y2 = cy + @sin(theta2) * radius;

        _ = renderer.drawLine(@intFromFloat(x1), @intFromFloat(y1), @intFromFloat(x2), @intFromFloat(y2)) catch {};
    }
}

// pub fn debug_draw_colliders_with_sdl2_render(it: *ecs.iter_t, positions: []Position, colliders: []Collider) void {
pub fn debug_draw_colliders_with_sdl2_render(world: *ecs.world_t) void {
    const engine = Engine.getEngine(world);

    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = ecs.id(Position), .inout = .In };
    desc.terms[1] = .{ .id = ecs.id(Collider), .inout = .In };
    const ground_q = ecs.query_init(world, &desc) catch unreachable;
    var q_it = ecs.query_iter(world, ground_q);

    engine.renderer.setColor(SDL.Color{ .r = 255, .g = 255, .b = 0, .a = 255 }) catch {};

    while (ecs.query_next(&q_it)) {
        const positions = ecs.field(&q_it, Position, 0).?;
        const colliders = ecs.field(&q_it, Collider, 1).?;

        var i: usize = 0;
        while (i < q_it.count()) : (i += 1) {
            const p = positions[i];
            const col = colliders[i];

            switch (col) {
                .circle => |c| {
                    const world_x = p.x + c.p.x;
                    const world_y = p.y + c.p.y;
                    drawCircleLines(engine.renderer, world_x, world_y, c.r);
                },
                .box => |b| {
                    const rect = SDL.Rectangle{
                        .x = @intFromFloat(p.x + b.min.x),
                        .y = @intFromFloat(p.y + b.min.y),
                        .width = @intFromFloat(b.max.x - b.min.x),
                        .height = @intFromFloat(b.max.y - b.min.y),
                    };
                    _ = engine.renderer.drawRect(rect) catch {};
                },
            }
        }
    }

    // --- LOOP 2: Draw the Constraints (Dedicated and safe) ---
    var cons_desc = ecs.query_desc_t{};
    cons_desc.terms[0] = .{ .id = ecs.id(Position), .inout = .In };
    cons_desc.terms[1] = .{ .id = ecs.id(components.DistanceConstraint), .inout = .In };
    const cons_q = ecs.query_init(world, &cons_desc) catch unreachable;
    var cons_it = ecs.query_iter(world, cons_q);

    engine.renderer.setColor(SDL.Color{ .r = 0, .g = 255, .b = 255, .a = 255 }) catch {};
    while (ecs.query_next(&cons_it)) {
        const positions = ecs.field(&cons_it, Position, 0).?;
        const constraints = ecs.field(&cons_it, components.DistanceConstraint, 1).?;

        for (0..cons_it.count()) |i| {
            const p = positions[i];
            const cons = constraints[i];

            // Look up the target's position directly
            if (ecs.get(world, cons.target, Position)) |target_p| {
                _ = engine.renderer.drawLine(@intFromFloat(p.x), @intFromFloat(p.y), @intFromFloat(target_p.x), @intFromFloat(target_p.y)) catch {};
            }
        }
    }
}
