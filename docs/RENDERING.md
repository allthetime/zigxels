# Rendering Abstraction Layer

This document outlines a pluggable rendering backend system that allows switching between different graphics libraries (SDL2, RayLib, GLFW+OpenGL) without duplicating game logic.

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│            Game Systems (ECS)                   │
│         (systems.zig, components.zig)           │
├─────────────────────────────────────────────────┤
│           Renderer Interface                    │
│              (renderer.zig)                     │
├───────────────┬───────────────┬─────────────────┤
│     SDL2      │    RayLib     │   GLFW+OpenGL   │
│    Backend    │    Backend    │     Backend     │
└───────────────┴───────────────┴─────────────────┘
```

## Renderer Interface

The core abstraction is a VTable-based interface that all backends implement:

```zig
// src/engine/renderer.zig
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fillRect: *const fn (ptr: *anyopaque, rect: Rect, color: Color) void,
        drawPixel: *const fn (ptr: *anyopaque, x: i32, y: i32, color: Color) void,
        drawPixelBuffer: *const fn (ptr: *anyopaque, buffer: []const u32, width: u32, height: u32) void,
        present: *const fn (ptr: *anyopaque) void,
        clear: *const fn (ptr: *anyopaque) void,
        getWidth: *const fn (ptr: *anyopaque) u32,
        getHeight: *const fn (ptr: *anyopaque) u32,
    };

    // Convenience methods that dispatch to vtable
    pub fn fillRect(self: Renderer, rect: Rect, color: Color) void {
        self.vtable.fillRect(self.ptr, rect, color);
    }

    pub fn drawPixel(self: Renderer, x: i32, y: i32, color: Color) void {
        self.vtable.drawPixel(self.ptr, x, y, color);
    }

    pub fn drawPixelBuffer(self: Renderer, buffer: []const u32, width: u32, height: u32) void {
        self.vtable.drawPixelBuffer(self.ptr, buffer, width, height);
    }

    pub fn present(self: Renderer) void {
        self.vtable.present(self.ptr);
    }

    pub fn clear(self: Renderer) void {
        self.vtable.clear(self.ptr);
    }
};
```

## Backend Implementations

### Directory Structure

```
src/engine/
├── renderer.zig           # Interface definition
├── backends/
│   ├── sdl2_renderer.zig  # Current SDL2 implementation
│   ├── raylib_renderer.zig
│   └── glfw_opengl_renderer.zig
```

### SDL2 Backend (Current)

The existing SDL2 code would be refactored into this backend. It uses SDL2's software renderer and texture streaming.

**Pros:**
- Already implemented
- Good cross-platform support
- Direct pixel buffer access (good for SIMD operations in `pixels.zig`)

**Cons:**
- Software rendering can be slower for complex scenes
- Limited shader support

### RayLib Backend

RayLib provides a higher-level API with built-in primitives.

**Pros:**
- Very simple API
- Built-in 3D support
- Good for rapid prototyping
- Active community

**Cons:**
- Less low-level control
- Would need custom texture for pixel buffer operations

```zig
// Example: raylib_renderer.zig
const rl = @import("raylib");

fn fillRect(ptr: *anyopaque, rect: Rect, color: Color) void {
    _ = ptr;
    rl.drawRectangle(rect.x, rect.y, rect.width, rect.height, .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
    });
}
```

---

## GLFW + OpenGL Backend

GLFW handles window creation and input, while OpenGL provides hardware-accelerated rendering with full shader support.

### Why GLFW + OpenGL?

**GLFW** is a lightweight library for:
- Window and OpenGL context creation
- Input handling (keyboard, mouse, gamepad)
- Cross-platform support (Windows, macOS, Linux)

**OpenGL** provides:
- Hardware acceleration
- Shader support (GLSL)
- Fine-grained control over the graphics pipeline
- Efficient batch rendering

### Considerations

**Pros:**
- Full GPU acceleration
- Maximum control over rendering pipeline
- Shaders for effects (blur, lighting, post-processing)
- Well-documented, widely used
- GLFW is minimal and focused

**Cons:**
- More complex setup than SDL2 or RayLib
- Need to manage OpenGL state carefully
- Different OpenGL versions have different APIs (recommend 3.3 Core for compatibility)
- Requires writing/loading shaders

### Implementation Approach

For this project's pixel-based rendering, OpenGL works well with texture streaming:

```zig
// glfw_opengl_renderer.zig
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
    @cInclude("glad/glad.h");  // or use zgl bindings
});

pub const GLFWOpenGLRenderer = struct {
    window: *c.GLFWwindow,
    texture_id: c.GLuint,
    shader_program: c.GLuint,
    quad_vao: c.GLuint,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32, title: [*:0]const u8) !GLFWOpenGLRenderer {
        if (c.glfwInit() == 0) return error.GLFWInitFailed;
        
        // Request OpenGL 3.3 Core
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
        c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
        c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE); // Required on macOS
        
        const window = c.glfwCreateWindow(@intCast(width), @intCast(height), title, null, null)
            orelse return error.WindowCreationFailed;
        c.glfwMakeContextCurrent(window);
        
        // Load OpenGL functions (via glad or similar)
        // Setup texture, shaders, VAO for fullscreen quad...
        
        return .{ .window = window, .width = width, .height = height, ... };
    }

    pub fn deinit(self: *GLFWOpenGLRenderer) void {
        c.glfwDestroyWindow(self.window);
        c.glfwTerminate();
    }
};

