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
fn getWorldAABB(pos: Position, collider: Collider) c2.AABB {
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

// --- Systems ---

pub fn gravity_system(it: *ecs.iter_t, velocities: []Velocity) void {
    const dt = it.delta_time;

    for (velocities) |*vel| {
        vel.y += GRAVITY * dt;
    }
}

fn move_axis(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, comptime axis: Axis) void {
    const dt = it.delta_time;

    for (positions, velocities) |*pos, vel| {
        @field(pos, @tagName(axis)) += @field(vel, @tagName(axis)) * dt;
    }
}

pub fn move_x_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity) void {
    move_axis(it, positions, velocities, .x);
}

pub fn move_y_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity) void {
    move_axis(it, positions, velocities, .y);
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
    for (positions, velocities, targets) |pos, *vel, target| {
        const p = c2.Vec2{ .x = pos.x, .y = pos.y };
        const t = c2.Vec2{ .x = target.x, .y = target.y };
        const diff = t.sub(p);
        const dist = diff.len();

        // If we are further than 2 pixels away, move towards target
        if (dist > 2.0) {
            const v = diff.norm().mul(BULLET_SPEED);
            vel.x = v.x;
            vel.y = v.y;
        } else {
            vel.x = 0;
            vel.y = 0;
        }
    }
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
pub fn player_controller_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, colliders: []Collider) void {
    const world = it.world;
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const dt = it.delta_time;

    for (positions, velocities, colliders) |*pos, *vel, col| {
        // 1. Horizontal Input
        var dx: f32 = 0;
        if (input.pressed_directions.left) dx -= 1;
        if (input.pressed_directions.right) dx += 1;
        vel.x = dx * PLAYER_SPEED;

        // 2. Vertical Input (Gravity + Jump)
        vel.y += GRAVITY * dt;
        if (input.pressed_directions.up) {
            // Jump only if on ground (simple check: if we are colliding with ground below)
            //
            // This is a simple way to check if we're on the ground: we move the player down slightly and see if it collides. If it does, we can jump.
            // Note: This is a common technique in platformers to allow jumping only when the player is "grounded".
            // We only check for collision below the player to allow jumping even if we're touching a wall on the side.
            // We can adjust the offset (e.g., 1 pixel) to be more or less strict about what counts as "grounded".
            const test_pos = Position{ .x = pos.x, .y = pos.y + 1 };
            const test_aabb = getWorldAABB(test_pos, col);
            if (checkCollision(world, test_aabb)) {
                vel.y = -PLAYER_SPEED * 1.5;
            }
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

fn collision_axis(it: *ecs.iter_t, positions: []Position, colliders: []Collider, velocities: []Velocity, comptime axis: Axis) void {
    const world = it.world;

    // var desc = ecs.query_desc_t{};
    // desc.terms[0] = .{ .id = ecs.id(Ground) };
    // desc.terms[1] = .{ .id = ecs.id(Position) };
    // desc.terms[2] = .{ .id = ecs.id(Collider) };
    // const query = ecs.query_init(world, &desc) catch return;
    // defer ecs.query_fini(query);

    const phys = ecs.singleton_get(world, components.PhysicsState) orelse return;

    for (positions, colliders, velocities) |*pos, col, *vel| {
        const entity_aabb = getWorldAABB(pos.*, col);

        var q_it = ecs.query_iter(world, phys.ground_query);

        while (ecs.query_next(&q_it)) {
            const g_positions = ecs.field(&q_it, Position, 1).?;
            const g_colliders = ecs.field(&q_it, Collider, 2).?;

            for (0..q_it.count()) |j| {
                const gp = g_positions[j];
                const gc = g_colliders[j];
                const ground_aabb = getWorldAABB(gp, gc);

                if (c2.aabbToAABB(entity_aabb, ground_aabb)) {
                    // Calculate overlap manually from AABBs
                    const overlap_x = @min(entity_aabb.max.x, ground_aabb.max.x) - @max(entity_aabb.min.x, ground_aabb.min.x);
                    const overlap_y = @min(entity_aabb.max.y, ground_aabb.max.y) - @max(entity_aabb.min.y, ground_aabb.min.y);

                    // Ignore shallow collision on the perpendicular axis
                    const other_overlap = if (axis == .x) overlap_y else overlap_x;
                    if (other_overlap < 0.2) continue;

                    const diff = if (axis == .x) (pos.x - gp.x) else (pos.y - gp.y);
                    const overlap = if (axis == .x) overlap_x else overlap_y;

                    @field(pos, @tagName(axis)) += if (diff > 0) overlap else -overlap;
                    @field(vel, @tagName(axis)) = 0;
                }
            }
        }
    }
}

pub fn ground_collision_x_system(it: *ecs.iter_t, positions: []Position, colliders: []Collider, velocities: []Velocity) void {
    collision_axis(it, positions, colliders, velocities, .x);
}

pub fn ground_collision_y_system(it: *ecs.iter_t, positions: []Position, colliders: []Collider, velocities: []Velocity) void {
    collision_axis(it, positions, colliders, velocities, .y);
}

pub fn shoot_system(it: *ecs.iter_t, positions: []Position) void {
    const world = it.world;
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    const bullets_group = ecs.singleton_get(world, components.BulletsGroup);

    // If mouse not pressed, do nothing
    if (!input.is_pressing) return;

    for (positions) |pos| {
        // Create Bullet Entity
        const bullet = ecs.new_id(world);
        ecs.add(world, bullet, Bullet); // TAG
        ecs.add(world, bullet, PhysicsBody); // NEW: Bullet is physics controlled

        // Add to Group
        if (bullets_group) |group| {
            ecs.add_pair(world, bullet, ecs.ChildOf, group.entity);
        }

        // Physics Components (10x10 Box centered)
        // Local AABB: -5 to 5
        _ = ecs.set(world, bullet, Collider, .{
            .box = .{ .min = .{ .x = -5, .y = -5 }, .max = .{ .x = 5, .y = 5 } },
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
            _ = ecs.set(world, bullet, Velocity, .{
                .x = (dx / dist) * BULLET_SPEED,
                .y = (dy / dist) * BULLET_SPEED,
            });
        } else {
            _ = ecs.set(world, bullet, Velocity, .{ .x = 0, .y = 0 });
        }
    }
}

pub fn gun_aim_system(it: *ecs.iter_t, gun_positions: []Position) void {
    const world = it.world;
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;

    // Find the player's Position (we assume exactly one player)
    // // this setup will be good for MULTIPLE PLAYERS
    // var desc = ecs.query_desc_t{};
    // desc.terms[0] = .{ .id = ecs.id(Player) };
    // desc.terms[1] = .{ .id = ecs.id(Position) };
    // const query = ecs.query_init(world, &desc) catch return;
    // defer ecs.query_fini(query);

    // var player_pos: Position = .{ .x = 0.0, .y = 0.0 };
    // var found_player = false;

    // var q_it = ecs.query_iter(world, query);
    // while (ecs.query_next(&q_it)) {
    //     const p_positions = ecs.field(&q_it, Position, 1).?;
    //     // there should be only one player, read the first
    //     if (q_it.count() > 0) {
    //         player_pos = p_positions[0];
    //         found_player = true;
    //     }
    //     // ecs.iter_fini(&q_it);
    // }
    // if (!found_player) return;

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

        if (dist == 0.0) {
            // Mouse exactly at player center -> gun centered on player
            gpos.x = player_pos.x;
            gpos.y = player_pos.y;
        } else if (dist <= GUN_RADIUS) {
            // Mouse within radius -> gun snaps to mouse world position
            gpos.x = mouse_x;
            gpos.y = mouse_y;
        } else {
            // Outside radius -> clamp to circle around player
            const nx = dx / dist;
            const ny = dy / dist;
            gpos.x = player_pos.x + nx * GUN_RADIUS;
            gpos.y = player_pos.y + ny * GUN_RADIUS;
        }
    }
}
