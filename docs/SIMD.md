# SIMD Optimization Guide for Zigxels

This document covers SIMD (Single Instruction, Multiple Data) optimization strategies for the Zigxels game engine.

## Overview

SIMD allows processing multiple data elements simultaneously, which is ideal for pixel buffer operations. Zig's `@Vector` type provides portable SIMD that compiles to native instructions (SSE, AVX, NEON, etc.).

## When to Use SIMD

### Good Candidates
- **Alpha blending parallax layers** - Process 4-8 pixels at once
- **Gradient generation** - Batch pixel color calculations
- **Color transformations** - Brightness, contrast, tinting
- **Buffer fills and copies** - Already optimized via `@memcpy`/`@memset`

### Already Optimized (No Manual SIMD Needed)
- `@memcpy()` - Used in `restoreBackground()`, already SIMD-optimized
- `@memset()` - Buffer clearing, already SIMD-optimized
- Simple loops with `-Doptimize=ReleaseFast` - Compiler auto-vectorizes

### Not Worth SIMD
- Small entity counts (dozens to hundreds)
- Complex branching logic
- Non-contiguous memory access

## Zig Vector Basics

```zig
// Create a vector of 4 u32 values
const vec: @Vector(4, u32) = .{ 1, 2, 3, 4 };

// Splat a scalar to all lanes
const all_fives = @as(@Vector(4, u32), @splat(5));

// Element-wise operations (automatic SIMD)
const result = vec + all_fives;  // .{ 6, 7, 8, 9 }

// Load from slice
const data: @Vector(4, u32) = slice[i..][0..4].*;

// Store to slice
slice[i..][0..4].* = result;

// Reduction operations
const sum = @reduce(.Add, vec);  // 1 + 2 + 3 + 4 = 10
const all_equal = @reduce(.And, vec == all_fives);  // false
```

## Implementation: SIMD Gradient

The `makeGradientSIMD` function processes 8 pixels at once:

```zig
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
                @intCast(x), @intCast(x + 1), @intCast(x + 2), @intCast(x + 3),
                @intCast(x + 4), @intCast(x + 5), @intCast(x + 6), @intCast(x + 7),
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
```

### Performance Characteristics
- Processes 8 pixels per iteration vs 1 in scalar version
- Eliminates per-pixel index calculations for most pixels
- Cache-friendly sequential memory access
- Scalar cleanup handles non-aligned buffer widths

## Implementation: SIMD Alpha Blending

For parallax layer compositing:

```zig
pub fn blendLayerAlphaSIMD(dst: []u32, src: []const u32) void {
    const simd_width = 4;
    var i: usize = 0;
    
    while (i + simd_width <= dst.len) : (i += simd_width) {
        const src_vec: @Vector(4, u32) = src[i..][0..4].*;
        const dst_vec: @Vector(4, u32) = dst[i..][0..4].*;
        
        const alpha = src_vec & @as(@Vector(4, u32), @splat(0xFF));
        
        // Fast path: fully opaque
        if (@reduce(.And, alpha == @as(@Vector(4, u32), @splat(0xFF)))) {
            dst[i..][0..4].* = src_vec;
            continue;
        }
        
        // Fast path: fully transparent
        if (@reduce(.And, alpha == @as(@Vector(4, u32), @splat(0)))) {
            continue;
        }
        
        dst[i..][0..4].* = blendPixelsVec(dst_vec, src_vec, alpha);
    }
    
    // Scalar cleanup
    while (i < dst.len) : (i += 1) {
        dst[i] = alphaBlendScalar(dst[i], src[i]);
    }
}

fn blendPixelsVec(dst: @Vector(4, u32), src: @Vector(4, u32), alpha: @Vector(4, u32)) @Vector(4, u32) {
    const inv_alpha = @as(@Vector(4, u32), @splat(255)) - alpha;
    
    const src_r = (src >> @splat(24)) & @as(@Vector(4, u32), @splat(0xFF));
    const dst_r = (dst >> @splat(24)) & @as(@Vector(4, u32), @splat(0xFF));
    const out_r = (src_r * alpha + dst_r * inv_alpha) / @as(@Vector(4, u32), @splat(255));
    
    const src_g = (src >> @splat(16)) & @as(@Vector(4, u32), @splat(0xFF));
    const dst_g = (dst >> @splat(16)) & @as(@Vector(4, u32), @splat(0xFF));
    const out_g = (src_g * alpha + dst_g * inv_alpha) / @as(@Vector(4, u32), @splat(255));
    
    const src_b = (src >> @splat(8)) & @as(@Vector(4, u32), @splat(0xFF));
    const dst_b = (dst >> @splat(8)) & @as(@Vector(4, u32), @splat(0xFF));
    const out_b = (src_b * alpha + dst_b * inv_alpha) / @as(@Vector(4, u32), @splat(255));
    
    return (out_r << @splat(24)) | (out_g << @splat(16)) | (out_b << @splat(8)) | alpha;
}
```

## Build Optimization

Always build with optimizations enabled to get full SIMD benefits:

```bash
# Release build with full optimizations
zig build -Doptimize=ReleaseFast

# Release with safety checks (good for testing)
zig build -Doptimize=ReleaseSafe
```

## Profiling Tips

1. **Measure before optimizing** - Use `std.time.Timer` or external profilers
2. **Compare SIMD vs scalar** - Keep both implementations for A/B testing
3. **Check generated assembly** - Use `zig build -Doptimize=ReleaseFast --verbose-llvm-ir`
4. **Memory bandwidth is often the limit** - SIMD helps CPU, not memory

## Future Enhancements

- [ ] SIMD rectangle/box filling
- [ ] SIMD color space conversions (HSV, etc.)
- [ ] SIMD noise generation for procedural backgrounds
- [ ] Platform-specific intrinsics for maximum performance
