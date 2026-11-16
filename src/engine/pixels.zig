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

/// Blend `src` over `dst` using `alpha` (0 = keep dst, 255 = replace with opaque src).
/// Color format is packed ABGR u32 (little-endian [R, G, B, A]).
pub fn blendPixel(dst: u32, src: u32, alpha: u8) u32 {
    if (alpha == 0) return dst;
    if (alpha == 255) return src | 0xFF000000;

    const a: u32 = alpha;
    const inv: u32 = 255 - a;

    const sr: u32 = src & 0xFF;
    const sg: u32 = (src >> 8) & 0xFF;
    const sb: u32 = (src >> 16) & 0xFF;

    const dr: u32 = dst & 0xFF;
    const dg: u32 = (dst >> 8) & 0xFF;
    const db: u32 = (dst >> 16) & 0xFF;

    const r: u32 = (sr * a + dr * inv + 127) / 255;
    const g: u32 = (sg * a + dg * inv + 127) / 255;
    const b: u32 = (sb * a + db * inv + 127) / 255;

    return 0xFF000000 | (b << 16) | (g << 8) | r;
}

/// Merge an actor's `Effect` flags into a single pixel of `effect_buffer`.
/// `Effect.none` is a no-op so actors without effects preserve underlying effect zones.
inline fn stampEffectPixel(effect_buffer: []u16, idx: usize, effect: Effect) void {
    const flags = effect.toByte();
    if (flags == 0) return;

    const existing = effect_buffer[idx];
    const existing_flags: u8 = @truncate(existing);
    const merged_flags = existing_flags | flags;
    effect_buffer[idx] = (@as(u16, 255) << 8) | @as(u16, merged_flags);
}

/// Merge an actor's `Effect` flags across a horizontal span of `effect_buffer`.
/// `Effect.none` preserves existing effect buffer values (such as environmental EffectZones).
fn stampEffectSpan(effect_slice: []u16, effect: Effect) void {
    const flags = effect.toByte();
    if (flags == 0) return;

    for (effect_slice) |*cell| {
        const existing = cell.*;
        const existing_flags: u8 = @truncate(existing);
        const merged_flags = existing_flags | flags;
        cell.* = (@as(u16, 255) << 8) | @as(u16, merged_flags);
    }
}

/// Draw a clipped solid rectangle into raw pixel and effect buffers.
/// Preserves existing effect flags when `effect == Effect.none`.
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
    const span = bounds.end_x - bounds.start_x;

    for (bounds.start_y..bounds.end_y) |cy| {
        const row_start = cy * buf_width + bounds.start_x;
        const row_end = row_start + span;
        @memset(pixel_buffer[row_start..row_end], color);
        stampEffectSpan(effect_buffer[row_start..row_end], effect);
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

fn fillCircleScanlines(
    pixel_buffer: []u32,
    effect_buffer: []u16,
    buf_width: usize,
    buf_height: usize,
    cx: f32,
    cy: f32,
    r: f32,
    color: u32,
    alpha: ?u8,
    effect: Effect,
) void {
    if (alpha) |a| {
        if (a == 0) return;
    }
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(r) or r <= 0.0) return;
    if (buf_width == 0 or buf_height == 0) return;

    const bw_f: f32 = @floatFromInt(buf_width);
    const bh_f: f32 = @floatFromInt(buf_height);
    if (cx + r < 0.0 or cx - r >= bw_f or cy + r < 0.0 or cy - r >= bh_f) return;

    const y_start_f = @max(0.0, @floor(cy - r));
    const y_end_f = @min(bh_f, @ceil(cy + r));
    if (y_end_f <= y_start_f) return;

    const start_y: usize = @intFromFloat(y_start_f);
    const end_y: usize = @intFromFloat(y_end_f);
    const r_sq = r * r;

    for (start_y..end_y) |py| {
        const dy = (@as(f32, @floatFromInt(py)) + 0.5) - cy;
        const rem_sq = r_sq - dy * dy;
        if (rem_sq < 0.0) continue;

        const half_w = @sqrt(rem_sq);
        const x0_f = @max(0.0, @ceil(cx - half_w - 0.5));
        const x1_f = @min(bw_f, @floor(cx + half_w - 0.5) + 1.0);
        if (x1_f <= x0_f) continue;

        const start_x: usize = @intFromFloat(x0_f);
        const end_x: usize = @intFromFloat(x1_f);
        const row_start = py * buf_width + start_x;
        const row_end = py * buf_width + end_x;

        if (alpha) |a| {
            for (pixel_buffer[row_start..row_end]) |*dst| {
                dst.* = blendPixel(dst.*, color, a);
            }
        } else {
            @memset(pixel_buffer[row_start..row_end], color);
        }
        stampEffectSpan(effect_buffer[row_start..row_end], effect);
    }
}

