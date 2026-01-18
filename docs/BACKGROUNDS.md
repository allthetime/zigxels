# Background System Documentation

This document outlines the efficient background rendering system for the Zigxels game engine, including static backgrounds, background switching, scrolling backgrounds, and parallax effects.

## Core Background System

The background system uses pre-computed pixel buffers and fast memory operations instead of real-time pixel calculations for optimal performance.

### Basic Architecture

```zig
pub const Engine = struct {
    pixel_buffer: []u32,        // Working buffer (what gets rendered)
    background_buffer: []u32,   // Static background storage
    // ... other fields
};
```

### Performance Benefits
- **~100x faster** than recalculating gradients every frame
- Uses `@memcpy()` instead of math operations
- Memory bandwidth limited, not CPU limited
- Cache-friendly sequential access patterns

## Static Background Switching

### Implementation

```zig
// Add multiple background buffers to Engine
pub const Engine = struct {
    background_buffer: []u32,
    gradient_background: []u32,
    starfield_background: []u32,
    cave_background: []u32,
    current_background: []u32,  // Points to active background
    
    pub fn setBackground(self: *Engine, background_type: BackgroundType) void {
        switch (background_type) {
            .gradient => self.current_background = self.gradient_background,
            .starfield => self.current_background = self.starfield_background,
            .cave => self.current_background = self.cave_background,
        }
    }

    pub fn restoreBackground(self: *Engine) void {
        @memcpy(self.pixel_buffer, self.current_background);
    }
};

pub const BackgroundType = enum {
    gradient,
    starfield,
    cave,
};
```

### Usage

```zig
// Initialize different backgrounds once at startup
generateGradientBackground(engine.gradient_background, width, height);
generateStarfieldBackground(engine.starfield_background, width, height);
generateCaveBackground(engine.cave_background, width, height);

// Switch backgrounds during gameplay
engine.setBackground(.starfield);  // Now using starfield
```

## Scrolling Backgrounds

### Large Buffer Approach

Create backgrounds wider than the screen and scroll through them by copying different portions.

```zig
pub const Engine = struct {
    // ... existing fields ...
    large_background: []u32,    // HEIGHT × (WIDTH × scroll_factor)
    scroll_offset_x: f32,
    scroll_factor: usize,       // How many screens wide (e.g., 10)
    
    pub fn initScrollingBackground(self: *Engine, scroll_factor: usize) !void {
        self.scroll_factor = scroll_factor;
        const large_width = self.width * scroll_factor;
        self.large_background = try allocator.alloc(u32, self.height * large_width);
        
        // Generate your large background once
        generateLargeBackground(self.large_background, large_width, self.height);
    }

    pub fn restoreScrollingBackground(self: *Engine) void {
        const large_width = self.width * self.scroll_factor;
        const max_offset = large_width - self.width;
        const offset_pixels = @min(@as(usize, @intFromFloat(self.scroll_offset_x)), max_offset);
        
        // Copy the visible portion row by row
        for (0..self.height) |y| {
            const src_start = y * large_width + offset_pixels;
            const dst_start = y * self.width;
            
            @memcpy(
                self.pixel_buffer[dst_start..dst_start + self.width],
                self.large_background[src_start..src_start + self.width]
            );
        }
    }

    pub fn updateScroll(self: *Engine, camera_x: f32, world_width: f32) void {
        // Scroll based on camera/player position
        const scroll_ratio = camera_x / world_width;
        const max_scroll = @as(f32, @floatFromInt(self.width * (self.scroll_factor - 1)));
        self.scroll_offset_x = scroll_ratio * max_scroll;
    }
};
```

### Seamless Wrapping

For infinite scrolling, use modulo arithmetic:

```zig
pub fn restoreWrappingBackground(self: *Engine) void {
    const large_width = self.width * self.scroll_factor;
    const offset_pixels = @as(usize, @intFromFloat(self.scroll_offset_x)) % large_width;
    
    for (0..self.height) |y| {
        const src_start = y * large_width;
        const dst_start = y * self.width;
        
        // Handle wrapping at buffer edge
        if (offset_pixels + self.width <= large_width) {
            // Simple case: no wrapping needed
            @memcpy(
                self.pixel_buffer[dst_start..dst_start + self.width],
                self.large_background[src_start + offset_pixels..src_start + offset_pixels + self.width]
            );
        } else {
            // Wrapping case: copy in two parts
            const first_part = large_width - offset_pixels;
            const second_part = self.width - first_part;
            
            @memcpy(
                self.pixel_buffer[dst_start..dst_start + first_part],
                self.large_background[src_start + offset_pixels..src_start + large_width]
            );
            @memcpy(
                self.pixel_buffer[dst_start + first_part..dst_start + self.width],
                self.large_background[src_start..src_start + second_part]
            );
        }
    }
}
```

## Parallax Scrolling

### Multi-Layer System

Different background layers scroll at different speeds to create depth perception.

