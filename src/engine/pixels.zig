const std = @import("std");

pub fn makeGradient(pixel_buffer: []u32, width: usize, height: usize, shift: ?@Vector(2, usize)) void {
    for (pixel_buffer, 0..) |*pixel, index| {
        const x = if (shift) |s| (index % width + s[0]) % width else index % width;
        const y = if (shift) |s| (index / width + s[1]) % height else index / width;
        const r: u8 = @intCast((x * 255) / width);
        const g: u8 = @intCast((y * 255) / height);
        const b: u8 = 0x80;
        // Pack RGBA values into a 32-bit pixel format (RGBA8888)
        pixel.* = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }
}