/// Draw a clipped scanline-filled circle into raw pixel and effect buffers.
pub fn drawCircleFilledInBuffers(
    pixel_buffer: []u32,
    effect_buffer: []u16,
    buf_width: usize,
    buf_height: usize,
    cx: f32,
    cy: f32,
    r: f32,
    color: u32,
    effect: Effect,
) void {
    fillCircleScanlines(pixel_buffer, effect_buffer, buf_width, buf_height, cx, cy, r, color, null, effect);
}

/// Draw a clipped scanline-filled circle into the engine pixel and effect buffers.
pub fn drawCircleFilled(engine: *Engine, cx: f32, cy: f32, r: f32, color: u32, effect: Effect) void {
    drawCircleFilledInBuffers(
        engine.pixel_buffer,
        engine.effect_buffer,
        engine.width,
        engine.height,
        cx,
        cy,
        r,
        color,
        effect,
    );
}

/// Draw a clipped alpha-blended filled circle into raw pixel and effect buffers.
pub fn drawCircleFilledAlphaInBuffers(
    pixel_buffer: []u32,
    effect_buffer: []u16,
    buf_width: usize,
    buf_height: usize,
    cx: f32,
    cy: f32,
    r: f32,
    color: u32,
    alpha: u8,
    effect: Effect,
) void {
    fillCircleScanlines(pixel_buffer, effect_buffer, buf_width, buf_height, cx, cy, r, color, alpha, effect);
}

/// Draw a clipped alpha-blended filled circle into the engine buffers.
pub fn drawCircleFilledAlpha(engine: *Engine, cx: f32, cy: f32, r: f32, color: u32, alpha: u8, effect: Effect) void {
    drawCircleFilledAlphaInBuffers(
        engine.pixel_buffer,
        engine.effect_buffer,
        engine.width,
        engine.height,
        cx,
        cy,
        r,
        color,
        alpha,
        effect,
    );
}

