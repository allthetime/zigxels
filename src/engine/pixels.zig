const std = @import("std");
const Engine = @import("core.zig").Engine;
const Effect = @import("effects.zig").Effect;

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

/// Pack RGBA into a u32 in ABGR bit order so that little-endian memory = [R, G, B, A]
/// which is exactly what GL_RGBA + GL_UNSIGNED_BYTE expects.
pub fn packColor(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
}

const ClippedBounds = struct {
    start_x: usize,
    start_y: usize,
    end_x: usize,
    end_y: usize,
};

fn clipRect(buf_width: usize, buf_height: usize, x: i32, y: i32, w: usize, h: usize) ?ClippedBounds {
    const bw: i64 = @intCast(buf_width);
    const bh: i64 = @intCast(buf_height);
    const x0: i64 = x;
    const y0: i64 = y;
    const x1: i64 = x0 + @as(i64, @intCast(w));
    const y1: i64 = y0 + @as(i64, @intCast(h));

    const start_x = @max(@as(i64, 0), x0);
    const start_y = @max(@as(i64, 0), y0);
    const end_x = @min(bw, x1);
    const end_y = @min(bh, y1);

    if (end_x <= start_x or end_y <= start_y) return null;

    return .{
        .start_x = @intCast(start_x),
        .start_y = @intCast(start_y),
        .end_x = @intCast(end_x),
        .end_y = @intCast(end_y),
    };
}

/// Draw a clipped solid rectangle into raw pixel and effect buffers.
pub fn drawRectInBuffers(
    pixel_buffer: []u32,
    effect_buffer: []u16,
    buf_width: usize,
    buf_height: usize,
    x: i32,
    y: i32,
    w: usize,
    h: usize,
    color: u32,
    effect: Effect,
) void {
    const bounds = clipRect(buf_width, buf_height, x, y, w, h) orelse return;
    const effect_val = effect.toU16();
    const span = bounds.end_x - bounds.start_x;

    for (bounds.start_y..bounds.end_y) |cy| {
        const row_start = cy * buf_width + bounds.start_x;
        const row_end = row_start + span;
        @memset(pixel_buffer[row_start..row_end], color);
        @memset(effect_buffer[row_start..row_end], effect_val);
    }
}

/// Highly optimized Rect drawer using Slice Assignment (memset)
pub fn drawRect(engine: *Engine, x: i32, y: i32, w: usize, h: usize, color: u32, effect: Effect) void {
    drawRectInBuffers(
        engine.pixel_buffer,
        engine.effect_buffer,
        engine.width,
        engine.height,
        x,
        y,
        w,
        h,
        color,
        effect,
    );
}

/// Stamp an effect region WITHOUT drawing any color.
/// Use for invisible "effect zones" (heat shimmer over lava, glow fields, etc.)
/// `feather` = number of pixels at each edge where intensity fades from 255→0.
/// Set feather=0 for hard edges (full intensity everywhere).
pub fn drawEffectOnly(engine: *Engine, x: i32, y: i32, w: usize, h: usize, effect: Effect, feather: u16) void {
    const bounds = clipRect(engine.width, engine.height, x, y, w, h) orelse return;

    const effect_flags = effect.toByte();
    const rect_w: u16 = @intCast(bounds.end_x - bounds.start_x);
    const rect_h: u16 = @intCast(bounds.end_y - bounds.start_y);

    for (bounds.start_y..bounds.end_y) |cy| {
        const row_start = cy * engine.width + bounds.start_x;
        const dy: u16 = @intCast(cy - bounds.start_y);
        const y_dist = @min(dy, rect_h - 1 - dy);

        for (bounds.start_x..bounds.end_x) |cx| {
            const dx: u16 = @intCast(cx - bounds.start_x);
            const x_dist = @min(dx, rect_w - 1 - dx);
            const edge_dist = @min(x_dist, y_dist);

            const intensity: u8 = if (feather == 0 or edge_dist >= feather)
                255
            else
                @intCast((@as(u32, edge_dist) * 255) / @as(u32, feather));

            const idx = row_start + dx;
            const existing = engine.effect_buffer[idx];
            const existing_flags: u8 = @truncate(existing);
            const existing_intensity: u8 = @truncate(existing >> 8);
            const merged_flags = existing_flags | effect_flags;
            const merged_intensity = @max(existing_intensity, intensity);
            engine.effect_buffer[idx] = (@as(u16, merged_intensity) << 8) | @as(u16, merged_flags);
        }
    }
}

/// Draw a clipped line directly into a pixel buffer.
pub fn drawLineInBuffer(
    pixel_buffer: []u32,
    buf_width: usize,
    buf_height: usize,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    color: u32,
) void {
    if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or !std.math.isFinite(x1) or !std.math.isFinite(y1)) return;

    const dx = @abs(x1 - x0);
    const dy = @abs(y1 - y0);
    const max_delta = @max(dx, dy);
    const steps: usize = if (max_delta < 1.0) 1 else @intFromFloat(@ceil(max_delta));

    const w_i: i32 = @intCast(buf_width);
    const h_i: i32 = @intCast(buf_height);
    const denom: f32 = @floatFromInt(steps);

    for (0..steps + 1) |s| {
        const t = @as(f32, @floatFromInt(s)) / denom;
        const ix: i32 = @intFromFloat(x0 + (x1 - x0) * t);
        const iy: i32 = @intFromFloat(y0 + (y1 - y0) * t);
        if (ix >= 0 and iy >= 0 and ix < w_i and iy < h_i) {
            const idx = @as(usize, @intCast(iy)) * buf_width + @as(usize, @intCast(ix));
            pixel_buffer[idx] = color;
        }
    }
}

