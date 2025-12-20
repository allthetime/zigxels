// pixels.zig
const std = @import("std");
const SDL = @import("sdl2");
const ecs = @import("zflecs");

const Dimensions = struct {
    width: usize,
    height: usize,
};

const windowDimensions = Dimensions{
    .width = 640,
    .height = 480,
};

const Input = struct {
    mouse_x: ?i32,
    mouse_y: ?i32,
    pressing: bool,
};

// --- 1. Components (Pure Data) ---
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Rectangle = struct { w: f32, h: f32, color: SDL.Color };
const Target = struct { x: f32, y: f32 };

fn move_system(positions: []Position, velocities: []Velocity) void {
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.x;
        pos.y += vel.y;

        const width = @as(f32, @floatFromInt(windowDimensions.width));
        const height = @as(f32, @floatFromInt(windowDimensions.height));

        pos.x = clamp(f32, pos.x, 0.0, width);
        pos.y = clamp(f32, pos.y, 0.0, height);
    }
}

fn clamp(comptime T: type, value: T, min: T, max: T) T {
    return @max(min, @min(value, max));
}

fn seek_system(it: *ecs.iter_t, positions: []Position, velocities: []Velocity, targets: []Target) void {
    const dt = it.delta_time;
    for (positions, velocities, targets) |pos, *vel, target| {
        const dx = target.x - pos.x;
        const dy = target.y - pos.y;
        const dist = @sqrt(dx * dx + dy * dy);

        // If we are further than 2 pixels away, move towards target
        if (dist > 2.0) {
            const speed: f32 = 500.0;
            vel.x = (dx / dist) * speed * dt;
            vel.y = (dy / dist) * speed * dt;
        } else {
            vel.x = 0;
            vel.y = 0;
        }
    }
}

