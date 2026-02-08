# OpenGL Shader Renderer

This document describes the hybrid CPU/GPU rendering architecture used in Pixels. The CPU handles simulation and pixel-level drawing, while the GPU applies post-processing effects via OpenGL shaders.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                     CPU (per frame)                      │
│                                                          │
│  ┌────────────────┐     ┌────────────────┐               │
│  │  pixel_buffer   │     │  effect_buffer  │              │
│  │  []u32 (ABGR)   │     │  []u16          │              │
│  │  w * h pixels   │     │  lo=flags hi=α  │              │
│  └───────┬────────┘     └───────┬────────┘               │
│          │                      │                        │
│          │   glTexSubImage2D    │   glTexSubImage2D      │
│          │   (RGBA8)            │   (RG8)                │
└──────────┼──────────────────────┼────────────────────────┘
           ▼                      ▼
┌──────────────────────────────────────────────────────────┐
│                     GPU (per frame)                      │
│                                                          │
│  ┌────────────────┐     ┌────────────────┐               │
│  │  GL_TEXTURE0    │     │  GL_TEXTURE1    │              │
│  │  u_color        │     │  u_effects      │              │
│  │  (sampler2D)    │     │  (sampler2D)    │              │
│  └───────┬────────┘     └───────┬────────┘               │
│          │                      │                        │
│          └──────────┬───────────┘                        │
│                     ▼                                    │
│          ┌────────────────────┐                           │
│          │  Fragment Shader    │                          │
│          │                     │                          │
│          │  for each pixel:    │                          │
│          │    read color       │                          │
│          │    read flags (.r)  │                          │
│          │    read intensity   │                          │
│          │      (.g = alpha)   │                          │
│          │    apply effects    │                          │
│          │      × intensity    │                          │
│          └─────────┬──────────┘                           │
│                    ▼                                     │
│          ┌────────────────────┐                           │
│          │  Fullscreen Quad    │                          │
│          │  → Screen           │                          │
│          └────────────────────┘                           │
└──────────────────────────────────────────────────────────┘
```

## File Structure

| File | Role |
|------|------|
| `src/engine/effects.zig` | `Effect` packed struct — bitflag definitions |
| `src/engine/gl.zig` | Minimal OpenGL 3.3 Core bindings (loaded via SDL) |
| `src/engine/shaders.zig` | `ShaderPipeline` — shader compilation, texture management, fullscreen quad |
| `src/engine/core.zig` | `Engine` — owns buffers, GL context, orchestrates frame rendering |
| `src/engine/pixels.zig` | `drawRect`, `drawEffectOnly`, `drawCursor` — pixel/effect buffer writers |
| `src/game/components.zig` | `EffectZone` tag — marks invisible effect-only entities |

## How It Works

### 1. Effect Buffer

Every pixel has a corresponding `u16` in `effect_buffer`. The low byte holds effect bitflags; the high byte holds intensity (0–255), which controls how strongly the shader applies the effect:

```
  u16 layout (little-endian memory: [low, high])
  ┌────────────────┬────────────────┐
  │ bits 0-7       │ bits 8-15      │
  │ effect flags   │ intensity      │
  │ (packed u8)    │ (0=off, 255=   │
  │                │  full strength)│
  └────────────────┴────────────────┘
```

The flag bits are defined as a packed struct:

```zig
pub const Effect = packed struct(u8) {
    bloom:     bool = false,  // bit 0 — bright additive glow
    blur:      bool = false,  // bit 1 — gaussian blur
    distort:   bool = false,  // bit 2 — UV distortion
    glow:      bool = false,  // bit 3 — soft edge glow
    heat:      bool = false,  // bit 4 — heat haze
    chromatic: bool = false,  // bit 5 — chromatic aberration
    dissolve:  bool = false,  // bit 6 — pixel dissolve
    _padding:  u1 = 0,        // bit 7 reserved
};
```

Effects are combinable:
```zig
const fx = Effect.merge(Effect.bloom_only, Effect.glow_only);
```

Packing for the u16 buffer:
```zig
// Full intensity (255) — used by drawRect
const val = effect.toU16();

