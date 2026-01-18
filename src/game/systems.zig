const std = @import("std");
const ecs = @import("zflecs");
const SDL = @import("sdl2");
const components = @import("components.zig");
const Engine = @import("../engine/core.zig").Engine;

const input_mod = @import("../engine/input.zig");
const pixel_mod = @import("../engine/pixels.zig");

const Position = components.Position;
const Velocity = components.Velocity;
const Target = components.Target;
const Rectangle = components.Rectangle;
const Box = components.Box;
const Ground = components.Ground;
const Bullet = components.Bullet;
const Player = components.Player;

const Axis = enum { x, y };

pub const PLAYER_SPEED: f32 = 400.0;
pub const BULLET_SPEED: f32 = 1000.0;
pub const GRAVITY: f32 = 2500.0;
pub const JUMP_IMPULSE: f32 = -600.0;

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

pub fn move_x_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity) void {
    move_axis(it, positions, velocities, .x);
}

pub fn move_y_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity) void {
    move_axis(it, positions, velocities, .y);
}

fn clamp(comptime T: type, value: T, min: T, max: T) T {
    return @max(min, @min(value, max));
}

pub fn seek_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, targets: []Target) void {
    _ = it;
    for (positions, velocities, targets) |pos, *vel, target| {
        const dx = target.x - pos.x;
        const dy = target.y - pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        // If we are further than 2 pixels away, move towards target
        if (dist > 2.0) {
            vel.x = (dx / dist) * BULLET_SPEED;
            vel.y = (dy / dist) * BULLET_SPEED;
        } else {
            vel.x = 0;
            vel.y = 0;
        }
    }
}

pub fn render_rect_system(it: *ecs.iter_t, positions: []Position, rectangles: []Rectangle) void {
    const engine = Engine.getEngine(it.world);

    for (positions, rectangles) |pos, rect| {
        engine.renderer.setColorRGBA(rect.color.r, rect.color.g, rect.color.b, rect.color.a) catch continue;
        engine.renderer.fillRect(.{
            .x = f32_to_i32(pos.x) - @divTrunc(f32_to_i32(rect.w), 2),
            .y = f32_to_i32(pos.y) - @divTrunc(f32_to_i32(rect.h), 2),
            .width = f32_to_i32(rect.w),
            .height = f32_to_i32(rect.h),
        }) catch continue;
    }
}

// pub fn render_pixel_box(it: *ecs.iter_t, positions: []Position, boxes: []Box) void {
pub fn render_pixel_box(it: *ecs.iter_t, positions: []Position, boxes: []Box) void {
    const engine = Engine.getEngine(it.world);
    pixel_mod.drawBoxes(engine, positions, boxes);
    for (positions, boxes) |pos, box| {
        // std.debug.print("call from render_pixel_box_system x:{d} y:{d} with size: {d}", .{ pos.x, pos.y, box.size });
        // pixel_mod.drawBox(engine, pos, box);
        _ = pos;
        _ = box;
    }
    // _ = boxes;
    // _ = engine;
}

pub fn player_input_system(it: *ecs.iter_t, velocities: []Velocity) void {
    // Access your global input variable
    // This retrieves the data you set in the main loop
    const input = ecs.singleton_get(it.world, input_mod.InputState) orelse return;

    for (velocities) |*vel| {
        // Horizontal movement: set directly
        var dx: f32 = 0;
        if (input.pressed_directions.left) dx -= 1;
        if (input.pressed_directions.right) dx += 1;
        vel.x = dx * PLAYER_SPEED;

        // Vertical movement: Only set if input is provided, otherwise let gravity handle it
        if (input.pressed_directions.up) {
            // Constant upward speed while holding "up"
            vel.y = -PLAYER_SPEED;
        } else if (input.pressed_directions.down) {
            vel.y = PLAYER_SPEED;
        }
        // If no vertical keys are pressed, we leave vel.y alone so gravity can accumulate
    }
}

fn collision_axis(it: *ecs.iter_t, positions: []Position, boxes: []Box, velocities: []Velocity, comptime axis: Axis) void {
    const world = it.world;

    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = ecs.id(Ground) };
    desc.terms[1] = .{ .id = ecs.id(Position) };
    desc.terms[2] = .{ .id = ecs.id(Box) };
    const query = ecs.query_init(world, &desc) catch return;
    defer ecs.query_fini(query);

    for (positions, boxes, velocities) |*pos, box, *vel| {
        const b_half = @as(f32, @floatFromInt(box.size));

        var q_it = ecs.query_iter(world, query);
        while (ecs.query_next(&q_it)) {
            const g_positions = ecs.field(&q_it, Position, 1).?;
            const g_boxes = ecs.field(&q_it, Box, 2).?;

            for (0..q_it.count()) |j| {
                const gp = g_positions[j];
                const gb = g_boxes[j];
                const g_half = @as(f32, @floatFromInt(gb.size));

                const dx = pos.x - gp.x;
                const dy = pos.y - gp.y;

                const overlap_x = (b_half + g_half) - @abs(dx);
                const overlap_y = (b_half + g_half) - @abs(dy);

                if (overlap_x > 0 and overlap_y > 0) {
                    const overlap = if (axis == .x) overlap_x else overlap_y;
                    const diff = if (axis == .x) dx else dy;
                    @field(pos, @tagName(axis)) += if (diff > 0) overlap else -overlap;
                    @field(vel, @tagName(axis)) = 0;
                }
            }
        }
    }
}

pub fn ground_collision_x_system(it: *ecs.iter_t, positions: []Position, boxes: []Box, velocities: []Velocity) void {
    collision_axis(it, positions, boxes, velocities, .x);
}

pub fn ground_collision_y_system(it: *ecs.iter_t, positions: []Position, boxes: []Box, velocities: []Velocity) void {
    collision_axis(it, positions, boxes, velocities, .y);
}

// pub fn shoot_bullet(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, targets: []Target) void {
pub fn shoot_bullet(it: *ecs.iter_t) void {
    _ = Engine.getEngine(it.world);
    return;
}

fn f32_to_i32(value: f32) i32 {
    return @as(i32, @intFromFloat(value));
}
