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
    for (engine.pixel_buffer, 0..) |*pixel, index| {
        const x = index % engine.width;
        const y = index / engine.width;

        // std.debug.print("index: {d}, AA x: {d}, y: {d}\n", .{ index, x, y });

        const black: @Vector(3, u8) = .{ 0x00, 0x00, 0x00 };

        for (positions, boxes) |pos, box| {
            const y_usize = @as(usize, @intFromFloat(pos.y));
            const x_usize = @as(usize, @intFromFloat(pos.x));

            if (box.size > y_usize or box.size > x_usize) {
                continue;
            }

            if (x <= x_usize + box.size and
                x > x_usize - box.size and
                y <= y_usize + box.size and
                y > y_usize - box.size)
            {
                pixel.* =
                    (@as(u32, black[0]) << 24) |
                    (@as(u32, black[1]) << 16) |
                    (@as(u32, black[2]) << 8) |
                    0xFF;
            }
        }

        // fn draw_rect (&self, x: i16, y: i16, thing: Ref<Thing>) -> bool {
        //     x >= thing.position.x
        //         && x < thing.position.x + thing.dimensions.width as i16
        //         && y >= thing.position.y
        //         && y < thing.position.y + thing.dimensions.height as i16
        // }

        // _ = pixel_buffer;
        // Pack RGBA values into a 32-bit pixel format (RGBA8888)
        // pixel.* = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }
}