// Custom intensity (for feathered edges)
const val = effect.withIntensity(128);  // half strength

// Unpacking
const flags = Effect.flagsFromU16(val);
const intensity = Effect.intensityFromU16(val);
```

### Effect as ECS Component

`Effect` is also registered as a Flecs component. The `render_system` does an optional per-entity lookup — entities without the component default to `Effect.none` (fast path, no shader work):

```zig
// Registration:
ecs.COMPONENT(world, Effect);

// Tagging an entity:
_ = ecs.set(world, player, Effect, Effect.glow_only);

// In render_system:
const effect = ecs.get(it.world, ents[i], Effect) orelse &Effect.none;
pixel_mod.drawRect(engine, x, y, w, h, color, effect.*);
```

This keeps `Renderable` clean (just color) and lets you query/filter entities by effect via ECS.

### 2. Drawing

`drawRect` writes to both buffers simultaneously:

```zig
pixel_mod.drawRect(engine, x, y, w, h, color, Effect.bloom_only);
```

This sets the color in `pixel_buffer` and the effect tag in `effect_buffer` for the same pixel region. Both use `@memset` for speed.

`drawEffectOnly` stamps *only* the effect buffer, leaving pixel colors untouched:

```zig
// Hard edges (full intensity everywhere)
pixel_mod.drawEffectOnly(engine, x, y, w, h, Effect.heat_only, 0);