/// Draw a clipped tapered filled capsule between `(x0, y0, r0)` and `(x1, y1, r1)`.
pub fn drawCapsuleFilledInBuffers(
    pixel_buffer: []u32,
    effect_buffer: []u16,
    buf_width: usize,
    buf_height: usize,
    x0: f32,
    y0: f32,
    r0_in: f32,
    x1: f32,
    y1: f32,
    r1_in: f32,
    color: u32,
    effect: Effect,
) void {
    if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or !std.math.isFinite(r0_in) or
        !std.math.isFinite(x1) or !std.math.isFinite(y1) or !std.math.isFinite(r1_in)) return;
    if (buf_width == 0 or buf_height == 0) return;

    const r0 = @max(0.0, r0_in);
    const r1 = @max(0.0, r1_in);
    if (r0 <= 0.0 and r1 <= 0.0) return;

    const abx = x1 - x0;
    const aby = y1 - y0;
    const ab_len_sq = abx * abx + aby * aby;
    if (ab_len_sq <= 1e-6) {
        drawCircleFilledInBuffers(pixel_buffer, effect_buffer, buf_width, buf_height, x0, y0, @max(r0, r1), color, effect);
        return;
    }

    const bw_f: f32 = @floatFromInt(buf_width);
    const bh_f: f32 = @floatFromInt(buf_height);
    const min_xf = @min(x0 - r0, x1 - r1);
    const max_xf = @max(x0 + r0, x1 + r1);
    const min_yf = @min(y0 - r0, y1 - r1);
    const max_yf = @max(y0 + r0, y1 + r1);

    if (max_xf < 0.0 or min_xf >= bw_f or max_yf < 0.0 or min_yf >= bh_f) return;

    const start_x: usize = @intFromFloat(@max(0.0, @floor(min_xf)));
    const end_x: usize = @intFromFloat(@min(bw_f, @ceil(max_xf)));
    const start_y: usize = @intFromFloat(@max(0.0, @floor(min_yf)));
    const end_y: usize = @intFromFloat(@min(bh_f, @ceil(max_yf)));
    if (end_x <= start_x or end_y <= start_y) return;

    const inv_ab_len_sq = 1.0 / ab_len_sq;
    const dr = r1 - r0;
    const r0_sq = r0 * r0;
    const r1_sq = r1 * r1;

    for (start_y..end_y) |py| {
        const sy = @as(f32, @floatFromInt(py)) + 0.5;
        const dy0 = sy - y0;
        const dy1 = sy - y1;
        const dy0_sq = dy0 * dy0;
        const dy1_sq = dy1 * dy1;
        const t_y = dy0 * aby;
        const row_base = py * buf_width;

        for (start_x..end_x) |px| {
            const sx = @as(f32, @floatFromInt(px)) + 0.5;
            const dx0 = sx - x0;
            const dx1 = sx - x1;

            const inside_cap0 = (r0 > 0.0) and (dx0 * dx0 + dy0_sq <= r0_sq);
            const inside_cap1 = (r1 > 0.0) and (dx1 * dx1 + dy1_sq <= r1_sq);

            var inside = inside_cap0 or inside_cap1;
            if (!inside) {
                const t = std.math.clamp((dx0 * abx + t_y) * inv_ab_len_sq, 0.0, 1.0);
                const cx = x0 + t * abx;
                const cy = y0 + t * aby;
                const rt = r0 + t * dr;
                const dcx = sx - cx;
                const dcy = sy - cy;
                inside = (dcx * dcx + dcy * dcy) <= (rt * rt);
            }

            if (inside) {
                const idx = row_base + px;
                pixel_buffer[idx] = color;
                stampEffectPixel(effect_buffer, idx, effect);
            }
        }
    }
}

/// Draw a clipped tapered filled capsule into the engine pixel and effect buffers.
pub fn drawCapsuleFilled(
    engine: *Engine,
    x0: f32,
    y0: f32,
    r0: f32,
    x1: f32,
    y1: f32,
    r1: f32,
    color: u32,
    effect: Effect,
) void {
    drawCapsuleFilledInBuffers(
        engine.pixel_buffer,
        engine.effect_buffer,
        engine.width,
        engine.height,
        x0,
        y0,
        r0,
        x1,
        y1,
        r1,
        color,
        effect,
    );
}

