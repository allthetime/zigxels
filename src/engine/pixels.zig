const std = @import("std");
const components = @import("../game/components.zig");
const Engine = @import("../engine/core.zig").Engine;
const Effect = @import("../engine/effects.zig").Effect;

/// SIMD-optimized gradient generation - processes 8 pixels at once
pub fn makeGradientSIMD(pixel_buffer: []u32, width: usize, height: usize) void {
    const simd_width = 8;

    for (0..height) |y| {
        const row_start = y * width;
        const g: u8 = @intCast((y * 255) / height);
        const g_component = @as(u32, g) << 8; // G at bits 8-15 in ABGR format

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

            // R at bits 0-7: no shift needed
            const r_vec = (x_vec * @as(@Vector(8, u32), @splat(255))) /
                @as(@Vector(8, u32), @splat(@intCast(width)));

            // ABGR: A=0xFF bits 24-31, B=0x80 bits 16-23, G bits 8-15, R bits 0-7
            const pixels = r_vec |
                @as(@Vector(8, u32), @splat(g_component)) |
                @as(@Vector(8, u32), @splat(0xFF800000));

            pixel_buffer[row_start + x ..][0..8].* = pixels;
        }

        // Scalar cleanup for remaining pixels
        while (x < width) : (x += 1) {
            const r: u8 = @intCast((x * 255) / width);
            pixel_buffer[row_start + x] = @as(u32, r) | g_component | 0xFF800000;
        }
    }
}

pub fn restoreBackground(self: *Engine) void {
    @memcpy(self.pixel_buffer, self.background_buffer);
}

/// Pack RGBA into a u32 in ABGR bit order so that little-endian memory = [R, G, B, A]
/// which is exactly what GL_RGBA + GL_UNSIGNED_BYTE expects.
pub fn packColor(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
}

/// Highly optimized Rect drawer using Slice Assignment (memset)
pub fn drawRect(engine: *Engine, x: i32, y: i32, w: usize, h: usize, color: u32, effect: Effect) void {
    const width = @as(i32, @intCast(engine.width));
    const height = @as(i32, @intCast(engine.height));

    // 1. Clipping (Don't draw outside screen)
    const start_x = @max(0, x);
    const start_y = @max(0, y);
    const end_x = @min(width, x + @as(i32, @intCast(w)));
    const end_y = @min(height, y + @as(i32, @intCast(h)));

    if (end_x <= start_x or end_y <= start_y) return;

    const effect_val = effect.toU16(); // flags + full intensity (255)

    // 2. The Speed Loop
    var current_y = start_y;
    while (current_y < end_y) : (current_y += 1) {
        // Calculate the memory range for this ROW
        const row_start = @as(usize, @intCast(current_y)) * engine.width + @as(usize, @intCast(start_x));
        const row_end = row_start + @as(usize, @intCast(end_x - start_x));

        // 3. MEMSET: Zig optimizes this to native assembly (SIMD/rep stos)
        // This is WAY faster than setting pixels one by one
        @memset(engine.pixel_buffer[row_start..row_end], color);
        @memset(engine.effect_buffer[row_start..row_end], effect_val);
    }
}

/// Stamp an effect region WITHOUT drawing any color.
/// Use for invisible "effect zones" (heat shimmer over lava, glow fields, etc.)
/// `feather` = number of pixels at each edge where intensity fades from 255→0.
/// Set feather=0 for hard edges (full intensity everywhere).
pub fn drawEffectOnly(engine: *Engine, x: i32, y: i32, w: usize, h: usize, effect: Effect, feather: u16) void {
    const width = @as(i32, @intCast(engine.width));
    const height = @as(i32, @intCast(engine.height));

    const start_x = @max(0, x);
    const start_y = @max(0, y);
    const end_x = @min(width, x + @as(i32, @intCast(w)));
    const end_y = @min(height, y + @as(i32, @intCast(h)));

    if (end_x <= start_x or end_y <= start_y) return;

    const effect_flags = effect.toByte();
    const rect_w = @as(u16, @intCast(end_x - start_x));
    const rect_h = @as(u16, @intCast(end_y - start_y));

    var current_y = start_y;
    while (current_y < end_y) : (current_y += 1) {
        const row_start = @as(usize, @intCast(current_y)) * engine.width + @as(usize, @intCast(start_x));
        const dy = @as(u16, @intCast(current_y - start_y));
        // Distance from nearest Y edge
        const y_dist = @min(dy, rect_h - 1 - dy);

        var cx = start_x;
        while (cx < end_x) : (cx += 1) {
            const dx = @as(u16, @intCast(cx - start_x));
            // Distance from nearest X edge
            const x_dist = @min(dx, rect_w - 1 - dx);
            // Min distance to any edge
            const edge_dist = @min(x_dist, y_dist);

            const intensity: u8 = if (feather == 0)
                255
            else if (edge_dist >= feather)
                255
            else
                @intCast((@as(u32, edge_dist) * 255) / @as(u32, feather));

            const idx = row_start + @as(usize, @intCast(dx));
            const existing = engine.effect_buffer[idx];
            // Merge flags with OR, keep the higher intensity
            const existing_flags = @as(u8, @truncate(existing));
            const existing_intensity = @as(u8, @truncate(existing >> 8));
            const merged_flags = existing_flags | effect_flags;
            const merged_intensity = @max(existing_intensity, intensity);
            engine.effect_buffer[idx] = @as(u16, merged_intensity) << 8 | @as(u16, merged_flags);
        }
    }
}

/// Draw a small crosshair cursor into the pixel buffer
pub fn drawCursor(engine: *Engine, mx: i32, my: i32, size: i32, color: u32) void {
    const w = @as(i32, @intCast(engine.width));
    const h = @as(i32, @intCast(engine.height));
    const half = @divTrunc(size, 2);

    // Horizontal line
    var cx = mx - half;
    while (cx <= mx + half) : (cx += 1) {
        if (cx >= 0 and cx < w and my >= 0 and my < h) {
            const idx = @as(usize, @intCast(my)) * engine.width + @as(usize, @intCast(cx));
            engine.pixel_buffer[idx] = color;
        }
    }
    // Vertical line
    var cy = my - half;
    while (cy <= my + half) : (cy += 1) {
        if (mx >= 0 and mx < w and cy >= 0 and cy < h) {
            const idx = @as(usize, @intCast(cy)) * engine.width + @as(usize, @intCast(mx));
            engine.pixel_buffer[idx] = color;
        }
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
        @memset(engine.effect_buffer[row_start..row_end], @as(u16, 0));
    }
}
