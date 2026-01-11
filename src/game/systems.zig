const std = @import("std");
const ecs = @import("zflecs");
const SDL = @import("sdl2");
const components = @import("components.zig");
const Engine = @import("../engine/core.zig").Engine;

const input_mod = @import("../engine/input.zig");

const Position = components.Position;
const Velocity = components.Velocity;
const Target = components.Target;
const Rectangle = components.Rectangle;
// const Projectile = components.Projectile;

pub fn move_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity) void {
    const engine = Engine.getEngine(it.world);
    const width = @as(f32, @floatFromInt(engine.width));
    const height = @as(f32, @floatFromInt(engine.height));

    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;

        pos.x = clamp(f32, pos.x, 0.0, width);
        pos.y = clamp(f32, pos.y, 0.0, height);
    }
}

fn clamp(comptime T: type, value: T, min: T, max: T) T {
    return @max(min, @min(value, max));
}

pub fn seek_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, targets: []Target) void {
    const dt = it.delta_time;
    for (positions, velocities, targets) |pos, *vel, target| {
        const dx = target.x - pos.x;
        const dy = target.y - pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        // If we are further than 2 pixels away, move towards target
        if (dist > 2.0) {
            const speed: f32 = 500.0;
            vel.x = (dx / dist) * speed * dt;
            vel.y = (dy / dist) * speed * dt;
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

pub fn player_input_system(it: *ecs.iter_t, velocities: []Velocity) void {
    // Access your global input variable
    // This retrieves the data you set in the main loop
    const input = ecs.singleton_get(it.world, input_mod.InputState) orelse return;
    const speed: f32 = 2.0;

    for (velocities) |*vel| {
        var dx: f32 = 0;
        var dy: f32 = 0;

        if (input.pressed_directions.up) dy -= 1;
        if (input.pressed_directions.down) dy += 1;
        if (input.pressed_directions.left) dx -= 1;
        if (input.pressed_directions.right) dx += 1;

        const len_sq = dx * dx + dy * dy;
        if (len_sq > 0) {
            const len = @sqrt(len_sq);
            vel.x = (dx / len) * speed;
            vel.y = (dy / len) * speed;
        } else {
            // Stop moving if no keys are pressed
            vel.x = 0;
            vel.y = 0;
        }
    }
}

// pub fn shoot_bullet(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, targets: []Target) void {
pub fn shoot_bullet(it: *ecs.iter_t) void {
    _ = Engine.getEngine(it.world);
    return;
}

fn f32_to_i32(value: f32) i32 {
    return @as(i32, @intFromFloat(value));
}