/// Draw a clipped alpha-blended filled triangle using half-open scanline spans (no double-blending on shared edges).
pub fn drawTriangleFilledAlphaInBuffers(
    pixel_buffer: []u32,
    buf_width: usize,
    buf_height: usize,
    x0_in: f32,
    y0_in: f32,
    x1_in: f32,
    y1_in: f32,
    x2_in: f32,
    y2_in: f32,
    color: u32,
) void {
    const alpha: u8 = @truncate(color >> 24);
    if (alpha == 0) return;
    if (!std.math.isFinite(x0_in) or !std.math.isFinite(y0_in) or
        !std.math.isFinite(x1_in) or !std.math.isFinite(y1_in) or
        !std.math.isFinite(x2_in) or !std.math.isFinite(y2_in)) return;
    if (buf_width == 0 or buf_height == 0) return;

    var vx = [3]f32{ x0_in, x1_in, x2_in };
    var vy = [3]f32{ y0_in, y1_in, y2_in };

    if (vy[0] > vy[1]) {
        std.mem.swap(f32, &vx[0], &vx[1]);
        std.mem.swap(f32, &vy[0], &vy[1]);
    }
    if (vy[1] > vy[2]) {
        std.mem.swap(f32, &vx[1], &vx[2]);
        std.mem.swap(f32, &vy[1], &vy[2]);
    }
    if (vy[0] > vy[1]) {
        std.mem.swap(f32, &vx[0], &vx[1]);
        std.mem.swap(f32, &vy[0], &vy[1]);
    }

    const total_h = vy[2] - vy[0];
    if (total_h <= 1e-4) return;

    const bw_f: f32 = @floatFromInt(buf_width);
    const bh_f: f32 = @floatFromInt(buf_height);
    const min_x = @min(vx[0], @min(vx[1], vx[2]));
    const max_x = @max(vx[0], @max(vx[1], vx[2]));
    if (max_x < 0.0 or min_x >= bw_f or vy[2] < 0.0 or vy[0] >= bh_f) return;

    const start_y: usize = @intFromFloat(@max(0.0, @ceil(vy[0] - 0.5)));
    const end_y: usize = @intFromFloat(@min(bh_f, @ceil(vy[2] - 0.5)));
    if (end_y <= start_y) return;

    const upper_h = vy[1] - vy[0];
    const lower_h = vy[2] - vy[1];

    for (start_y..end_y) |py| {
        const sy = @as(f32, @floatFromInt(py)) + 0.5;
        if (sy < vy[0] or sy >= vy[2]) continue;

        const xa = vx[0] + (vx[2] - vx[0]) * ((sy - vy[0]) / total_h);
        const xb = if (sy < vy[1] and upper_h > 1e-4)
            vx[0] + (vx[1] - vx[0]) * ((sy - vy[0]) / upper_h)
        else if (lower_h > 1e-4)
            vx[1] + (vx[2] - vx[1]) * ((sy - vy[1]) / lower_h)
        else
            vx[1];

        const left_x = @min(xa, xb);
        const right_x = @max(xa, xb);
        const x0_f = @max(0.0, @ceil(left_x - 0.5));
        const x1_f = @min(bw_f, @ceil(right_x - 0.5));
        if (x1_f <= x0_f) continue;

        const start_x: usize = @intFromFloat(x0_f);
        const end_x: usize = @intFromFloat(x1_f);
        const row_base = py * buf_width;
        for (start_x..end_x) |px| {
            const idx = row_base + px;
            pixel_buffer[idx] = blendPixel(pixel_buffer[idx], color, alpha);
        }
    }
}