pub fn main() !void {

    // Initialize SDL
    try initSDL();
    defer SDL.quit();

    // Create window
    var window = try createWindow(windowDimensions);
    defer window.destroy();

    // Create renderer
    var renderer = try initRenderer(window);
    defer renderer.destroy();

    // Create texture
    var texture = try createTexture(renderer, windowDimensions);
    defer texture.destroy();

    // Set texture pixel data
    const pixel_buffer = try std.heap.page_allocator.alloc(u32, windowDimensions.width * windowDimensions.height);
    defer std.heap.page_allocator.free(pixel_buffer);

    // Fill pixel buffer with a gradient
    makeGradient(pixel_buffer, windowDimensions, null);

    // Initialize ECS world
    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, Rectangle);
    ecs.COMPONENT(world, Target);

    // Register systems
    _ = ecs.ADD_SYSTEM(world, "seek system", ecs.OnUpdate, seek_system);
    _ = ecs.ADD_SYSTEM(world, "move system", ecs.OnUpdate, move_system);

    const player = ecs.new_entity(world, "Player");
    _ = ecs.set(world, player, Position, .{ .x = 100.0, .y = 100.0 });
    _ = ecs.set(world, player, Velocity, .{ .x = 1.0, .y = 2.0 });
    _ = ecs.set(world, player, Rectangle, .{ .w = 50.0, .h = 50.0, .color = SDL.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    _ = ecs.progress(world, 0);

    // Main loop

    var input = Input{
        .mouse_x = null,
        .mouse_y = null,
        .pressing = false,
    };

    var cursor_size: f32 = 20.0;
    var dragPoint: ?@Vector(2, i32) = null;

    var last_time = SDL.getTicks64();

    mainLoop: while (true) {
        const dt = calculateDeltaTime(&last_time);
        // _ = dt; // Currently unused, but can be used for time-based updates

        if (!handleInput(&input, &dragPoint)) break :mainLoop;
        try clearBackground(renderer);

        // const shifts = if (dragPoint) |dp| getShiftsForDragPoint(dp, windowDimensions) else .{ 0, 0 };
        // makeGradient(pixel_buffer, windowDimensions, shifts);

        try updateTexture(texture, pixel_buffer, windowDimensions);
        try renderer.copy(texture, null, null);

        _ = ecs.progress(world, dt);
        const player_position = ecs.get(world, player, Position).?;
        const player_rectangle = ecs.get(world, player, Rectangle).?;
        try renderer.setColorRGBA(player_rectangle.color.r, player_rectangle.color.g, player_rectangle.color.b, player_rectangle.color.a);
        try renderer.fillRect(.{
            .x = f32_to_i32(player_position.x) - @divTrunc(f32_to_i32(player_rectangle.w), 2),
            .y = f32_to_i32(player_position.y) - @divTrunc(f32_to_i32(player_rectangle.h), 2),
            .width = f32_to_i32(player_rectangle.w),
            .height = f32_to_i32(player_rectangle.h),
        });

        if (dragPoint) |dp| {
            _ = ecs.set(world, player, Target, .{ .x = @as(f32, @floatFromInt(dp[0])), .y = @as(f32, @floatFromInt(dp[1])) });
        }

        const cursorSize = updateCursorSize(input.pressing, &cursor_size);
        try renderMouseCursor(renderer, &input, cursorSize);

        renderer.present();
    }
}

fn calculateDeltaTime(last_time: *u64) f32 {
    const now = SDL.getTicks64();
    const dt = @as(f32, @floatFromInt(now - last_time.*)) / 1000.0;
    last_time.* = now;
    return dt;
}

fn getShiftsForDragPoint(dragPoint: ?@Vector(2, i32), dimensions: Dimensions) @Vector(2, usize) {
    const shift_x: usize = dimensions.width - @as(usize, @intCast(dragPoint.?[0])) % dimensions.width;
    const shift_y: usize = dimensions.height - @as(usize, @intCast(dragPoint.?[1])) % dimensions.height;
    return .{ shift_x, shift_y };
}

fn updateTexture(texture: SDL.Texture, pixel_buffer: []u32, comptime dimensions: Dimensions) !void {
    try texture.update(
        std.mem.sliceAsBytes(pixel_buffer),
        dimensions.width * @sizeOf(u32), // Pitch (bytes per row)
        .{
            .x = 0,
            .y = 0,
            .width = dimensions.width,
            .height = dimensions.height,
        },
    );
}

fn makeGradient(pixel_buffer: []u32, comptime dimensions: Dimensions, shift: ?@Vector(2, usize)) void {
    for (pixel_buffer, 0..) |*pixel, index| {
        const x = if (shift) |s| (index % dimensions.width + s[0]) % dimensions.width else index % dimensions.width;
        const y = if (shift) |s| (index / dimensions.width + s[1]) % dimensions.height else index / dimensions.width;
        const r: u8 = @intCast((x * 255) / dimensions.width);
        const g: u8 = @intCast((y * 255) / dimensions.height);
        const b: u8 = 0x80;
        // Pack RGBA values into a 32-bit pixel format (RGBA8888)
        // Each color component is 8 bits, arranged as: [R][G][B][A]
        // - r (red) shifted left 24 bits to occupy bits 31-24
        // - g (green) shifted left 16 bits to occupy bits 23-16
        // - b (blue) shifted left 8 bits to occupy bits 15-8
        // - 0xFF (alpha=255) occupies bits 7-0 for full opacity
        pixel.* = (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }
}

fn clearBackground(renderer: SDL.Renderer) !void {
    try renderer.setColorRGB(0xF7, 0xA4, 0x1D);
    try renderer.clear();
}

fn updateCursorSize(pressing: bool, current: *f32) i32 {
    const target: f32 = if (pressing) 5 else 10;
    const delta = lerp_delta(current.*, target, 0.1);
    current.* += delta;
    return f32_to_i32(current.*);
}

fn f32_to_i32(value: f32) i32 {
    return @as(i32, @intFromFloat(value));
}

/// Linear interpolation helper function
fn lerp_delta(current: f32, target: f32, time: f32) f32 {
    return (target - current) * time;
}

fn renderMouseCursor(renderer: SDL.Renderer, input: *Input, size: i32) !void {
    try renderer.setDrawBlendMode(.blend);
    try renderer.setColorRGBA(0xff, 0x00, 0x00, 0xAA);
    try renderer.fillRect(.{
        .x = if (input.mouse_x) |x| x - @divTrunc(size, 2) else 0 - @divTrunc(size, 2),
        .y = if (input.mouse_y) |y| y - @divTrunc(size, 2) else 0 - @divTrunc(size, 2),
        .width = size,
        .height = size,
    });
}

fn handleInput(input: *Input, dragPoint: *?@Vector(2, i32)) bool {
    while (SDL.pollEvent()) |e| {
        switch (e) {
            .quit => return false,
            .mouse_motion => |me| {
                input.mouse_x = me.x;
                input.mouse_y = me.y;
                if (input.pressing) {
                    dragPoint.* = .{ @max(0, @min(me.x, windowDimensions.width)), @max(0, @min(me.y, windowDimensions.height)) };
                    // std.debug.print("{}\n", .{dragPoint.*});
                }
            },
            .mouse_button_down => |mbe| {
                if (mbe.state == .pressed and mbe.button == .left) {
                    input.pressing = true;
                    dragPoint.* = .{ @max(0, @min(mbe.x, windowDimensions.width)), @max(0, @min(mbe.y, windowDimensions.height)) };
                    // std.debug.print("{}\n", .{dragPoint.*});

                }
            },
            .mouse_button_up => |mbe| {
                if (mbe.state == .released and mbe.button == .left) {
                    input.pressing = false;
                }
            },
            else => {},
        }
    }
    return true;
}

/// initialize SDL instance with video, audio, events, and timer subsystems
fn initSDL() !void {
    try SDL.init(.{
        .audio = true,
        .events = true,
        .video = true,
        .timer = true,
    });
    _ = try SDL.showCursor(false);
}

/// create game window (fixed size edit here)
fn createWindow(comptime dimensions: Dimensions) !SDL.Window {
    return try SDL.createWindow(
        "PIXELS",
        .{ .centered = {} },
        .{ .centered = {} },
        dimensions.width,
        dimensions.height,
        .{
            .vis = .shown,
        },
    );
}

fn initRenderer(window: SDL.Window) !SDL.Renderer {
    return try SDL.createRenderer(
        window,
        null,
        .{
            .accelerated = true,
            .present_vsync = true,
        },
    );
}

fn createTexture(renderer: SDL.Renderer, comptime dimensions: Dimensions) !SDL.Texture {
    return try SDL.createTexture(
        renderer,
        .rgba8888,
        .streaming,
        dimensions.width,
        dimensions.height,
    );
}
