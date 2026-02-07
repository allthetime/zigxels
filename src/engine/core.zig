const std = @import("std");
const SDL = @import("sdl2");
const ecs = @import("zflecs");

pub const Engine = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    arena: std.heap.ArenaAllocator,
    window: SDL.Window,
    renderer: SDL.Renderer,

    // Pixel layer
    pixel_buffer: []u32,
    background_buffer: []u32,
    sky_buffer: []u32,
    texture: SDL.Texture,
    width: usize,
    height: usize,

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

        const window = try SDL.createWindow(
            "PIXELS",
            .{ .centered = {} },
            .{ .centered = {} },
            width,
            height,
            .{
                .vis = .shown,
            },
        );

        const renderer = try SDL.createRenderer(
            window,
            null,
            .{
                .accelerated = true,
                .present_vsync = true,
            },
        );

        const texture = try SDL.createTexture(
            renderer,
            .rgba8888,
            .streaming,
            width,
            height,
        );

        const pixels = try allocator.alloc(u32, width * height);
        const background = try allocator.alloc(u32, width * height);
        const sky = try allocator.alloc(u32, width * height);

        return Engine{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .window = window,
            .renderer = renderer,
            .pixel_buffer = pixels,
            .background_buffer = background,
            .sky_buffer = sky,
            .texture = texture,
            .width = width,
            .height = height,
        };
    }

    pub fn beginFrame(self: *Engine) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn restoreBackground(self: *Engine) void {
        @memcpy(self.pixel_buffer, self.background_buffer);
    }

    pub fn updateTexture(self: *Engine) !void {
        try self.texture.update(
            std.mem.sliceAsBytes(self.pixel_buffer),
            self.width * @sizeOf(u32), // Pitch (bytes per row)
            .{
                .x = 0,
                .y = 0,
                .width = @intCast(self.width),
                .height = @intCast(self.height),
            },
        );
        try self.renderer.copy(self.texture, null, null);
    }

    pub fn deinit(self: *Engine) void {
        const allocator = self.gpa.allocator();
        allocator.free(self.pixel_buffer);
        allocator.free(self.background_buffer);
        allocator.free(self.sky_buffer);

        self.texture.destroy();
        self.renderer.destroy();
        self.window.destroy();
        SDL.quit();

        self.arena.deinit();
        _ = self.gpa.deinit();
    }
};
