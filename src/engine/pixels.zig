const std = @import("std");
const components = @import("../game/components.zig");
const Engine = @import("../engine/core.zig").Engine;

/// SIMD-optimized gradient generation - processes 8 pixels at once
pub fn makeGradientSIMD(pixel_buffer: []u32, width: usize, height: usize) void {
    const simd_width = 8;

    for (0..height) |y| {
        const row_start = y * width;
        const g: u8 = @intCast((y * 255) / height);
        const g_component = @as(u32, g) << 16;

        var x: usize = 0;

        // SIMD loop - process 8 pixels at once
        while (x + simd_width <= width) : (x += simd_width) {
            const x_vec: @Vector(8, u32) = .{
                @intCast(x),
                @intCast(x + 1),
                @intCast(x + 2),
                @intCast(x + 3),
                @intCast(x + 4),
                @intCast(x + 5),
                @intCast(x + 6),
                @intCast(x + 7),
            };

            const r_vec = (x_vec * @as(@Vector(8, u32), @splat(255))) /
                @as(@Vector(8, u32), @splat(@intCast(width)));

            const pixels = (r_vec << @as(@Vector(8, u5), @splat(24))) |
                @as(@Vector(8, u32), @splat(g_component)) |
                @as(@Vector(8, u32), @splat(0x80FF));

            pixel_buffer[row_start + x ..][0..8].* = pixels;
        }

        // Scalar cleanup for remaining pixels
        while (x < width) : (x += 1) {
            const r: u8 = @intCast((x * 255) / width);
            pixel_buffer[row_start + x] = (@as(u32, r) << 24) | g_component | 0x80FF;
        }
    }
}

pub fn restoreBackground(self: *Engine) void {
    @memcpy(self.pixel_buffer, self.background_buffer);
}

/// Helper to pack RGBA bytes into a u32 (Big Endian logic for some systems, but here RGBA8888)
/// Adjust shift order if colors look wrong (ABGR vs RGBA)
pub fn packColor(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | @as(u32, a);
}

/// Highly optimized Rect drawer using Slice Assignment (memset)
pub fn drawRect(engine: *Engine, x: i32, y: i32, w: usize, h: usize, color: u32) void {
    const width = @as(i32, @intCast(engine.width));
    const height = @as(i32, @intCast(engine.height));

    // 1. Clipping (Don't draw outside screen)
    const start_x = @max(0, x);
    const start_y = @max(0, y);
    const end_x = @min(width, x + @as(i32, @intCast(w)));
    const end_y = @min(height, y + @as(i32, @intCast(h)));

    if (end_x <= start_x or end_y <= start_y) return;

    // 2. The Speed Loop
    var current_y = start_y;
    while (current_y < end_y) : (current_y += 1) {
        // Calculate the memory range for this ROW
        const row_start = @as(usize, @intCast(current_y)) * engine.width + @as(usize, @intCast(start_x));
        const row_end = row_start + @as(usize, @intCast(end_x - start_x));

        // 3. MEMSET: Zig optimizes this to native assembly (SIMD/rep stos)
        // This is WAY faster than setting pixels one by one
        @memset(engine.pixel_buffer[row_start..row_end], color);
    }
}

pub fn restoreRect(engine: *Engine, x: i32, y: i32, w: usize, h: usize) void {
    const width = @as(i32, @intCast(engine.width));
    const height = @as(i32, @intCast(engine.height));

    // Clipping
    const start_x = @max(0, x);
    const start_y = @max(0, y);
    const end_x = @min(width, x + @as(i32, @intCast(w)));
    const end_y = @min(height, y + @as(i32, @intCast(h)));

    if (end_x <= start_x or end_y <= start_y) return;

    var current_y = start_y;
    while (current_y < end_y) : (current_y += 1) {
        const row_start = @as(usize, @intCast(current_y)) * engine.width + @as(usize, @intCast(start_x));
        const row_end = row_start + @as(usize, @intCast(end_x - start_x));

        const sky_slice = engine.sky_buffer[row_start..row_end];
        @memcpy(engine.background_buffer[row_start..row_end], sky_slice);
        @memcpy(engine.pixel_buffer[row_start..row_end], sky_slice);
    }
}