// Feathered edges (intensity fades over 20px at each border)
pixel_mod.drawEffectOnly(engine, x, y, w, h, Effect.heat_only, 20);
```

The `feather` parameter controls how many pixels at each edge linearly ramp from intensity 0 → 255. This creates smooth falloff so effects don't have hard cutoff lines. Flags are merged with `|=` and intensity uses `@max` so overlapping zones keep the strongest value.

#### Effect Zones

Invisible entities that stamp effect flags over an area without drawing any color. Create them with `Position` + `Collider` + `Effect` + `EffectZone` tag (no `Renderable`):

```zig
const zone = ecs.new_id(world);
ecs.add(world, zone, components.EffectZone);
_ = ecs.set(world, zone, Position, .{ .x = 400, .y = 200 });
_ = ecs.set(world, zone, Collider, .{ .box = .{ .min = .{ .x = -100, .y = -30 }, .max = .{ .x = 100, .y = 30 } } });
_ = ecs.set(world, zone, Effect, Effect.heat_only);
```

The `effect_zone_system` runs at `OnStore` and calls `drawEffectOnly` with `feather=20` for each zone entity.

**Spread pattern**: To make effects like bloom/glow radiate beyond a visible entity, create an effect zone with a collider larger than the entity's visual rect. The overflow region stamps effect flags with feathered intensity — the shader applies the effect at decreasing strength toward the edges. This replaces the old GPU-side neighbor probing (`nearbyEffect1D`) with full CPU-side control over spread shape and size.

### 3. GPU Upload

Each frame, `Engine.renderFrame()` uploads both buffers as GL textures:

- `pixel_buffer` → `GL_TEXTURE0` (RGBA8, 4 bytes/pixel, uploaded as `GL_RGBA`)
- `effect_buffer` → `GL_TEXTURE1` (RG8, 2 bytes/pixel — R=flags, G=intensity)

Upload uses `glTexSubImage2D` — only the pixel data changes, the texture objects persist.

The u16 layout maps naturally to `GL_RG + GL_UNSIGNED_BYTE`: on little-endian, the low byte (flags) becomes the R channel and the high byte (intensity) becomes the G channel.

#### Color Byte Order

`packColor` packs into **ABGR bit order** in the u32 (`A<<24 | B<<16 | G<<8 | R`). On little-endian this gives memory bytes `[R, G, B, A]`, which is exactly what `GL_RGBA + GL_UNSIGNED_BYTE` reads. The gradient SIMD code follows the same convention.

### 4. Fragment Shader

The shader runs once per screen pixel. It reads both channels from the effect texture:

```glsl
vec2 efx = texture(u_effects, TexCoord).rg;
float effects = efx.r * 255.0;   // bitflags
float intensity = efx.g;          // 0.0 - 1.0 (feathered alpha)
```

If the effect byte is 0, it outputs the color directly (early out — no texture reads beyond the initial two). Otherwise, it checks each bit and applies the corresponding effect, **modulated by intensity**. At feathered edges (low intensity) effects gently fade; at the center (intensity = 1.0) they're full strength.

All effect spread is handled on the CPU via effect zones with feathered `drawEffectOnly`. The shader does no neighbor probing — it only reads the current pixel's flags and intensity.

| Bit | Flag | Effect | Technique |
|-----|------|--------|-----------|
| 0 | `bloom` | Bright additive glow | Separable gaussian blur × intensity |
| 1 | `blur` | Soft blur | Separable gaussian blur, mix by intensity |
| 2 | `distort` | UV wobble | Sine/cosine UV offset × intensity |
| 3 | `glow` | Soft edge emission | Wide blur composited via `max()` × intensity |
| 4 | `heat` | Heat haze | Layered sine wave distortion + warm tint × intensity |
| 5 | `chromatic` | Chromatic aberration | RGB channel split, strength × intensity |
| 6 | `dissolve` | Pixel dissolve | Noise threshold fade-out × intensity |

### 5. Fullscreen Quad

The vertex shader draws a fullscreen quad (2 triangles, 6 vertices) that covers clip space `(-1,-1)` to `(1,1)`. The fragment shader does all the work.

## OpenGL Bindings

`gl.zig` is a hand-written minimal binding. It loads ~30 GL function pointers via `SDL.gl.getProcAddress` at startup. No external OpenGL library is needed.

Only GL 3.3 Core functions are used:
- Textures: `genTextures`, `bindTexture`, `texImage2D`, `texSubImage2D`, `activeTexture`
- Shaders: `createShader`, `shaderSource`, `compileShader`, `createProgram`, `linkProgram`
- Geometry: `genVertexArrays`, `genBuffers`, `bufferData`, `vertexAttribPointer`, `drawArrays`
- Uniforms: `getUniformLocation`, `uniform1i`, `uniform1f`, `uniform2f`

## Frame Lifecycle

```
1. input.update()
   - SDL_PollEvent for mouse, keyboard, controller
   - Mouse coords remapped: windowToLogical(wx, wy)
     (window space → logical pixel buffer space)

2. engine.restoreBackground()
   - memcpy background_buffer → pixel_buffer
   - memset effect_buffer → 0

3. ecs.progress(world, dt)
   - render_system: per-entity Effect lookup via ECS → drawRect
   - effect_zone_system: invisible zones → drawEffectOnly
   - Explosions: drawRect with merged effects

4. Cursor + Debug draw
   - drawCursor → pixel_buffer (crosshair at logical mouse coords)
   - debug_draw_colliders → pixel_buffer (Bresenham lines)

5. engine.renderFrame(dt)
   - Query SDL.gl.getDrawableSize for actual window pixels
   - glViewport(0, 0, drawable.w, drawable.h)
   - Upload pixel_buffer → GL_TEXTURE0 (GL_RGBA)
   - Upload effect_buffer → GL_TEXTURE1 (RG8, flags+intensity)
   - Set uniforms (resolution, time)
   - Draw fullscreen quad → fills entire viewport

6. engine.present()
   - SDL_GL_SwapWindow