/// Draw a clipped alpha-blended filled triangle into the engine pixel buffer.
pub fn drawTriangleFilledAlpha(
    engine: *Engine,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    color: u32,
) void {
    drawTriangleFilledAlphaInBuffers(
        engine.pixel_buffer,
        engine.width,
        engine.height,
        x0,
        y0,
        x1,
        y1,
        x2,
        y2,
        color,
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

/// Draw a 1px outline rectangle into the pixel buffer (clipped safely).
pub fn drawRectOutline(engine: *Engine, x: i32, y: i32, w: usize, h: usize, color: u32) void {
    if (w == 0 or h == 0) return;
    drawRectInBuffers(engine.pixel_buffer, engine.effect_buffer, engine.width, engine.height, x, y, w, 1, color, Effect.none);
    drawRectInBuffers(engine.pixel_buffer, engine.effect_buffer, engine.width, engine.height, x, y + @as(i32, @intCast(h - 1)), w, 1, color, Effect.none);
    drawRectInBuffers(engine.pixel_buffer, engine.effect_buffer, engine.width, engine.height, x, y, 1, h, color, Effect.none);
    drawRectInBuffers(engine.pixel_buffer, engine.effect_buffer, engine.width, engine.height, x + @as(i32, @intCast(w - 1)), y, 1, h, color, Effect.none);
}

fn glyphRows(ch_raw: u8) [7]u5 {
    const ch = std.ascii.toUpper(ch_raw);
    return switch (ch) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
        'D' => .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
        '6' => .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
        '-' => .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
        '/' => .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 },
        ':' => .{ 0b00000, 0b00100, 0b00100, 0b00000, 0b00100, 0b00100, 0b00000 },
        '!' => .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 },
        '.' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b00100 },
        '=' => .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 },
        '(' => .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 },
        ')' => .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 },
        '&' => .{ 0b01100, 0b10010, 0b10100, 0b01000, 0b10101, 0b10010, 0b01101 },
        else => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    };
}

/// Draw scaled 5x7 uppercase bitmap text directly into a raw pixel buffer (clipped safely).
pub fn drawPixelTextInBuffer(
    pixel_buffer: []u32,
    buf_width: usize,
    buf_height: usize,
    x: i32,
    y: i32,
    scale: usize,
    text: []const u8,
    color: u32,
) void {
    if (scale == 0 or buf_width == 0 or buf_height == 0) return;
    const s: i32 = @intCast(scale);
    const bw: i32 = @intCast(buf_width);
    const bh: i32 = @intCast(buf_height);
    var cursor_x = x;

    for (text) |ch| {
        const rows = glyphRows(ch);
        for (rows, 0..) |row_bits, ry| {
            var rx: usize = 0;
            while (rx < 5) : (rx += 1) {
                const bit: u5 = @as(u5, 1) << @intCast(4 - rx);
                if ((row_bits & bit) == 0) continue;

                const px0 = cursor_x + @as(i32, @intCast(rx)) * s;
                const py0 = y + @as(i32, @intCast(ry)) * s;
                const x_start = @max(0, px0);
                const y_start = @max(0, py0);
                const x_end = @min(bw, px0 + s);
                const y_end = @min(bh, py0 + s);
                if (x_end <= x_start or y_end <= y_start) continue;

                var py = y_start;
                while (py < y_end) : (py += 1) {
                    const row_base = @as(usize, @intCast(py)) * buf_width;
                    const ux0: usize = @intCast(x_start);
                    const ux1: usize = @intCast(x_end);
                    if (ux1 - ux0 <= 4) {
                        for (ux0..ux1) |px| {
                            pixel_buffer[row_base + px] = color;
                        }
                    } else {
                        @memset(pixel_buffer[row_base + ux0 .. row_base + ux1], color);
                    }
                }
            }
        }
        cursor_x += 6 * s;
    }
}

