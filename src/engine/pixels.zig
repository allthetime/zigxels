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

pub fn destroyCircle(engine: *Engine, cx: i32, cy: i32, r: i32) void {
    const width = @as(i32, @intCast(engine.width));
    const height = @as(i32, @intCast(engine.height));
    const r2 = r * r;

    // Bounding box of the circle
    const min_x = @max(0, cx - r);
    const min_y = @max(0, cy - r);
    const max_x = @min(width - 1, cx + r);
    const max_y = @min(height - 1, cy + r);

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r2) {
                const idx = @as(usize, @intCast(y)) * engine.width + @as(usize, @intCast(x));
                // Restore sky color
                engine.background_buffer[idx] = engine.sky_buffer[idx];
                // Also update current frame so we see it immediately
                engine.pixel_buffer[idx] = engine.sky_buffer[idx];
            }
        }
    }
}

pub fn checkCircleCollision(engine: *Engine, cx: i32, cy: i32, r: i32) bool {
    const width = @as(i32, @intCast(engine.width));
    const height = @as(i32, @intCast(engine.height));
    const r2 = r * r;

    const min_x = @max(0, cx - r);
    const min_y = @max(0, cy - r);
    const max_x = @min(width - 1, cx + r);
    const max_y = @min(height - 1, cy + r);

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r2) {
                const idx = @as(usize, @intCast(y)) * engine.width + @as(usize, @intCast(x));
                // If the background pixel is NOT the sky pixel, we hit something solid
                if (engine.background_buffer[idx] != engine.sky_buffer[idx]) {
                    return true;
                }
            }
        }
    }
    return false;
}

pub fn isSolid(engine: *Engine, x: i32, y: i32) bool {
    if (x < 0 or x >= engine.width or y < 0 or y >= engine.height) return false;
    const idx = @as(usize, @intCast(y)) * engine.width + @as(usize, @intCast(x));
    return engine.background_buffer[idx] != engine.sky_buffer[idx];
}

pub fn resolvePixelCollision(engine: *Engine, pos: *components.Position, vel: *components.Velocity, width: f32, height: f32) void {
    const w_i = @as(i32, @intFromFloat(width));
    const h_i = @as(i32, @intFromFloat(height));
    const x_i = @as(i32, @intFromFloat(pos.x));
    const y_i = @as(i32, @intFromFloat(pos.y));

    // Check feet (bottom edge)
    const feet_y = y_i + @divTrunc(h_i, 2);
    // Indent slightly so we don't catch on walls
    const left_x = x_i - @divTrunc(w_i, 2) + 2;
    const right_x = x_i + @divTrunc(w_i, 2) - 2;

    var solid_below = false;
    // Check Left, Center, Right of feet
    if (isSolid(engine, left_x, feet_y) or
        isSolid(engine, x_i, feet_y) or
        isSolid(engine, right_x, feet_y))
    {
        solid_below = true;
    }

    if (solid_below and vel.y >= 0) {
        // We are sinking into ground.
        // Search upwards for surface (limit 10 pixels to prevent teleporting to top of world)
        var offset: i32 = 0;
        while (offset < 10) : (offset += 1) {
            const check_y = feet_y - offset;
            if (!isSolid(engine, left_x, check_y) and
                !isSolid(engine, x_i, check_y) and
                !isSolid(engine, right_x, check_y))
            {
                // Found empty space!
                pos.y -= @as(f32, @floatFromInt(offset));
                vel.y = 0;
                return;
            }
        }
        // Fallback: stop velocity even if we couldn't snap cleanly
        vel.y = 0;
    }
}