```

## Current Effect Usage

| Entity Type | Effect | How Applied |
|-------------|--------|-------------|
| Ground tiles | `Effect.none` | No ECS component |
| Player | configurable | ECS `Effect` component (optional) |
| Bullets | `Effect.none` | No ECS component |
| Explosion particles | `bloom + heat + blur` | Hardcoded in `explosion_system` via `drawRect` |
| Tail segments | `Effect.none` | Candidate for `Effect.glow_only` via ECS |
| Effect zones | any | `EffectZone` tag + `Effect` component → `drawEffectOnly` (feather=20) |
| Cursor | N/A (no effects) | `drawCursor` writes directly to pixel_buffer |

## Window Resize

The window is created with `resizable = true`. The pixel buffer stays at a **fixed logical resolution** (e.g. 1280×720) regardless of window size — the fullscreen quad stretches to fill whatever the viewport is.

**Viewport**: `renderFrame()` calls `SDL.gl.getDrawableSize()` each frame (not the window's logical size — on Retina displays drawable pixels ≠ window points) and passes that to `glViewport`. This means the quad always fills the window.

**Mouse remapping**: SDL mouse events report window-space coordinates. `Engine.windowToLogical()` scales them to the pixel buffer's logical resolution:

```zig
const logical = engine.windowToLogical(input.mouse_x, input.mouse_y);
input.mouse_x = logical.x;
input.mouse_y = logical.y;
```

This runs after `input.update()` and before the coords are used for shooting, cursor drawing, etc.

**Note**: The current implementation does a simple stretch (no letterboxing). If the window aspect ratio differs from the pixel buffer's, the image will be slightly distorted. To add letterboxing, compute the largest centered rect that maintains aspect ratio and pass that to `glViewport` instead.

## Debug Mode

Debug collider rendering draws directly into `pixel_buffer` using Bresenham line drawing — no SDL renderer needed. Lines appear in the pixel buffer before GPU upload, so they render correctly through the shader pipeline. Toggle with the debug key.

## Adding New Effects

1. Add a bit to `Effect` in `effects.zig` (1 reserved padding bit remains — bit 7)
2. Add the corresponding `const float BIT_XXX` in the fragment shader
3. Add a `hasFlag` check + effect implementation in the shader's `main()`, multiply by `intensity`
4. To apply per-entity: `ecs.set(world, entity, Effect, Effect.xxx_only)`
5. To apply per-draw-call: pass directly to `drawRect(..., Effect.xxx_only)`
6. For soft spread: create an `EffectZone` entity with a larger collider + feathered edges







say i wanted to make a character that had the heat effect but I didnt want an ugly box around them. could I render a completely different layer/buffer that had (a) character sprite, transparent background (b) effect on everything and then i can place that on top of everything else so that its effects don't alter anything else?

Yes — that's essentially a compositing layer and it fits naturally into what you already have. Here's the concept:

Per-Entity Effect Layers
Instead of one global effect buffer, certain entities get their own mini render target:

The shader processes Layer 1 independently (heat distorts everything in that small texture), then alpha-blends the result onto the main framebuffer. The heat never touches the world underneath — it only warps the character's own pixels and the transparent area around them, which creates a natural silhouette haze.

How it would work concretely
The heat distortion warps the transparent pixels too, pulling in neighboring character pixels — that's what gives you the organic shimmer around the silhouette instead of a box.

But — you don't need this yet
For your current scale, there's a simpler approach that gets you 80% of the way:

Use a circular effect zone attached to the entity
With your feathering, the edges fade out smoothly. Yes it's technically a box, but with a 20px feather on a 50×50 zone, the visible heat is concentrated in the center and fades before the edges are apparent — especially since heat is a distortion effect, not a color overlay.

When to actually build the layer system
When you have:

Actual character sprites (not solid-color rects)
Multiple characters with different effects that shouldn't bleed into each other
Effects that need to wrap around a non-rectangular silhouette
At that point you'd add a RenderLayer component, sort entities by layer, and render each layer to its own FBO with its own effect pass. But that's a meaningful architectural step — don't build it until the simpler approach fails visually.

TL;DR: Attach a feathered EffectZone as a child entity for now. Build the FBO compositing layer system when you have real sprites and the box feathering isn't cutting it.