fn drawPixelBuffer(ptr: *anyopaque, buffer: []const u32, width: u32, height: u32) void {
    const self: *GLFWOpenGLRenderer = @ptrCast(@alignCast(ptr));
    
    // Update texture with pixel data from CPU buffer
    c.glBindTexture(c.GL_TEXTURE_2D, self.texture_id);
    c.glTexSubImage2D(
        c.GL_TEXTURE_2D, 0, 0, 0, 
        @intCast(width), @intCast(height), 
        c.GL_RGBA, c.GL_UNSIGNED_BYTE, 
        buffer.ptr
    );
    
    // Draw fullscreen quad with texture
    c.glUseProgram(self.shader_program);
    c.glBindVertexArray(self.quad_vao);
    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
}

fn present(ptr: *anyopaque) void {
    const self: *GLFWOpenGLRenderer = @ptrCast(@alignCast(ptr));
    c.glfwSwapBuffers(self.window);
    c.glfwPollEvents();
}
```

### Basic Shaders for Pixel Buffer Display

```glsl
// vertex.glsl
#version 330 core
layout (location = 0) in vec2 aPos;
layout (location = 1) in vec2 aTexCoord;
out vec2 TexCoord;

void main() {
    gl_Position = vec4(aPos, 0.0, 1.0);
    TexCoord = aTexCoord;
}

// fragment.glsl  
#version 330 core
in vec2 TexCoord;
out vec4 FragColor;
uniform sampler2D screenTexture;

void main() {
    FragColor = texture(screenTexture, TexCoord);
}
```

### Zig Bindings Options

| Library | Description |
|---------|-------------|
| **zglfw** | Part of zig-gamedev, idiomatic Zig bindings for GLFW |
| **zgl** | Part of zig-gamedev, OpenGL bindings |
| **mach-glfw** | Zig bindings from the Mach engine project |
| **@cImport** | Direct C interop with GLFW/OpenGL headers |

Recommended: Use **zig-gamedev** packages (zglfw + zgl) for the cleanest integration.

```zig
// build.zig.zon - add zig-gamedev dependencies
.dependencies = .{
    .zglfw = .{
        .url = "https://github.com/zig-gamedev/zglfw/archive/...",
    },
    .zgl = .{
        .url = "https://github.com/zig-gamedev/zgl/archive/...",
    },
},
```

### Input Handling with GLFW

GLFW provides its own input system, so the `InputState` would need a GLFW-specific implementation:

```zig
// Callback-based input
fn keyCallback(window: *c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = window; _ = scancode; _ = mods;
    const input = getInputState();
    const pressed = action != c.GLFW_RELEASE;
    
    switch (key) {
        c.GLFW_KEY_W, c.GLFW_KEY_UP => input.pressed_directions.up = pressed,
        c.GLFW_KEY_S, c.GLFW_KEY_DOWN => input.pressed_directions.down = pressed,
        c.GLFW_KEY_A, c.GLFW_KEY_LEFT => input.pressed_directions.left = pressed,
        c.GLFW_KEY_D, c.GLFW_KEY_RIGHT => input.pressed_directions.right = pressed,
        else => {},
    }
}

// Register callback
c.glfwSetKeyCallback(window, keyCallback);
```

---

## Build-Time Backend Selection

Use Zig's build system to select the backend at compile time:

```zig
// build.zig
const Backend = enum { sdl2, raylib, glfw_opengl };

const backend = b.option(Backend, "renderer", "Rendering backend") orelse .sdl2;

const backend_module = switch (backend) {
    .sdl2 => b.addModule("renderer_backend", .{ .root_source_file = b.path("src/engine/backends/sdl2_renderer.zig") }),
    .raylib => b.addModule("renderer_backend", .{ .root_source_file = b.path("src/engine/backends/raylib_renderer.zig") }),
    .glfw_opengl => b.addModule("renderer_backend", .{ .root_source_file = b.path("src/engine/backends/glfw_opengl_renderer.zig") }),
};

exe.root_module.addImport("renderer_backend", backend_module);
```

Build commands:
```bash
zig build                          # SDL2 (default)
zig build -Drenderer=raylib        # RayLib
zig build -Drenderer=glfw_opengl   # GLFW + OpenGL
```

---

## Migration Path

### Phase 1: Extract Interface
1. Create `renderer.zig` with the abstract interface
2. Refactor current SDL2 code into `backends/sdl2_renderer.zig`
3. Update `Engine` to use the abstract `Renderer`
4. Update systems to use the interface instead of direct SDL calls

### Phase 2: Add Alternative Backends
1. Implement RayLib backend for comparison
2. Test both backends work correctly
3. Document any API limitations

### Phase 3: Hardware Acceleration (Optional)
1. Add GLFW + OpenGL backend for GPU-accelerated rendering
2. Optimize pixel buffer operations with texture streaming
3. Consider compute shaders for SIMD-like operations on GPU
4. Add post-processing shader effects

---

## Pixel Buffer Compatibility

The current SIMD operations in `pixels.zig` work with a CPU-side pixel buffer. Each backend needs to handle this:

| Backend      | Pixel Buffer Approach |
|--------------|----------------------|
| SDL2         | `SDL_UpdateTexture` (current) |
| RayLib       | `UpdateTexture` with `Image` |
| GLFW+OpenGL  | `glTexSubImage2D` to stream pixels |

The SIMD code remains unchanged—only the final "upload to GPU" step differs per backend.

---

## Comparison Summary

| Feature | SDL2 | RayLib | GLFW+OpenGL |
|---------|------|--------|-------------|
| Setup Complexity | Low | Very Low | Medium |
| GPU Acceleration | Optional | Yes | Yes |
| Shader Support | Limited | Built-in | Full GLSL |
| Pixel Buffer Control | Excellent | Good | Excellent |
| Input Handling | Built-in | Built-in | Built-in (GLFW) |
| Learning Curve | Low | Very Low | Medium-High |
| Best For | Current setup | Rapid prototyping | Advanced effects |
