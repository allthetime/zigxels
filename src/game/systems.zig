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

pub const PLAYER_SPEED: f32 = 400.0;
pub const BULLET_SPEED: f32 = 600.0;
pub const GRAVITY: f32 = 2500.0;
pub const JUMP_IMPULSE: f32 = -600.0;

pub fn gravity_system(it: *ecs.iter_t, velocities: []Velocity) void {
    const dt = it.delta_time;

    for (velocities) |*vel| {
        vel.y += GRAVITY * dt;
    }
}

pub fn move_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity) void {
    const engine = Engine.getEngine(it.world);
    const width = @as(f32, @floatFromInt(engine.width));
    const height = @as(f32, @floatFromInt(engine.height));
    const dt = it.delta_time;

    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;

        pos.x = clamp(f32, pos.x, 0.0, width);
        pos.y = clamp(f32, pos.y, 0.0, height);
    }
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

pub fn ground_collision_system(it: *ecs.iter_t) void {
    _ = it;

    //
    // basic collision algo from rust proj for reference
    //
    // let x_collision_left = self.position.x < other.position.x + other.dimensions.width as i16;
    // let x_collision_right = self.position.x + self.dimensions.width as i16 > other.position.x;
    // let y_collision_top = self.position.y < other.position.y + other.dimensions.height as i16;
    // let y_collision_bottom = self.position.y + self.dimensions.height as i16 > other.position.y;

    //
    // box bounds
    //
    // x <= x_usize + box.size and
    // x > x_usize - box.size and
    // y <= y_usize + box.size and
    // y > y_usize - box.size

}

// pub fn shoot_bullet(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, targets: []Target) void {
pub fn shoot_bullet(it: *ecs.iter_t) void {
    _ = Engine.getEngine(it.world);
    return;
}

fn f32_to_i32(value: f32) i32 {
    return @as(i32, @intFromFloat(value));
}