```zig
pub const ParallaxLayer = struct {
    buffer: []u32,
    scroll_speed: f32,    // 0.0 = static, 1.0 = moves with camera
    offset_x: f32,
    blend_mode: BlendMode,
};

pub const BlendMode = enum {
    replace,    // Overwrite pixels
    alpha,      // Alpha blend
    multiply,   // Darken
    screen,     // Lighten
};

pub const Engine = struct {
    // ... existing fields ...
    parallax_layers: []ParallaxLayer,
    
    pub fn restoreParallaxBackground(self: *Engine, camera_x: f32) void {
        // Start with a clear buffer or base layer
        @memset(self.pixel_buffer, 0x000000FF); // Black background
        
        // Render each layer back-to-front
        for (self.parallax_layers) |*layer| {
            // Update layer offset based on camera and scroll speed
            layer.offset_x = camera_x * layer.scroll_speed;
            
            // Render this layer
            switch (layer.blend_mode) {
                .replace => copyLayer(self.pixel_buffer, layer),
                .alpha => blendLayerAlpha(self.pixel_buffer, layer),
                .multiply => blendLayerMultiply(self.pixel_buffer, layer),
                .screen => blendLayerScreen(self.pixel_buffer, layer),
            }
        }
    }
};
```

### Layer Blending Functions

```zig
fn copyLayer(dst: []u32, layer: *ParallaxLayer) void {
    // Simple replacement (for opaque backgrounds)
    const large_width = dst.len * layer.scroll_factor;
    const offset = @as(usize, @intFromFloat(layer.offset_x)) % large_width;
    
    // Copy logic similar to restoreWrappingBackground
    // ... implementation details ...
}

fn blendLayerAlpha(dst: []u32, layer: *ParallaxLayer) void {
    // Alpha blending for semi-transparent layers
    for (dst, 0..) |*pixel, i| {
        const src_pixel = getLayerPixel(layer, i);
        *pixel = alphaBlend(*pixel, src_pixel);
    }
}

fn alphaBlend(dst: u32, src: u32) u32 {
    // Extract RGBA components and blend
    const src_a = src & 0xFF;
    if (src_a == 0) return dst;
    if (src_a == 255) return src;
    
    // Proper alpha blending math
    // ... implementation details ...
}
```

## Example Usage Patterns

### Level-Based Background Switching

```zig
fn enterLevel(engine: *Engine, level: Level) void {
    switch (level.biome) {
        .forest => engine.setBackground(.gradient),
        .space => engine.setBackground(.starfield),
        .underground => engine.setBackground(.cave),
    }
}
```

### Parallax Setup for Side-Scrolling Game

```zig
fn initParallax(engine: *Engine) !void {
    engine.parallax_layers = try allocator.alloc(ParallaxLayer, 4);
    
    // Layer 0: Far mountains (very slow)
    engine.parallax_layers[0] = ParallaxLayer{
        .buffer = try allocator.alloc(u32, height * width * 3),
        .scroll_speed = 0.1,
        .blend_mode = .replace,
        .offset_x = 0,
    };
    generateMountains(engine.parallax_layers[0].buffer);
    
    // Layer 1: Mid-distance trees (slow)
    engine.parallax_layers[1] = ParallaxLayer{
        .buffer = try allocator.alloc(u32, height * width * 4),
        .scroll_speed = 0.3,
        .blend_mode = .alpha,
        .offset_x = 0,
    };
    generateTrees(engine.parallax_layers[1].buffer);
    
    // Layer 2: Foreground bushes (medium)
    engine.parallax_layers[2] = ParallaxLayer{
        .buffer = try allocator.alloc(u32, height * width * 6),
        .scroll_speed = 0.7,
        .blend_mode = .alpha,
        .offset_x = 0,
    };
    generateBushes(engine.parallax_layers[2].buffer);
    
    // Layer 3: Ground details (fast, matches gameplay)
    engine.parallax_layers[3] = ParallaxLayer{
        .buffer = try allocator.alloc(u32, height * width * 8),
        .scroll_speed = 1.0,
        .blend_mode = .alpha,
        .offset_x = 0,
    };
    generateGroundDetails(engine.parallax_layers[3].buffer);
}
```

## Performance Considerations

### Memory Usage
- Large backgrounds use significant RAM
- 640×480 × 10 screens = ~12MB per background layer
- Consider using compressed formats for storage
- Stream in background sections for very large worlds

### Optimization Tips
1. **Pre-compute everything** at load time, not runtime
2. **Use power-of-2 dimensions** when possible for better cache alignment
3. **Limit parallax layers** to 3-4 for optimal performance
4. **Consider LOD** (Level of Detail) for distant layers
5. **Profile memory bandwidth** - this is usually the bottleneck

### Platform-Specific Optimizations
- **SIMD instructions**: Use vector operations for blending when available
- **GPU upload**: For very complex scenes, consider uploading to GPU textures
- **Streaming**: For mobile platforms, stream background data from storage

## Future Enhancements

### Possible Extensions
1. **Animated backgrounds**: Swap between multiple pre-computed frames
2. **Dynamic backgrounds**: Procedurally modify pre-computed buffers
3. **Depth-based parallax**: Use Z-buffer information for automatic layer speeds
4. **Background physics**: Clouds, water effects using shader-like pixel operations