/// Draw a line into the engine pixel buffer.
pub fn drawLinePixels(engine: *Engine, x0: f32, y0: f32, x1: f32, y1: f32, color: u32) void {
    drawLineInBuffer(engine.pixel_buffer, engine.width, engine.height, x0, y0, x1, y1, color);
}

/// Draw a 32-segment circle outline into the engine pixel buffer.
pub fn drawCirclePixels(engine: *Engine, cx: f32, cy: f32, radius: f32, color: u32) void {
    const segments: usize = 32;
    const step = (std.math.pi * 2.0) / @as(f32, @floatFromInt(segments));

    for (0..segments) |i| {
        const theta1 = @as(f32, @floatFromInt(i)) * step;
        const theta2 = @as(f32, @floatFromInt(i + 1)) * step;

        const x1 = cx + @cos(theta1) * radius;
        const y1 = cy + @sin(theta1) * radius;
        const x2 = cx + @cos(theta2) * radius;
        const y2 = cy + @sin(theta2) * radius;

        drawLinePixels(engine, x1, y1, x2, y2, color);
    }
}

/// Draw a small crosshair cursor into the pixel buffer
pub fn drawCursor(engine: *Engine, mx: i32, my: i32, size: i32, color: u32) void {
    const w: i32 = @intCast(engine.width);
    const h: i32 = @intCast(engine.height);
    const half = @divTrunc(size, 2);

    var cx = mx - half;
    while (cx <= mx + half) : (cx += 1) {
        if (cx >= 0 and cx < w and my >= 0 and my < h) {
            const idx = @as(usize, @intCast(my)) * engine.width + @as(usize, @intCast(cx));
            engine.pixel_buffer[idx] = color;
        }
    }
    var cy = my - half;
    while (cy <= my + half) : (cy += 1) {
        if (mx >= 0 and mx < w and cy >= 0 and cy < h) {
            const idx = @as(usize, @intCast(cy)) * engine.width + @as(usize, @intCast(mx));
            engine.pixel_buffer[idx] = color;
        }
    }
}

pub fn restoreRect(engine: *Engine, x: i32, y: i32, w: usize, h: usize) void {
    const bounds = clipRect(engine.width, engine.height, x, y, w, h) orelse return;
    const span = bounds.end_x - bounds.start_x;

    for (bounds.start_y..bounds.end_y) |cy| {
        const row_start = cy * engine.width + bounds.start_x;
        const row_end = row_start + span;

        const sky_slice = engine.sky_buffer[row_start..row_end];
        @memcpy(engine.background_buffer[row_start..row_end], sky_slice);
        @memcpy(engine.pixel_buffer[row_start..row_end], sky_slice);
        @memset(engine.effect_buffer[row_start..row_end], @as(u16, 0));
    }
}

test "packColor packs RGBA in little-endian ABGR order" {
    const testing = std.testing;
    const c = packColor(0x11, 0x22, 0x33, 0x44);
    try testing.expectEqual(@as(u32, 0x44332211), c);
}

test "drawRectInBuffers clips safely on all edges" {
    const testing = std.testing;
    var pixels: [16]u32 = @splat(0); // 4x4
    var effects: [16]u16 = @splat(0);

    // Partially off top-left
    drawRectInBuffers(&pixels, &effects, 4, 4, -1, -1, 3, 3, 0xAABBCCDD, Effect.bloom_only);
    try testing.expectEqual(@as(u32, 0xAABBCCDD), pixels[0]);
    try testing.expectEqual(@as(u32, 0xAABBCCDD), pixels[5]);
    try testing.expectEqual(@as(u32, 0), pixels[2]);
    try testing.expectEqual(@as(u32, 0), pixels[8]);

    // Completely off-screen should be a no-op
    drawRectInBuffers(&pixels, &effects, 4, 4, 10, 10, 4, 4, 0x11111111, Effect.none);
    try testing.expectEqual(@as(u32, 0), pixels[15]);
}

test "drawLineInBuffer clips safely across out-of-bounds coordinates" {
    const testing = std.testing;
    var pixels: [16]u32 = @splat(0); // 4x4

    drawLineInBuffer(&pixels, 4, 4, -5.0, 1.0, 10.0, 1.0, 0xFFFFFFFF);
    for (0..4) |x| {
        try testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[4 + x]);
    }
    try testing.expectEqual(@as(u32, 0), pixels[0]);
    try testing.expectEqual(@as(u32, 0), pixels[8]);

    // Non-finite inputs must not panic
    drawLineInBuffer(&pixels, 4, 4, std.math.nan(f32), 0.0, 2.0, 2.0, 0x12345678);
}
