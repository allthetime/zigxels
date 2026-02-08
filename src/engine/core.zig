const std = @import("std");
const SDL = @import("sdl2");
const ecs = @import("zflecs");
const gl = @import("gl.zig");
const ShaderPipeline = @import("shaders.zig").ShaderPipeline;
pub const Effect = @import("effects.zig").Effect;

pub const Engine = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    arena: std.heap.ArenaAllocator,
    window: SDL.Window,
    gl_context: SDL.gl.Context,

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

    pub fn init(width: usize, height: usize) !Engine {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();

        // Initialize SDL
        try SDL.init(.{
            .audio = true,
            .events = true,
            .video = true,
            .timer = true,
            .game_controller = true,
        });
        _ = try SDL.showCursor(false);

        // Request OpenGL 3.3 Core
        try SDL.gl.setAttribute(.{ .context_major_version = 3 });
        try SDL.gl.setAttribute(.{ .context_minor_version = 3 });
        try SDL.gl.setAttribute(.{ .context_profile_mask = .core });
        try SDL.gl.setAttribute(.{ .doublebuffer = true });

        const window = try SDL.createWindow(
            "PIXELS",
            .{ .centered = {} },
            .{ .centered = {} },
            width,
            height,
            .{
                .vis = .shown,
                .resizable = true,
                .context = .opengl,
            },
        );

        // Create OpenGL context
        const gl_context = try SDL.gl.createContext(window);
        try gl_context.makeCurrent(window);

        // VSync
        SDL.gl.setSwapInterval(.vsync) catch {};

        // Load OpenGL function pointers
        gl.init();

        // Set viewport
        gl.viewport(0, 0, @intCast(width), @intCast(height));

        // Allocate buffers
        const pixels = try allocator.alloc(u32, width * height);
        const background = try allocator.alloc(u32, width * height);
        const sky = try allocator.alloc(u32, width * height);
        const effects = try allocator.alloc(u16, width * height);
        @memset(effects, 0);

        // Init shader pipeline (compiles shaders, creates textures + quad)
        const shader_pipeline = try ShaderPipeline.init(width, height);

        return Engine{
            .gpa = gpa,
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
        const drawable = SDL.gl.getDrawableSize(self.window);
        gl.viewport(0, 0, @intCast(drawable.w), @intCast(drawable.h));
        self.shader_pipeline.render(self.pixel_buffer, self.effect_buffer, self.time);
    }

    pub fn present(self: *Engine) void {
        SDL.gl.swapWindow(self.window);
    }

    /// Remap window-space mouse coordinates to logical pixel buffer coordinates.
    /// Accounts for window resize (the pixel buffer is a fixed logical resolution
    /// stretched to fill the window).
    pub fn windowToLogical(self: *Engine, wx: i32, wy: i32) struct { x: i32, y: i32 } {
        const win_size = self.window.getSize();
        const win_w: f32 = @floatFromInt(win_size.width);
        const win_h: f32 = @floatFromInt(win_size.height);
        const log_w: f32 = @floatFromInt(self.width);
        const log_h: f32 = @floatFromInt(self.height);

        const lx: i32 = @intFromFloat(@as(f32, @floatFromInt(wx)) * log_w / win_w);
        const ly: i32 = @intFromFloat(@as(f32, @floatFromInt(wy)) * log_h / win_h);
        return .{ .x = lx, .y = ly };
    }

    pub fn deinit(self: *Engine) void {
        const allocator = self.gpa.allocator();
        allocator.free(self.pixel_buffer);
        allocator.free(self.background_buffer);
        allocator.free(self.sky_buffer);
        allocator.free(self.effect_buffer);

        self.shader_pipeline.deinit();
        self.gl_context.delete();
        self.window.destroy();
        SDL.quit();

        self.arena.deinit();
        _ = self.gpa.deinit();
    }
};