/// Draw scaled 5x7 bitmap text with a 1px dark drop shadow into the engine pixel buffer.
pub fn drawPixelText(engine: *Engine, x: i32, y: i32, scale: usize, text: []const u8, color: u32) void {
    const shadow = packColor(12, 12, 18, 255);
    const offset: i32 = @intCast(@max(@as(usize, 1), scale));
    drawPixelTextInBuffer(engine.pixel_buffer, engine.width, engine.height, x + offset, y + offset, scale, text, shadow);
    drawPixelTextInBuffer(engine.pixel_buffer, engine.width, engine.height, x, y, scale, text, color);
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

test "drawCircleFilledInBuffers clips on all edges and rasterizes disk" {
    const testing = std.testing;
    var pixels: [64]u32 = @splat(0); // 8x8
    var effects: [64]u16 = @splat(0);

    // Centered circle of radius 2.0 at (4.0, 4.0)
    drawCircleFilledInBuffers(&pixels, &effects, 8, 8, 4.0, 4.0, 2.0, 0xFF112233, Effect.glow_only);
    try testing.expectEqual(@as(u32, 0xFF112233), pixels[4 * 8 + 4]);
    try testing.expectEqual(@as(u32, 0xFF112233), pixels[3 * 8 + 3]);
    try testing.expectEqual(@as(u32, 0), pixels[0]); // corner outside circle
    try testing.expect(Effect.flagsFromU16(effects[4 * 8 + 4]).glow);

    // Partially off top-left and bottom-right corners
    @memset(&pixels, 0);
    @memset(&effects, 0);
    drawCircleFilledInBuffers(&pixels, &effects, 8, 8, 0.0, 0.0, 2.0, 0xAAAAAAAA, Effect.none);
    try testing.expectEqual(@as(u32, 0xAAAAAAAA), pixels[0]);
    try testing.expectEqual(@as(u32, 0), pixels[4 * 8 + 4]);

    drawCircleFilledInBuffers(&pixels, &effects, 8, 8, 8.0, 8.0, 2.0, 0xBBBBBBBB, Effect.none);
    try testing.expectEqual(@as(u32, 0xBBBBBBBB), pixels[7 * 8 + 7]);

    // Completely off-screen and degenerate/non-finite inputs must be safe no-ops
    @memset(&pixels, 0);
    drawCircleFilledInBuffers(&pixels, &effects, 8, 8, -20.0, -20.0, 5.0, 0xCCCCCCCC, Effect.none);
    drawCircleFilledInBuffers(&pixels, &effects, 8, 8, 30.0, 30.0, 5.0, 0xCCCCCCCC, Effect.none);
    drawCircleFilledInBuffers(&pixels, &effects, 8, 8, 4.0, 4.0, 0.0, 0xCCCCCCCC, Effect.none);
    drawCircleFilledInBuffers(&pixels, &effects, 8, 8, std.math.nan(f32), 4.0, 3.0, 0xCCCCCCCC, Effect.none);
    for (pixels) |p| {
        try testing.expectEqual(@as(u32, 0), p);
    }
}

test "drawCapsuleFilledInBuffers clips, tapers, and handles degenerate segments" {
    const testing = std.testing;
    var pixels: [16 * 16]u32 = @splat(0);
    var effects: [16 * 16]u16 = @splat(0);

    // Tapered horizontal capsule from (4, 8) r=4 to (12, 8) r=1.5
    drawCapsuleFilledInBuffers(&pixels, &effects, 16, 16, 4.0, 8.0, 4.0, 12.0, 8.0, 1.5, 0xFF00FF00, Effect.bloom_only);
    try testing.expectEqual(@as(u32, 0xFF00FF00), pixels[8 * 16 + 4]); // thick start
    try testing.expectEqual(@as(u32, 0xFF00FF00), pixels[5 * 16 + 4]); // y=5.5 -> dy=2.5 <= 4.0
    try testing.expectEqual(@as(u32, 0xFF00FF00), pixels[8 * 16 + 12]); // thin end
    try testing.expectEqual(@as(u32, 0), pixels[5 * 16 + 12]); // thin end must not be 4px tall!
    try testing.expect(Effect.flagsFromU16(effects[8 * 16 + 8]).bloom);

    // Clipped off-bounds capsule
    @memset(&pixels, 0);
    drawCapsuleFilledInBuffers(&pixels, &effects, 16, 16, -4.0, 8.0, 3.0, 4.0, 8.0, 3.0, 0xFFFFFFFF, Effect.none);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[8 * 16 + 0]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[8 * 16 + 4]);
    try testing.expectEqual(@as(u32, 0), pixels[8 * 16 + 10]);

    // Degenerate zero-length segment acts like circle, and offscreen/NaN is safe no-op
    @memset(&pixels, 0);
    drawCapsuleFilledInBuffers(&pixels, &effects, 16, 16, 8.0, 8.0, 2.0, 8.0, 8.0, 3.0, 0x12345678, Effect.none);
    try testing.expectEqual(@as(u32, 0x12345678), pixels[8 * 16 + 8]);

    @memset(&pixels, 0);
    drawCapsuleFilledInBuffers(&pixels, &effects, 16, 16, -50.0, -50.0, 3.0, -30.0, -30.0, 3.0, 0x11111111, Effect.none);
    drawCapsuleFilledInBuffers(&pixels, &effects, 16, 16, std.math.inf(f32), 0.0, 2.0, 4.0, 4.0, 2.0, 0x11111111, Effect.none);
    for (pixels) |p| {
        try testing.expectEqual(@as(u32, 0), p);
    }
}

