const std = @import("std");
const sdl = @import("sdl3");
const ecs = @import("zflecs");
const gl = @import("gl.zig");
const ShaderPipeline = @import("shaders.zig").ShaderPipeline;
pub const Effect = @import("effects.zig").Effect;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *sdl.SDL_Window,
    gl_context: sdl.SDL_GLContext,

    // Pixel layer
    pixel_buffer: []u32,
    background_buffer: []u32,
    sky_buffer: []u32,
    effect_buffer: []u16,
    width: usize,
    height: usize,

    // GL rendering
    shader_pipeline: ShaderPipeline,
    time: f32,

    pub fn getEngine(world: *ecs.world_t) *Engine {
        return @as(*Engine, @ptrCast(@alignCast(ecs.get_ctx(world).?)));
    }

    pub fn getTicksMs() u64 {
        return sdl.SDL_GetTicks();
    }

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Engine {
        if (!sdl.SDL_Init(sdl.SDL_INIT_AUDIO | sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS | sdl.SDL_INIT_GAMEPAD)) {
            std.log.err("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
            return error.SDLInitFailed;
        }
        errdefer sdl.SDL_Quit();

        _ = sdl.SDL_HideCursor();

        // Request OpenGL 3.3 Core
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, 3);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 1);

        const window = sdl.SDL_CreateWindow(
            "PIXELS",
            @intCast(width),
            @intCast(height),
            sdl.SDL_WINDOW_OPENGL | sdl.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
            return error.WindowCreationFailed;
        };
        errdefer sdl.SDL_DestroyWindow(window);

        const gl_context = sdl.SDL_GL_CreateContext(window) orelse {
            std.log.err("SDL_GL_CreateContext failed: {s}", .{sdl.SDL_GetError()});
            return error.GLContextCreationFailed;
        };
        errdefer _ = sdl.SDL_GL_DestroyContext(gl_context);

        if (!sdl.SDL_GL_MakeCurrent(window, gl_context)) {
            std.log.err("SDL_GL_MakeCurrent failed: {s}", .{sdl.SDL_GetError()});
            return error.GLMakeCurrentFailed;
        }

        // VSync
        _ = sdl.SDL_GL_SetSwapInterval(1);

        // Load OpenGL function pointers
        gl.init();

        // Set viewport
        gl.viewport(0, 0, @intCast(width), @intCast(height));

        // Allocate buffers
        const pixels = try allocator.alloc(u32, width * height);
        errdefer allocator.free(pixels);
        const background = try allocator.alloc(u32, width * height);
        errdefer allocator.free(background);
        const sky = try allocator.alloc(u32, width * height);
        errdefer allocator.free(sky);
        const effects = try allocator.alloc(u16, width * height);
        errdefer allocator.free(effects);
        @memset(effects, 0);

        // Init shader pipeline (compiles shaders, creates textures + quad)
        const shader_pipeline = try ShaderPipeline.init(width, height);

        return Engine{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .window = window,
            .gl_context = gl_context,
            .pixel_buffer = pixels,
            .background_buffer = background,
            .sky_buffer = sky,
            .effect_buffer = effects,
            .width = width,
            .height = height,
            .shader_pipeline = shader_pipeline,
            .time = 0.0,
        };
    }

    pub fn beginFrame(self: *Engine) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn restoreBackground(self: *Engine) void {
        @memcpy(self.pixel_buffer, self.background_buffer);
        @memset(self.effect_buffer, 0);
    }

    /// Upload pixel + effect buffers to GPU and render via shader pipeline
    pub fn renderFrame(self: *Engine, dt: f32) void {
        self.time += dt;
        // Use actual drawable size so the quad scales to fill the window on resize
        var drawable_w: c_int = 0;
        var drawable_h: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(self.window, &drawable_w, &drawable_h);
        if (drawable_w > 0 and drawable_h > 0) {
            gl.viewport(0, 0, drawable_w, drawable_h);
        }
        self.shader_pipeline.render(self.pixel_buffer, self.effect_buffer, self.time);
    }

    /// Swap the OpenGL backbuffer to the front for display
    pub fn present(self: *Engine) void {
        _ = sdl.SDL_GL_SwapWindow(self.window);
    }

    /// Remap window-space mouse coordinates to logical pixel buffer coordinates.
    /// Accounts for window resize (the pixel buffer is a fixed logical resolution
    /// stretched to fill the window).
    pub fn windowToLogical(self: *Engine, wx: f32, wy: f32) struct { x: i32, y: i32 } {
        var win_w_int: c_int = 0;
        var win_h_int: c_int = 0;
        _ = sdl.SDL_GetWindowSize(self.window, &win_w_int, &win_h_int);
        if (win_w_int <= 0 or win_h_int <= 0) {
            return .{ .x = 0, .y = 0 };
        }

        const win_w: f32 = @floatFromInt(win_w_int);
        const win_h: f32 = @floatFromInt(win_h_int);
        const log_w: f32 = @floatFromInt(self.width);
        const log_h: f32 = @floatFromInt(self.height);

        const lx: i32 = @intFromFloat(wx * log_w / win_w);
        const ly: i32 = @intFromFloat(wy * log_h / win_h);
        return .{ .x = lx, .y = ly };
    }

    pub fn deinit(self: *Engine) void {
        self.allocator.free(self.pixel_buffer);
        self.allocator.free(self.background_buffer);
        self.allocator.free(self.sky_buffer);
        self.allocator.free(self.effect_buffer);

        self.shader_pipeline.deinit();
        _ = sdl.SDL_GL_DestroyContext(self.gl_context);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();

        self.arena.deinit();
    }
};
