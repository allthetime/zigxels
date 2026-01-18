const std = @import("std");
const components = @import("../game/components.zig");
const Engine = @import("../engine/core.zig").Engine;

const Position = components.Position;
const Box = components.Box;

pub fn makeGradient(pixel_buffer: []u32, width: usize, height: usize, shift: ?@Vector(2, usize)) void {
    for (pixel_buffer, 0..) |*pixel, index| {
        const x = if (shift) |s| (index % width + s[0]) % width else index % width;
        const y = if (shift) |s| (index / width + s[1]) % height else index / width;

        // std.debug.print("index: {d}, AA x: {d}, y: {d}\n", .{ index, x, y });

        const r: u8 = @intCast((x * 255) / width);
        const g: u8 = @intCast((y * 255) / height);
        const b: u8 = 0x80;
        // Pack RGBA values into a 32-bit pixel format (RGBA8888)
        pixel.* = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }
}

fn inBounds(max: usize, index: usize) bool {
    return index >= 0 and index < max;
}
// pub fn drawBox(pixel_buffer: []u32, width: usize, height: usize, position: Position, box: Box) void {
pub fn drawBox(engine: *Engine, position: Position, box: Box) void {
    const r: u8 = 0x00;
    const g: u8 = 0x00;
    const b: u8 = 0x00;

    const MAX_INDEX = engine.width * engine.height;

    const y_usize = @as(usize, @intFromFloat(position.y));
    const x_usize = @as(usize, @intFromFloat(position.x));
    const index = (MAX_INDEX -
        //
        // we need to somehow account for the 32 bit pixel
        // 4 x poles are being drawn to otherwise
        //
        ((engine.height * (engine.height - y_usize))) - // y offset
        (engine.width - x_usize) // x offset
    );

    if (index >= MAX_INDEX or index < 0) {
        return;
    }

    //
    // stuck!
    // how to derive index from x/y pair?
    // const index = y * width + x;
    // if 0,0 is bottom left, then
    // const index = (height - y - 1) * width + x;
    //

    const center_pixel = &engine.pixel_buffer[index];
    center_pixel.* = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    // _ = box;
    for (0..box.size) |i| {
        const left_pixel_index = index - i;
        const right_pixel_index = index + i;
        if (inBounds(MAX_INDEX, left_pixel_index)) {
            engine.pixel_buffer[left_pixel_index] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
        }
        if (inBounds(MAX_INDEX, right_pixel_index)) {
            engine.pixel_buffer[right_pixel_index] = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
        }
    }
}

pub fn drawBoxes(engine: *Engine, positions: []Position, boxes: []Box) void {
    const width = engine.width;
    const height = engine.height;
    const pixel_buffer = engine.pixel_buffer;

    for (positions, boxes) |pos, box| {
        // Robust checks to avoid panics on float-to-int conversion
        if (!std.math.isFinite(pos.x) or !std.math.isFinite(pos.y)) continue;
        if (pos.x < -100.0 or pos.y < -100.0 or pos.x > @as(f32, @floatFromInt(width)) + 100.0 or pos.y > @as(f32, @floatFromInt(height)) + 100.0) continue;

        const x_center = @as(i32, @intFromFloat(pos.x));
        const y_center = @as(i32, @intFromFloat(pos.y));
        const size = @as(i32, @intCast(box.size));

        const x_start = @max(0, x_center - size);
        const x_end = @min(@as(i32, @intCast(width)) - 1, x_center + size);
        const y_start = @max(0, y_center - size);
        const y_end = @min(@as(i32, @intCast(height)) - 1, y_center + size);

        var y: i32 = y_start;
        while (y <= y_end) : (y += 1) {
            var x: i32 = x_start;
            while (x <= x_end) : (x += 1) {
                const index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                pixel_buffer[index] = 0x000000FF; // Black RGBA8888
            }
        }
    }
}