test "Effect.none preserves existing effect zones and non-empty effects merge cleanly" {
    const testing = std.testing;
    var pixels: [64]u32 = @splat(0);
    var effects: [64]u16 = @splat(Effect.heat_only.withIntensity(180));

    // Actor draws with Effect.none must preserve underlying heat zone
    drawRectInBuffers(&pixels, &effects, 8, 8, 1, 1, 2, 2, 0xFF00FF00, Effect.none);
    drawCircleFilledInBuffers(&pixels, &effects, 8, 8, 5.0, 5.0, 2.0, 0xFFFF0000, Effect.none);
    try testing.expectEqual(Effect.heat_only.withIntensity(180), effects[1 * 8 + 1]);
    try testing.expectEqual(Effect.heat_only.withIntensity(180), effects[5 * 8 + 5]);

    // Actor draw with Effect.glow_only must merge with existing heat flag
    drawCapsuleFilledInBuffers(&pixels, &effects, 8, 8, 2.0, 2.0, 1.5, 6.0, 2.0, 1.5, 0xFFFFFFFF, Effect.glow_only);
    const merged = Effect.flagsFromU16(effects[2 * 8 + 4]);
    try testing.expect(merged.heat);
    try testing.expect(merged.glow);
}

test "drawTriangleFilledAlphaInBuffers blends without panics or out-of-bounds" {
    const testing = std.testing;
    var pixels: [64]u32 = @splat(packColor(0, 0, 100, 255)); // 8x8 dark blue
    const fill = packColor(200, 0, 0, 128);

    drawTriangleFilledAlphaInBuffers(&pixels, 8, 8, 4.0, 1.0, 7.0, 7.0, 1.0, 7.0, fill);
    // Interior pixel (4, 5) should be blended (R > 0, B < 100)
    const center = pixels[5 * 8 + 4];
    try testing.expect((center & 0xFF) > 50);
    try testing.expect(((center >> 16) & 0xFF) < 80);
    // Top-left corner (0, 0) untouched
    try testing.expectEqual(packColor(0, 0, 100, 255), pixels[0]);

    // Non-finite/off-screen is safe
    drawTriangleFilledAlphaInBuffers(&pixels, 8, 8, -20.0, -20.0, -10.0, -5.0, -5.0, -15.0, fill);
    drawTriangleFilledAlphaInBuffers(&pixels, 8, 8, std.math.nan(f32), 0.0, 2.0, 2.0, 0.0, 2.0, fill);
}

test "drawPixelTextInBuffer renders glyphs and clips safely at boundaries" {
    const testing = std.testing;
    var pixels: [24 * 16]u32 = @splat(0);
    const white = packColor(255, 255, 255, 255);

    // Draw "A!" partially clipped off bottom-right
    drawPixelTextInBuffer(&pixels, 24, 16, 2, 2, 1, "A!", white);
    // 'A' top row is 0b01110 -> center pixel at (2+2, 2) = (4, 2) must be white
    try testing.expectEqual(white, pixels[2 * 24 + 4]);
    // Clipping test: out-of-bounds text does not crash
    drawPixelTextInBuffer(&pixels, 24, 16, -4, -3, 2, "CLEAR!", white);
}
